"""Pin the approved bounded training schedule before optimization starts."""
import hashlib
import json
from pathlib import Path
import subprocess
from zyren_train.dataset import DatasetPartition
from zyren_train.multi_train import MultiTrainingConfig
from zyren_train.multi_execution import MultiFixedActor
from zyren_train.scenario import canonical_bytes
from zyren_train.train import worker_native_hashes

ROOT=Path(__file__).resolve().parents[5]
HERE=Path(__file__).resolve().parent
SOURCES=('multi_train.py','self_play.py','multi_recording.py','train.py','normalize.py','checkpoint.py',
         'run_manifest.py','dataset.py','demonstration.py','scenario.py','worker.py','pettingzoo_env.py',
         'opponents.py','multi_execution.py','export.py','policies/structured.py','policies/masked_recurrent.py','policies/cloning.py')
SCHEDULE=(('withheld-2001','competitive-pursuit',2001,4,256),
          ('withheld-2003','competitive-pursuit',2003,6,256),
          ('cooperative','cooperative-search',101,16,8192),
          ('competitive','competitive-pursuit',211,16,16384))


def main():
    corpus=HERE/'corpus-v3';receipt=json.loads((corpus/'receipt.json').read_bytes())
    rows=[json.loads(line) for line in (corpus/'recordings.jsonl').read_text().splitlines()]
    if receipt['status']!='passed' or receipt['recordings']!=48 or len(rows)!=48 or receipt['recorded_steps']!=receipt['replayed_steps']:
        raise ValueError('The approved corpus must finish exact native replay first')
    if hashlib.sha256((corpus/'recordings.jsonl').read_bytes()).hexdigest()!=receipt['recordings_sha256']:
        raise ValueError('Corpus receipt bytes differ')
    frozen=ROOT/'.superpowers/sdd/README/task-T6-frozen-multi-worker-1e74c220adce/bin/multi_worker'
    if hashlib.sha256(frozen.read_bytes()).hexdigest()!=receipt['worker_sha256'] or worker_native_hashes(frozen)!=receipt['worker_native_sha256']:
        raise ValueError('The frozen worker bytes differ')
    specs=json.loads(subprocess.check_output([str(frozen),'--scenario-specs'],text=True))
    output=HERE/'configs';output.mkdir(exist_ok=True)
    counts={};pins={};configs={}
    for family in ('cooperative-search','competitive-pursuit'):
        paths=[corpus/r['path'] for r in rows if r['scenario']==family]
        partition=DatasetPartition.from_recordings('train',paths)
        for _ in partition.observation_samples():pass
        counts[family]={'sequences':{'a':0,'b':0},'rows':{'a':0,'b':0}}
        pins[family]=[]
        for path,manifest in partition.recordings:
            actors=manifest.recording['recording_settings']['learner_actors']
            pins[family].append({'path':Path(path).relative_to(ROOT).as_posix(),'manifest_hash':manifest.hash})
            for actor in actors:counts[family]['sequences'][actor]+=1
            for record in manifest.records(path):
                for actor in actors:counts[family]['rows'][actor]+=1
    for name,family,seed,epochs,steps in SCHEDULE:
        spec=next(s for s in specs if s['id']==family)
        data={'schema_version':2,'task':family,'history_every_updates':16,'history_versions':8,
              'training':{'schema_version':1,'policy_distribution':'masked-categorical-v1',
              'seed':seed,'device':'cpu','algorithm':'recurrent_ppo',
              'network':{'hidden_sizes':[128,128],'lstm_hidden_size':128},
              'optimizer':{'learning_rate':.0003,'epochs':2,'gamma':.99,'gae_lambda':.95,
                           'clip':.2,'entropy':.001,'value':.5,'max_grad_norm':.5},
              'rollout':{'environments':1,'steps':64},'total_steps':steps,
              'checkpoint_every_steps':1024,'evaluation_every_steps':1000000,
              'scenarios':[spec],'curriculum':[{'name':'occlusion','scenario':family,'after_steps':0}],
              'rewards':{'task.progress':1},'datasets':{'train':[p['path'] for p in pins[family]],'validation':[],'test':[]},
              'bc_epochs':epochs,'worker_sha256':receipt['worker_sha256'],
              'worker_native_sha256':receipt['worker_native_sha256']}}
        config=MultiTrainingConfig.from_dict(data)
        path=output/f'{name}.json';encoded=config.encoded+b'\n'
        if path.exists() and path.read_bytes()!=encoded:raise ValueError('Immutable training config differs')
        if not path.exists():path.write_bytes(encoded)
        configs[name]={'path':(output/f'{name}.json').relative_to(ROOT).as_posix(),'configuration_hash':config.hash,
                       'optimizer_rng_seed':seed,'native_train_seed_rule':'optimizer_rng_seed + completed_native_steps',
                       'bc_epochs':epochs,'native_ppo_steps':steps,'maximum_actual_updates':4096}
    source_hashes={p:hashlib.sha256((ROOT/'tool/zyren_train/src/zyren_train'/p).read_bytes()).hexdigest() for p in SOURCES}
    competitive=next(s for s in specs if s['id']=='competitive-pursuit')
    fixed={}
    for mode in ('stationary','observed-route'):
        actor=MultiFixedActor(mode,observation_hash=competitive['observation_schema_hash'],action_hash=competitive['action_schema_hash'])
        fixed['fixed-'+mode]={'policy_hash':actor.model_hash,'config_hash':actor.config_hash,'provider':actor.provider}
    plan={'schema_version':1,'purpose':'training-and-dev-only','worker_sha256':receipt['worker_sha256'],
          'worker_native_sha256':receipt['worker_native_sha256'],'corpus_receipt_sha256':hashlib.sha256((corpus/'receipt.json').read_bytes()).hexdigest(),
          'source_hashes':source_hashes,'corpus_manifests':pins,'effective_teacher_samples':counts,'fixed_final_opponents':fixed,
          'configs':configs,'execution_order':['withheld-2001','withheld-2003','cooperative','competitive'],
          'withheld_rule':'freeze completed weights without DEV selection; never load into student training or history pool',
          'historical_checkpoints':{'task':'competitive-pursuit','bc_epochs':[4,8,12,16],'require_distinct_actor_bytes':True},
          'dev_selection':{'seeds':list(range(30000,30020)),'competitive_opponents':['withheld-2001','withheld-2003'],
              'cooperative_bc_epochs':[4,8,12,16],'cooperative_ppo_checkpoint_after_steps':[2048,4096,8192],
              'competitive_bc_epochs':[4,8,12,16],'competitive_ppo_checkpoint_after_steps':[2048,4096,8192,16384],
              'ppo_rule':'first saved checkpoint at or after each threshold',
              'criterion':'zero invalid or failed slots, then fewest contact episodes, then highest joint/mean role success',
              'tie_break':'earliest optimization checkpoint; no TEST evaluation or best-opponent selection'},
          'final_test':'blocked until candidate/opponent bytes, independent role/history gates and final cases/seeds are locked'}
    encoded=canonical_bytes(plan)+b'\n';path=HERE/'optimization-plan.json'
    if path.exists() and path.read_bytes()!=encoded:raise ValueError('Immutable optimization plan differs')
    if not path.exists():path.write_bytes(encoded)
    print(json.dumps({'configuration_hashes':{k:v['configuration_hash'] for k,v in configs.items()},
                      'effective_teacher_samples':counts,'plan_sha256':hashlib.sha256((HERE/'optimization-plan.json').read_bytes()).hexdigest()}))


if __name__=='__main__':main()
