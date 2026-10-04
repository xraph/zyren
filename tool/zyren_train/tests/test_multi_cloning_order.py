import os
from pathlib import Path
from types import SimpleNamespace
import pytest
import torch
from zyren_train.multi_train import MultiTrainingConfig,train_multi,cloning_sequence_order
from zyren_train.checkpoint import TrainingCheckpoint


def test_epoch_order_is_complete_stable_and_does_not_change_global_rng():
    import random
    state=random.getstate();torch_state=torch.get_rng_state().clone()
    order=cloning_sequence_order(48,211,3,enabled=True)
    assert sorted(order)==list(range(48)) and order!=list(range(48))
    assert order==cloning_sequence_order(48,211,3,enabled=True)
    assert order!=cloning_sequence_order(48,211,4,enabled=True)
    assert cloning_sequence_order(48,211,3,enabled=False)==list(range(48))
    assert random.getstate()==state and torch.equal(torch_state,torch.get_rng_state())


def _same(left,right):
    if isinstance(left,torch.Tensor):assert torch.equal(left,right)
    elif isinstance(left,dict):
        assert left.keys()==right.keys()
        for key in left:_same(left[key],right[key])
    elif isinstance(left,(list,tuple)):
        assert len(left)==len(right)
        for a,b in zip(left,right):_same(a,b)
    else:assert left==right


def test_interrupted_mid_epoch_restores_identical_weights_optimizer_rng_and_later_order(tmp_path,monkeypatch):
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly pinned multi worker')
    source=Path(__file__).resolve().parents[1]/'qualification/multi-2026-10-03/training/configs/competitive.json'
    value=MultiTrainingConfig.load(source).data
    value['cloning_order']='seeded-per-epoch-v1';value['training']['bc_epochs']=2
    value['training']['total_steps']=64
    cfg=MultiTrainingConfig.from_dict(value)
    original=torch.optim.Adam.step;counter={'count':0}
    def step(optimizer,*args,**kwargs):
        result=original(optimizer,*args,**kwargs);counter['count']+=1;return result
    monkeypatch.setattr(torch.optim.Adam,'step',step)
    def native_forbidden(*args,**kwargs):raise AssertionError('BC resume test stops before native allocation')
    import zyren_train.multi_train as module
    monkeypatch.setattr(module,'Worker',native_forbidden)
    cwd=Path(__file__).resolve().parents[3]
    full=tmp_path/'full';partial=tmp_path/'partial'
    train_multi(cfg,full,[command],cwd=cwd,cancelled=lambda:counter['count']>=96)
    baseline=TrainingCheckpoint.load(SimpleNamespace(path=full),cfg.hash)
    counter['count']=0
    train_multi(cfg,partial,[command],cwd=cwd,cancelled=lambda:counter['count']>=17)
    first=TrainingCheckpoint.load(SimpleNamespace(path=partial),cfg.hash)
    assert first['cloning_progress']=={'epoch':0,'sequence':17,'complete':False}
    train_multi(cfg,partial,[command],cwd=cwd,resume=True,cancelled=lambda:counter['count']>=96)
    resumed=TrainingCheckpoint.load(SimpleNamespace(path=partial),cfg.hash)
    for key in ('model','optimizer','torch_rng','python_rng','numpy_rng','cloning_progress'):_same(baseline[key],resumed[key])
    import json
    orders=lambda path:[r['sequence_order'] for r in map(json.loads,(path/'receipts.jsonl').read_text().splitlines()) if r.get('phase')=='cloning']
    assert orders(full)==orders(partial)==[cloning_sequence_order(48,211,epoch,enabled=True) for epoch in range(2)]
