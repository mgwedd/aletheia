#!/usr/bin/env bash
# Theme guard: screens take every color from `Theme` (CLAUDE.md, Conventions).
#
#   Sources/App/Views/**/*.swift  ──grep──▶  system color?  ──▶  fail
#   (except Views/Theme/, which defines the tokens)
#
# System colors (`.secondary`, `.orange`, `Color.red`, `.accentColor`,
# `NSColor.labelColor`, `Color(nsColor:)`, `Color(red:…)`, `.white`/`.black` as a
# style) ignore the app's palette and its Increase Contrast variants, so a screen
# that uses one drifts from the design in one appearance or another.
#
# Escape hatch for a deliberate fixed color (e.g. an opaque export surface): end
# the line with `// theme-lint: allow <reason>`.
#
# Pure bash/grep/sed, so it runs on the Linux CI runner and on a Mac alike.
# Usage: scripts/check-theme-colors.sh [--self-test] [dir]   (from anywhere)

set -euo pipefail
cd "$(dirname "$0")/.."

PATTERN='\.(secondary|tertiary|quaternary|red|orange|yellow|green|blue|gray|accentColor)\b|Color\.(primary|secondary|red|orange|yellow|green|blue|gray|accentColor|white|black)\b|NSColor\.[a-z]|Color\(nsColor|Color\((red|white|hue):|\b(foregroundStyle|foregroundColor|fill|background|tint|stroke|strokeBorder)\(\.(primary|white|black)\b'

# Prints `file:line: code` for each offending line under $1.
scan() {
    local root=$1
    find "$root" -name '*.swift' -not -path '*/Theme/*' -print0 | sort -z |
        while IFS= read -r -d '' file; do
            local n=0 line code
            while IFS= read -r line || [ -n "$line" ]; do
                n=$((n + 1))
                case "$line" in *"theme-lint: allow"*) continue ;; esac
                # Drop `//` comments (prose may name a color) and switch arms
                # over app enums that merely share a color's name (`case .red:`).
                code=$(printf '%s' "$line" | sed -e 's#//.*$##')
                printf '%s' "$code" | grep -qE '^[[:space:]]*case[[:space:]]+\.' && continue
                if printf '%s' "$code" | grep -qE "$PATTERN"; then
                    printf '%s:%d: %s\n' "$file" "$n" "$(printf '%s' "$line" | sed -e 's/^[[:space:]]*//')"
                fi
            done < "$file"
        done
}

self_test() {
    local dir
    dir=$(mktemp -d)
    trap 'rm -rf "$dir"' RETURN
    mkdir -p "$dir/Theme"
    cat > "$dir/Bad.swift" <<'EOF'
Text("a").foregroundStyle(.secondary)
Image("b").foregroundColor(.orange)
let c = Color.red
let d = NSColor.labelColor
let e = Color(nsColor: .windowBackgroundColor)
Rectangle().fill(.white)
Text("f").tint(.accentColor)
EOF
    cat > "$dir/Good.swift" <<'EOF'
Text("a").foregroundStyle(Theme.muted.color)
// Prose that names .secondary and Color.red is fine.
case .green: return Theme.accent.color
Button("Delete", role: .destructive) {}
.background(Color.white) // theme-lint: allow opaque PNG export surface
let url = "https://example.com"
EOF
    cat > "$dir/Theme/Tokens.swift" <<'EOF'
static let fallback = Color.red
EOF
    local out bad
    out=$(scan "$dir")
    bad=$(printf '%s\n' "$out" | grep -c '/Bad.swift:' || true)
    if [ "$bad" -ne 7 ]; then
        echo "self-test: expected 7 hits in Bad.swift, got $bad" >&2
        printf '%s\n' "$out" >&2
        return 1
    fi
    if printf '%s\n' "$out" | grep -qE '/(Good|Theme/Tokens)\.swift:'; then
        echo "self-test: false positive:" >&2
        printf '%s\n' "$out" | grep -E '/(Good|Theme/Tokens)\.swift:' >&2
        return 1
    fi
    echo "check-theme-colors: self-test passed"
}

if [ "${1:-}" = "--self-test" ]; then
    self_test
    exit
fi

hits=$(scan "${1:-Sources/App/Views}")
if [ -n "$hits" ]; then
    printf '%s\n' "$hits" >&2
    echo "check-theme-colors: $(printf '%s\n' "$hits" | wc -l | tr -d ' ') system color use(s) in screens; use a Theme token (Sources/App/Views/Theme) or mark a deliberate fixed color with '// theme-lint: allow <reason>'." >&2
    exit 1
fi
echo "check-theme-colors: ok"
