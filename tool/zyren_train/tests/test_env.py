import json
import subprocess
import numpy as np
import pytest
from zyren_train.gym_env import ZyrenEnv
from zyren_train.vector_env import ZyrenVectorEnv
from zyren_train.protocol import ProtocolError


def test_native_reset_step_snapshot_and_invalid_actions(worker):
    env = ZyrenEnv(worker)
    obs, info = env.reset(seed=7)
    assert obs.shape == (8,)
    assert info['physics_backend'] == 'rapier' and info['renderer'] is None
    assert info['observation_schema_hash'] == env.observation_schema_hash
    initial_tick = info['tick']
    with pytest.raises(ValueError):
        env.step(np.array([float('nan'), 0]))
    snapshot = env.snapshot()
    result = env.step(np.array([0.25, -0.5], dtype=np.float32))
    assert result[4]['tick'] == initial_tick + 1
    assert result[4]['run_id'] == 'test-run'
    assert result[4]['environment_id'] == 'env'
    assert result[4]['episode_id'] == info['episode_id']
    assert result[4]['actor_ids'] == ['actor']
    restored, restored_info = env.restore(snapshot)
    np.testing.assert_array_equal(restored, obs)
    assert restored_info['tick'] == initial_tick
    repeated = env.step(np.array([0.25, -0.5], dtype=np.float32))
    np.testing.assert_array_equal(repeated[0], result[0])
    assert repeated[4]['physics_position'] == result[4]['physics_position']
    env.close()


def test_vector_environments_have_independent_episodes(worker):
    vector = ZyrenVectorEnv([ZyrenEnv(worker, environment_id='a'), ZyrenEnv(worker, environment_id='b')])
    obs, infos = vector.reset(seed=7)
    assert obs.shape == (2, 8)
    ids = [i['episode_id'] for i in infos['individual']]
    assert len(set(ids)) == 2
    result = vector.step(np.array([[.25, 0], [-.25, 0]], dtype=np.float32))
    assert result[4]['individual'][0]['physics_position'][0] > 0
    assert result[4]['individual'][1]['physics_position'][0] < 0
    vector.close()


def test_validation_scenario_cannot_enter_training(worker):
    env = ZyrenEnv(worker, purpose='validation')
    with pytest.raises(ProtocolError):
        env.reset(seed=7)
    env.close()


def test_thousand_actions_match_direct_game_runtime(worker, worker_command):
    reference = json.loads(subprocess.check_output(worker_command + ['--fixture-log'], cwd=worker.cwd))
    env = ZyrenEnv(worker)
    env.reset(seed=7)
    actual = []
    for _ in range(1000):
        _, _, terminated, truncated, info = env.step(np.array([.25, -.5], dtype=np.float32))
        assert not terminated and not truncated
        actual.append({'tick': info['tick'], 'action': info['accepted_action'], 'position': info['physics_position']})
    assert actual == reference
    env.close()


def test_single_actor_adapter_pins_game_and_action_identity():
    from zyren_train.protocol import Frame
    from test_protocol import header
    env = ZyrenEnv(None)
    def frame(**changes):
        h = dict(header(), observation_schema_hash='obs', action_schema_hash='action', build_id='build')
        h.update(changes)
        return Frame.from_arrays(h, {'observation.actor': np.zeros(8, dtype=np.float32)})
    env._update(frame())
    for changes in ({'action_schema_hash': 'different'}, {'build_id': 'different'},
                    {'actor_ids': ['actor', 'ground'], 'actor_generations': {'actor': 1, 'ground': 1}}):
        with pytest.raises(ProtocolError):
            env._update(frame(**changes))


def test_generated_discrete_space_and_input_width_are_pinned():
    import gymnasium as gym
    from zyren_train.protocol import Frame
    from test_protocol import header
    env=ZyrenEnv(None,observation_width=None)
    h=dict(header(),observation_schema_hash='obs',action_schema_hash='act',build_id='build',action_width=6,
           observation_schema={'fields':[{'width':7},{'width':7}]},
           action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]})
    env._update(Frame.from_arrays(h,{'observation.actor':np.zeros(14,dtype=np.float32)}))
    assert env.observation_space.shape==(14,) and isinstance(env.action_space,gym.spaces.MultiDiscrete)
    with pytest.raises(ProtocolError):
        env._update(Frame.from_arrays(dict(h,action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,3]}),
                                      {'observation.actor':np.zeros(14,dtype=np.float32)}))
