import numpy as np
import pytest
from zyren_train.pettingzoo_env import ZyrenParallelEnv
from zyren_train.protocol import ProtocolError


def native_parallel(worker,scenario):
    frame=worker.call('reset',environment_id='parallel-probe',episode_id='reset',actor_ids=[],tick=0,
        extra={'seed':7,'scenario':scenario,'purpose':'training'})
    h=frame.header
    width=sum(f['width'] for f in h['observation_schema']['fields'])
    worker.call('close',environment_id='parallel-probe',episode_id=h['episode_id'],actor_ids=h['actor_ids'],actor_generations=h['actor_generations'],tick=h['tick'])
    return ZyrenParallelEnv(worker,scenario=scenario,possible_agents=['a','b','guest'] if scenario.endswith('dynamic') else ['a','b'],observation_width=width,action_space=h['action_space'])


@pytest.mark.parametrize('scenario',['cooperative-search','competitive-pursuit','cooperative-search-dynamic'])
def test_actual_native_parallel_api_checker_1000_cycles(worker,scenario):
    from pettingzoo.test import parallel_api_test
    env=native_parallel(worker,scenario)
    try:parallel_api_test(env,num_cycles=1000)
    finally:env.close()


def test_actual_membership_done_reset_and_training_only_boundary(worker):
    env=native_parallel(worker,'cooperative-search-dynamic')
    try:
        observations,infos=env.reset(seed=7)
        assert set(observations)=={'a','b'} and all(set(i).isdisjoint({'state','teacher_actions','distances'}) for i in infos.values())
        assert 'teacher_actions' in env.training_only and env.state().shape==(9,)
        for index in range(10):
            actions={a:np.asarray([2,2,2,1,0,0],dtype=np.int64) for a in env.agents}
            observations,rewards,terminated,truncated,infos=env.step(actions)
            if index==4:assert 'guest' in env.agents
        assert 'guest' not in env.agents and terminated['guest'] is True
        assert observations['guest'].shape==env.observation_space('guest').shape and np.isfinite(observations['guest']).all()
        assert all(set(i).isdisjoint(env.training_only) for i in infos.values())
        with pytest.raises(ValueError):env.step({**{a:np.asarray([2,2,2,1,0,0]) for a in env.agents},'guest':np.asarray([2,2,2,1,0,0])})
        observations,_=env.reset(seed=7)
        assert set(observations)=={'a','b'} and not env._done
    finally:env.close()
