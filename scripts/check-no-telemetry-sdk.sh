#!/usr/bin/env bash
# Privacy guard: no analytics, telemetry, crash-reporting or ad SDK may be a
# dependency of the app or be imported by its sources.
#
#   dependency manifests ──▶ names a known SDK package?        ──▶ fail
#   Sources/ (swift, objc) ─▶ imports a known SDK module?       ──▶ fail
#
# Manifests scanned: Package.swift, Package.resolved, project.yml, Podfile*,
# Cartfile* (repo root and Packages/*). Sources scanned: everything under
# Sources/. Source files are matched on import statements only, so ordinary
# words in prose or identifiers never trip it.
#
# Usage: scripts/check-no-telemetry-sdk.sh [--self-test]   (from anywhere)

set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# Substrings (case-insensitive) that identify an SDK in a manifest: package
# names, repo URLs and pod/product names.
MANIFEST_RE='firebase|crashlytics|sentry|bugsnag|mixpanel|amplitude|segmentio|analytics-swift|analytics-ios|appcenter|datadog|posthog|telemetrydeck|appsflyer|adjust-ios|adjust_ios|googleanalytics|google-analytics|googlemobileads|google-mobile-ads|admob|onesignal|instabug|rollbar|countly|matomo|logrocket|newrelic|raygun|fullstory|smartlook|flurry|kochava|plcrashreporter|kscrash|honeycomb|opentelemetry|heap-ios|swift-log-datadog|statsig|launchdarkly|splitio|optimizely|hotjar|apphud|revenuecat'

# Module names (case-sensitive) as they appear in `import X` / `canImport(X)`.
MODULE_RE='(Firebase|Datadog|AppCenter|OneSignal|Kochava|OpenTelemetry|Matomo|Sentry|Bugsnag|Mixpanel|Amplitude|PostHog|TelemetryDeck|AppsFlyer|GoogleAnalytics|GoogleMobileAds|Instabug|Rollbar|Countly|NewRelic|Raygun|FullStory|Smartlook|Flurry|Honeycomb|Statsig|LaunchDarkly|Optimizely|RevenueCat)[A-Za-z0-9_]*|Crashlytics|Segment|Analytics|Adjust|MSAppCenter|CrashReporter|PLCrashReporter|KSCrash|Hotjar'
# Followed by a non-identifier character or end of line.
TAIL='([^A-Za-z0-9_]|$)'

# scan <root>; prints one line per offending file, returns 1 if any.
scan() {
    local root=$1 bad=0 f hits
    local -a manifests=()
    while IFS= read -r f; do manifests+=("$f"); done < <(
        find "$root" -maxdepth 3 \( -path '*/.build' -o -path '*/.dd*' -o -path '*/.git' \) -prune -o -type f \
            \( -name 'Package.swift' -o -name 'Package.resolved' -o -name 'project.yml' \
               -o -name 'Podfile*' -o -name 'Cartfile*' \) -print | LC_ALL=C sort)
    for f in ${manifests[@]+"${manifests[@]}"}; do
        hits=$(grep -inE "$MANIFEST_RE" "$f" | head -3 || true)
        if [ -n "$hits" ]; then
            echo "${f#"$root"/}: dependency manifest references an analytics/telemetry/crash/ad SDK:"
            echo "$hits" | sed 's/^/    /'
            bad=1
        fi
    done
    if [ -d "$root/Sources" ]; then
        hits=$(grep -rnE --include='*.swift' --include='*.m' --include='*.mm' --include='*.h' \
            -e "^[[:space:]]*(@_exported[[:space:]]+|@testable[[:space:]]+|@preconcurrency[[:space:]]+)*import[[:space:]]+((struct|class|enum|protocol|typealias|func|var|let)[[:space:]]+)?($MODULE_RE)$TAIL" \
            -e "canImport\(($MODULE_RE)$TAIL" \
            -e "^[[:space:]]*(#import|#include)[[:space:]]*[<\"]($MODULE_RE)/" \
            -e "^[[:space:]]*@import[[:space:]]+($MODULE_RE)$TAIL" \
            "$root/Sources" || true)
        if [ -n "$hits" ]; then
            echo "Sources import an analytics/telemetry/crash/ad SDK module:"
            echo "$hits" | sed "s#$root/#    #"
            bad=1
        fi
    fi
    return $bad
}

if [ "${1:-}" = "--self-test" ]; then
    t=$(mktemp -d); trap 'rm -rf "$t"' EXIT
    fail=0
    mk() { rm -rf "$t/r"; mkdir -p "$t/r/Sources/App" "$t/r/Packages/X"
           printf 'import SwiftUI\nimport Foundation\n// Sentry is prose here\nlet analyticsEnabled = false\n' > "$t/r/Sources/App/A.swift"
           printf '// swift-tools-version: 5.9\nlet deps = ["https://github.com/ggerganov/llama.cpp"]\n' > "$t/r/Package.swift"
           printf '{"pins":[{"identity":"llama.cpp"}]}\n' > "$t/r/Package.resolved"
           printf 'name: Aletheia\npackages:\n  LlamaCpp:\n    path: Packages/LlamaCpp\n' > "$t/r/project.yml"; }
    expect_fail() { # label
        scan "$t/r" >/dev/null 2>&1 && { echo "self-test: $1 was not flagged"; fail=1; } || true; }
    mk
    scan "$t/r" >/dev/null 2>&1 || { echo "self-test: clean tree was flagged"; fail=1; }
    mk; printf 'import FirebaseAnalytics\n' >> "$t/r/Sources/App/A.swift";           expect_fail "import FirebaseAnalytics"
    mk; printf '@_exported import Sentry\n' >> "$t/r/Sources/App/A.swift";           expect_fail "@_exported import Sentry"
    mk; printf '#if canImport(Mixpanel)\n#endif\n' >> "$t/r/Sources/App/A.swift";    expect_fail "canImport(Mixpanel)"
    mk; printf '#import <Bugsnag/Bugsnag.h>\n' > "$t/r/Sources/App/B.h";             expect_fail "objc #import Bugsnag"
    mk; printf '  .package(url: "https://github.com/getsentry/sentry-cocoa", from: "8.0.0")\n' >> "$t/r/Package.swift"; expect_fail "Package.swift sentry"
    mk; printf '{"identity":"posthog-ios"}\n' >> "$t/r/Package.resolved";             expect_fail "Package.resolved posthog"
    mk; printf '  TelemetryDeck:\n    url: x\n' >> "$t/r/project.yml";              expect_fail "project.yml TelemetryDeck"
    mk; printf '// swift-tools-version: 5.9\n.package(url: "https://github.com/DataDog/dd-sdk-ios")\n' > "$t/r/Packages/X/Package.swift"; expect_fail "nested Package.swift Datadog"
    [ "$fail" = 0 ] || { echo "check-no-telemetry-sdk self-test: FAILED" >&2; exit 1; }
    echo "no-telemetry-sdk guard self-test passed"; exit 0
fi

if out=$(scan "$ROOT"); then
    echo "no analytics/telemetry/crash/ad SDK OK"
else
    echo "$out" >&2
    echo "check-no-telemetry-sdk: FAILED. The app must not depend on or import such SDKs (PHI never leaves the Mac)." >&2
    exit 1
fi
