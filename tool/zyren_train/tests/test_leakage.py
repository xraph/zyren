import pytest
from test_scenario import spec
from zyren_train.evaluate import EvaluationPlan,evaluate
from zyren_train.regression import TARGETS


def plan():
    def scenario(name):
        data=spec().to_dict();data.update(id=name,partition='test',settings={'held-out':name});return data
    return {'schema_version':1,'id':'immutable-tests-v1','targets':dict(TARGETS),
        'training_scenario_hashes':[], 'worker_sha256':'0'*64,'worker_native_sha256':{'lib/probe':'0'*64},
        'paired_worlds':{'left':scenario('left'),'right':scenario('right'),'seed':7,'steps':10},
        'cases':[{'id':name,'family':name,'scenario':scenario(name),'seeds':list(range(20)),
                  'stress':{'miss_every':0,'delay_every':0},'coverage':[]} for name in ('guard','vehicle')]}


def test_immutable_plan_rejects_train_test_overlap_and_gate_mutation():
    from zyren_train.scenario import ScenarioSpec
    value=plan(); selected=EvaluationPlan.from_dict(value)
    value['cases'][0]['seeds'].append(999)
    assert selected.requested==40
    value=plan();value['training_scenario_hashes']=[ScenarioSpec.from_dict(value['cases'][0]['scenario']).hash]
    with pytest.raises(ValueError,match='overlap'): EvaluationPlan.from_dict(value)
    value=plan();value['targets']={'guard':{'success_rate':0},'vehicle':{}}
    with pytest.raises(ValueError,match='immutable'): EvaluationPlan.from_dict(value)
    with pytest.raises(TypeError):TARGETS['guard']['success_rate']=0


def test_startup_failure_and_cancel_keep_every_requested_episode():
    class Candidate: model_hash='model';provider='test'
    selected=EvaluationPlan.from_dict(plan())
    def broken():raise RuntimeError('supervisor failed')
    result=evaluate(Candidate(),selected,broken).data
    assert result['status']=='failed' and len(result['episodes'])==40
    assert sum(m['failed'] for m in result['metrics'].values())==40
    assert result['metrics']['guard']['success_denominator']==20
    cancelled=evaluate(Candidate(),selected,broken,cancelled=lambda:True).data
    assert sum(m['cancelled'] for m in cancelled['metrics'].values())==40
    assert cancelled['status']!='passed'


def test_report_rejects_modified_metrics_slots_gates_and_overwrite(tmp_path):
    import copy
    from zyren_train.report import EvaluationReport
    class Candidate:model_hash='model';provider='test'
    selected=EvaluationPlan.from_dict(plan())
    def broken():raise RuntimeError('offline failure')
    report=evaluate(Candidate(),selected,broken)
    for mutate in (lambda d:d['metrics']['guard'].update(success_denominator=19),lambda d:d['episodes'].pop(),lambda d:d.update(status='passed'),lambda d:d['episodes'][0].update(success=True)):
        value=copy.deepcopy(report.data);mutate(value)
        with pytest.raises(ValueError):EvaluationReport.from_dict(value)
    path=tmp_path/'receipt.json';report.write(path)
    assert EvaluationReport.load(path).hash==report.hash
    with pytest.raises(ValueError,match='immutable'):report.write(path)


def test_artifact_path_and_paired_training_overlap_rejected():
    from zyren_train.scenario import ScenarioSpec
    for name in ('../probe','lib/../probe','lib/\\probe'):
        value=plan();value['worker_native_sha256']={name:'0'*64}
        with pytest.raises(ValueError):EvaluationPlan.from_dict(value)
    value=plan();value['training_scenario_hashes']=[ScenarioSpec.from_dict(value['paired_worlds']['left']).hash]
    with pytest.raises(ValueError,match='held out'):EvaluationPlan.from_dict(value)
