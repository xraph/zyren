from pathlib import Path
import json,hashlib,math,time
import numpy as np
import torch
from zyren_train.dataset import DatasetManifest
from zyren_train.scenario import canonical_bytes
from zyren_train.train import worker_native_hashes
from zyren_train.worker import Worker
from zyren_train.gym_env import ZyrenEnv
root=Path('/Users/rexraphael/Work/TwinOS/flutter-geospatial');out=root/'.superpowers/sdd/README/task-T6-depth-block-recovery-pilot';torch.set_num_threads(1);start=time.perf_counter()
plan=json.loads((out/'experiment-plan.json').read_text());coverage=json.loads((out/'coverage-audit.json').read_text());phase=json.loads((out/'phase-diagnostic.json').read_text());exe=root/'.superpowers/sdd/README/task-T6-frozen-catalog-worker-cc102a7b7625/bin/train_worker'
def sha(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()
def pins():return {'worker_sha256':sha(exe),'worker_native_sha256':worker_native_hashes(exe)}
assert pins()=={k:plan[k] for k in ('worker_sha256','worker_native_sha256')}
# 4200 x 14120 F32 is bounded at 237,216,000 bytes. No optimizer/model mutation.
inputs=np.empty((7,600,14120),dtype=np.float32);labels=np.empty((7,600,6),dtype=np.int64);stages=np.zeros((7,600),dtype=np.int8);cue=[];manifest_hashes=[]
for course,seed in enumerate(range(7,14)):
 path=out/f'blocks-{seed}';manifest=DatasetManifest.load(path);manifest_hashes.append(manifest.hash)
 for ordinal,row in enumerate(manifest.records(path)):
  actor=next(iter(row['observations']));inputs[course,ordinal]=row['observations'][actor];labels[course,ordinal]=row['teacher_labels'][actor]
 assert ordinal==599
 for transition in coverage['episodes'][course]['transitions']:stages[course,transition['ordinal']:]=transition['to']
 image=inputs[course,0,:14112].reshape(2,84,84)
 # Diagnostic geometry ROI only, not a trained actor or policy input transformation.
 mask=(image[1]>0)&(image[0]>.12)&(image[0]<.17);mask[:35]=False;mask[52:]=False;ys,xs=np.nonzero(mask)
 cue.append({'seed':seed,'pixels':int(len(xs)),'mean_column':None if not len(xs) else float(xs.mean()),'teacher_initial_moveX':int(labels[course,0,0])})
exact_frame={};exact_prefix={};frame_conflicts=[];prefix_conflicts=[]
for course,seed in enumerate(range(7,14)):
 history=hashlib.sha256()
 for ordinal in range(600):
  data=inputs[course,ordinal].tobytes();digest=hashlib.sha256(data).hexdigest();history.update(data);prefix=history.hexdigest();entry={'seed':seed,'ordinal':ordinal,'phase':int(stages[course,ordinal]),'label':labels[course,ordinal].tolist()}
  for registry,key,destination in [(exact_frame,digest,frame_conflicts),(exact_prefix,prefix,prefix_conflicts)]:
   old=registry.get(key)
   if old is not None and old['label']!=entry['label']:
    if len(destination)<32:destination.append({'first':old,'second':entry,'hash':key})
   registry.setdefault(key,entry)
# Coarse candidate search, followed by exact raw F32 camera/body/history comparison.
flat=inputs.reshape(4200,14120);body_scale=np.maximum(inputs[:,:,-8:].std(axis=(0,1)),1e-4);body_scale[5:]=1
pooled=inputs[:,:,:14112].reshape(7,600,2,7,12,7,12).mean(axis=(4,6)).reshape(4200,98)
features=np.concatenate((pooled/math.sqrt(98),flat[:,-8:]/body_scale/math.sqrt(8)),axis=1)
features=torch.from_numpy(features);phaseflat=stages.reshape(-1);labelflat=labels.reshape(4200,6);nearest=[]
def comparisons(a,b):
 current=inputs[a[0],a[1]];other=inputs[b[0],b[1]];result={'camera_rms':float(np.sqrt(np.mean((current[:14112]-other[:14112])**2))),'camera_max_absolute':float(np.max(np.abs(current[:14112]-other[:14112]))),'body_raw_difference':(current[-8:]-other[-8:]).tolist(),'recent_histories':[]}
 for length in [8,32,64]:
  if min(a[1],b[1])+1<length:continue
  x=inputs[a[0],a[1]-length+1:a[1]+1];y=inputs[b[0],b[1]-length+1:b[1]+1]
  result['recent_histories'].append({'steps':length,'camera_rms':float(np.sqrt(np.mean((x[:,:14112]-y[:,:14112])**2))),'body_standardized_rms':float(np.sqrt(np.mean(((x[:,-8:]-y[:,-8:])/body_scale)**2))),'exact_equal':bool(np.array_equal(x,y))})
 if a[1]==b[1]:
  x=inputs[a[0],:a[1]+1];y=inputs[b[0],:b[1]+1];result['full_prefix']={'steps':a[1]+1,'camera_rms':float(np.sqrt(np.mean((x[:,:14112]-y[:,:14112])**2))),'body_standardized_rms':float(np.sqrt(np.mean(((x[:,-8:]-y[:,-8:])/body_scale)**2))),'exact_equal':bool(np.array_equal(x,y))}
 return result
for course,seed in enumerate(range(7,14)):
 for ordinal in [60,83,97,257,330,409]:
  index=course*600+ordinal;dist=((features-features[index])**2).sum(dim=1).numpy();eligible=(phaseflat!=phaseflat[index])&np.any(labelflat[:,:2]!=labelflat[index,:2],axis=1);dist[~eligible]=np.inf
  candidates=np.argsort(dist)[:8];best=min(candidates,key=lambda j:float(np.mean((flat[index,:14112]-flat[j,:14112])**2)+np.mean(((flat[index,-8:]-flat[j,-8:])/body_scale)**2)))
  other=divmod(int(best),600);nearest.append({'query':{'seed':seed,'ordinal':ordinal,'phase':int(stages[course,ordinal]),'label':labels[course,ordinal].tolist()},'candidate':{'seed':other[0]+7,'ordinal':other[1],'phase':int(stages[other]),'label':labels[other].tolist()},'comparison':comparisons((course,ordinal),other)})
print('TRAIN analysis complete',flush=True)
# Native replay at the first actual development divergences. Camera histories are held only in memory.
worker=Worker([str(exe)],cwd=root/'examples/game_lab/training_worker',run_id='visual-identifiability-audit');development=[]
try:
 for seed in range(1001,1006):
  teacher=next(e for e in phase['episodes'] if e['seed']==seed and e['path_kind']=='teacher');student=next(e for e in phase['episodes'] if e['seed']==seed and e['path_kind']=='student');first=student['first_five_step_mismatch']['starts']['tick'];limit=min(600,first+4);histories=[];native_labels=[]
  for kind,episode in [('teacher',teacher),('student',student)]:
   env=ZyrenEnv(worker,scenario='guard-visual-depth-validation',purpose='validation',observation_width=None,environment_id=f'audit-{seed}-{kind}');history=[];known_labels=[]
   try:
    obs,info=env.reset(seed=seed)
    for ordinal in range(limit):
     expected=episode['records'][ordinal];assert info['camera_tick']==expected['tick'];assert np.allclose(info['physics_position'],expected['position'],atol=1e-6,rtol=0);assert info['teacher_action']==expected['teacher'];history.append(obs.copy());known_labels.append(list(info['teacher_action']))
     obs,_,term,trunc,info=env.step(np.asarray(expected['teacher'] if kind=='teacher' else expected['student'],dtype=np.int64))
   finally:env.close()
   histories.append(np.asarray(history,dtype=np.float32));native_labels.append(known_labels)
  x,y=histories;query=first-1;current_x,current_y=x[query],y[query]
  row={'seed':seed,'first_sustained_mismatch_tick':first,'history_steps':limit,'teacher_label_on_teacher_state':native_labels[0][query],'teacher_label_on_student_state':native_labels[1][query],'student_prediction':student['records'][query]['student'],'current_frame_exact_equal':bool(np.array_equal(current_x,current_y)),'full_prefix_exact_equal':bool(np.array_equal(x[:first],y[:first])),'camera_current_rms':float(np.sqrt(np.mean((current_x[:14112]-current_y[:14112])**2))),'camera_prefix_rms':float(np.sqrt(np.mean((x[:first,:14112]-y[:first,:14112])**2))),'body_current_difference':(current_x[-8:]-current_y[-8:]).tolist(),'prefix_hashes':[hashlib.sha256(h[:first].tobytes()).hexdigest() for h in histories]}
  # Reconstruct own XZ from permitted local velocity/angularY, known reset pose and fixedHz.
  recon=[]
  for episode in [teacher,student]:
   yaw=0.;xz=np.zeros(2);errors=[]
   for record in episode['records']:
    b=record['body'];yaw+=b[3]*.02;c,s=math.cos(yaw),math.sin(yaw);xz+=np.asarray([c*b[0]+s*b[2],-s*b[0]+c*b[2]])*.02;errors.append(float(np.linalg.norm(xz-np.asarray(record['position'])[[0,2]])))
   recon.append({'error_at_first_divergence_metres':errors[query],'max_error_through_first_divergence_metres':max(errors[:first]),'max_error_full_600_metres':max(errors),'first_error_above_1cm_tick':next((i+1 for i,e in enumerate(errors) if e>.01),None)})
  row['permitted_body_odometry']=recon;development.append(row);print(json.dumps(row),flush=True)
finally:worker.close()
assert pins()=={k:plan[k] for k in ('worker_sha256','worker_native_sha256')}
receipt={'schema_version':1,'accepted':False,'experiment_plan_hash':plan['sha256'],'qualification':'read-only identifiability diagnostic; no optimizer, no final seeds, no new observation/teacher fields','manifest_hashes':manifest_hashes,'train_frames':4200,'matrix_bytes':inputs.nbytes,'exact_current_frame_conflicts':frame_conflicts,'exact_complete_prefix_conflicts':prefix_conflicts,'nearest_method':'7x7 mean pooling candidate search over native depth/valid planes plus TRAIN-standardized body, eight candidates reranked by exact raw frame RMS; cross private route phases/different movement labels only; approximate similarity does not prove impossibility','camera_cue_roi':'diagnostic only: depth(.12,.17), valid1, rows35..51 at initial frame; no teacher input or model implementation','initial_cue':cue,'nearest_conflicting_examples':nearest,'development_first_divergences':development,'body_odometry_assumptions':['known authored reset position [0,.81,0] and yaw0','fixed50Hz','local velocity rotated by integrated angularVelocityY','phase audit world pose used only to measure reconstruction error, never inference'],'source_files':{p:sha(root/p) for p in ['examples/game_lab/training_worker/lib/visual_scenario.dart','examples/game_lab/training_worker/lib/task_scenarios.dart','packages/zyren_game_ai/lib/src/brain/training_visual_profiles.dart','packages/zyren_game_native/lib/src/character.dart','packages/zyren_characters/lib/physics.dart']},'worker_pins_after':pins(),'wall_seconds':time.perf_counter()-start}
(out/'identifiability-audit.json').write_text(json.dumps(receipt,separators=(',',':'),allow_nan=False))
