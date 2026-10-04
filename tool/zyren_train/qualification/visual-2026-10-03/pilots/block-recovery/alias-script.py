from pathlib import Path
import json,hashlib
import numpy as np
from zyren_train.dataset import DatasetManifest
root=Path('/Users/rexraphael/Work/TwinOS/flutter-geospatial');out=root/'.superpowers/sdd/README/task-T6-depth-block-recovery-pilot'
values=[];pins=[]
for seed in [11,13]:
 path=out/f'blocks-{seed}';manifest=DatasetManifest.load(path);pins.append(manifest.hash);rows=[]
 for ordinal,row in enumerate(manifest.records(path)):
  if ordinal>327:break
  rows.append(row['observations'][next(iter(row['observations']))])
 values.append(np.asarray(rows,dtype=np.float32))
x,y=values;summary=[]
for start,end in [(0,60),(0,328),(60,328),(264,328),(296,328),(320,328),(327,328)]:
 a,b=x[start:end],y[start:end];summary.append({'ordinals':[start,end],'steps':end-start,'exact_equal':bool(np.array_equal(a,b)),'camera_rms':float(np.sqrt(np.mean((a[:,:14112]-b[:,:14112])**2))),'body_max_absolute':float(np.max(np.abs(a[:,-8:]-b[:,-8:]))),'permitted_history_hashes':[hashlib.sha256(v.tobytes()).hexdigest() for v in [a,b]]})
result={'schema_version':1,'accepted':False,'qualification':'pure exact native-record comparison, no optimization','seeds':[11,13],'recording_manifest_hashes':pins,'current_ordinal':327,'labels':[[0,3,2,1,0,0],[1,4,2,1,0,0]],'route_phase':2,'windows':summary,'interpretation':'Exact current/recent input aliases do not prove complete-history nonidentifiability. Initial visible camera cues differ, so retention of the permitted observed goal is necessary.'}
(out/'alias-history-detail.json').write_text(json.dumps(result,sort_keys=True,separators=(',',':')));print(json.dumps(result),flush=True)
