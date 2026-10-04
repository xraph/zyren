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


def test_visual_export_preserves_public_profile_and_compact_body_normalization(tmp_path):
    from zyren_train.policies.visual import create_policy
    schemas=json.loads((Path(__file__).parent/'fixtures/visual-profiles.json').read_text())['guard-visual-depth']
    action=json.loads((Path(__file__).parent/'fixtures/policy-schemas.json').read_text())['guard']
    network={'architecture':'native-camera-cnn-v1','channels':2,'body_width':8,'lstm_hidden_size':128}
    config=SimpleNamespace(hash='c'*64,data={'network':network,'policy_distribution':'masked-categorical-v1','worker_sha256':'d'*64,'worker_native_sha256':{'lib/probe':'e'*64}})
    policy=create_policy(network,14120,action['action_space'],observation_schema=schemas['observation'],visual_profile=schemas['visual_profile'],fallback=action['action_schema']['fallbackDiscrete'])
    config.data['policy_distribution']=policy.distribution_id
    policy.observation_mean[-8:]=torch.arange(8,dtype=torch.float32)
    policy.observation_scale[-8:]=torch.arange(1,9,dtype=torch.float32)
    state={'model':policy.state_dict(),'normalization':{'source_hash':'a'*64},'source_pins':{},'_checkpoint_sha256':'f'*64}
    checkpoint=ActorCheckpoint(config,state,schemas['observation'],action['action_schema'],action['action_space'],schemas['visual_profile'])
    result=export_actor(checkpoint,tmp_path/'visual')
    assert result['family']=='guard-visual-depth' and not result['accepted']
    manifest=json.loads((tmp_path/'visual/model.json').read_text());normalization=json.loads((tmp_path/'visual/normalization.json').read_text())
    assert manifest['preprocessing']['visualProfile']==schemas['visual_profile']
    assert runtime_schema_hash(manifest['preprocessing']['visualProfile'])==schemas['observation']['configurationHash']
    assert normalization=={'schema_version':1,'mode':'embedded-camera-body-affine-v1','camera_width':14112,'mean':list(range(8)),'scale':list(range(1,9)),'source_hash':'a'*64}
    loaded=create_policy(network,14120,action['action_space'],observation_schema=schemas['observation'],visual_profile=manifest['preprocessing']['visualProfile'],fallback=action['action_schema']['fallbackDiscrete'])
    loaded.load_state_dict(state['model']);loaded.eval()
    session=ort.InferenceSession(str(tmp_path/'visual/actor.onnx'),providers=['CPUExecutionProvider'])
    inputs=(torch.rand(2,14120),torch.randn(2,128),torch.randn(2,128))
    with torch.no_grad():reference=ActorStep(loaded)(*inputs)
    actual=session.run(None,{n:v.numpy() for n,v in zip(['observation','hidden','cell'],inputs)})
    for left,right in zip(actual,reference):np.testing.assert_allclose(left,right.numpy(),atol=1e-5,rtol=1e-4)
