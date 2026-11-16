extends Node
## Floating origin (PLAN 2.1). World = local + offset. Scene nodes live in local coords.

signal shifted(d: Vector3)

const THRESHOLD: float = 2048.0
const STEP: float = 1024.0

var offset: Vector3 = Vector3.ZERO
var shifts: int = 0


func to_world(local: Vector3) -> Vector3:
	return local + offset


func to_local(world: Vector3) -> Vector3:
	return world - offset


## Call from a physics frame with the car's local position; shifts by whole tiles when far out.
func maybe_shift(local: Vector3) -> bool:
	if maxf(absf(local.x), absf(local.z)) <= THRESHOLD:
		return false
	var d: Vector3 = Vector3(roundf(local.x / STEP) * STEP, 0.0, roundf(local.z / STEP) * STEP)
	offset += d
	shifts += 1
	shifted.emit(d)
	return true


func reset() -> void:
	offset = Vector3.ZERO
	shifts = 0
