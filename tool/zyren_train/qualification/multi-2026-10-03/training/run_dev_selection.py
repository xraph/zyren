"""Select the preregistered candidates on DEV layouts, retaining every slot."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import torch
from zyren_train.export import ActorCheckpoint
from zyren_train.multi_dev import checkpoint_candidates, load_checkpoint_receipt, run_dev_slot, select_dev_candidate
from zyren_train.multi_execution import MultiPolicyActor
from zyren_train.multi_train import MultiTrainingConfig
from zyren_train.pettingzoo_env import ZyrenParallelEnv
from zyren_train.run_manifest import RunDirectory
from zyren_train.scenario import canonical_bytes
from zyren_train.train import worker_native_hashes
from zyren_train.worker import Worker

ROOT=Path(__file__).resolve().parents[5]
HERE=Path(__file__).resolve().parent
OUTPUT=HERE/'dev-selection'


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_new(path,value):
    data=canonical_bytes(value)+b'\n'
    if path.exists():
        if path.read_bytes()!=data:raise ValueError('Immutable DEV record differs: '+str(path))
    else:
        with path.open('xb') as stream:stream.write(data)


def actor(config,state,header,model_hash=None):
    pins={(s['observation_schema_hash'],s['action_schema_hash']) for s in config.data['training']['scenarios']}
    if (header['observation_schema_hash'],header['action_schema_hash']) not in pins:raise ValueError('DEV schema differs from TRAIN actor')
    cp=ActorCheckpoint(SimpleNamespace(hash=config.hash,data=config.data['training']),state,
                       header['observation_schema'],header['action_schema'],{'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},
                       multi_profile=header['multi_profile'])
    return MultiPolicyActor(cp.policy(),model_hash=model_hash or state['_checkpoint_sha256'],config_hash=config.hash,
        observation_hash=header['observation_schema_hash'],action_hash=header['action_schema_hash'])


def source_hashes():
    directory=ROOT/'tool/zyren_train/src/zyren_train'
    paths=sorted(directory.rglob('*.py'))+[Path(__file__)]
    if not 2<=len(paths)<=256 or any(p.is_symlink() or p.stat().st_size>1_048_576 for p in paths) or sum(p.stat().st_size for p in paths)>16_777_216:
        raise ValueError('DEV source inventory exceeds bounded repository files')
    return {str(p.relative_to(ROOT)):sha(p) for p in paths}


def main():
    if Path.cwd()!=ROOT:raise ValueError('Run from repository root')
    torch.set_num_threads(1)
    schedule=json.loads((HERE/'optimization-plan.json').read_bytes());selection=schedule['dev_selection']
    worker_path=ROOT/'.superpowers/sdd/README/task-T6-frozen-multi-worker-1e74c220adce/bin/multi_worker'
    if sha(worker_path)!=schedule['worker_sha256'] or worker_native_hashes(worker_path)!=schedule['worker_native_sha256']:
        raise ValueError('Frozen DEV worker differs')
    configs={n:MultiTrainingConfig.load(HERE/'configs'/f'{n}.json') for n in ('cooperative','competitive')}
    candidates={}
    for name,config in configs.items():
        if config.hash!=schedule['configs'][name]['configuration_hash']:raise ValueError('DEV config pin differs')
        run=SimpleNamespace(path=HERE/'runs'/name,config_hash=config.hash)
        rows=RunDirectory.read_receipts(run)
        if rows[-1]['state']!='completed':raise ValueError('DEV requires a completed optimization run')
        candidates[name]=checkpoint_candidates(rows,bc_epochs=selection[name+'_bc_epochs'],ppo_steps=selection[name+'_ppo_checkpoint_after_steps'])
        for receipt in candidates[name]:load_checkpoint_receipt(run.path,config.hash,receipt)
    sources=source_hashes()
    OUTPUT.mkdir(exist_ok=True)
    worker=Worker([str(worker_path)],cwd=ROOT,run_id='multi-dev-selection',timeout=60)
    headers={};all_rows={}
    try:
        for name,config in configs.items():
            task=config.data['task'];env=ZyrenParallelEnv(worker,scenario=task+'-validation',possible_agents=['a','b'],
                observation_width=36,action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},
                environment_id='dev-schema-'+name,purpose='validation')
            try:env.reset(seed=selection['seeds'][0]);headers[name]=dict(env._header)
            finally:env.close()
        withheld=json.loads((HERE/'withheld-opponents.json').read_bytes())
        opponents={}
        for entry in withheld['opponents']:
            n=entry['id'];cfg=MultiTrainingConfig.load(HERE/'configs'/f'{n}.json')
            run=SimpleNamespace(path=HERE/'frozen-withheld'/n,config_hash=cfg.hash)
            from zyren_train.checkpoint import TrainingCheckpoint
            state=TrainingCheckpoint.load(run,cfg.hash)
            if state['_checkpoint_sha256']!=entry['source_checkpoint_sha256'] or sha(HERE/'actors'/n/'actor.onnx')!=entry['policy_hash']:
                raise ValueError('Withheld opponent differs')
            opponents[n]=actor(cfg,state,headers['competitive'],entry['policy_hash'])
        plan={'schema_version':1,'purpose':'validation-selection-only','schedule_sha256':sha(HERE/'optimization-plan.json'),
              'selection':selection,'candidate_receipts':candidates,'scenarios':{n:h['scenario_spec'] for n,h in headers.items()},
              'worker_sha256':sha(worker_path),'worker_native_sha256':worker_native_hashes(worker_path),
              'withheld_receipt_sha256':sha(HERE/'withheld-opponents.json'),'source_hashes':sources,
              'provider':f'torch-{torch.__version__}-cpu','acceptance':None}
        save_new(OUTPUT/'plan.json',plan)
        for name,config in configs.items():
            summaries=[];header=headers[name]
            for receipt in candidates[name]:
                output=OUTPUT/f'{name}-{receipt["sequence"]:06d}.json'
                if output.exists():
                    saved=json.loads(output.read_bytes())
                    if saved['plan_sha256']!=sha(OUTPUT/'plan.json') or saved['checkpoint_sha256']!=receipt['checkpoint_sha256']:
                        raise ValueError('Existing DEV candidate identity differs')
                    summaries.append(saved['summary']);continue
                policy=actor(config,load_checkpoint_receipt(HERE/'runs'/name,config.hash,receipt),header)
                slots=[];faults=stale=0
                pairs=[('joint',None)] if name=='cooperative' else [(role,op) for role in ('pursuer','evader') for op in selection['competitive_opponents']]
                for role,opponent in pairs:
                    case={'id':f'dev-{name}-{role}-{opponent or "joint"}','family':config.data['task'],'role':role,
                          'opponent':opponent,'scenario':header['scenario_spec']}
                    for seed in selection['seeds']:
                        row,fault,outdated=run_dev_slot(worker,case,seed,policy,opponents.get(opponent),len(slots))
                        slots.append(row.to_dict());faults+=fault;stale+=outdated
                summary={'checkpoint_sequence':receipt['sequence'],'steps':receipt['steps'],'requested':len(slots),
                    'failed':sum(r['status']=='failed' for r in slots),'cancelled':sum(r['status']=='cancelled' for r in slots),
                    'invalid_actions':sum(r['invalid_actions'] for r in slots)+faults+stale,
                    'collisions':sum(r['collision'] for r in slots),'score':sum(r['success'] for r in slots)/len(slots)}
                value={'schema_version':1,'purpose':'validation-selection-only','plan_sha256':sha(OUTPUT/'plan.json'),
                       'checkpoint_sha256':receipt['checkpoint_sha256'],'checkpoint_receipt':receipt,'episodes':slots,
                       'reward_faults':faults,'stale_outputs':stale,'summary':summary,'acceptance':None}
                save_new(output,value);summaries.append(summary);print(name,summary,flush=True)
            all_rows[name]=summaries
    finally:worker.close()
    if worker.process.returncode!=0 or sources!=source_hashes():
        raise ValueError('DEV owner cleanup or source stability differs')
    selected={n:select_dev_candidate(rows) for n,rows in all_rows.items()}
    save_new(OUTPUT/'selection.json',{'schema_version':1,'purpose':'validation-selection-only','plan_sha256':sha(OUTPUT/'plan.json'),
             'candidates':all_rows,'selected':selected,'worker_exit':worker.process.returncode,'source_inputs_stable':True,'acceptance':None})
    print(json.dumps(selected),flush=True)


if __name__=='__main__':main()
