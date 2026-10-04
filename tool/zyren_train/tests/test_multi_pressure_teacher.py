import math
import numpy as np
import pytest
from zyren_train.multi_pressure_teacher import MultiPressureTeacher
from zyren_train.multi_execution import StaleMultiReceipt


def inputs(*,x=2,z=5,local_target=(-4,0,-5),tick=1,generation=1,visible=True,route_index=0):
    obs=np.zeros(36,dtype=np.float32);obs[26]=-1;obs[29]=1
    point=((6,5),(6,-6),(-6,-6),(-6,6))[route_index]
    obs[27]=(point[0]-x)/15;obs[28]=(point[1]-z)/15
    if visible:obs[4:7]=np.asarray(local_target)/15;obs[17:20]=1
    info={'tick':tick,'episode_id':'one','actor_generation':generation,'observation_schema_hash':'obs',
          'action_schema_hash':'act','legality':[[True]*n for n in [5,5,5,3,2,2]]}
    return obs,info


def teacher():return MultiPressureTeacher(observation_hash='obs',action_hash='act')


def test_escape_uses_full_speed_typed_actions_and_observer_relative_target():
    actor=teacher();obs,info=inputs()
    action=actor.act('b',obs,info)
    x,z=[actor.BINS[int(i)] for i in action[:2]]
    assert math.hypot(x,z)>=1 and x>0 and z>0
    assert action[2:].tolist()==[2,1,0,0]
    assert actor.states['b']['direction']==pytest.approx((-4.,-5.))
    assert actor.states['b']['position_bounds'][0]==pytest.approx((-8.,2.),abs=2e-5)


def test_previous_applied_heading_rebases_sighting_without_exact_pose_or_cursor():
    actor=teacher();obs,info=inputs();actor.act('b',obs,info)
    heading=actor.states['b']['heading'];target=(-2.,0.);own=(2.1,5.1)
    dx,dz=target[0]-own[0],target[1]-own[1]
    local=(dx*math.cos(heading)-dz*math.sin(heading),0,dx*math.sin(heading)+dz*math.cos(heading))
    obs,info=inputs(x=own[0],z=own[1],local_target=local,tick=2)
    actor.act('b',obs,info);assert actor.states['b']['direction']==pytest.approx((dx,dz),abs=1e-5)
    obs,info=inputs(x=5.7,z=5,local_target=(0,0,-4),tick=3,route_index=1)
    actor.act('b',obs,info)
    assert 'route_index' not in actor.states['b'] and 'position' not in actor.states['b']
    bounds=actor.states['b']['position_bounds']
    assert bounds[0][0]<=5.7<=bounds[0][1] and bounds[1][0]<=5<=bounds[1][1]


def test_wall_safe_projection_and_historical_memory_expiry_and_generation_reset():
    actor=teacher();obs,info=inputs(x=6.9,z=7.9,local_target=(-4,0,-4));action=actor.act('b',obs,info)
    x,z=[actor.BINS[int(i)] for i in action[:2]];length=math.hypot(x,z)
    assert length>=1
    assert abs(6.9+x/length*actor.SPEED*actor.LOOK_AHEAD)<=actor.SAFE_X
    assert abs(7.9+z/length*actor.SPEED*actor.LOOK_AHEAD)<=actor.SAFE_Z
    obs,info=inputs(x=6.9,z=7.9,tick=102,visible=False);actor.act('b',obs,info)
    assert actor.states['b']['direction'] is None
    obs,info=inputs(tick=1,generation=2,visible=False);actor.act('b',obs,info)
    assert actor.states['b']['direction'] is None and actor.states['b']['identity']==('one',2)
    with pytest.raises(StaleMultiReceipt):actor.act('b',obs,info)


def test_hidden_training_fields_bad_role_route_and_masks_are_rejected_before_state_change():
    actor=teacher();obs,info=inputs()
    for bad in ({**info,'teacher_actions':[1]},{**info,'distance':1}):
        with pytest.raises(ValueError):actor.act('b',obs,bad)
    assert actor.states=={}
    for index,value in ((26,1),(29,0)):
        bad=obs.copy();bad[index]=value
        with pytest.raises(ValueError):actor.act('b',bad,info)
    bad={**info,'legality':[[True]*n for n in [5,5,5,3,2,2]]};bad['legality'][4]=[False,True]
    with pytest.raises(ValueError):actor.act('b',obs,bad)
    assert actor.states=={}


def test_bounds_cover_all_public_route_cursors_and_zero_route_falls_back_to_idle():
    points=((6,5),(6,-6),(-6,-6),(-6,6))
    for own in ((-7.9,-8.9),(7.9,8.9),(1.25,-2.5)):
        for point in points:
            delta=np.asarray((point[0]-own[0],point[1]-own[1]),dtype=np.float32)
            bounds=MultiPressureTeacher.position_bounds(delta)
            assert all(low<=value<=high for value,(low,high) in zip(own,bounds))
    actor=teacher();obs,info=inputs(x=6,z=5,visible=False)
    assert actor.act('b',obs,info).tolist()==[2,2,2,1,0,0]


def test_ttl_boundary_and_rejection_preserve_existing_state():
    import copy
    actor=teacher();obs,info=inputs();actor.act('b',obs,info)
    obs,info=inputs(tick=101,visible=False);actor.act('b',obs,info)
    assert actor.states['b']['seen_tick']==1 and actor.states['b']['direction'] is not None
    before=copy.deepcopy(actor.states)
    with pytest.raises(StaleMultiReceipt):actor.act('b',obs,info)
    with pytest.raises(ValueError):actor.act('b',obs,{**info,'tick':102,'critic_state':[]})
    assert actor.states==before
    actor.act('b',obs,{**info,'tick':102})
    assert actor.states['b']['seen_tick'] is None and actor.states['b']['direction'] is None


def test_invalid_vision_content_cannot_refresh_or_change_permitted_direction():
    left=teacher();right=teacher();obs,info=inputs(visible=False)
    hidden=obs.copy();hidden[4:7]=[.8,-.3,.9]
    assert np.array_equal(left.act('b',obs,info),right.act('b',hidden,info))
    assert left.states==right.states
