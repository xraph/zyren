"""Validation-only checkpoint selection through the native multi episode loop."""
import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
from .checkpoint import TrainingCheckpoint
from .multi_execution import _slot
from .pettingzoo_env import ZyrenParallelEnv
from .run_manifest import RunDirectory
from .scenario import ScenarioSpec, canonical_bytes


def checkpoint_candidates(receipts,*,bc_epochs,ppo_steps):
    result=[]
    for epoch in bc_epochs:
        matched=None
        for i,row in enumerate(receipts):
            if row.get('phase')=='cloning' and row.get('epoch')==epoch:
                matched=receipts[i+1] if i+1<len(receipts) and receipts[i+1].get('phase')=='checkpoint' else None
                break
        if matched is None or matched['steps']!=0:raise ValueError('Requested cloning checkpoint missing')
        result.append(matched)
    for threshold in ppo_steps:
        matched=next((r for r in receipts if r.get('phase')=='checkpoint' and r['steps']>=threshold),None)
        if matched is None:raise ValueError('Requested PPO checkpoint missing')
        result.append(matched)
    return list({r['sequence']:r for r in result}.values())


def load_checkpoint_receipt(run_path,config_hash,receipt):
    run=SimpleNamespace(path=Path(run_path),config_hash=config_hash)
    chain=RunDirectory.read_receipts(run)
    if receipt not in chain or receipt.get('phase')!='checkpoint':raise ValueError('Checkpoint receipt is outside the checked chain')
    name=receipt['checkpoint']
    # TrainingCheckpoint performs the bounded filename, bytes and internal-state checks.
    if Path(name).name!=name:raise ValueError('Checkpoint filename differs')
    with tempfile.TemporaryDirectory(prefix='multi-dev-checkpoint-') as directory:
        path=Path(directory)
        pointer={'version':1,'file':name,'sha256':receipt['checkpoint_sha256'],'steps':receipt['steps'],
                 'updates':receipt['updates'],'config_hash':config_hash,'environment_restore':'reset-boundary','numerical_reproducibility':False}
        (path/'checkpoint.json').write_bytes(canonical_bytes(pointer))
        os.link(run.path/name,path/name)
        return TrainingCheckpoint.load(SimpleNamespace(path=path),config_hash)


def _dev_env(worker,spec,name):
    return ZyrenParallelEnv(worker,scenario=spec.id,possible_agents=['a','b'],observation_width=36,
        action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id=name,purpose='validation')


def _verify_dev(env,spec):
    h=env._header;native=ScenarioSpec.from_dict(h['scenario_spec'])
    if native.partition!='validation' or native.hash!=spec.hash or h.get('physics_backend')!='rapier' or h.get('split')!='validation':
        raise ValueError('Pinned native DEV scenario differs')


def run_dev_slot(worker,case,seed,candidate,opponent,index,*,environment_factory=None):
    spec=ScenarioSpec.from_dict(case['scenario'])
    if spec.partition!='validation':raise ValueError('DEV cannot consume TRAIN or TEST scenarios')
    return _slot(worker,case,seed,candidate,opponent,index,lambda:False,
                 environment_factory=environment_factory or _dev_env,verify=_verify_dev)


def select_dev_candidate(rows):
    eligible=[r for r in rows if r['invalid_actions']==r['failed']==r['cancelled']==0]
    return min(eligible,key=lambda r:(r['collisions'],-r['score'],r['checkpoint_sequence'])) if eligible else None
