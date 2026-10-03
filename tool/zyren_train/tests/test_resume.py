import torch
import pytest
from training_support import configuration,ROOT
from zyren_train.train import train,WorkerPool
from zyren_train.run_manifest import RunDirectory
from zyren_train.checkpoint import TrainingCheckpoint


def test_real_worker_stops_then_optimizer_and_steps_resume_at_recorded_reset(worker_command,tmp_path):
    config=configuration(worker_command,steps=24)
    run=RunDirectory(tmp_path/'run',config.hash)
    first_pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    stopped=train(config,first_pool,run,stop_after_updates=1)
    assert stopped['state']=='cancelled' and first_pool.worker.process.poll()==0
    before=TrainingCheckpoint.load(run,config.hash)
    new_run=RunDirectory(run.path,config.hash,resume=True)
    pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    final=train(config,pool,new_run,resume=True)
    after=TrainingCheckpoint.load(new_run,config.hash)
    assert final['state']=='completed' and after['steps']==24 and after['updates']==3
    prior=max(float(v['step']) for v in before['optimizer']['state'].values())
    current=max(float(v['step']) for v in after['optimizer']['state'].values())
    assert current>prior and not torch.equal(before['model']['action_head.weight'],after['model']['action_head.weight'])
    receipt=next(r for r in new_run.read_receipts() if r.get('phase')=='resume')
    assert receipt['environment_restore']=='reset-boundary' and receipt['numerical_reproducibility'] is False
    assert final['worker_exit_codes']==[0]
    pointer=new_run.path/'checkpoint.json'; value=__import__('json').loads(pointer.read_text()); value['sha256']='0'*64; pointer.write_text(__import__('json').dumps(value))
    with pytest.raises(ValueError,match='hash'): TrainingCheckpoint.load(new_run,config.hash)


def test_tampered_receipt_or_configuration_cannot_resume(tmp_path):
    run=RunDirectory(tmp_path/'run','pin'); run.append('cancelled',steps=0)
    with pytest.raises(ValueError): RunDirectory(run.path,'other',resume=True)
    path=run.path/'receipts.jsonl'; path.write_bytes(path.read_bytes().replace(b'cancelled',b'completed'))
    with pytest.raises(ValueError): RunDirectory(run.path,'pin',resume=True)


def test_failed_worker_is_failed_run_with_closed_supervisor(worker_command,tmp_path):
    config=configuration(worker_command)
    pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    pool.worker.process.kill(); pool.worker.process.wait()
    run=RunDirectory(tmp_path/'run',config.hash)
    with pytest.raises(Exception): train(config,pool,run)
    final=run.read_receipts()[-1]
    assert final['state']=='failed' and final['workers_closed']
    assert final['worker_exit_codes'][0]!=0


def test_active_run_rejects_second_trainer_and_reserved_receipt_fields(tmp_path):
    run=RunDirectory(tmp_path/'run','pin'); run.append('running',steps=0); run.acquire()
    other=RunDirectory(run.path,'pin',resume=True)
    with pytest.raises(ValueError,match='active'): other.acquire()
    with pytest.raises(ValueError,match='Reserved'): run.append('running',sha256='not-a-chain')
    run.release(); other.acquire(); other.release()


def test_checkpoint_distribution_pin_rejects_previous_sampler(worker_command,tmp_path):
    import json,hashlib
    config=configuration(worker_command,scenario='vehicle',steps=8)
    run=RunDirectory(tmp_path/'run',config.hash); pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    train(config,pool,run)
    pointer=run.path/'checkpoint.json'; meta=json.loads(pointer.read_text()); path=run.path/meta['file']
    state=torch.load(path,weights_only=True); state['policy_distribution']='squashed-normal-v1'; torch.save(state,path)
    meta['sha256']=hashlib.sha256(path.read_bytes()).hexdigest(); pointer.write_text(json.dumps(meta))
    with pytest.raises(ValueError,match='distribution'): TrainingCheckpoint.load(run,config.hash)


def test_resumed_immediate_cancel_reuses_exact_checkpoint_and_optimizer(worker_command,tmp_path):
    config=configuration(worker_command,steps=24)
    run=RunDirectory(tmp_path/'run',config.hash); first=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    stopped=train(config,first,run,stop_after_updates=1)
    original=TrainingCheckpoint.load(run,config.hash)
    resumed=RunDirectory(run.path,config.hash,resume=True); second=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    final=train(config,second,resumed,resume=True,cancelled=lambda:True)
    restored=TrainingCheckpoint.load(resumed,config.hash)
    assert final['state']=='cancelled' and final['steps']==8 and final['updates']==1
    assert final['checkpoint']==stopped['checkpoint'] and final['checkpoint_sha256']==stopped['checkpoint_sha256']
    assert final['worker_exit_codes']==[0]
    assert torch.equal(original['model']['action_head.weight'],restored['model']['action_head.weight'])
    assert max(float(v['step']) for v in original['optimizer']['state'].values())==max(float(v['step']) for v in restored['optimizer']['state'].values())


@pytest.mark.parametrize('boundary',['epoch','sequence'])
def test_cloning_cancels_at_sequence_boundary_and_resumes_without_replay(worker,worker_command,tmp_path,boundary):
    import numpy as np
    from zyren_train.gym_env import ZyrenEnv
    from zyren_train.scenario import ScenarioSpec
    from zyren_train.demonstration import DemonstrationRecorder,record_episode
    env=ZyrenEnv(worker,scenario='guard',observation_width=None); _,info=env.reset(seed=7)
    recording=tmp_path/'recording'; recorder=DemonstrationRecorder(recording,scenario=ScenarioSpec.from_dict(info['scenario_spec']),session_id='bc-cancel',run_id=worker.run_id,environment_id=env.environment_id,source='scripted',model_hash='scripted-v1')
    record_episode(env,recorder,lambda obs,receipt:np.asarray(receipt['baseline_action'],dtype=np.int64),seed=7)
    if boundary=='sequence': record_episode(env,recorder,lambda obs,receipt:np.asarray(receipt['baseline_action'],dtype=np.int64),seed=7)
    recorder.finalize(); env.close()
    config=configuration(worker_command,steps=8,datasets={'train':[str(recording)],'validation':[],'test':[]},bc_epochs=3)
    run=RunDirectory(tmp_path/'run',config.hash); pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    calls=[0]
    def cancel(): calls[0]+=1; return calls[0]>=3
    stopped=train(config,pool,run,cancelled=cancel)
    before=TrainingCheckpoint.load(run,config.hash)
    assert stopped['state']=='cancelled' and before['steps']==0 and before['cloning_progress']==({'epoch':1,'sequence':0,'complete':False} if boundary=='epoch' else {'epoch':0,'sequence':1,'complete':False})
    assert max(float(v['step']) for v in before['optimizer']['state'].values())==1
    resumed=RunDirectory(run.path,config.hash,resume=True); pool=WorkerPool(worker_command,cwd=ROOT/'examples/game_lab/training_worker',config=config)
    final=train(config,pool,resumed,resume=True); after=TrainingCheckpoint.load(resumed,config.hash)
    assert final['state']=='completed' and after['cloning_progress']['complete']
    assert max(float(v['step']) for v in after['optimizer']['state'].values())==(5 if boundary=='epoch' else 8) # Each completed BC sequence counts once, plus2 PPO updates.
    epochs=[r['epoch'] for r in resumed.read_receipts() if r.get('phase')=='behavior-cloning']
    assert epochs==[0,1,2] and final['worker_exit_codes']==[0]
