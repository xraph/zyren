import copy,hashlib,json,shutil
from pathlib import Path
import pytest
from test_export import actor_checkpoint
from zyren_train.bundle import ModelBundleManifest,publish_actor
from zyren_train.export import export_actor
from zyren_train.evaluate import EvaluationPlan,_finish
from zyren_train.metrics import EpisodeMetric
from zyren_train.regression import TARGETS
from zyren_train.scenario import canonical_bytes


def accepted_receipt(checkpoint,candidate):
    root=Path(__file__).resolve().parents[3]
    plan=EvaluationPlan.load(root/'tool/zyren_train/configs/evaluation.yaml')
    sha=hashlib.sha256((candidate/'actor.onnx').read_bytes()).hexdigest()
    class Candidate:
        model_hash='a'*64;provider='python-onnxruntime-1.23.2-cpu'
        family_model_hashes={'guard':sha,'vehicle':sha}
    rows=[]
    for case in plan.data['cases']:
        for seed in case['seeds']:rows.append(EpisodeMetric(len(rows),seed,case['scenario']['id'],case['family'],'completed',True,False,1.,1.,240,fallback_steps=1 if case['stress']['miss_every'] else 0))
    evidence={'guard-evaluation':['unfamiliar-layouts','friction'],'guard-memory':['moving-target','occlusion-memory','missed-decisions','delayed-observations','fallback-recovery'],'vehicle-recovery':['moving-hazards']}
    coverage={label for labels in evidence.values() for label in labels}
    return _finish(Candidate(),plan,rows,0,0,0,coverage,[0],evidence)


def prepare(tmp_path):
    checkpoint=actor_checkpoint();candidate=tmp_path/'candidate';export_actor(checkpoint,candidate)
    report=accepted_receipt(checkpoint,candidate);sha=hashlib.sha256((candidate/'actor.onnx').read_bytes()).hexdigest()
    parity={'model_sha256':sha,'status':'passed','provider':'native-onnxruntime-1.23.2-cpu','steps':1000,'completed_runs':1000,'live_sessions':0,'live_results':0,'native_worker_sha256':'b'*64,'typed_controller_steps':1000,'atol':1e-5,'rtol':1e-4,'input_sequence_hash':'a'*64,'max_absolute_error':1e-6,'native_asset_sha256':{'lib/probe':'e'*64}}
    folder=tmp_path/'accepted';publish_actor(candidate,folder,report,parity)
    return candidate,folder,report,parity


def test_directory_resource_integrity_missing_extra_symlink_and_tamper(tmp_path):
    _,folder,report,_=prepare(tmp_path);manifest=ModelBundleManifest.load(folder)
    assert manifest.data['evaluation_report_hash']==report.hash
    for mode in ('missing','extra','symlink','tamper'):
        path=tmp_path/mode;shutil.copytree(folder,path)
        if mode=='missing':(path/'normalization.json').unlink()
        elif mode=='extra':(path/'optimizer.pt').write_bytes(b'no')
        elif mode=='symlink':(path/'normalization.json').unlink();(path/'normalization.json').symlink_to(folder/'normalization.json')
        else:(path/'actor.onnx').write_bytes(b'tampered')
        with pytest.raises((ValueError,OSError)):ModelBundleManifest.load(path)


def test_manifest_path_controller_and_exact_model_evaluation(tmp_path):
    candidate,folder,report,parity=prepare(tmp_path);data=ModelBundleManifest.load(folder).data
    for mutate in (lambda d:d['files'][0].update(path='../actor.onnx'),lambda d:d.update(controller_mapping='vehicle-pedals-v1'),lambda d:d.update(accepted=False),lambda d:d['policy'].update(latency_ticks=2)):
        value=copy.deepcopy(data);mutate(value)
        with pytest.raises(ValueError):ModelBundleManifest.from_dict(value)
    with pytest.raises(ValueError,match='qualification'):publish_actor(candidate,tmp_path/'bad-parity',report,{**parity,'live_results':1})
    with pytest.raises(ValueError,match='qualification'):publish_actor(candidate,tmp_path/'other-model',report,{**parity,'model_sha256':'0'*64})
    assert not (tmp_path/'bad-parity').exists()
    assert not (tmp_path/'other-model').exists()
    with pytest.raises(FileExistsError):publish_actor(candidate,folder,report,parity)
    path=tmp_path/'normalization-forgery';shutil.copytree(folder,path)
    normalization=json.loads((path/'normalization.json').read_bytes());normalization['mean'][0]=1.
    raw=canonical_bytes(normalization);(path/'normalization.json').write_bytes(raw)
    forged=copy.deepcopy(data)
    for resource in forged['files']:
        if resource['path']=='normalization.json':resource.update(sha256=hashlib.sha256(raw).hexdigest(),bytes=len(raw))
    (path/'bundle.json').write_bytes(canonical_bytes(forged))
    with pytest.raises(ValueError,match='embedded actor'):ModelBundleManifest.load(path)


def test_torch_receipt_rejected_even_when_every_resource_pin_is_recomputed(tmp_path):
    from zyren_train.report import EvaluationReport
    candidate,folder,report,parity=prepare(tmp_path)
    for provider in ('torch-2.8.0-cpu','python-onnxruntime-1.23.2-cpu;torch-2.8.0-cpu','python-onnxruntime-1.23.2-cpu;'):
        data=report.data;data['provider']=provider;forged=EvaluationReport.from_dict(data)
        with pytest.raises(ValueError,match='ONNX inference'):publish_actor(candidate,tmp_path/('invalid-'+hashlib.sha256(provider.encode()).hexdigest()[:8]),forged,parity)
        broken=tmp_path/('forged-'+hashlib.sha256(provider.encode()).hexdigest()[:8]);shutil.copytree(folder,broken)
        (broken/'evaluation.json').write_bytes(forged.encoded)
        manifest=json.loads((broken/'bundle.json').read_bytes());manifest['evaluation_report_hash']=forged.hash
        for resource in manifest['files']:
            if resource['path']=='evaluation.json':resource.update(sha256=forged.hash,bytes=len(forged.encoded))
        (broken/'bundle.json').write_bytes(canonical_bytes(manifest))
        with pytest.raises(ValueError,match='ONNX inference'):ModelBundleManifest.load(broken)
