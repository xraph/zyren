import base64,copy
import numpy as np
import pytest
import torch
from test_export import actor_checkpoint
from zyren_train.export import ActorStep
from zyren_train.parity import compare_sequence,decode_reference


def fixture_executor(actor,rows,schema):
    hidden=torch.zeros(1,128);cell=hidden.clone();outputs=[];actions=[]
    for row in rows:
        if row['reset']:hidden.zero_();cell.zero_()
        with torch.no_grad():values=actor(torch.tensor([row['observation']],dtype=torch.float32),hidden,cell)
        keys=('logits' if actor.discrete else 'action','next_hidden','next_cell')
        outputs.append({name:{'dtype':'float32','shape':list(value.shape),'data':base64.b64encode(value.numpy().astype('<f4').tobytes()).decode()} for name,value in zip(keys,values)})
        actions.append(decode_reference(values[0].numpy()[0],schema,row.get('legality')));hidden,cell=values[1:]
    return {'model_sha256':'a'*64,'outputs':outputs,'actions':actions,'provider':'native-onnxruntime-1.23.2-cpu','completed_runs':len(rows),'live_sessions':0,'live_results':0}


@pytest.mark.parametrize('family',['guard','vehicle'])
def test_sequence_rejects_action_hidden_identity_and_reset_drift(family):
    checkpoint=actor_checkpoint(family);actor=ActorStep(checkpoint.policy()).eval();schema=checkpoint.action
    rows=[{'observation':[0.1]*actor.observation_mean.numel(),'reset':i%3==0} for i in range(8)]
    if family=='guard':
        for row in rows:row['legality']=[[i==0 for i in range(len(branch['choices']))] for branch in schema['branches']]
    actual=fixture_executor(actor,rows,schema)
    receipt=compare_sequence(actor,rows,lambda _:actual,model_sha256='a'*64,action_schema=schema)
    assert receipt['typed_controller_steps']==8
    broken=copy.deepcopy(actual);broken['model_sha256']='b'*64
    with pytest.raises(ValueError,match='identity'):compare_sequence(actor,rows,lambda _:broken,model_sha256='a'*64,action_schema=schema)
    broken=copy.deepcopy(actual);broken['outputs'][2]['next_hidden']['data']=base64.b64encode(np.ones((1,128),'<f4').tobytes()).decode()
    with pytest.raises(AssertionError):compare_sequence(actor,rows,lambda _:broken,model_sha256='a'*64,action_schema=schema)
    broken=copy.deepcopy(actual);broken['actions'][2]['continuous' if family=='vehicle' else 'discrete'][0]=2
    with pytest.raises((ValueError,AssertionError)):compare_sequence(actor,rows,lambda _:broken,model_sha256='a'*64,action_schema=schema)


def test_pedals_zero_brake_positive_priority_and_masked_ties():
    assert decode_reference(np.array([.2,.8,0]),{'id':'vehicle-pedals-v1','branches':[]})['continuous']==[.2,.8,0]
    assert decode_reference(np.array([.2,.8,.1]),{'id':'vehicle-pedals-v1','branches':[]})['continuous']==[.2,0,.1]
    schema={'branches':[{'choices':['a','b','c']} ]}
    assert decode_reference([9,2,2],schema,[[False,True,True]])['discrete']==[1]
    with pytest.raises(ValueError,match='Legality'):decode_reference([9,2,2],schema,[[False,False,False]])


def test_quantization_requires_verified_training_source_and_preserves_float(tmp_path):
    import hashlib,json
    import onnxruntime as ort
    from test_bundle import prepare
    from test_dataset import recorder,row
    from test_scenario import spec
    from zyren_train.scenario import ScenarioSpec
    from zyren_train.demonstration import DemonstrationRecorder
    from zyren_train.dataset import DatasetPartition
    from zyren_train.quantize import quantize_candidate,qualify_quantized
    _,folder,report,parity=prepare(tmp_path);data=json.loads((folder/'bundle.json').read_bytes())
    source=tmp_path/'calibration';scenario=ScenarioSpec.from_dict({**spec().to_dict(),'observation_schema_hash':data['observation_schema_hash'],'action_schema_hash':data['action_schema_hash']})
    recording=DemonstrationRecorder(source,scenario=scenario,session_id='fixture',run_id='fixture',environment_id='env',source='player',model_hash='none')
    for tick in range(1,9):
        value=row(tick,end=tick==8);value['observations']={'actor':[tick*.01]*14};recording.append(value)
    recording.finalize();partition=DatasetPartition.from_recordings('train',[source])
    before=(folder/'actor.onnx').read_bytes();candidate=quantize_candidate(folder,tmp_path/'int8',partition,steps=8)
    assert candidate['accepted'] is False and not (tmp_path/'int8/bundle.json').exists()
    assert candidate['app_binary_delta_bytes'] is None and candidate['working_memory_delta_bytes'] is None
    assert (folder/'actor.onnx').read_bytes()==before
    ort.InferenceSession(str(tmp_path/'int8/actor.onnx'),providers=['CPUExecutionProvider'])
    with pytest.raises(ValueError,match='Training-only'):quantize_candidate(folder,tmp_path/'bad',DatasetPartition('test',()),steps=8)
    assert qualify_quantized(report,report,'guard')['success_loss']==0
    from test_bundle import accepted_receipt
    from zyren_train.bundle import publish_actor,ModelBundleManifest
    candidate_report=accepted_receipt(None,tmp_path/'int8')
    parity={**parity,'model_sha256':candidate['model_sha256']}
    with pytest.raises(ValueError,match='baseline proof'):publish_actor(tmp_path/'int8',tmp_path/'no-baseline',candidate_report,parity,precision='int8')
    accepted=publish_actor(tmp_path/'int8',tmp_path/'accepted-int8',candidate_report,parity,precision='int8',baseline_bundle=folder)
    assert accepted.data['precision']=='int8'
    provenance=json.loads((tmp_path/'accepted-int8/provenance.json').read_bytes())
    assert provenance['quantization']['success_loss']==0
    provenance['quantization']['success_loss']=.01
    raw=__import__('zyren_train.scenario',fromlist=['canonical_bytes']).canonical_bytes(provenance,262144)
    (tmp_path/'accepted-int8/provenance.json').write_bytes(raw)
    manifest=accepted.data
    for resource in manifest['files']:
        if resource['path']=='provenance.json':resource.update(bytes=len(raw),sha256=hashlib.sha256(raw).hexdigest())
    (tmp_path/'accepted-int8/bundle.json').write_text(json.dumps(manifest))
    with pytest.raises(ValueError,match='success loss'):ModelBundleManifest.load(tmp_path/'accepted-int8')
