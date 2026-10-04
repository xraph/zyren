import numpy as np
import pytest
from zyren_train.multi_pressure_audit import run_pressure_slot,verify_pressure_contract
from test_multi_evaluation import plan_value
from zyren_train.scenario import ScenarioSpec


def spec(partition='train'):
    value=plan_value()['cases'][0]['scenario']
    value.update(id='competitive-pursuit',partition=partition,callback_id='competitive.pursuit',max_steps=400)
    value['settings'].update(competitive=True,dynamic=False,legal_bounds=[8,9],evader_speed=1.5,fixed_hz=50)
    return ScenarioSpec.from_dict(value)


def test_test_partition_and_unpublished_routes_reject_before_teacher_call():
    class Forbidden:
        def reset(self):raise AssertionError('Teacher must not run')
    with pytest.raises(ValueError):run_pressure_slot(None,spec('test'),7,Forbidden(),Forbidden(),0)
    class Env:
        _header={'scenario_spec':spec().to_dict(),'physics_backend':'rapier','split':'train',
                 'authored_routes':{'a':[],'b':[[6,.81,5]]}}
    with pytest.raises(ValueError):verify_pressure_contract(Env(),spec())


def test_rejected_applied_action_stops_before_next_heading_dependent_teacher_call():
    count={'acts':0,'closed':0}
    class Actor:
        def reset(self):pass
        def act(self,actor,observation,info):count['acts']+=1;return np.array([2,2,2,1,0,0])
    class Env:
        def __init__(self,*args):self.agents=[];self.training_only={'distances':{'a':5.,'b':5.}}
        def reset(self,seed):
            self.agents=['a','b'];self._header={'scenario_spec':spec().to_dict(),'physics_backend':'rapier','split':'train',
                'authored_routes':{'a':[],'b':[[6,.81,5],[6,.81,-6],[-6,.81,-6],[-6,.81,6]]},
                'task_roles':{'a':'pursuer','b':'evader'}}
            return {a:np.zeros(36) for a in self.agents},{a:{} for a in self.agents}
        def step(self,actions):
            self._header.update(collision=False,applied_actions={'a':[2,2,2,1,0,0],'b':[3,2,2,1,0,0]})
            return {a:np.zeros(36) for a in self.agents},{a:0. for a in self.agents},{},{},{a:{} for a in self.agents}
        def close(self):count['closed']+=1
    row,fault,stale=run_pressure_slot(None,spec(),7,Actor(),Actor(),0,environment_factory=lambda *args:Env())
    assert row.status=='failed' and row.invalid_actions>0 and row.steps==1
    assert count=={'acts':2,'closed':1} and fault==stale==0
