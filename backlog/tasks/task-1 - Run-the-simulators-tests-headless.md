---
id: TASK-1
title: Run the simulator's tests headless
status: Done
assignee:
  - '@claude'
created_date: '2026-11-14 08:47'
updated_date: '2026-11-14 08:49'
labels: []
dependencies: []
ordinal: 1000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
A GDScript test runner in the repository runs every tests/test_*.gd under godot --headless and exits non-zero on a failure, so the checks run without the editor or a third-party add-on.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [x] #1 mise run test runs every test script headless and fails on a failing assertion
- [x] #2 A failing test names its script, test and the assertion that failed
<!-- AC:END -->
