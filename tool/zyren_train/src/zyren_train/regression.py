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
