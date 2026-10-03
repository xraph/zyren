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
