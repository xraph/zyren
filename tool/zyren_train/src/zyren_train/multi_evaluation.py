"""Additive v2 team contracts used by the existing evaluation receipt classes."""
import hashlib
import re
from .scenario import ScenarioSpec, canonical_bytes
from .regression import MULTI_TARGETS

FAMILIES = frozenset(MULTI_TARGETS)
SHA = re.compile(r'^[0-9a-f]{64}$')


def _digest(value):
    if not isinstance(value, str) or not SHA.fullmatch(value):
        raise ValueError('Immutable multi artifact hash differs')
    return value


def validate_plan(value):
    required = {'schema_version','id','cases','paired_worlds','targets',
                'training_scenario_hashes','training_opponent_hashes','worker_sha256',
                'worker_native_sha256','multi_profiles','multi_profile_hashes',
                'opponents','initial_baseline','previous_checkpoint'}
    if not isinstance(value, dict) or set(value) != required or type(value['schema_version']) is not int or value['schema_version'] != 2 or value['targets'] != MULTI_TARGETS:
        raise ValueError('Immutable multi evaluation schema or gate changed')
    canonical_bytes(value)
    if not isinstance(value['id'],str) or not 1 <= len(value['id']) <= 128:
        raise ValueError('Multi evaluation identity differs')
    for field in ('training_scenario_hashes','training_opponent_hashes'):
        hashes=value[field]
        if not isinstance(hashes,list) or len(hashes)>1000 or len(set(hashes))!=len(hashes):
            raise ValueError('Multi training lineage differs')
        for digest in hashes:_digest(digest)
    _digest(value['worker_sha256'])
    native=value['worker_native_sha256']
    if not isinstance(native,dict) or not native or len(native)>64:
        raise ValueError('Native multi worker pins missing')
    for name,digest in native.items():
        if not isinstance(name,str) or not name.startswith('lib/') or '..' in name.split('/') or '\\' in name:
            raise ValueError('Native artifact path differs')
        _digest(digest)
    profiles=value['multi_profiles'];profile_hashes=value['multi_profile_hashes']
    if not isinstance(profiles,dict) or set(profiles)!=FAMILIES or not isinstance(profile_hashes,dict) or set(profile_hashes)!=FAMILIES:
        raise ValueError('Both shared multi profiles required')
    for family,profile in profiles.items():
        if not isinstance(profile,dict) or profile.get('version')!=2 or profile.get('task')!=family or profile.get('fixed_hz')!=50 or profile.get('max_hold_ticks')!=2:
            raise ValueError('Shared multi profile identity differs')
        if hashlib.sha256(canonical_bytes(profile)).hexdigest()!=_digest(profile_hashes[family]):
            raise ValueError('Shared multi profile hash differs')
    opponents=value['opponents']
    if not isinstance(opponents,list) or not 8<=len(opponents)<=16:
        raise ValueError('Pinned fixed, withheld and historical opponents required')
    catalog={}
    for item in opponents:
        if not isinstance(item,dict) or set(item)!={'id','kind','policy_hash','config_hash'} or item['kind'] not in ('fixed','withheld','historical') or not isinstance(item['id'],str) or not re.fullmatch('[A-Za-z0-9_-]{1,80}',item['id']) or item['id'] in catalog:
            raise ValueError('Opponent identity differs')
        _digest(item['policy_hash']);_digest(item['config_hash'])
        if item['kind']=='withheld' and item['policy_hash'] in value['training_opponent_hashes']:
            raise ValueError('Withheld opponent entered training pool')
        catalog[item['id']]=item
    if sum(o['kind']=='fixed' for o in opponents)!=2 or sum(o['kind']=='withheld' for o in opponents)!=2 or sum(o['kind']=='historical' for o in opponents)<4:
        raise ValueError('Opponent strata differ from preregistered gate')
    withheld=[o['policy_hash'] for o in opponents if o['kind']=='withheld']
    if len(set(withheld))!=2:raise ValueError('Withheld opponents must be independently frozen')
    cases=value['cases']
    if not isinstance(cases,list) or not 1<=len(cases)<=128:
        raise ValueError('Bounded multi cases required')
    identifiers=set();slots=set();profile_pins={};counts={};requested=0
    for case in cases:
        if not isinstance(case,dict) or set(case)!={'id','family','role','opponent','phase','scenario','seeds','stress','coverage'} or case['family'] not in FAMILIES or not isinstance(case['id'],str) or not re.fullmatch('[A-Za-z0-9_-]{1,80}',case['id']) or case['id'] in identifiers:
            raise ValueError('Multi case identity differs')
        identifiers.add(case['id']);family=case['family'];role=case['role'];opponent=case['opponent'];phase=case['phase']
        if family=='cooperative-search':
            if role!='joint' or opponent is not None or phase!='heldout':raise ValueError('Cooperative episodes require joint outcomes')
        elif role not in ('pursuer','evader') or opponent not in catalog or phase not in ('heldout','historical') or (catalog[opponent]['kind']=='historical')!=(phase=='historical'):
            raise ValueError('Competitive role/opponent phase differs')
        spec=ScenarioSpec.from_dict(case['scenario'])
        if spec.partition!='test' or spec.hash in value['training_scenario_hashes']:
            raise ValueError('Multi TRAIN/test content overlap')
        if spec.control_cadence!=1 or spec.latency_ticks!=1 or spec.settings.get('fixed_hz')!=50:raise ValueError('Native multi clock ABI differs')
        pin=(spec.observation_schema_hash,spec.action_schema_hash)
        if family in profile_pins and profile_pins[family]!=pin:raise ValueError('Multi family tensor profile differs')
        profile_pins[family]=pin
        seeds=case['seeds']
        if not isinstance(seeds,list) or not seeds or len(seeds)>2048 or any(type(seed) is not int or not 0<=seed<2**31 for seed in seeds) or len(set(seeds))!=len(seeds):
            raise ValueError('Fixed multi episode seeds differ')
        for seed in seeds:
            slot=(family,role,opponent,phase,spec.hash,seed)
            if slot in slots:raise ValueError('Duplicate multi evaluation slot')
            slots.add(slot)
        if case['stress']!={'miss_every':0,'delay_every':0}:
            raise ValueError('Multi stress must retain the registered exact-due controller')
        if not isinstance(case['coverage'],list) or len(case['coverage'])>16 or any(not isinstance(c,str) for c in case['coverage']):raise ValueError('Multi coverage differs')
        counts[(family,role,opponent,phase)]=counts.get((family,role,opponent,phase),0)+len(seeds)
        requested+=len(seeds)
    if requested>8192 or sum(n for (f,_,_,_),n in counts.items() if f=='cooperative-search')<200:
        raise ValueError('Joint multi episode budget differs')
    for role in ('pursuer','evader'):
        for opponent,item in catalog.items():
            phase='historical' if item['kind']=='historical' else 'heldout'
            count=counts.get(('competitive-pursuit',role,opponent,phase),0)
            if count!=50:raise ValueError('Every role requires 50 slots per pinned opponent')
    pairs=value['paired_worlds']
    if not isinstance(pairs,list) or not 1<=len(pairs)<=16:raise ValueError('Multi paired-world suite required')
    represented=set()
    for pair in pairs:
        if not isinstance(pair,dict) or set(pair)!={'family','left','right','seed','steps','actors'} or pair['family'] not in FAMILIES or type(pair['seed']) is not int or not 0<=pair['seed']<2**31 or type(pair['steps']) is not int or not 1<=pair['steps']<=600 or not isinstance(pair['actors'],list) or not pair['actors'] or len(pair['actors'])>64 or len(set(pair['actors']))!=len(pair['actors']) or any(not isinstance(actor,str) or not re.fullmatch('[A-Za-z0-9_.:/-]{1,256}',actor) for actor in pair['actors']):raise ValueError('Multi paired-world identity differs')
        represented.add(pair['family'])
        a,b=[ScenarioSpec.from_dict(pair[k]) for k in ('left','right')]
        if a.partition!='test' or b.partition!='test' or a.hash==b.hash or any(s.hash in value['training_scenario_hashes'] for s in (a,b)) or (a.observation_schema_hash,a.action_schema_hash)!=(b.observation_schema_hash,b.action_schema_hash) or (a.observation_schema_hash,a.action_schema_hash)!=profile_pins.get(pair['family']):raise ValueError('Multi paired worlds must remain separate with matching profiles')
    if represented!=FAMILIES:raise ValueError('Every multi family requires paired-hidden evidence')
    initial=value['initial_baseline'];previous=value['previous_checkpoint']
    if type(initial) is not bool or initial and previous is not None:
        raise ValueError('Explicit initial cycling baseline differs')
    if not initial:
        if not isinstance(previous,dict) or set(previous)!={'report_hash','role_win_rates'} or set(previous['role_win_rates'])!={'pursuer','evader'} or any(type(n) not in (int,float) or not 0<=n<=1 for n in previous['role_win_rates'].values()):raise ValueError('Previous cycling checkpoint receipt differs')
        _digest(previous['report_hash'])
    return canonical_bytes(value)


def validate_report(value):
    from .evaluate import EvaluationPlan
    from .metrics import EpisodeMetric, aggregate
    from .regression import qualify_multi
    required={'schema_version','plan','plan_hash','model_hash','family_model_hashes','provider',
              'status','reasons','requested','metrics','episodes','opponent_metrics','historical_metrics','role_model_hashes',
              'layout_seed_counts','hidden_state_leaks','reward_exploits','stale_outputs',
              'worker_failures','worker_exit_codes','worker_sha256','worker_native_sha256','historical_role_metrics'}
    if not isinstance(value,dict) or set(value)!=required or type(value['schema_version']) is not int or value['schema_version']!=2:
        raise ValueError('Multi evaluation report schema differs')
    canonical_bytes(value,16_777_216)
    plan=EvaluationPlan.from_dict(value['plan']);data=plan.data
    if value['plan_hash']!=plan.hash or value['requested']!=plan.requested or any(value[key]!=data[key] for key in ('worker_sha256','worker_native_sha256')):
        raise ValueError('Multi report artifact identity differs')
    models=value['family_model_hashes']
    if not isinstance(models,dict) or set(models)!=FAMILIES:
        raise ValueError('Independent multi family actor pins required')
    for digest in models.values():_digest(digest)
    if value['role_model_hashes']!={'pursuer':models['competitive-pursuit'],'evader':models['competitive-pursuit']}:
        raise ValueError('Both competitive roles require the exact same actor bytes')
    if value['model_hash']!=hashlib.sha256(canonical_bytes(models)).hexdigest() or not isinstance(value['provider'],str) or not value['provider']:
        raise ValueError('Multi model/provider identity differs')
    expected=[(seed,case) for case in data['cases'] for seed in case['seeds']]
    rows=[EpisodeMetric(**row) for row in value['episodes']]
    if len(rows)!=len(expected) or any((row.index,row.seed,row.scenario,row.family,row.role,row.opponent)!=(index,seed,case['scenario']['id'],case['family'],case['role'],case['opponent']) for index,(row,(seed,case)) in enumerate(zip(rows,expected))):
        raise ValueError('Multi requested slot/role/opponent coverage differs')
    joint=[row for row in rows if row.family=='cooperative-search']
    cooperative=aggregate(joint,len(joint))
    roles={};opponents={};historical={};historical_roles={}
    for role in ('pursuer','evader'):
        opponents[role]={};historical[role]={};heldout=[]
        for opponent in data['opponents']:
            selected=[row for row in rows if row.family=='competitive-pursuit' and row.role==role and row.opponent==opponent['id']]
            item=aggregate(selected,len(selected))
            if opponent['kind']=='historical':historical[role][opponent['id']]=item
            else:opponents[role][opponent['id']]=item;heldout.extend(selected)
        roles[role]=aggregate(heldout,len(heldout))
        previous=[row for row in rows if row.family=='competitive-pursuit' and row.role==role and any(o['id']==row.opponent and o['kind']=='historical' for o in data['opponents'])]
        historical_roles[role]=aggregate(previous,len(previous))
    metrics={'cooperative-search':cooperative,'competitive-pursuit':roles}
    seeds={'cooperative-search':len({row.seed for row in joint}),
           'competitive-pursuit':{role:len({row.seed for row in rows if row.family=='competitive-pursuit' and row.role==role and any(o['id']==row.opponent and o['kind']!='historical' for o in data['opponents'])}) for role in roles}}
    if value['metrics']!=metrics or value['opponent_metrics']!=opponents or value['historical_metrics']!=historical or value['layout_seed_counts']!=seeds or value['historical_role_metrics']!=historical_roles:
        raise ValueError('Multi aggregate or independent denominator differs')
    for counter in ('hidden_state_leaks','reward_exploits','stale_outputs','worker_failures'):
        if value[counter] is not None and (type(value[counter]) is not int or value[counter]<0):raise ValueError('Multi failure counter differs')
    exits=value['worker_exit_codes']
    if not isinstance(exits,list) or len(exits)>64 or any(code is not None and type(code) is not int for code in exits):raise ValueError('Multi worker close receipt differs')
    previous=data['previous_checkpoint']
    status,reasons=qualify_multi(cooperative,roles,opponents,
        hidden_state_leaks=value['hidden_state_leaks'],reward_exploits=value['reward_exploits'],
        worker_failures=value['worker_failures'],stale_outputs=value['stale_outputs'],historical=historical,
        previous=None if previous is None else previous['role_win_rates'],initial_baseline=data['initial_baseline'])
    if not exits or any(code!=0 for code in exits):reasons.append('worker close evidence missing or failed');status='failed'
    if seeds['cooperative-search']<20 or any(n<20 for n in seeds['competitive-pursuit'].values()):reasons.append('held-out layout seeds too few');status='failed'
    if any(row.status=='completed' and row.steps<1 for row in rows):reasons.append('native task execution missing');status='failed'
    if value['status']!=status or value['reasons']!=reasons:raise ValueError('Multi acceptance differs from immutable gate')
    return canonical_bytes(value,16_777_216)
