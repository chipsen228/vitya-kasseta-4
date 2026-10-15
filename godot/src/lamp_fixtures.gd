## Крепление, корпус и световой якорь наружной лампы в одном месте.
class_name LampFixtures
extends RefCounted

const BODY_RADIUS := 0.18
const BODY_BELOW := 0.060
const BODY_ABOVE := 0.15
const SPECS := {
	"porch": {"kind": "beam", "anchor": Vector3(-2.30, 2.58, 6.30),
		"mount": Vector3(-2.30, 2.88, 6.30), "floor_y": 0.36},
	"office-porch": {"kind": "wall", "anchor": Vector3(-28.95, 2.20, -7.20),
		"mount": Vector3(-28.95, 2.43, -7.51), "floor_y": 0.12},
	"stop": {"kind": "beam", "anchor": Vector3(-42.60, 2.16, -6.60),
		"mount": Vector3(-42.60, 2.30, -6.60), "floor_y": 0.10},
	"booth": {"kind": "wall", "anchor": Vector3(22.55, 2.42, -8.35),
		"mount": Vector3(22.55, 2.60, -8.61), "floor_y": 0.02},
	"lane-pole": {"kind": "pole", "anchor": Vector3(-28.60, 3.10, -16.20),
		"mount": Vector3(-29.30, 0, -16.20), "wire_to": Vector3(0.20, 4.80, -16.20), "floor_y": 0.02},
	"lane-pole-2": {"kind": "pole", "anchor": Vector3(0.90, 3.10, -16.20),
		"mount": Vector3(0.20, 0, -16.20), "floor_y": 0.02},
	"barn-gate": {"kind": "pole", "anchor": Vector3(-36.30, 3.20, -25.60),
		"mount": Vector3(-37.10, 0, -25.60), "wire_to": Vector3(-19.30, 4.80, -24.60), "floor_y": 0.02},
	"pump-lane": {"kind": "pole", "anchor": Vector3(-18.50, 3.10, -24.60),
		"mount": Vector3(-19.30, 0, -24.60), "floor_y": 0.02},
	"hen-yard": {"kind": "pole", "anchor": Vector3(-7.20, 2.20, -26.60),
		"mount": Vector3(-8.05, 0, -26.60), "wire_to": Vector3(-19.30, 4.80, -24.60), "floor_y": 0.02},
	"snt-gate": {"kind": "beam", "anchor": Vector3(36.80, 2.83, -35.25),
		"mount": Vector3(36.80, 3.12, -35.25), "floor_y": 0.02},
	"snt-lane": {"kind": "pole", "anchor": Vector3(13.55, 3.10, -47.00),
		"mount": Vector3(14.55, 0, -47.00), "wire_to": Vector3(36.80, 3.12, -35.25), "floor_y": 0.02},
	"snt-booth": {"kind": "wall", "anchor": Vector3(7.10, 2.30, -69.02),
		"mount": Vector3(7.10, 2.42, -69.26), "floor_y": 0.02},
}


static func apply(lamps: Array) -> void:
	for lamp: Dictionary in lamps:
		var id := String(lamp["id"])
		if not SPECS.has(id):
			continue
		var spec: Dictionary = SPECS[id].duplicate(true)
		if id == "porch":
			spec["anchor"] = lamp["pos"]
			spec["mount"] = (lamp["pos"] as Vector3) + Vector3(0, 0.26, 0)
			spec["floor_y"] = float(GameData.site()["Y"]["FLOOR1"])
		lamp["fixture"] = spec
		lamp["pos"] = spec["anchor"]
		lamp["cord"] = false
		lamp["shade"] = false


static func body_bounds(anchor: Vector3) -> AABB:
	return AABB(anchor - Vector3(BODY_RADIUS, BODY_BELOW, BODY_RADIUS),
		Vector3(BODY_RADIUS * 2.0, BODY_BELOW + BODY_ABOVE, BODY_RADIUS * 2.0))


static func append(st: SurfaceTool, lamp: Dictionary) -> void:
	var spec: Dictionary = lamp.get("fixture", {})
	if spec.is_empty():
		return
	var p: Vector3 = spec["anchor"]
	var mount: Vector3 = spec["mount"]
	match String(spec["kind"]):
		"pole":
			_rod(st, mount, Vector3(mount.x, 4.85, mount.z), 0.095, 8)
			_rod(st, Vector3(mount.x, p.y + 0.36, mount.z), p + Vector3(0, 0.20, 0), 0.032, 6)
			_rod(st, Vector3(mount.x, p.y - 0.10, mount.z), p + Vector3(0, 0.20, 0), 0.018, 5)
			_rod(st, p + Vector3(0, 0.20, 0), p + Vector3(0, 0.12, 0), 0.024, 5)
			# Провод на изоляторе и спуск по столбу.
			_rod(st, Vector3(mount.x + 0.10, p.y + 0.28, mount.z),
				Vector3(mount.x + 0.10, 4.86, mount.z), 0.007, 4)
			if spec.has("wire_to"):
				var start := Vector3(mount.x, 4.80, mount.z)
				var end: Vector3 = spec["wire_to"]
				var last := start
				for i in range(1, 9):
					var t := float(i) / 8.0
					var next := start.lerp(end, t) + Vector3.DOWN * sin(t * PI) * 0.26
					_rod(st, last, next, 0.007, 4)
					last = next
		"wall", "beam":
			_rod(st, mount, p + Vector3(0, 0.13, 0), 0.025, 6)
			_box(st, Vector3(0.16, 0.20, 0.06), mount)
	# Стальной колпак открыт снизу. Вся колба радиуса .048 внутри корпуса.
	var shell := CylinderMesh.new()
	shell.top_radius = 0.08
	shell.bottom_radius = BODY_RADIUS
	shell.height = BODY_ABOVE + BODY_BELOW
	shell.radial_segments = 10
	shell.rings = 1
	shell.cap_bottom = false
	st.append_from(shell, 0, Transform3D(Basis.IDENTITY, p + Vector3(0, (BODY_ABOVE - BODY_BELOW) * 0.5, 0)))
	st.append_from(shell, 0, Transform3D(Basis.IDENTITY.scaled(Vector3(-1, 1, 1)), p + Vector3(0, (BODY_ABOVE - BODY_BELOW) * 0.5, 0)))


static func _rod(st: SurfaceTool, start: Vector3, end: Vector3, radius: float, segments: int) -> void:
	var delta := end - start
	if delta.length_squared() < 0.000001:
		return
	var mesh := CylinderMesh.new()
	mesh.top_radius = radius
	mesh.bottom_radius = radius
	mesh.height = delta.length()
	mesh.radial_segments = segments
	mesh.rings = 1
	var up := delta.normalized()
	var right := up.cross(Vector3.FORWARD).normalized()
	if right.length_squared() < 0.001:
		right = up.cross(Vector3.RIGHT).normalized()
	var basis := Basis(right, up, right.cross(up)).orthonormalized()
	st.append_from(mesh, 0, Transform3D(basis, (start + end) * 0.5))


static func _box(st: SurfaceTool, size: Vector3, at: Vector3) -> void:
	var mesh := BoxMesh.new()
	mesh.size = size
	st.append_from(mesh, 0, Transform3D(Basis.IDENTITY, at))
