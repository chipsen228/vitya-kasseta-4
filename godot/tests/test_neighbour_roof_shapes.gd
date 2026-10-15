extends SceneTree

func _initialize() -> void:
	var mats := Materials.new().load_all()
	var col := CollisionWorld.new()
	var world := Node3D.new()
	WorldBuilder.build(world, mats, col)
	var found := 0
	for group: Dictionary in GameData.site()["NEIGHBOURS"]:
		for house: Array in group["houses"]:
			var x := float(house[0])
			var z := float(house[1])
			var width := float(house[2]) + 0.6
			var run := float(house[3]) * 0.5 + 0.3
			var height := float(house[4]) + 0.65
			for side: float in [-1.0, 1.0]:
				var expected := PackedFloat64Array([CollisionWorld.AXIS_X,
					side * atan2(1.3, run), x, height, z + side * run * 0.5,
					width * 0.5, 0.07, sqrt(run * run + 1.3 * 1.3) * 0.5])
				var matches := 0
				for index in col.box_count(CollisionWorld.SET_STATIC):
					var actual := col.box_shape_d(CollisionWorld.SET_STATIC, index)
					var same := true
					for component in expected.size():
						if absf(actual[component] - expected[component]) > 0.00001:
							same = false
					if same:
						matches += 1
				assert(matches == 1, "neighbour roof moved/resized/rotated: %s" % expected)
				found += 1
	assert(found == 18)
	world.free()
	print("test_neighbour_roof_shapes: PASS (18 positions, half sizes and rotations)")
	quit(0)
