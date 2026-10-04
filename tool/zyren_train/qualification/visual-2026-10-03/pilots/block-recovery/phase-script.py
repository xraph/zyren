from pathlib import Path
import json,time,hashlib
import numpy as np
import torch
from zyren_train.train import TrainingConfig
from zyren_train.evaluate import StructuredCandidate
from zyren_train.worker import Worker
from zyren_train.gym_env import ZyrenEnv
root=Path('/Users/rexraphael/Work/TwinOS/flutter-geospatial');out=root/'.superpowers/sdd/README/task-T6-depth-block-recovery-pilot';torch.set_num_threads(1)
config=TrainingConfig.load(out/'config.json');candidate=StructuredCandidate(config,out/'bc-only-run')
exe=root/'.superpowers/sdd/README/task-T6-frozen-catalog-worker-cc102a7b7625/bin/train_worker';worker=Worker([str(exe)],cwd=root/'examples/game_lab/training_worker',run_id='depth-block-recovery-phase-diagnostic');results=[];start=time.perf_counter()
try:
 env=ZyrenEnv(worker,scenario='guard-visual-depth-validation',purpose='validation',observation_width=None,environment_id='phases')
 try:
  for path_kind in ['teacher','student']:
   for seed in range(1001,1006):
    obs,info=env.reset(seed=seed);candidate.reset();teacher_side=-1 if info['teacher_action'][0]<2 else 1;waypoint=0
    phases={p:{'steps':0,'confusion':[np.zeros((5,5),dtype=np.int64) for _ in range(2)]} for p in ['before-cue-loss','occlusion-navigation','final-approach']};records=[];first=None;first_sustained=None;streak=0;streak_start=None;colliding=False
    for step in range(600):
     tick=int(info['camera_tick']);position=np.asarray(info['physics_position'],dtype=float)
     if waypoint<2:
      route=np.asarray([teacher_side*2.55,.81,3.3 if waypoint==0 else 4.65]);
      if np.linalg.norm(route-position)<.35:waypoint+=1
     phase='before-cue-loss' if tick<=60 else ('final-approach' if waypoint==2 else 'occlusion-navigation')
     teacher=np.asarray(info['teacher_action'],dtype=np.int64);action=candidate.act(obs,{k:info[k] for k in ('observation_schema','observation_schema_hash','action_schema','action_schema_hash','action_space','visual_profile','legality','episode_id','tick','build_id','actor_generations') if k in info});different=np.flatnonzero(action[:2]!=teacher[:2]).tolist()
     record={'tick':tick,'phase':phase,'position':position.tolist(),'body':obs[-8:].tolist(),'teacher':teacher.tolist(),'student':action.tolist(),'wrong_movement_heads':different,'waypoint':waypoint}
     records.append(record);bucket=phases[phase];bucket['steps']+=1
     for head in range(2):bucket['confusion'][head][teacher[head],action[head]]+=1
     if different:
      if first is None:first=record
      if streak==0:streak_start=record
      streak+=1
      if streak==5 and first_sustained is None:first_sustained={'starts':streak_start,'fifth':record}
     else:streak=0;streak_start=None
     obs,_,terminal,truncated,info=env.step(teacher if path_kind=='teacher' else action);colliding|=bool(info['collision'])
     if terminal or truncated:break
    for bucket in phases.values():
     bucket['correct']=[int(np.trace(matrix)) for matrix in bucket['confusion']];bucket['accuracy']=[None if not bucket['steps'] else c/bucket['steps'] for c in bucket['correct']];bucket['confusion']=[m.tolist() for m in bucket['confusion']]
    row={'path_kind':path_kind,'seed':seed,'success':bool(info['success']),'collision':colliding,'steps':step+1,'remaining_distance':info['task_remaining_distance'],'first_movement_mismatch':first,'first_five_step_mismatch':first_sustained,'phases':phases,'records':records};results.append(row);print(json.dumps({k:v for k,v in row.items() if k!='records'}),flush=True)
 finally:env.close()
finally:worker.close()
receipt={'schema_version':1,'accepted':False,'final_acceptance_eligible':False,'qualification':'actual native development phase and student-visited-path diagnostic; teacher comparisons never actor input/optimizer/normalizer','development_seeds':list(range(1001,1006)),'config_hash':config.hash,'checkpoint_sha256':candidate.model_hash,'worker_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'phase_rule':{'before-cue-loss':'camera tick <=60','occlusion-navigation':'later tick until both authored waypoints reached within .35m','final-approach':'after second waypoint; purely diagnostic route stage'},'movement_heads':['moveX','moveZ'],'confusion_layout':'rows=teacher action index, columns=student action index','episodes':results,'wall_seconds':time.perf_counter()-start}
(out/'phase-diagnostic.json').write_text(json.dumps(receipt,separators=(',',':')))
