"""Recorded sequence parity through a prepared Dart/native inference process."""
from pathlib import Path
import base64,hashlib,json,subprocess,tempfile
import numpy as np
import torch
from .scenario import canonical_bytes,decode_json_bytes
from .train import worker_native_hashes


class DartNativeSequence:
    def __init__(self,executable,cwd,manifest,*,family=None):
        self.family=family
        self.executable=Path(executable).resolve();self.cwd=Path(cwd).resolve();self.manifest=Path(manifest).resolve()
        self.artifact_sha256=hashlib.sha256(self.executable.read_bytes()).hexdigest();self.native_sha256=worker_native_hashes(self.executable)
    def _verify(self):
        if hashlib.sha256(self.executable.read_bytes()).hexdigest()!=self.artifact_sha256 or worker_native_hashes(self.executable)!=self.native_sha256:raise ValueError('Native sequence artifact changed')
    def __call__(self,rows):
        self._verify()
        request=canonical_bytes({'manifest':str(self.manifest),'rows':rows,**({'family':self.family} if self.family else {})})
        with tempfile.TemporaryDirectory(prefix='zyren-parity-') as folder:
            source=Path(folder)/'sequence.json';source.write_bytes(request)
            result=subprocess.run([str(self.executable),'--policy-sequence',str(source)],cwd=self.cwd,capture_output=True,timeout=60,check=False)
        self._verify()
        if result.returncode!=0:raise ValueError('Native sequence process failed: '+result.stderr.decode(errors='replace')[:2048])
        data=decode_json_bytes(result.stdout,16_777_216)
        if data.get('provider')!='native-onnxruntime-1.23.2-cpu' or data.get('completed_runs')!=len(rows) or data.get('live_sessions')!=0 or data.get('live_results')!=0 or len(data.get('outputs',[]))!=len(rows):raise ValueError('Native sequence lifetime/provider evidence differs')
        return data


def compare_sequence(actor,rows,native_executor,*,model_sha256,action_schema=None,tensor_evidence_path=None,control_evidence_path=None):
    if not isinstance(rows,list) or not 1<=len(rows)<=2000 or any(set(row)!=({'observation','reset','legality'} if action_schema and actor.discrete else {'observation','reset'}) or type(row['reset']) is not bool for row in rows):raise ValueError('Recorded sequence budget/layout differs')
    result=native_executor(rows)
    if result['model_sha256']!=model_sha256:raise ValueError('Native sequence model identity differs')
    if action_schema and len(result.get('actions',[]))!=len(rows):raise ValueError('Native typed controller evidence missing')
    hidden=torch.zeros(1,actor.lstm.hidden_size);cell=torch.zeros_like(hidden);max_error=0.;max_normalized_error=0.;evidence=[];control_records=[]
    name='logits' if actor.discrete else 'action'
    for index,(row,actual) in enumerate(zip(rows,result['outputs'])):
        if row['reset']:hidden.zero_();cell.zero_()
        observation=torch.tensor([row['observation']],dtype=torch.float32)
        with torch.no_grad():expected=actor(observation,hidden,cell)
        if set(actual)!={name,'next_hidden','next_cell'}:raise ValueError('Native sequence tensor names differ')
        references=[];natives=[]
        for key,reference in zip((name,'next_hidden','next_cell'),expected):
            tensor=actual[key]
            if set(tensor)!={'dtype','shape','data'} or tensor['dtype']!='float32' or tensor['shape']!=list(reference.shape) or not isinstance(tensor['data'],str) or len(tensor['data'])>2048:raise ValueError('Native sequence tensor layout differs')
            raw=base64.b64decode(tensor['data'],validate=True)
            if len(raw)!=reference.numel()*4:raise ValueError('Native tensor byte count differs')
            value=np.frombuffer(raw,dtype='<f4').reshape(reference.shape)
            np.testing.assert_allclose(value,reference.numpy(),atol=1e-5,rtol=1e-4)
            reference_values=reference.numpy();absolute=np.abs(value.astype(np.float64)-reference_values.astype(np.float64))
            max_error=max(max_error,float(np.max(absolute)))
            max_normalized_error=max(max_normalized_error,float(np.max(absolute/(1e-5+1e-4*np.abs(reference_values.astype(np.float64))))))
            references.append(reference_values.reshape(-1));natives.append(value.reshape(-1))
        if action_schema:
            decoded=decode_reference(expected[0].numpy()[0],action_schema,row.get('legality'))
            actual_action=result['actions'][index]
            if set(actual_action)!={'continuous','discrete'} or decoded['discrete']!=actual_action['discrete']:raise ValueError('Native typed categorical controller differs')
            np.testing.assert_allclose(decoded['continuous'],actual_action['continuous'],atol=1e-5,rtol=1e-4)
        evidence.append(np.stack((np.concatenate(references),np.concatenate(natives))))
        if action_schema:control_records.append({'step':index,'reference':decoded,'native':actual_action,**({'legality':row['legality']} if actor.discrete else {})})
        hidden,cell=expected[1:]
    receipt={'schema_version':1,'model_sha256':model_sha256,'steps':len(rows),'max_absolute_error':max_error,'max_normalized_error':max_normalized_error,'atol':1e-5,'rtol':1e-4,
            'provider':result['provider'],'completed_runs':result['completed_runs'],'live_sessions':result['live_sessions'],'live_results':result['live_results'],
            'typed_controller_steps':len(rows) if action_schema else 0,'input_sequence_hash':hashlib.sha256(canonical_bytes(rows)).hexdigest(),'native_worker_sha256':getattr(native_executor,'artifact_sha256',None),'native_asset_sha256':getattr(native_executor,'native_sha256',None),'status':'passed'}
    if tensor_evidence_path is not None:
        tensor=np.asarray(evidence,dtype='<f4');raw=tensor.tobytes(order='C');path=Path(tensor_evidence_path)
        with path.open('xb') as stream:stream.write(raw)
        receipt['tensor_evidence']={'path':path.name,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'dtype':'float32-le','shape':list(tensor.shape),'tensor_widths':{name:expected[0].numel(),'next_hidden':expected[1].numel(),'next_cell':expected[2].numel()}}
    if control_evidence_path is not None:
        if not action_schema:raise ValueError('Typed control evidence requires an action schema')
        raw=canonical_bytes(control_records);path=Path(control_evidence_path)
        with path.open('xb') as stream:stream.write(raw)
        receipt['control_evidence']={'path':path.name,'sha256':hashlib.sha256(raw).hexdigest(),'bytes':len(raw),'steps':len(control_records)}
    return receipt


def recorded_rows(partition,limit=1000,*,include_legality=False):
    from .dataset import DatasetPartition
    if not isinstance(partition,DatasetPartition) or partition.name!='train' or not partition.recordings or not 1<=limit<=2000:raise ValueError('Verified training sequence source required')
    for _ in partition.observation_samples():pass
    rows=[];previous=None
    for path,manifest in partition.recordings:
        for row in manifest.records(path):
            identity=(manifest.recording['session_id'],row['episode_id'])
            if len(row['observations'])!=1:raise ValueError('Single actor sequence required')
            item={'observation':next(iter(row['observations'].values())),'reset':identity!=previous}
            if include_legality:
                item['legality']=next(iter(row['legality'].values()))
            rows.append(item);previous=identity
            if len(rows)==limit:return rows
    raise ValueError('Recorded sequence source has fewer than requested steps')


def decode_reference(values,schema,legality=None):
    if schema['branches']:
        if legality is None or len(legality)!=len(schema['branches']):raise ValueError('Fresh legality mask required')
        choices=[];offset=0
        for branch,mask in zip(schema['branches'],legality):
            width=len(branch['choices'])
            if len(mask)!=width or any(type(v) is not bool for v in mask) or not any(mask):raise ValueError('Legality mask differs')
            choices.append(max((i for i,allowed in enumerate(mask) if allowed),key=lambda i:values[offset+i]));offset+=width
        if offset!=len(values):raise ValueError('Categorical width differs')
        return {'continuous':[],'discrete':choices}
    if schema['id']!='vehicle-pedals-v1' or len(values)!=3 or not np.isfinite(values).all():raise ValueError('Pedal schema/output differs')
    return {'continuous':[float(values[0]),0. if values[2]>0 else float(values[1]),float(values[2])],'discrete':[]}
