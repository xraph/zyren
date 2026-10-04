import copy
import os
from pathlib import Path
import pytest
from zyren_train.multi_dev import checkpoint_candidates, run_dev_slot, select_dev_candidate


def test_checkpoint_schedule_uses_first_saved_threshold_and_exact_cloning_epoch():
    rows=[{'phase':'cloning','epoch':4}, {'phase':'checkpoint','steps':0,'sequence':2},
          {'phase':'checkpoint','steps':2112,'sequence':3}, {'phase':'checkpoint','steps':4160,'sequence':4}]
    candidates=checkpoint_candidates(rows,bc_epochs=[4],ppo_steps=[2048,4096])
    assert [c['sequence'] for c in candidates]==[2,3,4]
    with pytest.raises(ValueError):checkpoint_candidates(rows,bc_epochs=[8],ppo_steps=[])
    with pytest.raises(ValueError):checkpoint_candidates([rows[0],{'phase':'cloning','epoch':5},rows[1]],bc_epochs=[4],ppo_steps=[])


def test_dev_rejects_other_partitions_before_allocating_worker():
    from test_multi_evaluation import plan_value
    case=plan_value()['cases'][0]
    def forbidden(*args,**kwargs):raise AssertionError('must reject before allocation')
    with pytest.raises(ValueError):run_dev_slot(None,case,30000,None,None,0,environment_factory=forbidden)


def test_selection_uses_contacts_before_success_and_earliest_tie():
    rows=[{'checkpoint_sequence':3,'invalid_actions':0,'failed':0,'cancelled':0,'collisions':1,'score':1.},
          {'checkpoint_sequence':9,'invalid_actions':0,'failed':0,'cancelled':0,'collisions':0,'score':.5},
          {'checkpoint_sequence':6,'invalid_actions':0,'failed':0,'cancelled':0,'collisions':0,'score':.5}]
    assert select_dev_candidate(rows)['checkpoint_sequence']==6
    assert select_dev_candidate([{**r,'failed':1} for r in rows]) is None


def test_real_native_dev_slot_uses_validation_layout_and_closes_owner():
    from zyren_train.worker import Worker
    from zyren_train.pettingzoo_env import ZyrenParallelEnv
    from zyren_train.multi_execution import MultiFixedActor
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    worker=Worker([command],cwd=Path(__file__).resolve().parents[3],run_id='multi-dev-test',timeout=60)
    env=ZyrenParallelEnv(worker,scenario='cooperative-search-validation',possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id='dev-schema',purpose='validation')
    try:
        env.reset(seed=30000);header=copy.deepcopy(env._header)
        assert header['split']=='validation' and header['scenario_spec']['settings']['layout_range']==[.15,.25]
        env.close()
        case={'id':'dev-cooperative','family':'cooperative-search','role':'joint','opponent':None,'scenario':header['scenario_spec']}
        actor=MultiFixedActor('stationary',observation_hash=header['observation_schema_hash'],action_hash=header['action_schema_hash'])
        row,fault,stale=run_dev_slot(worker,case,30000,actor,None,0)
        assert row.status=='completed' and row.steps==400 and row.invalid_actions==fault==stale==0
    finally:env.close();worker.close()
    assert worker.process.returncode==0


def test_checked_checkpoint_receipt_cannot_be_swapped_or_changed(tmp_path):
    import torch
    from zyren_train.checkpoint import TrainingCheckpoint
    from zyren_train.multi_dev import load_checkpoint_receipt
    from zyren_train.policies.structured import StructuredPolicy
    from zyren_train.run_manifest import RunDirectory
    run=RunDirectory(tmp_path/'run','a'*64)
    policy=StructuredPolicy(36,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},fallback=[2,2,2,1,0,0])
    cp=TrainingCheckpoint.save(run,policy=policy,optimizer=torch.optim.Adam(policy.parameters()),steps=3,updates=1,
        curriculum={},normalization=None,config_hash='a'*64,source_pins={},cloning_progress={})
    receipt=run.append('running',phase='checkpoint',checkpoint=cp.path.name,checkpoint_sha256=cp.sha256,steps=3,updates=1)
    state=load_checkpoint_receipt(run.path,'a'*64,receipt)
    assert state['steps']==3 and state['_checkpoint_sha256']==cp.sha256
    with pytest.raises(ValueError):load_checkpoint_receipt(run.path,'a'*64,{**receipt,'steps':4})
    cp.path.write_bytes(b'corrupt')
    with pytest.raises(ValueError):load_checkpoint_receipt(run.path,'a'*64,receipt)
