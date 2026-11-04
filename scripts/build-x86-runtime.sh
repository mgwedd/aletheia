#!/usr/bin/env bash
# Builds the AVX2 x86_64 slice of a bundled runtime (llama.cpp or whisper.cpp)
# and swaps it into the official upstream XCFramework.
#
#   scripts/build-x86-runtime.sh llama|whisper <out-dir>
#
# Upstream's prebuilt macOS framework is one universal build, and ggml only
# turns on SIMD for a single-arch build, so its x86_64 slice has no AVX. This
# script:
#   1. downloads upstream's XCFramework zip and checks its SHA-256;
#   2. fetches the source at the pinned commit and checks that the release
#      tag points at that commit;
#   3. builds x86_64 only, with upstream's own options plus explicit x86
#      flags for Haswell and later (SSE4.2, AVX, AVX2, BMI2, FMA, F16C;
#      GGML_NATIVE off, so the build machine doesn't matter);
#   4. links the libraries into one dylib, as upstream's build-xcframework.sh
#      does, and swaps it in for the x86_64 slice with `lipo -replace`;
#   5. checks that the arm64 slice is byte-for-byte upstream's and that the
#      new x86_64 slice has AVX2/FMA code;
#   6. writes <name>-<tag>-x86avx2-xcframework.zip (upstream's zip with that
#      one file replaced) and its SHA-256, the SwiftPM checksum.
#
# The pins come from the `// upstream:` and `// upstream-zip:` lines in
# Packages/<LlamaCpp|WhisperCpp>/Package.swift. Needs Xcode, cmake and git;
# runs on Apple silicon or Intel. First-party tools only.
set -euo pipefail

usage() { echo "usage: $0 llama|whisper <out-dir>" >&2; exit 2; }
[[ $# -eq 2 ]] || usage
name="$1"
out="$2"
case "$name" in
  llama) package=Packages/LlamaCpp/Package.swift ;;
  whisper) package=Packages/WhisperCpp/Package.swift ;;
  *) usage ;;
esac

root="$(cd "$(dirname "$0")/.." && pwd)"
read -r _ _ repo tag commit < <(grep -E '^// upstream: ' "$root/$package")
read -r _ _ base_sha < <(grep -E '^// upstream-zip: ' "$root/$package")
[[ "$repo" == ggml-org/llama.cpp || "$repo" == ggml-org/whisper.cpp ]] || { echo "unexpected upstream repo: $repo" >&2; exit 1; }
[[ "$commit" =~ ^[0-9a-f]{40}$ && "$base_sha" =~ ^[0-9a-f]{64}$ ]] || { echo "bad pin in $package" >&2; exit 1; }

mkdir -p "$out"
out="$(cd "$out" && pwd)"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
echo "==> $name $tag ($commit) in $work"

# 1. Upstream XCFramework.
base_zip="$work/upstream.zip"
curl -fsSL --retry 3 -o "$base_zip" \
  "https://github.com/$repo/releases/download/$tag/$name-$tag-xcframework.zip"
got="$(shasum -a 256 "$base_zip" | cut -c1-64)"
[[ "$got" == "$base_sha" ]] || { echo "upstream zip SHA-256 $got, pinned $base_sha" >&2; exit 1; }

# 2. Source at the pinned commit; the tag must name the same commit.
tagged="$(git ls-remote "https://github.com/$repo.git" "refs/tags/$tag" "refs/tags/$tag^{}" | awk 'END { print $1 }')"
[[ "$tagged" == "$commit" ]] || { echo "tag $tag is $tagged, pinned $commit" >&2; exit 1; }
src="$work/src"
git init -q "$src"
git -C "$src" fetch -q --depth 1 "https://github.com/$repo.git" "$commit"
git -C "$src" -c advice.detachedHead=false checkout -q FETCH_HEAD
[[ "$(git -C "$src" rev-parse HEAD)" == "$commit" ]] || { echo "checkout is not $commit" >&2; exit 1; }

# 3. Build x86_64 only. Upstream's options from build-xcframework.sh, plus
#    the x86 flags. A single-arch build is what lets ggml pick its x86 code.
# The prefix map keeps the temporary build path out of the binary (ggml's
# asserts embed source paths) and ZERO_AR_DATE keeps timestamps out of the
# archives, so the same commit builds the same slice.
flags="-Wno-macro-redefined -Wno-shorten-64-to-32 -Wno-unused-command-line-argument -g -ffile-prefix-map=$src=/src -ffile-prefix-map=$work=/work"
export ZERO_AR_DATE=1
common=(
  -G Xcode
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_REQUIRED=NO
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGN_IDENTITY=""
  -DCMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED=NO
  -DCMAKE_OSX_DEPLOYMENT_TARGET=13.3
  -DCMAKE_OSX_ARCHITECTURES=x86_64
  -DCMAKE_C_FLAGS="$flags"
  -DCMAKE_CXX_FLAGS="$flags"
  -DBUILD_SHARED_LIBS=OFF
  -DGGML_METAL=ON
  -DGGML_METAL_EMBED_LIBRARY=ON
  -DGGML_BLAS_DEFAULT=ON
  -DGGML_OPENMP=OFF
  -DGGML_NATIVE=OFF
  -DGGML_SSE42=ON -DGGML_AVX=ON -DGGML_AVX2=ON -DGGML_BMI2=ON -DGGML_FMA=ON -DGGML_F16C=ON
  -DGGML_AVX_VNNI=OFF -DGGML_AVX512=OFF -DGGML_AVX512_VBMI=OFF -DGGML_AVX512_VNNI=OFF
  -DGGML_AVX512_BF16=OFF -DGGML_AMX_TILE=OFF -DGGML_AMX_INT8=OFF -DGGML_AMX_BF16=OFF
)
build="$src/build-x86"
if [[ "$name" == llama ]]; then
  common+=(
    -DLLAMA_BUILD_APP=OFF -DLLAMA_BUILD_COMMON=OFF -DLLAMA_BUILD_EXAMPLES=OFF
    -DLLAMA_BUILD_TOOLS=OFF -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_SERVER=OFF
    -DLLAMA_BUILD_MTMD=ON -DLLAMA_OPENSSL=OFF
  )
  libs=(src/Release/libllama.a tools/mtmd/Release/libmtmd.a vendor/hash/Release/libvendor-hash.a)
  frameworks=(-framework Foundation -framework Metal -framework Accelerate)
else
  common+=(
    -DWHISPER_BUILD_EXAMPLES=OFF -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_SERVER=OFF
    -DGGML_METAL_USE_BF16=ON -DWHISPER_COREML=ON -DWHISPER_COREML_ALLOW_FALLBACK=ON
  )
  libs=(src/Release/libwhisper.a src/Release/libparakeet.a src/Release/libwhisper.coreml.a)
  frameworks=(-framework Foundation -framework Metal -framework Accelerate -framework CoreML)
fi
libs+=(
  ggml/src/Release/libggml.a ggml/src/Release/libggml-base.a ggml/src/Release/libggml-cpu.a
  ggml/src/ggml-metal/Release/libggml-metal.a ggml/src/ggml-blas/Release/libggml-blas.a
)
# SOURCE_DATE_EPOCH changes ggml's defaults; the flags above are explicit,
# but keep the configure identical wherever it runs.
env -u SOURCE_DATE_EPOCH cmake -S "$src" -B "$build" "${common[@]}" > "$out/$name-configure.log"
grep -q "GGML_SYSTEM_ARCH: x86" "$out/$name-configure.log" || { echo "ggml did not configure for x86" >&2; exit 1; }
cmake --build "$build" --config Release -j "$(sysctl -n hw.logicalcpu)" -- -quiet > "$out/$name-build.log" 2>&1 \
  || { tail -40 "$out/$name-build.log" >&2; exit 1; }

# 4. One dylib, linked the way upstream links its framework binary.
lib_paths=()
for lib in "${libs[@]}"; do
  [[ -f "$build/$lib" ]] || { echo "missing $lib" >&2; exit 1; }
  lib_paths+=("$build/$lib")
done
xcrun libtool -static -o "$work/combined.a" "${lib_paths[@]}"
xcrun -sdk macosx clang++ -dynamiclib \
  -isysroot "$(xcrun --sdk macosx --show-sdk-path)" \
  -arch x86_64 -mmacosx-version-min=13.3 \
  -Wl,-force_load,"$work/combined.a" \
  "${frameworks[@]}" \
  -install_name "@rpath/$name.framework/Versions/Current/$name" \
  -o "$work/x86_64.dylib"
xcrun strip -S "$work/x86_64.dylib" -o "$work/x86_64"
codesign --force --sign - "$work/x86_64"

# 5. Swap it into upstream's framework.
unpacked="$work/unpacked"
mkdir "$unpacked"
ditto -x -k "$base_zip" "$unpacked"
member="build-apple/$name.xcframework/macos-arm64_x86_64/$name.framework/Versions/A/$name"
binary="$unpacked/$member"
[[ -f "$binary" ]] || { echo "upstream zip has no $member" >&2; exit 1; }
lipo -thin arm64 "$binary" -output "$work/arm64.before"
lipo "$binary" -replace x86_64 "$work/x86_64" -output "$work/fat"
lipo -thin arm64 "$work/fat" -output "$work/arm64.after"
cmp -s "$work/arm64.before" "$work/arm64.after" || { echo "arm64 slice changed" >&2; exit 1; }
[[ "$(lipo -archs "$work/fat")" == *x86_64* ]] || { echo "no x86_64 slice" >&2; exit 1; }
otool -arch x86_64 -tv "$work/fat" > "$work/x86_64.s"
grep -q 'vfmadd' "$work/x86_64.s" || { echo "x86_64 slice has no FMA code" >&2; exit 1; }
grep -q 'vpmaddubsw.*%ymm' "$work/x86_64.s" || { echo "x86_64 slice has no AVX2 code" >&2; exit 1; }
[[ "$(otool -arch x86_64 -D "$work/fat" | tail -1)" == "@rpath/$name.framework/Versions/Current/$name" ]] \
  || { echo "install name differs from upstream" >&2; exit 1; }
cp "$work/fat" "$binary"

# 6. Upstream's zip with only that file replaced; a fixed mtime keeps the
#    zip the same for the same binary.
zip_name="$name-$tag-x86avx2-xcframework.zip"
cp "$base_zip" "$out/$zip_name"
TZ=UTC touch -t 202001010000 "$binary"
(cd "$unpacked" && TZ=UTC zip -q -X "$out/$zip_name" "$member")
sha="$(shasum -a 256 "$out/$zip_name" | cut -c1-64)"
echo "$sha  $zip_name" > "$out/$zip_name.sha256"
echo "x86_64 slice SHA-256: $(shasum -a 256 "$work/x86_64" | cut -c1-64)"
echo "==> $out/$zip_name"
echo "    checksum: $sha"
