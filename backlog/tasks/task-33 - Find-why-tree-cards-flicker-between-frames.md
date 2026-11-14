---
id: TASK-33
title: Find why tree cards flicker between frames
status: To Do
assignee: []
created_date: '2026-11-14 21:46'
labels: []
dependencies: []
ordinal: 33000
---

## Description

<!-- SECTION:DESCRIPTION:BEGIN -->
Between any two frames of the same view, about 270 pixels of tree impostor cards change by 1/255, in every viewport, with or without upscaling, so stereo images are never byte-identical where trees are in view. Possibly the same cause as TASK-32 (segmentation differing by a few pixels between recording runs). Find the cause and make rendering of a still view stable.
<!-- SECTION:DESCRIPTION:END -->

## Acceptance Criteria
<!-- AC:BEGIN -->
- [ ] #1 Two frames of a still view with trees are byte-identical in every viewport, or the remaining difference is explained
- [ ] #2 The cause is documented, with a test or a capture that shows it
<!-- AC:END -->
