"""Execute only the pre-registered TRAIN schedule, retaining unaccepted actors."""
import argparse
import hashlib
import json
from pathlib import Path
from zyren_train.export import load_multi_actor,export_actor
from zyren_train.multi_train import MultiTrainingConfig,train_multi
from zyren_train.pettingzoo_env import ZyrenParallelEnv
from zyren_train.scenario import canonical_bytes
from zyren_train.worker import Worker

ROOT=Path(__file__).resolve().parents[5]
HERE=Path(__file__).resolve().parent


def verify_sources(plan):
    for name,sha in plan['source_hashes'].items():
        if hashlib.sha256((ROOT/'tool/zyren_train/src/zyren_train'/name).read_bytes()).hexdigest()!=sha:
            raise ValueError('Pinned training source differs: '+name)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--only',choices=['withheld-2001','withheld-2003','cooperative','competitive'])
    parser.add_argument('--resume',action='store_true')
    args=parser.parse_args();plan=json.loads((HERE/'optimization-plan.json').read_bytes())
    worker_path=ROOT/'.superpowers/sdd/README/task-T6-frozen-multi-worker-1e74c220adce/bin/multi_worker'
    names=[args.only] if args.only else plan['execution_order']
    if Path.cwd()!=ROOT:raise ValueError('Run from the repository root so corpus pins resolve')
    for name in names:
        verify_sources(plan);entry=plan['configs'][name]
        config=MultiTrainingConfig.load(ROOT/entry['path'])
        if config.hash!=entry['configuration_hash']:raise ValueError('Pinned training config differs')
        run=HERE/'runs'/name
        result=train_multi(config,run,[str(worker_path)],cwd=ROOT,resume=args.resume)
        if result['state']!='completed' or result['steps']!=entry['native_ppo_steps']:raise ValueError('Pinned run did not complete')
        verify_sources(plan)
        worker=Worker([str(worker_path)],cwd=ROOT,run_id='multi-export-'+name,timeout=60)
        env=ZyrenParallelEnv(worker,scenario=config.data['task'],possible_agents=['a','b'],observation_width=36,
            action_space={'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},environment_id='export-'+name,purpose='training')
        try:
            env.reset(seed=config.data['training']['seed']);header=dict(env._header);header['action_space']=env._action_contract
            checkpoint=load_multi_actor(config,run,header)
            export=export_actor(checkpoint,HERE/'actors'/name)
        finally:env.close();worker.close()
        if worker.process.returncode!=0:raise ValueError('Export schema owner cleanup failed')
        receipt={'schema_version':1,'purpose':'training','name':name,'status':'completed',
                 'steps':result['steps'],'updates':result['updates'],'actor_transitions':result['actor_transitions'],
                 'training_config_hash':config.hash,'checkpoint_sha256':result['checkpoint_sha256'],
                 'schedule_sha256':hashlib.sha256((HERE/'optimization-plan.json').read_bytes()).hexdigest(),
                 'runner_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                 'source_inputs_stable':True,'export':export,'quality':None}
        (HERE/f'{name}-training-receipt.json').write_bytes(canonical_bytes(receipt)+b'\n')
        print(json.dumps(receipt),flush=True)


if __name__=='__main__':main()
