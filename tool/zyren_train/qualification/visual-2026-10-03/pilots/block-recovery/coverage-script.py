from pathlib import Path
import json,hashlib,time
import numpy as np
from zyren_train.dataset import DatasetManifest
from zyren_train.worker import Worker
from zyren_train.gym_env import ZyrenEnv
from zyren_train.train import worker_native_hashes
root=Path('/Users/rexraphael/Work/TwinOS/flutter-geospatial');source=root/'.superpowers/sdd/README/task-T6-depth-block-recovery-pilot';exe=root/'.superpowers/sdd/README/task-T6-frozen-catalog-worker-cc102a7b7625/bin/train_worker';plan=json.loads((source/'experiment-plan.json').read_text())
def pins():return {'worker_sha256':hashlib.sha256(exe.read_bytes()).hexdigest(),'worker_native_sha256':worker_native_hashes(exe)}
expected={k:plan[k] for k in ('worker_sha256','worker_native_sha256')};assert pins()==expected
worker=Worker([str(exe)],cwd=root/'examples/game_lab/training_worker',run_id='fixed-corrective-coverage-audit');results=[];started=time.perf_counter()
try:
 for seed in range(7,14):
  path=source/f'blocks-{seed}';manifest=DatasetManifest.load(path);meta=manifest.recording;window=meta['recording_settings']['student_windows'][0];env=ZyrenEnv(worker,scenario=meta['scenario']['id'],purpose='training',observation_width=None,environment_id=f'coverage-{seed}')
  try:
   obs,info=env.reset(seed=seed);side=-1 if info['teacher_action'][0]<2 else 1;waypoint=0;phases={i:{'teacher_steps':0,'student_steps':0,'max_student_run':0,'movement_label_mismatches':[0,0]} for i in range(3)};streak=0;transitions=[];steps=0;colliding=False;max_error=0.;block=[]
   for ordinal,row in enumerate(manifest.records(path)):
    actor=next(iter(row['observations']));error=float(np.max(np.abs(np.asarray(row['observations'][actor])-obs)));max_error=max(max_error,error);assert error<=1e-6
    assert row['teacher_labels'][actor]==info['teacher_action'];assert info['tick']+1==row['tick']
    pos=np.asarray(info['physics_position']);old=waypoint
    if waypoint<2 and np.linalg.norm(np.asarray([side*2.55,.81,3.3 if waypoint==0 else 4.65])-pos)<.35:waypoint+=1
    student=window[0]<=ordinal<window[1];streak=streak+1 if student else 0;phase=phases[waypoint];phase['student_steps' if student else 'teacher_steps']+=1;phase['max_student_run']=max(phase['max_student_run'],streak)
    if student:
     for head in range(2):phase['movement_label_mismatches'][head]+=int(row['proposed_actions'][actor][head]!=row['teacher_labels'][actor][head])
     block.append({'ordinal':ordinal,'camera_tick':int(info['camera_tick']),'waypoint':waypoint,'position':pos.tolist(),'applied':row['applied_actions'][actor],'teacher':row['teacher_labels'][actor]})
    if old!=waypoint:transitions.append({'ordinal':ordinal,'tick':info['tick'],'from':old,'to':waypoint,'next_action_source':'student' if student else 'teacher','preceding_student_run':streak,'position':pos.tolist()})
    obs,_,terminal,truncated,info=env.step(np.asarray(row['proposed_actions'][actor],dtype=np.int64));assert info['accepted_action']==row['applied_actions'][actor];assert terminal==row['terminated'] and truncated==row['truncated'];colliding|=bool(info['collision']);steps+=1
   assert steps==600 and len(block)==180 and (terminal or truncated)
   result={'seed':seed,'steps':steps,'student_window':list(window),'student_steps':len(block),'recording_manifest_hash':manifest.hash,'input_max_absolute_error':max_error,'assisted_episode_success':info['success'],'collision':colliding,'phases':phases,'transitions':transitions,'student_first_state':block[0],'student_last_state':block[-1],'student_waypoint_transitions':sum(t['next_action_source']=='student' for t in transitions),'cloning_sequence':{'length':600,'episode_starts':[0],'teacher_labels_not_applied_actions':True,'gradients_retained_across_image_chunks':True}}
   results.append(result);print(json.dumps(result),flush=True)
  finally:env.close()
finally:worker.close()
assert pins()==expected
receipt={'schema_version':1,'accepted':False,'experiment_plan_hash':plan['sha256'],'qualification':'TRAIN-only frozen native replay and intervention coverage audit; no optimizer updates; waypoint counts use diagnostic authored proximity, not final acceptance','worker_pins_before':expected,'worker_pins_after':pins(),'phase_basis':'authored waypoint proximity .35m; diagnostic own position is never actor input','episodes':results,'wall_seconds':time.perf_counter()-started}
(source/'coverage-audit.json').write_text(json.dumps(receipt,separators=(',',':')))
