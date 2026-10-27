---
paths:
  - "Sources/**"
  - "Tests/AletheiaAcceptance/**"
  - "Tests/AletheiaUITests/**"
  - "docs/spec/**"
---

# Acceptance criteria and UI tests

`docs/spec/ACCEPTANCE-CRITERIA.md` holds the product's requirements. The
acceptance tests (`Tests/AletheiaAcceptance`) and XCUI tests
(`Tests/AletheiaUITests`) are those requirements in executable form. Green CI,
including the Acceptance and UI tests checks, means the product meets them.
See `docs/spec/EXECUTION-LAYER.md` for how the layers fit together.

## Every feature ships all three

A new feature, or a substantial change to one, is not done without:

1. An acceptance criterion, written first, in product words, with a stable ID.
2. An acceptance test named after that ID (`test_EXPORT_07`).
3. An XCUI test named after that ID that drives the real app the way a user
   would.

## Tests assert the requirement, not the code

- A test checks what its criterion says, not what the code happens to do. It
  may stay red until the feature meets the criterion; don't mark it as an
  expected failure.
- When a test fails because its setup is broken, fix the setup. Never loosen
  the check to get green.

## Refactors must not touch acceptance or UI tests

Criteria are the fixed rules of the product. They change only when the product
requirement changes, so their tests should too.

- Tests talk only to the DSL and driver (Given, When, Then). They never name an
  app type, view, file layout or function.
- The harness under the DSL and driver (fixture mode, probes, launch setup,
  element lookups) is expected to need small adjustments as the implementation
  changes. That is its job.
- Anything more than that is a warning sign. If reorganizing code without
  changing behaviour forces edits to acceptance or UI test bodies, or large
  rewrites of the DSL or driver, the tests are coupled to internals. Move the
  coupling down into the harness so the test bodies stay as written.
- When reviewing a diff, flag edits to test bodies that a changed criterion
  doesn't explain, and harness churn out of proportion to the code change.
- Unit tests (`Tests/AletheiaTests`) are free to change with internals.
