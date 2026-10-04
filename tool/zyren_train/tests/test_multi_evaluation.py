import copy
import hashlib
import json
import pytest
from zyren_train.evaluate import EvaluationPlan
from zyren_train.metrics import EpisodeMetric, aggregate
from zyren_train.regression import MULTI_TARGETS, qualify_multi
from zyren_train.report import EvaluationReport
from zyren_train.scenario import canonical_bytes


def digest(value): return hashlib.sha256(canonical_bytes(value)).hexdigest()


def plan_value():
    def spec(family, variant='heldout'):
        return {'schema_version':1,'id':family+'-'+variant,'partition':'test',
                'game_build_hash':'build','observation_schema_hash':family+'-obs','action_schema_hash':'action',
                'callback_id':family,'reward_terms':[{'id':'progress','cap':1.}], 'seed':7,'max_steps':600,
                'control_cadence':1,'latency_ticks':1,'assets':[],'settings':{'map':variant,'fixed_hz':50}}
    profiles={f:{'version':2,'task':f,'fixed_hz':50,'max_hold_ticks':2} for f in MULTI_TARGETS}
    opponents=[{'id':kind+'-'+str(i),'kind':kind,'policy_hash':digest([kind,i]),'config_hash':digest(['config',kind,i])}
               for kind,n in [('fixed',2),('withheld',2),('historical',4)] for i in range(n)]
    cases=[{'id':'joint','family':'cooperative-search','role':'joint','opponent':None,'phase':'heldout',
            'scenario':spec('cooperative-search'),'seeds':list(range(100,300)),
            'stress':{'miss_every':0,'delay_every':0},'coverage':['joint-goal']}]
    for role in ['pursuer','evader']:
        for opponent in opponents:
            cases.append({'id':role+'-'+opponent['id'],'family':'competitive-pursuit','role':role,
                          'opponent':opponent['id'],'phase':'historical' if opponent['kind']=='historical' else 'heldout',
                          'scenario':spec('competitive-pursuit'),'seeds':list(range(300,350)),
                          'stress':{'miss_every':0,'delay_every':0},'coverage':['role-cross-play']})
    return {'schema_version':2,'id':'team-release-v2','targets':MULTI_TARGETS,'cases':cases,
            'training_scenario_hashes':[],'training_opponent_hashes':[],
            'worker_sha256':'a'*64,'worker_native_sha256':{'lib/physics.dylib':'b'*64},
            'multi_profiles':profiles,'multi_profile_hashes':{f:digest(p) for f,p in profiles.items()},
            'opponents':opponents,'initial_baseline':True,'previous_checkpoint':None,
            'paired_worlds':[{'family':f,'left':spec(f,'hidden-left'),
                              'right':spec(f,'hidden-right'),'seed':7,'steps':20,'actors':['a']} for f in MULTI_TARGETS]}


def report_value(plan):
    data=plan.data
    rows=[EpisodeMetric(index,seed,c['scenario']['id'],c['family'],'completed',True,False,0.,0.,100,
                        role=c['role'],opponent=c['opponent'],result='win')
          for index,(seed,c) in enumerate((seed,c) for c in data['cases'] for seed in c['seeds'])]
    joint=[r for r in rows if r.family=='cooperative-search'];roles={};opponents={};history={};history_roles={}
    for role in ['pursuer','evader']:
        selected=[r for r in rows if r.role==role];opponents[role]={};history[role]={}
        for o in data['opponents']:
            group=[r for r in selected if r.opponent==o['id']]
            (history if o['kind']=='historical' else opponents)[role][o['id']]=aggregate(group,len(group))
        group=[r for r in selected if any(o['id']==r.opponent and o['kind']!='historical' for o in data['opponents'])]
        roles[role]=aggregate(group,len(group))
        group=[r for r in selected if any(o['id']==r.opponent and o['kind']=='historical' for o in data['opponents'])]
        history_roles[role]=aggregate(group,len(group))
    cooperative=aggregate(joint,len(joint))
    status,reasons=qualify_multi(cooperative,roles,opponents,hidden_state_leaks=0,reward_exploits=0,
        worker_failures=0,stale_outputs=0,historical=history,previous=None,initial_baseline=True)
    models={'cooperative-search':'c'*64,'competitive-pursuit':'d'*64}
    return {'schema_version':2,'plan':data,'plan_hash':plan.hash,'model_hash':digest(models),
        'family_model_hashes':models,'role_model_hashes':{'pursuer':models['competitive-pursuit'],'evader':models['competitive-pursuit']},'provider':'test-identity-only','status':status,'reasons':reasons,
        'requested':plan.requested,'metrics':{'cooperative-search':cooperative,'competitive-pursuit':roles},
        'episodes':[r.to_dict() for r in rows],'opponent_metrics':opponents,'historical_metrics':history,'historical_role_metrics':history_roles,
        'layout_seed_counts':{'cooperative-search':200,'competitive-pursuit':{'pursuer':50,'evader':50}},
        'hidden_state_leaks':0,'reward_exploits':0,'stale_outputs':0,'worker_failures':0,
        'worker_exit_codes':[0],'worker_sha256':data['worker_sha256'],
        'worker_native_sha256':data['worker_native_sha256']}


def test_v2_plan_keeps_each_role_and_withheld_opponent_separate():
    value=plan_value();plan=EvaluationPlan.from_dict(value)
    assert plan.requested==1000 and plan.data['targets']==MULTI_TARGETS
    for mutate in [lambda v:v['cases'].pop(),
                   lambda v:v['training_opponent_hashes'].append(v['opponents'][2]['policy_hash']),
                   lambda v:v['targets']['competitive-pursuit'].__setitem__('win_rate',0),
                   lambda v:v['cases'][1]['seeds'].append(v['cases'][1]['seeds'][0])]:
        forged=json.loads(canonical_bytes(value));mutate(forged)
        with pytest.raises(ValueError):EvaluationPlan.from_dict(forged)


def test_v2_report_recomputes_joint_role_and_opponent_denominators():
    plan=EvaluationPlan.from_dict(plan_value());value=report_value(plan)
    assert EvaluationReport.from_dict(value).data['status']=='passed'
    for mutate in [lambda v:v['episodes'][200].__setitem__('role','evader'),
                   lambda v:v['metrics']['competitive-pursuit']['evader'].__setitem__('wins',2000),
                   lambda v:v['family_model_hashes'].__setitem__('evader','e'*64),
                   lambda v:v['role_model_hashes'].__setitem__('evader','e'*64),
                   lambda v:v['episodes'].pop(),
                   lambda v:v['worker_exit_codes'].clear()]:
        forged=copy.deepcopy(value);mutate(forged)
        with pytest.raises(ValueError):EvaluationReport.from_dict(forged)
