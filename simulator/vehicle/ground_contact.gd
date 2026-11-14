class_name GroundContact
extends RefCounted
## How a vehicle rests on the ground under its four wheels. Pure.
##
## The body follows the plane through the wheels' contacts: its pitch from front against rear,
## its roll from left against right. Each wheel then rises or drops, within the suspension's
## travel, to touch its own contact where the ground is not one plane.

## How far a wheel moves up or down from its rest position on the body.
const SUSPENSION_TRAVEL_M := 0.1


static func fit(origin: Vector3, contacts: Array[Vector3]) -> Dictionary:
	## `pose`: the body's transform, its origin on the contact plane below `origin`, and
	## `wheel_lifts_m`: how far each wheel rises above its rest position (negative: drops).
	## `contacts` are where the front left, front right, rear left and rear right wheels touch
	## the ground.
	var front := (contacts[0] + contacts[1]) * 0.5
	var rear := (contacts[2] + contacts[3]) * 0.5
	var left := (contacts[0] + contacts[2]) * 0.5
	var right := (contacts[1] + contacts[3]) * 0.5
	var forward := (front - rear).normalized()
	var up := forward.cross((left - right).normalized()).normalized()
	var sideways := up.cross(forward)
	var centre := (front + rear) * 0.5
	var on_plane := Vector3(
		origin.x,
		centre.y - ((origin.x - centre.x) * up.x + (origin.z - centre.z) * up.z) / up.y,
		origin.z
	)
	var lifts: Array[float] = []
	for contact in contacts:
		lifts.append(clampf((contact - centre).dot(up), -SUSPENSION_TRAVEL_M, SUSPENSION_TRAVEL_M))
	return {"pose": Transform3D(Basis(sideways, up, forward), on_plane), "wheel_lifts_m": lifts}
