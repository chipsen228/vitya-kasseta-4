# Физические тела мира для капсулы игрока (Jolt, слой 1).
#
# Источник правды по коллизиям — CollisionWorld: по нему ходят навграф, дед и
# интеракции. Jolt получает ТЕ ЖЕ коробки только ради move_and_slide игрока —
# любое расхождение наборов означало бы, что игрок и дед живут в разных домах.
# Поэтому здесь нет своей геометрии: всё читается из CollisionWorld через
# box_shape_d (повёрнутые скаты и пандусы обязаны попасть в Jolt повёрнутыми,
# объемлющий AABB сделал бы лестницы стеной).
#
# Активность (двери, ворота, скрытая динамика реквизита) не отслеживается сама:
# после col.set_blocker_active или props.rebuild_collision зовите sync() —
# формы не пересоздаются, переключается только disabled; если набор реквизита
# пересобрался с другим числом коробок, набор форм строится заново.
class_name PhysicsBodies
extends Node3D

var _col: CollisionWorld
var _bodies: Array[StaticBody3D] = []
var _shapes: Array = []		# set_id -> Array[CollisionShape3D]


func build(col: CollisionWorld) -> void:
	_col = col
	for set_id in CollisionWorld.SET_COUNT:
		var body := StaticBody3D.new()
		body.name = "set_%d" % set_id
		body.collision_layer = 1
		body.collision_mask = 0
		add_child(body)
		_bodies.append(body)
		_shapes.append([])
		_fill(set_id)


func sync() -> void:
	for set_id in CollisionWorld.SET_COUNT:
		var list: Array = _shapes[set_id]
		if list.size() != _col.box_count(set_id):
			for cs: CollisionShape3D in list:
				cs.queue_free()
			_shapes[set_id] = []
			_fill(set_id)
			continue
		for idx in list.size():
			(list[idx] as CollisionShape3D).disabled = not _col.is_box_active(set_id, idx)


func _fill(set_id: int) -> void:
	var body := _bodies[set_id]
	var list: Array = _shapes[set_id]
	for idx in _col.box_count(set_id):
		var s := _col.box_shape_d(set_id, idx)	# ось, угол, центр xyz, полуразмеры xyz
		var shape := BoxShape3D.new()
		shape.size = Vector3(s[5] * 2.0, s[6] * 2.0, s[7] * 2.0)
		var cs := CollisionShape3D.new()
		cs.shape = shape
		var xf := Transform3D(Basis.IDENTITY, Vector3(s[2], s[3], s[4]))
		match int(s[0]):
			CollisionWorld.AXIS_X:
				xf.basis = Basis(Vector3.RIGHT, s[1])
			CollisionWorld.AXIS_Y:
				xf.basis = Basis(Vector3.UP, s[1])
			CollisionWorld.AXIS_Z:
				xf.basis = Basis(Vector3.BACK, s[1])
		cs.transform = xf
		cs.disabled = not _col.is_box_active(set_id, idx)
		body.add_child(cs)
		list.append(cs)
