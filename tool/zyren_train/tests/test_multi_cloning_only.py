import json
import os
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import onnxruntime as ort
import pytest
import torch
from zyren_train.checkpoint import TrainingCheckpoint
from zyren_train.export import ActorStep,export_actor,load_multi_actor
from zyren_train.multi_train import MultiTrainingConfig,train_multi
from test_multi_cloning_order import _same


def test_cloning_only_completes_and_resume_exports_identical_actor_without_worker(tmp_path,monkeypatch):
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly pinned multi worker bytes')
    folder=Path(__file__).resolve().parents[1]/'qualification/multi-2026-10-03/training'
    value=MultiTrainingConfig.load(folder/'configs/competitive.json').data
    value['cloning_order']='seeded-per-epoch-v1';value['training']['bc_epochs']=2
    value['training']['datasets']['train']=value['training']['datasets']['train'][:1]
    cfg=MultiTrainingConfig.from_dict(value)
    import zyren_train.multi_train as module
    def forbidden(*args,**kwargs):raise AssertionError('BC-only must not allocate a native worker')
    monkeypatch.setattr(module,'Worker',forbidden)
    original=torch.optim.Adam.step;counter={'count':0}
    def step(optimizer,*args,**kwargs):
        result=original(optimizer,*args,**kwargs);counter['count']+=1;return result
    monkeypatch.setattr(torch.optim.Adam,'step',step)
    cwd=Path(__file__).resolve().parents[3]
    full=tmp_path/'full';partial=tmp_path/'partial'
    done=train_multi(cfg,full,[command],cwd=cwd,cloning_only=True)
    assert done['state']=='completed' and done['execution_mode']=='cloning-only' and done['cloning_epochs']==2
    assert done['steps']==done['updates']==done['actor_transitions']==0 and done['worker_exit_codes']==[] and done['quality'] is None
    baseline=TrainingCheckpoint.load(SimpleNamespace(path=full),cfg.hash)
    counter['count']=0
    first=train_multi(cfg,partial,[command],cwd=cwd,cloning_only=True,cancelled=lambda:counter['count']>=1)
    assert first['state']=='cancelled' and first['cloning_epochs']==0
    with pytest.raises(ValueError,match='execution mode'):train_multi(cfg,partial,[command],cwd=cwd,resume=True)
    resumed=train_multi(cfg,partial,[command],cwd=cwd,resume=True,cloning_only=True)
    assert resumed['state']=='completed' and resumed['steps']==0
    state=TrainingCheckpoint.load(SimpleNamespace(path=partial),cfg.hash)
    for key in ('model','optimizer','torch_rng','python_rng','numpy_rng','cloning_progress'):_same(baseline[key],state[key])
    actors=folder/'actors/competitive'
    header={'multi_profile':json.loads((actors/'model.json').read_bytes())['preprocessing']['multiProfile'],
        'observation_schema':json.loads((actors/'observation.json').read_bytes()),'action_schema':json.loads((actors/'action.json').read_bytes()),
        'action_space':{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},
        'observation_schema_hash':cfg.data['training']['scenarios'][0]['observation_schema_hash'],
        'action_schema_hash':cfg.data['training']['scenarios'][0]['action_schema_hash']}
    checkpoint=load_multi_actor(cfg,partial,header);output=tmp_path/'actor';receipt=export_actor(checkpoint,output)
    assert receipt['family']=='competitive-pursuit' and not receipt['accepted'] and not (output/'evaluation.json').exists()
    session=ort.InferenceSession(str(output/'actor.onnx'),providers=['CPUExecutionProvider'])
    inputs=(torch.zeros(1,36),torch.zeros(1,128),torch.zeros(1,128))
    with torch.no_grad():expected=ActorStep(checkpoint.policy()).eval()(*inputs)
    actual=session.run(None,{name:value.numpy() for name,value in zip(('observation','hidden','cell'),inputs)})
    for left,right in zip(actual,expected):np.testing.assert_allclose(left,right.numpy(),atol=1e-5,rtol=1e-4)


def test_cloning_only_requires_boolean_and_actual_cloning_epochs(tmp_path):
    folder=Path(__file__).resolve().parents[1]/'qualification/multi-2026-10-03/training'
    cfg=MultiTrainingConfig.load(folder/'configs/competitive.json')
    for invalid in (0,1,'yes'):
        with pytest.raises(ValueError,match='cloning-only'):train_multi(cfg,tmp_path/'unused',['absent'],cwd=tmp_path,cloning_only=invalid)
    value=cfg.data;value['training']['bc_epochs']=0;cfg=MultiTrainingConfig.from_dict(value)
    with pytest.raises(ValueError,match='cloning-only'):train_multi(cfg,tmp_path/'unused',['absent'],cwd=tmp_path,cloning_only=True)
    assert not (tmp_path/'unused').exists()
