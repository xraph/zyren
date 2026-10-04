import numpy as np
import torch
from zyren_train.multi_execution import MultiPolicyActor, evaluate_multi
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.evaluate import EvaluationPlan
from test_multi_evaluation import plan_value


def test_shared_actor_weights_have_private_generation_memory_and_no_teacher_inputs():
    torch.manual_seed(3)
    policy=StructuredPolicy(36,{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},fallback=[2,2,2,1,0,0])
    actor=MultiPolicyActor(policy,model_hash='a'*64,config_hash='b'*64,
        observation_hash='obs',action_hash='action')
    info={'episode_id':'one','actor_generation':1,'tick':1,'observation_schema_hash':'obs',
          'action_schema_hash':'action','legality':[[True]*n for n in policy.nvec]}
    obs=np.zeros(36,dtype=np.float32)
    a=actor.act('a',obs,info);ha=actor.hidden_snapshot('a')
    b=actor.act('b',obs,info);hb=actor.hidden_snapshot('b')
    assert np.array_equal(a,b) and all(torch.equal(x,y) for x,y in zip(ha,hb))
    actor.act('a',obs,{**info,'tick':2})
    assert all(torch.equal(x,y) for x,y in zip(hb,actor.hidden_snapshot('b')))
    actor.act('a',obs,{**info,'actor_generation':2,'tick':1})
    assert all(torch.equal(x,y) for x,y in zip(ha,actor.hidden_snapshot('a')))
    import pytest
    with pytest.raises(ValueError):actor.act('a',obs,{**info,'teacher_actions':[1]})


def test_cancelled_multi_execution_retains_every_requested_role_and_opponent_slot():
    plan=EvaluationPlan.from_dict(plan_value())
    class Candidate:
        model_hash='c'*64;config_hash='d'*64;provider='synthetic-no-qualification'
    families={'cooperative-search':Candidate(),'competitive-pursuit':Candidate()}
    opponents={o['id']:type('Opponent',(),{'model_hash':o['policy_hash'],'config_hash':o['config_hash']})()
               for o in plan.data['opponents']}
    def forbidden():raise AssertionError('cancelled work cannot allocate a worker')
    report=evaluate_multi(families,plan,forbidden,opponents=opponents,cancelled=lambda:True)
    assert report.data['status']=='failed' and len(report.data['episodes'])==1000
    assert all(row['status']=='cancelled' for row in report.data['episodes'])
    assert report.data['historical_role_metrics']['evader']['cancelled']==200


def test_native_execution_adapter_runs_joint_and_each_role_without_metric_inputs(monkeypatch):
    import zyren_train.multi_execution as execution
    plan=EvaluationPlan.from_dict(plan_value())
    class Candidate:
        model_hash='c'*64;config_hash='d'*64;provider='synthetic-no-qualification'
        def reset(self):pass
        def act(self,actor,observation,info):
            assert set(info)=={'tick','episode_id','actor_generation','observation_schema_hash','action_schema_hash','legality'}
            return np.array([2,2,2,1,0,0])
    class Process:returncode=0
    class Worker:
        process=Process()
        def close(self):pass
    class Env:
        def __init__(self,spec,name):self.spec=spec;self.name=name;self.agents=[];self.training_only={'distances':{'a':5.,'b':5.}}
        def reset(self,seed):
            self.agents=['a','b'];self._header={'scenario_spec':self.spec.to_dict(),'split':'test',
                'physics_backend':'rapier','task_roles':{'a':'pursuer','b':'evader'}}
            if self.spec.callback_id=='cooperative-search':self._header['task_roles']={'a':'scout','b':'searcher'}
            return {a:np.zeros(36,dtype=np.float32) for a in self.agents},{a:{'tick':1,'episode_id':'one','actor_generation':1,
                'observation_schema_hash':self.spec.observation_schema_hash,'action_schema_hash':self.spec.action_schema_hash,
                'legality':[[True]*n for n in [5,5,5,3,2,2]]} for a in self.agents}
        def step(self,actions):
            self.agents=[];self._header.update(collision=False,applied_actions={a:v.tolist() for a,v in actions.items()},
                per_agent_results=({'a':'win','b':'win'} if self.spec.callback_id=='cooperative-search' else
                    {'a':'loss','b':'win'} if self.name.startswith('multi-evader') else {'a':'win','b':'loss'}))
            return {},{'a':0.,'b':0.},{'a':True,'b':True},{'a':False,'b':False},{}
        def close(self):pass
    monkeypatch.setattr(execution,'_env',lambda worker,spec,name:Env(spec,name))
    candidates={f:Candidate() for f in plan.data['multi_profiles']}
    opponents={o['id']:Candidate() for o in plan.data['opponents']}
    for o in plan.data['opponents']:
        opponents[o['id']].model_hash=o['policy_hash'];opponents[o['id']].config_hash=o['config_hash']
    report=evaluate_multi(candidates,plan,Worker,opponents=opponents,auxiliary=False).data
    assert len(report['episodes'])==1000 and all(r['status']=='completed' for r in report['episodes'])
    assert report['metrics']['competitive-pursuit']['evader']['wins']==200
    assert report['historical_role_metrics']['pursuer']['wins']==200
    assert report['hidden_state_leaks'] is None and report['status']=='failed'
