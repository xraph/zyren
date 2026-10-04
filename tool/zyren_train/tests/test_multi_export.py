import copy
import hashlib
import json
import os
from pathlib import Path
import numpy as np
import onnxruntime as ort
import pytest
import torch
from zyren_train.export import ActorStep,export_actor,load_multi_actor
from zyren_train.multi_train import train_multi
from zyren_train.worker import Worker
from zyren_train.pettingzoo_env import ZyrenParallelEnv
from test_multi_train import config


@pytest.mark.parametrize('family',['cooperative-search','competitive-pursuit'])
def test_real_multi_checkpoint_exports_shared_profile_and_private_recurrent_state(tmp_path,family):
    command=os.environ.get('MULTI_WORKER')
    if not command:pytest.skip('Requires explicitly frozen multi worker')
    cfg=config(command,family,steps=8);run=tmp_path/'run'
    train_multi(cfg,run,[command],cwd=Path(__file__).resolve().parents[3])
    worker=Worker([command],cwd=Path(__file__).resolve().parents[3],run_id='multi-export',timeout=60)
    env=ZyrenParallelEnv(worker,scenario=family,possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id='export',purpose='training')
    try:
        env.reset(seed=7);header=copy.deepcopy(env._header)
        header['action_space']=env._action_contract
        checkpoint=load_multi_actor(cfg,run,header)
        exported=export_actor(checkpoint,tmp_path/'actor')
        assert exported['family']==family and not exported['accepted']
        manifest=json.loads((tmp_path/'actor/model.json').read_bytes())
        assert manifest['preprocessing']['multiProfile']==header['multi_profile']
        assert manifest['inputs'][0]['shape']==[-1,36] and manifest['outputs'][0]['shape']==[-1,22]
        provenance=json.loads((tmp_path/'actor/provenance.json').read_bytes())
        assert provenance['training_config_hash']==cfg.hash
        assert json.loads((tmp_path/'actor/observation.json').read_bytes())==header['observation_schema']
        assert not (tmp_path/'actor/evaluation.json').exists()
        session=ort.InferenceSession(str(tmp_path/'actor/actor.onnx'),providers=['CPUExecutionProvider'])
        actor=ActorStep(checkpoint.policy()).eval()
        values=(torch.rand(2,36),torch.rand(2,128),torch.rand(2,128))
        with torch.no_grad():expected=actor(*values)
        actual=session.run(None,{k:v.numpy() for k,v in zip(('observation','hidden','cell'),values)})
        for a,b in zip(actual,expected):np.testing.assert_allclose(a,b.numpy(),atol=1e-5,rtol=1e-4)
        bad=copy.deepcopy(header);bad['multi_profile']['message_cadence_ticks']=6
        with pytest.raises(ValueError,match='profile'):load_multi_actor(cfg,run,bad)
        assert hashlib.sha256((tmp_path/'actor/actor.onnx').read_bytes()).hexdigest()==manifest['sha256']
    finally:env.close();worker.close()
    assert worker.process.returncode==0
