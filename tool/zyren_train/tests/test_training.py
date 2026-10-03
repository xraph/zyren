import torch
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.policies.cloning import cloning_loss


def test_schema_network_sequence_padding_and_episode_reset():
    torch.manual_seed(7)
    policy=StructuredPolicy(14,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},fallback=[2,2,2,1,0,0])
    observations=torch.randn(5,2,14); starts=torch.zeros(5,2,dtype=torch.bool); starts[2,0]=True
    valid=torch.ones(5,2,dtype=torch.bool); valid[4,1]=False
    output,value,state=policy.sequence(observations,starts,valid=valid)
    isolated=policy.sequence(observations[2:3,:1],torch.ones(1,1,dtype=torch.bool))[0]
    assert torch.allclose(output[2:3,:1],isolated,atol=1e-6)
    prior=policy.sequence(observations[:4],starts[:4])[2]
    assert torch.allclose(state[0][1],prior[0][1])
    assert output.shape==(5,2,22) and value.shape==(5,2)
    assert [m.out_features for m in policy.mlp if isinstance(m,torch.nn.Linear)]==[128,128]
    assert policy.lstm.hidden_size==128


def test_behavior_cloning_loss_decreases_and_padding_excluded():
    torch.manual_seed(7)
    policy=StructuredPolicy(4,{'kind':'multi_discrete','nvec':[3]},fallback=[1])
    optimizer=torch.optim.Adam(policy.parameters(),lr=.01)
    observations=torch.zeros(3,1,4); actions=torch.ones(3,1,1,dtype=torch.long)
    masks=[torch.ones(3,1,3,dtype=torch.bool)]; starts=torch.zeros(3,1,dtype=torch.bool)
    valid=torch.tensor([[True],[True],[False]])
    initial=cloning_loss(policy,observations,actions,starts,masks,valid).item()
    for _ in range(4):
        optimizer.zero_grad(); loss=cloning_loss(policy,observations,actions,starts,masks,valid); loss.backward(); optimizer.step()
    assert loss.item()<initial


import pytest
from training_support import configuration,ROOT
from zyren_train.train import train,WorkerPool
from zyren_train.run_manifest import RunDirectory
from zyren_train.checkpoint import TrainingCheckpoint


@pytest.mark.parametrize('scenario',['guard','vehicle'])
def test_ppo_updates_through_real_native_controller(worker_command,tmp_path,scenario):
    config=configuration(worker_command,scenario=scenario)
    pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    run=RunDirectory(tmp_path/'run',config.hash)
    final=train(config,pool,run)
    assert final['state']=='completed' and final['steps']==16 and final['updates']==2
    assert final['workers_closed'] and final['worker_exit_codes']==[0]
    updates=[r for r in run.read_receipts() if r.get('phase')=='ppo-update']
    assert len(updates)==2 and all(r['metrics']['gradient_norm']>0 for r in updates)
    state=TrainingCheckpoint.load(run,config.hash)
    assert state['optimizer']['state'] and state['steps']==16
    assert final['policy_quality'] is None


@pytest.mark.parametrize('family',['guard','vehicle'])
def test_verified_scripted_cloning_precedes_real_ppo(worker,worker_command,tmp_path,family):
    from zyren_train.gym_env import ZyrenEnv
    from zyren_train.scenario import ScenarioSpec
    from zyren_train.demonstration import DemonstrationRecorder,record_episode
    import numpy as np
    env=ZyrenEnv(worker,scenario=family,observation_width=None)
    _,info=env.reset(seed=7); spec=ScenarioSpec.from_dict(info['scenario_spec'])
    path=tmp_path/'recording'
    recorder=DemonstrationRecorder(path,scenario=spec,session_id='cloning',run_id=worker.run_id,environment_id=env.environment_id,source='scripted',model_hash='scripted-v1')
    record_episode(env,recorder,lambda obs,receipt:np.asarray(receipt['baseline_action'],dtype=np.int64 if family=='guard' else np.float32),seed=7)
    recorder.finalize(); env.close()
    config=configuration(worker_command,scenario=family,steps=8,datasets={'train':[str(path)],'validation':[],'test':[]},bc_epochs=1)
    run=RunDirectory(tmp_path/'run',config.hash); pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    final=train(config,pool,run)
    assert final['state']=='completed'
    receipts=run.read_receipts(); assert any(r.get('phase')=='behavior-cloning' for r in receipts)
    saved=TrainingCheckpoint.load(run,config.hash)
    assert saved['normalization']['count']==240 and saved['source_pins']['train']


def test_invalid_curriculum_cannot_consume_test_scenario(worker_command):
    from zyren_train.train import TrainingConfig
    data=configuration(worker_command).data
    data['scenarios'][0]['partition']='test'
    with pytest.raises(ValueError,match='Held-out'): TrainingConfig.from_dict(data)


@pytest.mark.parametrize('family',['guard','vehicle'])
def test_real_curriculum_reaches_all_five_stages_at_episode_boundaries(worker_command,tmp_path,family):
    import json
    from zyren_train.train import TrainingConfig
    data=configuration(worker_command,scenario=family,steps=1216).data
    stages=['empty-arena','static-obstacles','occlusion','moving-hazards','task-combinations']
    data['scenarios']=[json.loads((ROOT/f'examples/game_lab/game/scenarios/{family}-{stage}.json').read_text()) for stage in stages]
    data['curriculum']=[{'name':stage,'scenario':family+'-'+stage,'after_steps':i*240} for i,stage in enumerate(stages)]
    data['rollout']['steps']=128; data['checkpoint_every_steps']=256
    config=TrainingConfig.from_dict(data);run=RunDirectory(tmp_path/'run',config.hash)
    pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    final=train(config,pool,run)
    assert final['state']=='completed' and final['steps']==1216
    stages_seen={r['curriculum']['stage'] for r in run.read_receipts() if r.get('phase')=='ppo-update'}
    assert stages_seen==set(range(5))


def test_changed_native_asset_pin_is_rejected_before_launch(worker_command):
    from zyren_train.train import TrainingConfig
    data=configuration(worker_command).data
    name=next(iter(data['worker_native_sha256'])); data['worker_native_sha256'][name]='0'*64
    config=TrainingConfig.from_dict(data)
    with pytest.raises(ValueError,match='asset bytes'): WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)


def test_learned_vehicle_distribution_can_accelerate_with_brake_zero(worker,worker_command):
    import numpy as np
    from zyren_train.gym_env import ZyrenEnv
    policy=StructuredPolicy(10,{'kind':'box','low':[-1,0,0],'high':[1,1,1]})
    torch.manual_seed(7)
    with torch.no_grad():
        policy.action_head.weight.zero_(); policy.action_head.bias.copy_(torch.tensor([0.,.8,-.5])); policy.log_std.fill_(-2)
    env=ZyrenEnv(worker,scenario='vehicle',observation_width=None); observation,info=env.reset(seed=7)
    hidden=policy.initial_state(1); zero_brake=0; positive_brake=0
    for tick in range(100):
        with torch.no_grad():
            output,_,hidden=policy.step(torch.tensor(observation).unsqueeze(0),hidden,torch.tensor([tick==0]))
            action=policy.distribution(output).sample()[0].numpy()
        observation,_,_,_,info=env.step(action)
        if action[2]==0 and action[1]>0: zero_brake+=1; assert info['accepted_action'][1]>0
        elif action[2]>0: positive_brake+=1; assert info['accepted_action'][1]==0
    assert zero_brake>0 and info['physics_position'][2]>1
    env.step(np.array([0.,.8,.5],dtype=np.float32))
    assert env._info['accepted_action']==[0.,0.,.5]
    env.close()
