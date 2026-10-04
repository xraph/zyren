import pytest
import torch
from zyren_train.policies.visual import VisualPolicy


@pytest.mark.parametrize('channels',[2,3,5])
def test_visual_encoder_uses_camera_planes_and_body_with_recurrent_reset(channels):
    torch.set_num_threads(1); torch.manual_seed(7)
    policy=VisualPolicy(channels,8,{'kind':'multi_discrete','nvec':[3]},fallback=[1])
    observations=torch.zeros(3,2,channels*84*84+8)
    observations[:,:,:channels*84*84]=.2
    observations[:,:,channels*84*84:]=.1
    starts=torch.zeros(3,2,dtype=torch.bool); starts[1,0]=True
    output,value,state=policy.sequence(observations,starts)
    isolated=policy.sequence(observations[1:2,:1],torch.ones(1,1,dtype=torch.bool))[0]
    assert torch.allclose(output[1:2,:1],isolated,atol=1e-6)
    assert output.shape==(3,2,3) and value.shape==(3,2)
    assert sum(p.numel() for p in policy.parameters())<500_000
    assert torch.isfinite(output).all() and torch.isfinite(state[0]).all()
    loss=output.square().mean()+value.square().mean(); loss.backward()
    assert policy.mlp.camera[0].weight.grad.abs().sum()>0
    assert policy.mlp.body[0].weight.grad.abs().sum()>0
    with pytest.raises(ValueError):VisualPolicy(4,8,{'kind':'box','low':[0],'high':[1]})


def test_visual_factory_rejects_structured_teacher_as_student_input():
    from zyren_train.policies.visual import create_policy
    network={'architecture':'native-camera-cnn-v1','channels':3,'body_width':8,'lstm_hidden_size':128}
    import json
    from pathlib import Path
    profile=json.loads((Path(__file__).parent/'fixtures/visual-profiles.json').read_text())['guard-visual-rgb']
    schema=profile['observation'];metadata=profile['visual_profile']
    assert isinstance(create_policy(network,21176,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},observation_schema=schema,visual_profile=metadata,fallback=[2,2,2,1,0,0]),VisualPolicy)
    schema['fields'][1]['name']='teacher_observation'
    with pytest.raises(ValueError,match='Native camera'):create_policy(network,21176,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},observation_schema=schema,visual_profile=metadata,fallback=[2,2,2,1,0,0])



def test_visual_actor_only_onnx_carries_explicit_state(tmp_path):
    import numpy as np
    import onnxruntime as ort
    from zyren_train.export import ActorStep
    policy=VisualPolicy(2,8,{'kind':'box','low':[-1,0,0],'high':[1,1,1]}).eval()
    actor=ActorStep(policy).eval();inputs=(torch.zeros(1,policy.width),torch.zeros(1,128),torch.zeros(1,128))
    path=tmp_path/'visual.onnx'
    torch.onnx.export(actor,inputs,str(path),input_names=['observation','hidden','cell'],output_names=['action','next_hidden','next_cell'],opset_version=17,dynamo=False)
    session=ort.InferenceSession(str(path),providers=['CPUExecutionProvider'])
    with torch.no_grad():expected=actor(*inputs)
    actual=session.run(None,{n:v.numpy() for n,v in zip(['observation','hidden','cell'],inputs)})
    for left,right in zip(actual,expected):np.testing.assert_allclose(left,right.numpy(),atol=1e-5,rtol=1e-4)


@pytest.mark.parametrize('width',[21176,35288])
def test_existing_recording_and_statistics_accept_bounded_native_camera_width(width):
    from zyren_train.demonstration import validate_record
    from zyren_train.dataset import DatasetPartition,EpisodeReceipt
    from zyren_train.normalize import ObservationNormalizer,ObservationSample
    values=[.2]*width
    row={'episode_id':'ep','tick':1,'actor_generations':{'actor':1},'observations':{'actor':values},
        'proposed_actions':{'actor':[0.]},'applied_actions':{'actor':[0.]},'fallback':{'actor':False},
        'delay_ticks':{'actor':1},'reward_terms':{'task.progress':0.},'terminated':True,'truncated':False}
    validate_record(row,{'scenario':{'reward_terms':[{'id':'task.progress','cap':1}]}})
    episode=EpisodeReceipt('ep','scenario','session',1,'observation','action','build','train','scripted')
    normalizer=ObservationNormalizer.fit(DatasetPartition('train',(episode,)),observations=[ObservationSample('session','ep','scenario',tuple(values))])
    assert len(normalizer.mean)==width and normalizer.count==1
    row['observations']['actor']=[0.]*65537
    with pytest.raises(ValueError):validate_record(row,{'scenario':{'reward_terms':[{'id':'task.progress','cap':1}]}})


def test_visual_normalization_preserves_native_camera_affine_and_pins_strategy():
    from zyren_train.dataset import DatasetPartition,EpisodeReceipt
    from zyren_train.normalize import ObservationNormalizer,ObservationSample
    episode=EpisodeReceipt('ep','scenario','session',2,'observation','action','build','train','scripted')
    part=DatasetPartition('train',(episode,))
    samples=[ObservationSample('session','ep','scenario',(.2,.4,2.,4.)),ObservationSample('session','ep','scenario',(.8,.6,4.,8.))]
    fitted=ObservationNormalizer.fit(part,observations=samples,identity_prefix=2)
    ordinary=ObservationNormalizer.fit(part,observations=samples)
    assert fitted.mean==(0.,0.,3.,6.) and fitted.scale==(1.,1.,1.,2.)
    assert fitted.source_hash!=ordinary.source_hash and fitted.transform([.2,.4,2.,4.])==[.2,.4,-1.,-1.]
    with pytest.raises(ValueError):ObservationNormalizer.fit(part,observations=samples,identity_prefix=5)
