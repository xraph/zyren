"""Write a bounded TRAIN pressure audit, never a model acceptance report."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from zyren_train.multi_execution import MultiFixedActor
from zyren_train.multi_pressure_audit import PUBLIC_ROUTES,run_pressure_slot,validate_pressure_scenario
from zyren_train.multi_pressure_teacher import MultiPressureTeacher
from zyren_train.scenario import ScenarioSpec,canonical_bytes
from zyren_train.train import worker_native_hashes
from zyren_train.worker import Worker
from run_dev_selection import source_hashes

SEEDS=(7,17,29,41,53,67,79,97,109,127,139,151)


def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('worker',type=Path);parser.add_argument('output',type=Path)
    args=parser.parse_args();command=args.worker.resolve();output=args.output.resolve()
    pins={'worker_sha256':sha(command),'worker_native_sha256':worker_native_hashes(command)}
    sources=source_hashes();script=sha(__file__)
    catalog=json.loads(subprocess.check_output([str(command),'--scenario-specs'],timeout=60))
    specs=[ScenarioSpec.from_dict(s) for s in catalog if s['id']=='competitive-pursuit']
    if len(specs)!=1:raise ValueError('Exactly one static TRAIN pursuit scenario required')
    spec=specs[0];validate_pressure_scenario(spec)
    kwargs={'observation_hash':spec.observation_schema_hash,'action_hash':spec.action_schema_hash}
    actors={'original-observed-route':MultiFixedActor('observed-route',**kwargs),'pressure-audit':MultiPressureTeacher(**kwargs)}
    pursuer=MultiFixedActor('observed-route',**kwargs)
    output.mkdir(parents=True,exist_ok=False)
    plan={'schema_version':1,'purpose':'train-pressure-coverage-diagnostic','scenario':spec.to_dict(),
          'seeds':list(SEEDS),'episodes':24,'maximum_native_steps':9600,'source_hashes':sources,
          'script_sha256':script,'actor_contract':{'legal_bounds':[8,9],'authored_routes':PUBLIC_ROUTES,
              'cursor_observed':False,'position':'conservative interval only','historical_target':'direction only',
              'heading_admission':'native applied action equals emitted action before next call'},
          'controllers':{k:{'model_hash':v.model_hash,'config_hash':v.config_hash,'provider':v.provider} for k,v in actors.items()},
          'pursuer':{'model_hash':pursuer.model_hash,'config_hash':pursuer.config_hash},'accepted_model':None,**pins}
    (output/'audit-plan.json').write_bytes(canonical_bytes(plan)+b'\n')
    worker=Worker([str(command)],cwd=Path.cwd(),run_id='multi-pressure-train-audit',timeout=60);rows=[]
    try:
        for mode,actor in actors.items():
            for seed in SEEDS:
                row,fault,stale=run_pressure_slot(worker,spec,seed,actor,pursuer,len(rows))
                result={'controller':mode,'metric':row.to_dict(),'reward_faults':fault,'stale_outputs':stale}
                rows.append(result)
                with (output/'episodes.jsonl').open('ab') as stream:stream.write(canonical_bytes(result)+b'\n');stream.flush()
                print(mode,seed,row.result,row.steps,row.collision,row.status,flush=True)
    finally:worker.close()
    stable=(pins=={'worker_sha256':sha(command),'worker_native_sha256':worker_native_hashes(command)} and sources==source_hashes() and script==sha(__file__))
    receipt={'schema_version':1,'purpose':plan['purpose'],'execution_status':'passed' if stable and worker.process.returncode==0 and len(rows)==24 and all(r['metric']['status']=='completed' and r['metric']['invalid_actions']==0 and r['reward_faults']==r['stale_outputs']==0 for r in rows) else 'failed',
             'episodes':len(rows),'native_steps':sum(r['metric']['steps'] for r in rows),'worker_exit':worker.process.returncode,
             'source_inputs_stable':stable,'plan_sha256':sha(output/'audit-plan.json'),'episodes_sha256':sha(output/'episodes.jsonl'),
             'summary':{k:{'episodes':len([r for r in rows if r['controller']==k]),'evader_wins':sum(r['metric']['success'] for r in rows if r['controller']==k),
                           'contact_episodes':sum(r['metric']['collision'] for r in rows if r['controller']==k)} for k in actors},
             'accepted_model':None,**pins}
    (output/'receipt.json').write_bytes(canonical_bytes(receipt)+b'\n')
    if receipt['execution_status']!='passed':raise ValueError('Pressure audit execution/cleanup evidence failed')


if __name__=='__main__':main()
