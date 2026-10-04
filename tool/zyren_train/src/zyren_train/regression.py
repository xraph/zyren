"""Fixed first-release policy gates. Changing a gate changes evaluation identity."""
from .dataset import _freeze

TARGETS=_freeze({'guard':{'success_rate':.90,'success_lower95':.85,'collision_rate':None},
         'vehicle':{'success_rate':.95,'success_lower95':.90,'collision_rate':.02}})


def qualify(metrics,*,hidden_state_leaks,reward_exploits,stress_coverage,requested_per_family=200):
    reasons=[]
    if hidden_state_leaks is None: reasons.append('paired-world suite missing')
    elif hidden_state_leaks!=0: reasons.append('hidden-state leakage')
    if reward_exploits is None: reasons.append('reward exploit suite missing')
    elif reward_exploits!=0: reasons.append('repeatable reward exploit')
    required={'unfamiliar-layouts','moving-target','friction','occlusion-memory','moving-hazards','missed-decisions','delayed-observations','fallback-recovery'}
    if not required<=set(stress_coverage): reasons.append('stress coverage missing')
    for family in ('guard','vehicle'):
        item=metrics.get(family)
        if item is None: reasons.append(f'{family} metrics missing'); continue
        if item.get('success_denominator')!=item['requested'] or item.get('collision_denominator')!=item['requested'] or not 0<=item['success_rate']<=1 or not 0<=item['success_lower95']<=item['success_rate'] or not 0<=item['collision_rate']<=1:reasons.append(f'{family} denominator/rate differs')
        if item['requested']<requested_per_family: reasons.append(f'{family} episode budget too small')
        if item['failed'] or item['cancelled'] or item['completed']!=item['requested']: reasons.append(f'{family} incomplete/failed episodes')
        if item['invalid_actions']: reasons.append(f'{family} invalid actions')
        targets=TARGETS[family]
        if item['success_rate']<targets['success_rate'] or item['success_lower95']<targets['success_lower95']: reasons.append(f'{family} success target missed')
        if targets['collision_rate'] is not None and item['collision_rate']>targets['collision_rate']: reasons.append('vehicle collision target missed')
    return 'passed' if not reasons else 'failed',reasons


MULTI_TARGETS=_freeze({
    'cooperative-search': {'joint_episodes':200,'joint_success_rate':.95,'joint_success_lower95':.90,'collision_upper95':.02},
    'competitive-pursuit': {'episodes_per_role':200,'opponents_per_role':4,'episodes_per_opponent':50,
        'win_rate':.60,'win_lower95':.50,'per_opponent_win_rate':.50,'collision_upper95':.02,
        'historical_opponents_min':4,'historical_episodes_per_role':200,'historical_episodes_per_opponent':50,'historical_win_rate':.40,'maximum_cycling_drop':.10},
})


def qualify_multi(cooperative,roles,opponents,*,hidden_state_leaks,reward_exploits,
                  worker_failures,stale_outputs,historical,previous,initial_baseline):
    reasons=[]
    for name,count in [('paired-world leakage',hidden_state_leaks),('reward exploits',reward_exploits),('worker failures',worker_failures),('stale outputs',stale_outputs)]:
        if type(count) is not int or count!=0:reasons.append(name+' missing or nonzero')
    def execution(item,label,minimum,contact_gate=True):
        from .confidence import wilson
        if not isinstance(item,dict):reasons.append(label+' missing');return False
        fields=('requested','completed','failed','cancelled','successes','collisions','invalid_actions','wins','draws','losses','success_denominator','collision_denominator','win_denominator')
        if any(type(item.get(key)) is not int or item[key]<0 for key in fields):
            reasons.append(label+' count receipt differs');return False
        count=item['requested']
        if count<minimum or any(item[key]!=count for key in ('success_denominator','collision_denominator','win_denominator')) or item['completed']+item['failed']+item['cancelled']!=count or item['wins']+item['draws']+item['losses']!=count or item['successes']!=item['wins'] or item['collisions']>count:
            reasons.append(label+' denominator/budget differs');return False
        low,high=wilson(item['wins'],count);clow,chigh=wilson(item['collisions'],count)
        expected={'win_rate':item['wins']/count,'success_rate':item['wins']/count,'win_lower95':low,'win_upper95':high,'success_lower95':low,'success_upper95':high,'collision_rate':item['collisions']/count,'collision_lower95':clow,'collision_upper95':chigh}
        if any(item.get(key)!=number for key,number in expected.items()):reasons.append(label+' rate/CI receipt differs');return False
        if item['failed'] or item['cancelled'] or item['completed']!=count or item['invalid_actions']:reasons.append(label+' incomplete or invalid')
        if contact_gate and chigh>.02:reasons.append(label+' contact target missed')
        return True
    target=MULTI_TARGETS['cooperative-search']
    if execution(cooperative,'cooperative joint',target['joint_episodes']):
        if cooperative.get('success_rate',0)<target['joint_success_rate'] or cooperative.get('success_lower95',0)<target['joint_success_lower95']:reasons.append('cooperative joint success missed')
    target=MULTI_TARGETS['competitive-pursuit']
    if not isinstance(roles,dict) or set(roles)!={'pursuer','evader'}:reasons.append('competitive roles missing');roles={}
    if not isinstance(opponents,dict) or set(opponents)!={'pursuer','evader'}:reasons.append('opponent strata missing');opponents={}
    if not isinstance(historical,dict) or set(historical)!={'pursuer','evader'}:reasons.append('historical strata missing');historical={}
    for role in ('pursuer','evader'):
        item=roles.get(role)
        if execution(item,role,target['episodes_per_role']):
            if item.get('win_rate',0)<target['win_rate'] or item.get('win_lower95',0)<target['win_lower95']:reasons.append(role+' win target missed')
        strata=opponents.get(role,{})
        if not isinstance(strata,dict) or len(strata)!=target['opponents_per_role']:reasons.append(role+' opponent coverage differs');strata={}
        for identity,stratum in strata.items():
            if not execution(stratum,role+' opponent '+identity,target['episodes_per_opponent'],False) or stratum.get('requested')!=target['episodes_per_opponent'] or stratum.get('win_rate',0)<target['per_opponent_win_rate']:reasons.append(role+' opponent '+identity+' failed')
        pool=historical.get(role,{})
        if not isinstance(pool,dict) or len(pool)<target['historical_opponents_min']:reasons.append(role+' historical pool missing');pool={}
        total=contacts=0
        for identity,stratum in pool.items():
            valid=execution(stratum,role+' historical '+identity,target['historical_episodes_per_opponent'],False)
            if not valid or stratum.get('win_rate',0)<target['historical_win_rate']:reasons.append(role+' historical '+identity+' failed')
            if valid:
                total+=stratum.get('requested',0);contacts+=stratum.get('collisions',0)
        from .confidence import wilson
        if total<target['historical_episodes_per_role']:reasons.append(role+' historical episode budget differs')
        elif wilson(contacts,total)[1]>target['collision_upper95']:reasons.append(role+' historical contact target missed')
    if initial_baseline is True:
        if previous is not None:reasons.append('initial baseline cannot hide previous checkpoint')
    elif initial_baseline is False:
        if not isinstance(previous,dict) or set(previous)!={'pursuer','evader'}:reasons.append('previous role checkpoint missing')
        else:
            for role in ('pursuer','evader'):
                if previous[role]-roles.get(role,{}).get('win_rate',0)>target['maximum_cycling_drop']:reasons.append(role+' cycling regression')
    else:reasons.append('initial baseline status missing')
    return ('passed' if not reasons else 'failed'),reasons
