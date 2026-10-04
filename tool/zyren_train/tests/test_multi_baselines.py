import numpy as np
import pytest
from zyren_train.multi_execution import MultiFixedActor


def info(tick=1):
    return {'tick':tick,'episode_id':'episode','actor_generation':1,'observation_schema_hash':'a'*64,
            'action_schema_hash':'b'*64,'build_id':'native','legality':[[True]*n for n in [5,5,5,3,2,2]]}


def test_fixed_route_uses_only_authored_displacement_and_observed_target():
    actor=MultiFixedActor('observed-route',observation_hash='a'*64,action_hash='b'*64)
    row=np.zeros(36,dtype=np.float32);row[26]=-1;row[27]=1;row[29]=1
    assert actor.act('b',row,info()).tolist()==[4,2,2,1,0,0]
    row[29]=0;row[26]=1;row[4]=0;row[6]=1;row[17:20]=1
    # The prior applied east intent turns the actor, so local forward is east.
    assert actor.act('b',row,info(2)).tolist()==[4,2,2,1,0,0]
    row[17:20]=0
    assert actor.act('b',row,info(3)).tolist()==[2,2,2,1,0,0]
    bad=info(4);bad['teacher_actions']={}
    with pytest.raises(ValueError,match='actor-only'):actor.act('b',row,bad)


def test_frozen_fixed_policy_identity_and_reset_are_stable():
    first=MultiFixedActor('stationary',observation_hash='a'*64,action_hash='b'*64)
    second=MultiFixedActor('stationary',observation_hash='a'*64,action_hash='b'*64)
    route=MultiFixedActor('observed-route',observation_hash='a'*64,action_hash='b'*64)
    assert first.model_hash==second.model_hash and first.model_hash!=route.model_hash
    assert first.act('a',np.zeros(36,dtype=np.float32),info()).tolist()==[2,2,2,1,0,0]
    first.reset()
    assert first.act('a',np.zeros(36,dtype=np.float32),info()).tolist()==[2,2,2,1,0,0]


def test_fixed_observed_route_matches_native_permitted_teacher_on_train_prefix():
    import os
    from pathlib import Path
    from zyren_train.worker import Worker
    from zyren_train.pettingzoo_env import ZyrenParallelEnv
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    worker=Worker([command],cwd=Path(__file__).resolve().parents[3],run_id='fixed-train-prefix',timeout=60)
    env=ZyrenParallelEnv(worker,scenario='competitive-pursuit',possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id='baseline-prefix',purpose='training')
    try:
        observations,infos=env.reset(seed=7)
        actor=MultiFixedActor('observed-route',observation_hash=infos['a']['observation_schema_hash'],action_hash=infos['a']['action_schema_hash'])
        for _ in range(20):
            actions={a:actor.act(a,observations[a],infos[a]) for a in env.agents}
            assert all(np.array_equal(v,env.training_only['teacher_actions'][a]) for a,v in actions.items())
            observations,_,_,_,infos=env.step(actions)
    finally:env.close();worker.close()
    assert worker.process.returncode==0
