import numpy as np
import pytest
from zyren_train.gym_env import ZyrenEnv
from zyren_train.scenario import ScenarioSpec
from zyren_train.demonstration import DemonstrationRecorder, record_episode, replay_recording


@pytest.mark.parametrize('scenario,width,actions', [('guard',14,6),('vehicle',10,3)])
@pytest.mark.parametrize('source',['player','scripted'])
def test_real_task_demonstrations_replay_controller_and_observed_input(worker,tmp_path,scenario,width,actions,source):
    env=ZyrenEnv(worker,scenario=scenario,observation_width=width,action_width=actions)
    _,info=env.reset(seed=7)
    spec=ScenarioSpec.from_dict(info['scenario_spec'])
    recorder=DemonstrationRecorder(tmp_path,scenario=spec,session_id=f'{scenario}-{source}',
        run_id=worker.run_id,environment_id=env.environment_id,source=source,
        model_hash='scripted-v1' if source=='scripted' else 'none',
        recording_settings={'input_origin':'authored-controller-fixture' if source=='player' else 'scripted-baseline',
                            'physical_device_qualified':None})
    modes=set(); accepted=[]
    def action_source(observation,receipt):
        if 'task_mode' in receipt: modes.add(receipt['task_mode'])
        accepted.append(receipt['accepted_action'])
        if source=='scripted':
            values=receipt['baseline_action']
        elif scenario=='guard':
            values=[2,4,2,1,0,0]
        else:
            values=[.35,.5,0] if receipt['tick']<130 else [.1,.7,1]
        return np.asarray(values,dtype=np.int64 if scenario=='guard' else np.float32)
    assert record_episode(env,recorder,action_source,seed=7)==240
    manifest=recorder.finalize(); env.close()
    assert manifest.recording['source']==source
    assert replay_recording(worker,tmp_path)['steps']==240
    if scenario=='guard': assert 'pursuit' in modes and 'investigation' in modes
    else:
        assert any(a[0]>0 for a in accepted)
        assert any(a[2]>0 and a[1]==0 for a in accepted)
