"""Bounded privileged physical admission, never part of an actor observation."""
import math
from .scenario import canonical_bytes,decode_json_bytes,identifier,integer

PHYSICAL_CONTRACT='authored-flat-capsule-v1'
SNAPSHOT_FIELDS={'schema_version','geometry','episode_id','tick','actor_ids','actor_generations',
    'positions','active','floor_surface_y','capsule_half_height','capsule_radius','floor_clearance',
    'collision','terminal','contact_depths'}


def _finite(value):
    if type(value) not in (int,float) or not math.isfinite(value) or abs(value)>100000:
        raise ValueError('Invalid bounded physical number')
    return value


def validate_physical_snapshot(value,*,require_admission=True):
    if type(require_admission) is not bool:raise ValueError('Physical admission flag differs')
    if not isinstance(value,dict) or set(value)!=SNAPSHOT_FIELDS or type(value['schema_version']) is not int or value['schema_version']!=1 or value['geometry']!=PHYSICAL_CONTRACT:
        raise ValueError('Physical snapshot schema differs')
    identifier(value['episode_id']);integer(value['tick'],1,2**53-1)
    actors=value['actor_ids']
    if not isinstance(actors,list) or not 1<=len(actors)<=64:raise ValueError('Physical actor budget differs')
    for actor in actors:identifier(actor)
    if len(set(actors))!=len(actors):raise ValueError('Physical actor identity differs')
    for name in ('actor_generations','active','floor_clearance'):
        if not isinstance(value[name],dict) or set(value[name])!=set(actors):raise ValueError('Physical actor identity differs')
    for generation in value['actor_generations'].values():integer(generation,1,2**53-1)
    if any(type(v) is not bool for v in value['active'].values()) or any(type(value[k]) is not bool for k in ('collision','terminal')) or value['contact_depths'] is not None:
        raise ValueError('Physical state or unmeasured contact depth differs')
    geometry=tuple(_finite(value[k]) for k in ('floor_surface_y','capsule_half_height','capsule_radius'))
    if geometry!=(0,.5,.3):raise ValueError('Authored flat floor/capsule geometry differs')
    positions=value['positions']
    if not isinstance(positions,list) or len(positions)!=3*len(actors):raise ValueError('Physical XYZ width differs')
    for coordinate in positions:_finite(coordinate)
    for index,actor in enumerate(actors):
        x,y,z=positions[index*3:index*3+3];clearance=_finite(value['floor_clearance'][actor])
        if abs(clearance-(y-sum(geometry)))>1e-6:raise ValueError('Physical floor clearance contradicts pose')
        if require_admission and (not value['active'][actor] or clearance<-.001 or abs(x)>8 or abs(z)>9 or y>=3):
            raise ValueError('Physical actor failed floor/arena/liveness admission')
    if require_admission and value['collision']:raise ValueError('Native avoidable collision outcome rejected')
    canonical_bytes(value,max_bytes=32768)


def capture_physical_snapshot(header,*,require_admission=True):
    if not isinstance(header,dict) or not isinstance(header.get('training_only'),dict):raise ValueError('Native physical frame required')
    centralized=header['training_only'];value=centralized.get('physical_diagnostics')
    validate_physical_snapshot(value,require_admission=require_admission)
    if value['positions']!=centralized.get('state') or (value['episode_id'],value['tick'],value['actor_generations'],value['collision'])!=(header.get('episode_id'),header.get('tick'),header.get('actor_generations'),header.get('collision')):
        raise ValueError('Physical diagnostics disagree with native frame/state')
    return decode_json_bytes(canonical_bytes(value,max_bytes=32768),max_bytes=32768)


def validate_physical_pair(pair,row):
    if not isinstance(row,dict) or not {'tick','terminated','truncated','episode_id','actor_generations'}<=set(row):raise ValueError('Physical recording identity required')
    if type(row['terminated']) is not bool or type(row['truncated']) is not bool:raise ValueError('Physical terminal flags differ')
    if not isinstance(pair,dict) or set(pair)!={'before','after'}:raise ValueError('Physical before/after pair required')
    before,after=pair['before'],pair['after']
    for value in (before,after):validate_physical_snapshot(value)
    if before['tick']+1!=after['tick'] or after['tick']!=row['tick'] or before['terminal'] or after['terminal']!=(row['terminated'] or row['truncated']):
        raise ValueError('Physical step or terminal continuity differs')
    if any(value['episode_id']!=row['episode_id'] or value['actor_generations']!=row['actor_generations'] for value in (before,after)) or before['actor_ids']!=after['actor_ids']:
        raise ValueError('Physical episode/actor continuity differs')


def compare_physical_snapshot(actual,expected,*,atol,replay_episode_id=None):
    if type(atol) not in (int,float) or not math.isfinite(atol) or not 0<=atol<=1e-4:raise ValueError('Physical replay tolerance differs')
    for value in (actual,expected):validate_physical_snapshot(value)
    # Reset creates a new host episode. Only that identity may be remapped.
    if replay_episode_id is not None:
        identifier(replay_episode_id)
        if actual['episode_id']!=replay_episode_id:raise ValueError('Physical replay episode changed')
        expected={**expected,'episode_id':replay_episode_id}
    numbers={'positions','floor_clearance'}
    if any(actual[k]!=expected[k] for k in SNAPSHOT_FIELDS-numbers):raise ValueError('Physical replay identity/outcome differs')
    if any(abs(a-b)>atol for a,b in zip(actual['positions'],expected['positions'])) or any(abs(actual['floor_clearance'][a]-expected['floor_clearance'][a])>atol for a in actual['actor_ids']):
        raise ValueError('Physical replay pose/clearance differs')


def validate_physical_continuity(previous,row):
    pair=row.get('physical_diagnostics')
    if pair is None:return None
    if previous is not None and previous['episode_id']==row['episode_id'] and previous!=pair['before']:
        raise ValueError('Physical cross-row continuity differs')
    return pair['after']
