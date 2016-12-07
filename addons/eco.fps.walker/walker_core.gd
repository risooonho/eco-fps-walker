extends RigidBody

const UP=Vector3(0,1,0)
var current_target=null
var navmesh=null

const ANGULAR_SPEED=4
const WAYPOINT_ERROR_DELTA=2
const WAYPOINT_MAX_TIMEOUT=5

var going_backward=false
onready var target_ray=get_node("target_ray")
onready var leg_ray=get_node("leg_ray")
onready var node_yaw=get_node("yaw")
var current_direction=Vector3()
var current_waypoint=null
var current_path=null
var no_move=false
var waypoint_timeout=0
var is_temp_waypoint=false
var is_temp_side_right=false
var was_UTurn=false

const action_states=["sleep","move","turn","follow"]
var fsm_action
var current_action={
	move=true,
	follow_target=false
}

# ground sensors -----------------------
onready var ground_sensor_l=get_node("ray_ground_left")
onready var ground_sensor_r=get_node("ray_ground_right")
var old_sensor_status_l=false
var old_sensor_status_r=false

var aim_offset=Vector3(0,1.8,0)

# original -----------
const walk_speed = 3;
const max_accel = 0.02;
const air_accel = 0.05;

func _ready():
	target_ray.add_exception_rid(get_rid())
	_init_fsm()

func _init_fsm():
	fsm_action=preload("fsm.gd").new()
	fsm_action.add_state("decide")
	fsm_action.add_state("sleep",{move=false,follow=false})
	fsm_action.add_state("turn",{move=false,follow=false})
	fsm_action.add_state("move",{move=true,follow=false})
	
	fsm_action.add_state_link("sleep","decide","timeout",[0.2])
	fsm_action.add_state_link("move","decide","timeout",[2])
	fsm_action.add_state_link("turn","decide","timeout",[1])
	
	fsm_action.add_state_link("decide","sleep","condition",[self,"fsm_has_no_target",true])
	fsm_action.add_state_link("decide","move","condition",[self,"fsm_has_no_target",false])
	
	fsm_action.connect("state_changed",self,"_action_state_changed")

func _integrate_forces(state):
	
	var yaw_t=node_yaw.get_global_transform()
	if current_target!=null:
		var target_transform=target_ray.get_global_transform().looking_at(current_target.get_global_transform().origin+get_target_offset(current_target),UP).orthonormalized()
		target_ray.set_global_transform(target_transform)
	else:
		target_ray.set_rotation(Vector3(0,0,0))
	
	fsm_action.process(state.get_step())
	
	if current_waypoint!=null:
		if get_translation().distance_to(current_waypoint)<WAYPOINT_ERROR_DELTA or waypoint_timeout<=0:
			calculate_destination()
		else:
			waypoint_timeout-=state.get_step()
	
	do_current_action(state)

func do_current_action(state):
	var current_t=node_yaw.get_global_transform()
	var current_z=current_t.basis.z
	
	var aim = current_t.basis;
	var direction = Vector3();
	
	# moving
	if current_action.move and not no_move:
		#move forward
		direction -= current_z;
	
	direction = direction.normalized();
	
	# ground collision detection
	if leg_ray.is_colliding():
		# is walking on the ground
		# calculate the impulse vector for horizontal movement. Vertical velocity is kept but not amplified
		var diff = Vector3() + direction * walk_speed - state.get_linear_velocity();
		var vertdiff = aim[1] * diff.dot(aim[1]); # vertical velocity
		diff -= vertdiff; # we remove vertical velocity temporarely for working only with horizontal velocity
		diff = diff.normalized() * clamp(diff.length(), 0, max_accel / state.get_step());
		diff += vertdiff; # vertical velocity is put back
		if not no_move:
			apply_impulse(Vector3(), diff * get_mass());
		
	else:
		# is falling
		apply_impulse(Vector3(), direction * air_accel * get_mass());
	
	# set rotation

	var target_z
	if current_action.follow_target:
		# when attacking, the npc always face the target
		target_z=target_ray.get_global_transform().basis.z
	else:
		if current_waypoint!=null:
			var offset=Vector3(0,0,0)
			if current_target!=null:
				offset=get_target_offset(current_target)
			var tt=current_t.looking_at(current_waypoint+offset,Vector3(0,1,0))
			target_z=tt.basis.z
		else:
			target_z=current_direction
	
	var vx=Vector2(current_z.x,current_z.z).angle_to(Vector2(target_z.x,target_z.z))
	
	if not current_action.follow_target:
		var gs_left=check_ground_sensor(ground_sensor_l)
		var gs_right=check_ground_sensor(ground_sensor_r)
		var is_new_hole_l=gs_left and !old_sensor_status_l
		var is_new_hole_r=gs_right and !old_sensor_status_r
		
		if gs_left and gs_right and not (is_new_hole_l and is_new_hole_r) and (is_new_hole_r or is_new_hole_l):
			is_new_hole_r=true
			is_new_hole_l=true
		
		old_sensor_status_r=gs_right
		old_sensor_status_l=gs_left
		
		var new_vx=vx
		if is_new_hole_l and is_new_hole_r:
			new_vx=PI
			calculate_destination()
			fsm_action.set_state("turn")
			state.set_linear_velocity(Vector3(0,0,0))
		elif is_new_hole_l or is_new_hole_r:
			if is_new_hole_l:
				new_vx=0+PI/6
			else:
				new_vx=-PI/6
		
		if new_vx!=vx:
			is_temp_waypoint=true
			is_temp_side_right=is_new_hole_r
			vx=new_vx
			var dir=current_z.rotated(UP,new_vx).normalized()*4
			current_waypoint=get_global_transform().origin-dir
	 
	# if not aiming at target, turn at constant speed
	if not (abs(vx)<0.3):
		vx=sign(vx)
		
	state.set_angular_velocity(Vector3(0,vx*ANGULAR_SPEED,0))
	state.integrate_forces();
	var vel_speed=state.get_linear_velocity().length()/walk_speed;
	
	var speed=state.get_angular_velocity().length()*0.1+vel_speed;
#	model.set_walk_speed(speed)

func calculate_destination(force_recalculate=false):
	var offset=Vector3(0,0,0)
	
	if current_target!=null and navmesh!=null:
		var did_reach_wpt=current_waypoint!=null and (current_waypoint-get_translation()).length()<WAYPOINT_ERROR_DELTA
		if force_recalculate or current_waypoint==null or did_reach_wpt or waypoint_timeout<=0:
			_update_waypoint(did_reach_wpt)
		
		offset=get_target_offset(current_target)
	else:
		var curr_pos=get_global_transform().origin
		
		var a=(randf()*2-1)*PI
		var candidate_dir=Vector3(0,0,-2).rotated(Vector3(0,1,0),a)
		if navmesh!=null:
			current_waypoint=navmesh.get_closest_point(curr_pos+candidate_dir)
		else:
			current_waypoint=curr_pos+candidate_dir
		waypoint_timeout=WAYPOINT_MAX_TIMEOUT
	
	var old_direction=current_direction
	current_direction=get_global_transform().looking_at(current_waypoint+offset,Vector3(0,1,0)).orthonormalized().basis.z
	if (current_direction+old_direction).length()<1.2:
		fsm_action.set_state("turn")

func _update_waypoint(reached_wpt):
	var current_t=node_yaw.get_global_transform()
	var cur_dir=current_t.basis.z
	
	#convert start and end points to local
	var navt=navmesh.get_global_transform()
	var local_begin=navt.xform_inv(current_t.origin)
	var local_end=navt.xform_inv(current_target.get_global_transform().origin)
	
	#calculate path
	var begin=navmesh.get_closest_point(local_begin)
	var end=navmesh.get_closest_point(local_end)
	var p=navmesh.get_simple_path(begin,end, true)
	
	#process path
	var path=Array(p)
	
	var was_temp_waypoint=is_temp_waypoint
	is_temp_waypoint=false
	
	if current_path==null or current_path.size()<3 or was_temp_waypoint:
		current_path=path
		if current_path.size()==0:
			current_waypoint=navt.xform(end)
		else:
			current_waypoint=navt.xform(path[1])
			
		if not was_UTurn and was_temp_waypoint and cur_dir.dot(current_t.looking_at(current_waypoint,UP).basis.z)<-0.4:
			was_UTurn=true
			var factor=1
			if is_temp_side_right:
				factor=-1
			current_waypoint=current_t.origin+cur_dir.rotated(UP,factor*PI*0.5)*4
			is_temp_waypoint=true
		else:
			was_UTurn=false
	else:
		#remove begin and end
		path.pop_back()
		path.pop_front()
		path.invert()
		var found=false
		while not path.empty() and not found:
			var wpt=path[0]
			path.pop_front()
			for wpt_ref in current_path:
				if wpt_ref.distance_to(wpt)==0:
					found=true
					break
		
		if found:
			if reached_wpt:
				current_path.pop_front()
			current_waypoint=navt.xform(current_path[1])
		else:
			current_path=Array(p)
			if(current_path.size()>=2):
				current_waypoint=navt.xform(current_path[1])
		
		# check if doing U-Turn
		
		var wpt_dir=current_t.looking_at(current_waypoint,UP).basis.z
		var a=cur_dir.dot(wpt_dir)
		if a<-0.89:
			print(a)
		if not was_UTurn and cur_dir.dot(wpt_dir)<-0.4:
			was_UTurn=true
			
			current_waypoint=current_t.origin-cur_dir.rotated(UP,PI/16*-sign(current_t.basis.x.dot(wpt_dir)))*6
		else:
			was_UTurn=false
	
	
	waypoint_timeout=WAYPOINT_MAX_TIMEOUT
	# reset ground sensors
	old_sensor_status_r=false
	old_sensor_status_l=false

func check_ground_sensor(sensor):
	if sensor.is_colliding():
		var dot=abs(UP.dot(sensor.get_collision_normal()))
		var len=sensor.get_global_transform().origin.distance_to(sensor.get_collision_point())
		return dot < 0.4 or (dot==1 and len>4)
	else:
		return true

func _action_state_changed(state_from,state_to,params):
	print("state: ",state_to)
	
	if state_to=="move":
		calculate_destination()
	
	if action_states.has(state_to):
		current_action.move=params.move
		current_action.follow_target=params.follow

func get_target_offset(target):
	return Vector3(0,0,0)

func fsm_has_no_target():
	return current_target==null
