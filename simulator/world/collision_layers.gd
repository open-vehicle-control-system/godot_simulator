class_name CollisionLayers
extends RefCounted
## The physics layers of the world: what the vehicle rests on, and what stops its body.

## What stands on the ground: every body's layer unless it says otherwise.
const OBSTACLES := 1
## The ground's height grid: the wheels' rays find it; the body touches it only off its
## wheels.
const GROUND := 1 << 1
## The vehicle's body: its own wheels' rays never find it.
const VEHICLE := 1 << 2
