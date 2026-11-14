---
id: TASK-32
title: Find why a recorded segmentation differs by a few pixels between two runs
status: Done
assignee: []
created_date: '2026-11-14 21:31'
updated_date: '2026-11-14 23:27'
labels: []
dependencies: []
ordinal: 32000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Two --record runs of the same drive write identical poses, depth and disparity, but about one segmentation frame in fifty differs: four or eight pixels (whole 2x2 blocks) of a surface that carries a label pass (building, structure) are unlabelled in one run and labelled in the other, at pixels whose depth is the same in both. Seen on Spa and Mettet (ovcs1, 1280x720), not on the generated scene of tests/rendered/test_record.gd. Ruled out: the tiles' loading pace (TilesAtOnce), a delay after tile loads, the depth test between a surface and its label (the label is drawn nearer and writes no depth). Not ruled out: the renderer skipping a draw whose pipeline is still compiling, something transparent and unlabelled drawn over the label, the order of draws.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Two --record runs on Spa and on Mettet write identical segmentation files over 60 simulated seconds
<!-- AC:END -->
