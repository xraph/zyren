import copy,hashlib,json
from pathlib import Path
from types import SimpleNamespace
import numpy as np
import onnx
import onnxruntime as ort
import pytest
import torch
from zyren_train.export import ActorCheckpoint,ActorStep,export_actor,runtime_schema_hash
from zyren_train.policies.structured import StructuredPolicy


def actor_checkpoint(family='guard'):
    info=json.loads((Path(__file__).parent/'fixtures/policy-schemas.json').read_text())[family]
    policy=StructuredPolicy(sum(field['width'] for field in info['observation_schema']['fields']),info['action_space'],fallback=info['action_schema']['fallbackDiscrete'])
    config=SimpleNamespace(hash='c'*64,data={'policy_distribution':policy.distribution_id,'worker_sha256':'d'*64,'worker_native_sha256':{'lib/probe':'e'*64}})
    state={'model':policy.state_dict(),'normalization':None,'source_pins':{},'_checkpoint_sha256':'f'*64}
    return ActorCheckpoint(config,state,info['observation_schema'],info['action_schema'],info['action_space'])


@pytest.mark.parametrize('family',['guard','vehicle'])
def test_actor_only_candidate_dynamic_batch_carry_reset_and_normalization(tmp_path,family):
    torch.manual_seed(7);checkpoint=actor_checkpoint(family);candidate=export_actor(checkpoint,tmp_path/family)
    assert candidate['accepted'] is False and candidate['native_load_verified'] is False
    assert not (tmp_path/family/'bundle.json').exists()
    graph=onnx.load(tmp_path/family/'actor.onnx');names=[v.name for v in graph.graph.initializer]
    assert not any('value_head' in name or 'log_std' in name or 'optimizer' in name for name in names)
    manifest=json.loads((tmp_path/family/'model.json').read_text())
    assert all(spec['shape'][0]==-1 and spec['maxShape'][0]==64 for spec in manifest['inputs']+manifest['outputs'])
    session=ort.InferenceSession(str(tmp_path/family/'actor.onnx'),providers=['CPUExecutionProvider']);actor=ActorStep(checkpoint.policy())
    hidden=torch.zeros(3,128);cell=torch.zeros(3,128)
    for tick in range(4):
        observation=torch.randn(3,checkpoint.policy().width)
        if tick==2:hidden.zero_();cell.zero_()
        with torch.no_grad():expected=actor(observation,hidden,cell)
        actual=session.run(None,{'observation':observation.numpy(),'hidden':hidden.numpy(),'cell':cell.numpy()})
        for left,right in zip(actual,expected):np.testing.assert_allclose(left,right.numpy(),atol=1e-5,rtol=1e-4)
        hidden,cell=expected[1:]
    assert runtime_schema_hash(checkpoint.observation)==json.loads((Path(__file__).parent/'fixtures/policy-schemas.json').read_text())[family]['observation_schema_hash']
    with pytest.raises(ValueError,match='exists'):export_actor(checkpoint,tmp_path/family)
