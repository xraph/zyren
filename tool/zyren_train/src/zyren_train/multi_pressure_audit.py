"""TRAIN-only pressure diagnostics through the existing native slot adapter."""
from .multi_execution import _slot
from .pettingzoo_env import ZyrenParallelEnv
from .scenario import ScenarioSpec

PUBLIC_ROUTES={'a':[],'b':[[6,.81,5],[6,.81,-6],[-6,.81,-6],[-6,.81,6]]}


def validate_pressure_scenario(spec):
    settings=spec.settings
    if spec.partition!='train' or spec.callback_id!='competitive.pursuit' or spec.max_steps>400 or spec.control_cadence!=1 or spec.latency_ticks!=1 or settings.get('competitive') is not True or settings.get('dynamic') is not False or settings.get('legal_bounds')!=[8,9] or settings.get('evader_speed')!=1.5 or settings.get('fixed_hz')!=50:
        raise ValueError('Pressure audit requires the bounded public TRAIN pursuit contract')


def verify_pressure_contract(env,spec):
    validate_pressure_scenario(spec);h=env._header
    if ScenarioSpec.from_dict(h['scenario_spec']).hash!=spec.hash or h.get('physics_backend')!='rapier' or h.get('split')!='train' or h.get('authored_routes')!=PUBLIC_ROUTES:
        raise ValueError('Pinned pressure arena or authored waypoint bounds differ')


def _train_env(worker,spec,name):
    return ZyrenParallelEnv(worker,scenario=spec.id,possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id=name,purpose='training')


def run_pressure_slot(worker,spec,seed,evader,pursuer,index,*,environment_factory=None):
    validate_pressure_scenario(spec)
    case={'id':'pressure-audit','family':'competitive-pursuit','role':'evader','opponent':'observed-route-pursuer','scenario':spec.to_dict()}
    # _slot compares every proposed action with the actual native applied action
    # before the next actor call. Teacher heading is inferred from emitted action
    # and is usable only under this admission check, not an internal verification.
    return _slot(worker,case,seed,evader,pursuer,index,lambda:False,
                 environment_factory=environment_factory or _train_env,verify=verify_pressure_contract)
