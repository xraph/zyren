from pathlib import Path
import hashlib,json,sys,time
import numpy as np
import torch
from zyren_train.worker import Worker
from zyren_train.distill import record_dagger
from zyren_train.dataset import DatasetManifest
from zyren_train.scenario import canonical_bytes,ScenarioSpec
from zyren_train.train import TrainingConfig,WorkerPool,train,worker_native_hashes
from zyren_train.run_manifest import RunDirectory
from zyren_train.evaluate import StructuredCandidate
from zyren_train.gym_env import ZyrenEnv
ROOT=Path('/Users/rexraphael/Work/TwinOS/flutter-geospatial');torch.set_num_threads(1)
OUT=ROOT/'.superpowers/sdd/README/task-T6-depth-block-recovery-pilot'
SOURCE=ROOT/'.superpowers/sdd/README/task-T6-depth-memory-pilot'
EXE=ROOT/'.superpowers/sdd/README/task-T6-frozen-catalog-worker-cc102a7b7625/bin/train_worker'
CWD=ROOT/'examples/game_lab/training_worker'
def sha(path):return hashlib.sha256(Path(path).read_bytes()).hexdigest()
def store(path,value):path.write_bytes(canonical_bytes(value))
def artifact_pins():return {'worker_sha256':sha(EXE),'worker_native_sha256':worker_native_hashes(EXE)}
def cohort_bytes():return sum(p.stat().st_size for d in OUT.glob('blocks-*') for p in d.rglob('*') if p.is_file())
def context(info):return {key:info[key] for key in ('observation_schema','observation_schema_hash','action_schema','action_schema_hash','action_space','visual_profile','legality','episode_id','tick','build_id','actor_generations') if key in info}
if sys.argv[1:] == ['--freeze']:
 OUT.mkdir(exist_ok=False)
 source_config=TrainingConfig.load(SOURCE/'config.json');source=StructuredCandidate(source_config,SOURCE/'bc-only-run')
 source_checkpoint=SOURCE/'bc-only-run'/source.checkpoint['_checkpoint_name'] if '_checkpoint_name' in source.checkpoint else next((SOURCE/'bc-only-run').glob('checkpoint-*.pt'))
 assert sha(source_checkpoint)==source.model_hash
 data=source_config.data;data['bc_epochs']=10;data['optimizer']['learning_rate']=.00005
 data['datasets']={'train':[str(OUT/f'blocks-{seed}') for seed in range(7,14)],'validation':[],'test':[]}
 data['initial_actor']={'config':str(SOURCE/'config.json'),'config_sha256':sha(SOURCE/'config.json'),'checkpoint':str(source_checkpoint),'checkpoint_sha256':sha(source_checkpoint)}
 config=TrainingConfig.from_dict(data);(OUT/'config.json').write_bytes(config.encoded)
 pins=artifact_pins();assert pins['worker_sha256']==data['worker_sha256'] and pins['worker_native_sha256']==data['worker_native_sha256']
 files=['tool/zyren_train/src/zyren_train/'+p for p in ['distill.py','demonstration.py','dataset.py','train.py','warm_start.py','normalize.py','evaluate.py','policies/cloning.py','policies/visual.py','policies/recurrent.py']]
 files=[p for p in files if (ROOT/p).exists()]
 cases=[]
 for seed in range(7,14):
  manifest=DatasetManifest.load(ROOT/f'.superpowers/sdd/README/task-T6-depth-balanced-pilot/demo-{seed}')
  spec=dict(manifest.recording['scenario']);assert spec['partition']=='train' and spec['seed']==seed and spec['max_steps']==600
  cases.append({'seed':seed,'student_windows':[[60,240]] if seed%2 else [[230,410]],'scenario':spec,'scenario_hash':ScenarioSpec.from_dict(json.loads(canonical_bytes(spec))).hash})
 plan={'schema_version':1,'qualification':'TRAIN-only development experiment, no final acceptance eligibility','accepted':False,'source_actor':data['initial_actor'],'config_hash':config.hash,'config_raw_sha256':sha(OUT/'config.json'),**pins,'source_files':{p:sha(ROOT/p) for p in files},'experiment_script_sha256':sha(__file__),'cases':cases,'recording_budget_bytes':512*1048576,'per_course_budget_mib':128,'control_index_basis':'zero-based-proposed-control','captured_camera_tick_offset':1,'application_latency_ticks':1,'bc_epochs':10,'learning_rate':.00005,'ppo_steps':0,'complete_recurrent_sequence_steps':600,'actor_inputs':['camera','own-body'],'teacher_input_to_actor':False,'optimizer_reset':True,'critic_reset':True,'development_seeds':list(range(1001,1006)),'final_test_seeds_used':False}
 plan['sha256']=hashlib.sha256(canonical_bytes(plan)).hexdigest();store(OUT/'experiment-plan.json',plan)
 print(json.dumps({'plan_hash':plan['sha256'],'config_hash':config.hash,'source_checkpoint':source.model_hash}),flush=True);raise SystemExit()
plan=json.loads((OUT/'experiment-plan.json').read_text());pin=dict(plan);pin.pop('sha256');assert hashlib.sha256(canonical_bytes(pin)).hexdigest()==plan['sha256']
assert plan['experiment_script_sha256']==sha(__file__)
assert all(sha(ROOT/p)==v for p,v in plan['source_files'].items())
assert artifact_pins()=={k:plan[k] for k in ('worker_sha256','worker_native_sha256')}
config=TrainingConfig.load(OUT/'config.json');assert config.hash==plan['config_hash'] and sha(OUT/'config.json')==plan['config_raw_sha256']
source_config=TrainingConfig.load(SOURCE/'config.json');student=StructuredCandidate(source_config,SOURCE/'bc-only-run');assert student.model_hash==plan['source_actor']['checkpoint_sha256']
worker=Worker([str(EXE)],cwd=CWD,run_id='depth-block-recovery-training');receipts=[]
try:
 for case in plan['cases']:
  assert cohort_bytes()+128*1048576<=plan['recording_budget_bytes'],'cohort lacks conservative next-course budget'
  receipt=record_dagger(worker,student,scenario='guard-visual-depth',seed=case['seed'],output=OUT/f"blocks-{case['seed']}",session_id=f"depth-block-recovery-{case['seed']}",disk_mib=128,student_windows=case['student_windows'])
  store(OUT/f"recording-receipt-{case['seed']}.json",receipt)
  assert receipt['scenario_hash']==case['scenario_hash'] and receipt['steps']==600 and receipt['student_steps']==receipt['max_uninterrupted_student_steps']==180
  manifest=DatasetManifest.load(OUT/f"blocks-{case['seed']}");assert manifest.hash==receipt['recording_manifest_hash'] and canonical_bytes(dict(manifest.recording['scenario']))==canonical_bytes(case['scenario'])
  receipts.append(receipt);store(OUT/'recording-receipts.json',receipts);print(json.dumps(receipt),flush=True)
finally:worker.close()
assert artifact_pins()=={k:plan[k] for k in ('worker_sha256','worker_native_sha256')}
store(OUT/'cohort-finalized.json',{'experiment_plan_hash':plan['sha256'],'accepted':False,'bytes':cohort_bytes(),'recordings':len(receipts),'rows':sum(r['steps'] for r in receipts),'student_controls':sum(r['student_steps'] for r in receipts),'teacher_controls':sum(r['teacher_steps'] for r in receipts),'recording_manifest_hashes':[r['recording_manifest_hash'] for r in receipts],'worker_pins_after':artifact_pins(),'source_files_unchanged':all(sha(ROOT/p)==v for p,v in plan['source_files'].items())})
run=RunDirectory(OUT/'bc-only-run',config.hash);pool=WorkerPool([str(EXE)],cwd=CWD,config=config)
def stop_before_ppo():return any(r.get('phase')=='behavior-cloning' and r.get('epoch')==9 for r in run.read_receipts())
start=time.perf_counter();cpu=time.process_time();final=train(config,pool,run,cancelled=stop_before_ppo)
assert final['state']=='cancelled' and final['steps']==final['updates']==0 and final['cloning_progress']=={'epoch':10,'sequence':0,'complete':True}
store(OUT/'bc-only-measurements.json',{'experiment_plan_hash':plan['sha256'],'qualification':'10 completed BC epochs only; stop before PPO; concurrent performance unqualified','wall_seconds':time.perf_counter()-start,'cpu_seconds':time.process_time()-cpu,'final':final});print(json.dumps(final),flush=True)
candidate=StructuredCandidate(config,OUT/'bc-only-run');worker=Worker([str(EXE)],cwd=CWD,run_id='depth-block-recovery-validation');rows=[]
try:
 env=ZyrenEnv(worker,scenario='guard-visual-depth-validation',purpose='validation',observation_width=None,environment_id='closed-loop')
 try:
  for seed in plan['development_seeds']:
   obs,info=env.reset(seed=seed);candidate.reset();collision=False
   for step in range(600):
    action=candidate.act(obs,context(info));obs,_,term,trunc,info=env.step(action);collision|=bool(info['collision'])
    if term or trunc:break
   row={'seed':seed,'success':bool(info['success']),'collision':collision,'steps':step+1,'remaining_distance':info.get('task_remaining_distance'),'physics_position':info['physics_position']};rows.append(row);print(json.dumps(row),flush=True)
 finally:env.close()
finally:worker.close()
assert artifact_pins()=={k:plan[k] for k in ('worker_sha256','worker_native_sha256')}
store(OUT/'development-validation.json',{'experiment_plan_hash':plan['sha256'],'accepted':False,'qualification':'development-only fixed-window corrective BC; no final test seed or acceptance claim','config_hash':config.hash,'checkpoint_sha256':candidate.model_hash,'episodes':rows,'worker_pins_after':artifact_pins()})
