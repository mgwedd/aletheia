#!/bin/bash
# Reminds Claude, once, to check the acceptance criteria when a feat/fix commit
# changes the app but no criterion or acceptance/UI test.
# Retrying the same commit goes through: not every fix needs a criterion.
# See .claude/rules/acceptance-tests.md.
cmd=$(jq -r '.tool_input.command // ""')
[[ "$cmd" =~ (^|[[:space:];\&|])git([[:space:]].*)?[[:space:]]commit([[:space:]]|$) ]] || exit 0
[[ "$cmd" == *--amend* ]] && exit 0
grep -qE '(-m[[:space:]]+["'"'"']?|^)(feat|fix)(\([^)]*\))?!?:' <<<"$cmd" || exit 0

if [[ "$cmd" =~ [[:space:]](-a|--all|-am)([[:space:]]|$) ]]; then
  files=$(git diff HEAD --name-only)
else
  files=$(git diff --cached --name-only)
fi
grep -q '^Sources/App/' <<<"$files" || exit 0
grep -qE '^(docs/spec/ACCEPTANCE-CRITERIA\.md|Tests/AletheiaAcceptance/|Tests/AletheiaUITests/)' <<<"$files" && exit 0

# Remind once per set of changes.
key=$(git diff HEAD | git hash-object --stdin)
seen="$(git rev-parse --git-dir)/criteria-reminded"
grep -qx "$key" "$seen" 2>/dev/null && exit 0
echo "$key" >> "$seen"

cat >&2 <<'MSG'
Check the acceptance criteria before committing: this feat/fix changes
Sources/App but no criterion, acceptance test or UI test. If it adds a
behaviour or changes one a criterion describes, add or update the criterion
and its tests (.claude/rules/acceptance-tests.md). If not (an internal fix, or
one the existing criteria already cover), run the same commit again.
MSG
exit 2
