from zyren_train.regression import qualify


def test_missing_metrics_or_auxiliary_qualification_never_passes():
    status,reasons=qualify({},hidden_state_leaks=None,reward_exploits=None,stress_coverage=[])
    assert status=='failed' and reasons


def test_targets_require_denominators_and_fixed_confidence():
    good={'requested':200,'success_denominator':200,'collision_denominator':200,'completed':200,'failed':0,'cancelled':0,'invalid_actions':0,'success_rate':1.,'success_lower95':.98,'collision_rate':0.}
    coverage=['unfamiliar-layouts','moving-target','friction','occlusion-memory','moving-hazards','missed-decisions','delayed-observations','fallback-recovery']
    assert qualify({'guard':good,'vehicle':good},hidden_state_leaks=0,reward_exploits=0,stress_coverage=coverage)[0]=='passed'
    for changed in ({'success_denominator':199},{'failed':1},{'cancelled':1},{'success_lower95':.1},{'requested':1},{'invalid_actions':1}):
        assert qualify({'guard':{**good,**changed},'vehicle':good},hidden_state_leaks=0,reward_exploits=0,stress_coverage=coverage)[0]=='failed'
    assert qualify({'guard':good,'vehicle':{**good,'collision_rate':.03}},hidden_state_leaks=0,reward_exploits=0,stress_coverage=coverage)[0]=='failed'


def test_delayed_sensor_frame_and_missed_decision_do_not_commit_hidden():
    import numpy as np
    from zyren_train.evaluate import decision_action
    class Candidate:
        calls=0
        def act(self,observation,info):self.calls+=1;return np.asarray([1],dtype=np.int64)
    candidate=Candidate()
    info={'tick':5,'episode_id':'episode','actor_generations':{'actor':1},'observation_schema_hash':'obs','action_schema_hash':'action','action_schema':{'branches':[{}],'fallbackDiscrete':[0]}}
    current={**info,'tick':6}
    assert decision_action(candidate,(np.zeros(1),info),current).tolist()==[0]
    assert decision_action(candidate,(np.zeros(1),current),current,missed=True).tolist()==[0]
    assert candidate.calls==0
    assert decision_action(candidate,(np.zeros(1),current),current).tolist()==[1]
    assert candidate.calls==1


def test_subprocess_registers_test_worlds_and_proves_native_metrics(worker_command):
    import hashlib,json
    from pathlib import Path
    from zyren_train.evaluate import EvaluationPlan,PreparedEvaluationWorker,ScriptedCandidate,evaluate,compare_baseline
    from zyren_train.regression import TARGETS
    from zyren_train.train import worker_native_hashes
    from training_support import ROOT
    selected=json.loads((ROOT/'tool/zyren_train/configs/evaluation.yaml').read_text())
    selected['worker_sha256']=hashlib.sha256(Path(worker_command[0]).read_bytes()).hexdigest();selected['worker_native_sha256']=worker_native_hashes(worker_command[0])
    for case in selected['cases']:case['seeds']=case['seeds'][:1]
    plan=EvaluationPlan.from_dict(selected)
    report=evaluate(ScriptedCandidate(),plan,PreparedEvaluationWorker(worker_command,ROOT/'examples/game_lab/training_worker',plan))
    assert all(row['status']=='completed' and row['steps']==240 for row in report.data['episodes'])
    assert report.data['worker_failures']==0 and report.data['worker_exit_codes']==[0]
    assert report.data['hidden_state_leaks']==0 and report.data['reward_exploits']==0
    assert report.data['status']=='failed'  # Four physical episodes do not satisfy the release gate.
    assert compare_baseline(report,report)['families']['guard']['success_rate_delta']==0
