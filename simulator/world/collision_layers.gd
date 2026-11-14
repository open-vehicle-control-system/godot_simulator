class_name CollisionLayers
extends RefCounted
## The physics layers of the world: what the vehicle rests on, and what stops its body.

## What stands on the ground: every body's layer unless it says otherwise.
const OBSTACLES := 1
## The ground's height grid: the wheels' rays find it, the body's sweep never does.
const GROUND := 1 << 1
