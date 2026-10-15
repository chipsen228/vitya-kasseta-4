## Read-only replay of original and approved shape14 snapshots; no world or rendering.
extends SceneTree
const OUTPUT := "C:/Users/Peter Zakharov/Desktop/vitya-godot/output/environment-refresh/"

func _initialize() -> void:
	var report: Dictionary={"cases":[],"runtime_cabinet_built":false,"new_physics_added":false,"probe_y":.90,"gap_min":.90}
	for phase: String in ["before","after"]:
		var source: Dictionary=JSON.parse_string(FileAccess.get_file_as_string(OUTPUT+phase+"/physics.json"))
		var col:=CollisionWorld.new()
		for set_id in CollisionWorld.SET_COUNT:
			var values:=PackedFloat64Array()
			var bits:=PackedByteArray()
			for row: Dictionary in source["sets"][set_id]:
				values.append_array(PackedFloat64Array(row["shape"]))
				bits.append(1 if row["active"] and row["id"]!="door-office" else 0)
			col._data[set_id]=values;col._active[set_id]=bits;col._dirty[set_id]=true
		for x: float in [-15.0,-15.75,-16.75]:
			var y: float=col.ray_down(x,.55,-40.85,CollisionWorld.ALL_SOLID).get("y",-999)
			var small:=_fits(col,x,-40.85,y,.30)
			var wide:=_fits(col,x,-40.85,y,.45)
			var gap:=_span(col,x,-40.85,y)
			var row: Dictionary={"phase":phase,"at":[x,y,-40.85],"fits_r030":small,"fits_r045":wide,"sampled_z_gap":gap}
			report["cases"].append(row)
			print("REACH CELL ",JSON.stringify(row))
	var file:=FileAccess.open(OUTPUT+"reachable-cells-capsules.json",FileAccess.WRITE)
	file.store_string(JSON.stringify(report,"\t"));file.close()
	quit(0)

func _fits(col: CollisionWorld,x: float,z: float,y: float,r: float) -> bool:
	if col.point_hit(x,y+.9,z,CollisionWorld.ALL_SOLID): return false
	for mask: int in [1,4,2,8]:
		var hit:=col.capsule_hit_d(x,y+r+.03,z,x,y+1.78-r,z,r,mask)
		if not hit.is_empty() and float(hit["depth"])>.06 and absf(float(hit["ny"]))<.5: return false
	return true

func _span(col: CollisionWorld,x: float,z: float,y: float) -> float:
	var total:=0.0
	for sign: float in [1.0,-1.0]:
		var d:=.05
		var hit:=false
		while d<=1.6:
			if col.point_hit(x,y+.9,z+sign*d,CollisionWorld.ALL_SOLID): hit=true;break
			d+=.05
		if not hit: return 1e9
		total+=d
	return total
