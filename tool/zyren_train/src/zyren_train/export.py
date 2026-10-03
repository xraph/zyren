"""Actor-only ONNX candidates with explicit recurrent state and source pins."""
from dataclasses import dataclass
from pathlib import Path
from types import SimpleNamespace
import hashlib,json,shutil,tempfile
import numpy as np
import onnx
import onnxruntime as ort
import torch
from torch import nn
from .checkpoint import TrainingCheckpoint
from .scenario import canonical_bytes
from .policies.structured import StructuredPolicy


def runtime_schema_hash(value):
    # Native schema toJson ordering is retained in the exported schema file.
    return hashlib.sha256(json.dumps(value,separators=(',',':'),ensure_ascii=False,allow_nan=False).encode()).hexdigest()


@dataclass(frozen=True)
class ActorCheckpoint:
    config: object
    state: object
    observation: object
    action: object
    action_space: object
    @classmethod
    def load(cls,config,run,info):
        state=TrainingCheckpoint.load(SimpleNamespace(path=Path(run)),config.hash)
        pins={(s['observation_schema_hash'],s['action_schema_hash']) for s in config.data['scenarios']}
        if (info['observation_schema_hash'],info['action_schema_hash']) not in pins or runtime_schema_hash(info['observation_schema'])!=info['observation_schema_hash'] or runtime_schema_hash(info['action_schema'])!=info['action_schema_hash']: raise ValueError('Native checkpoint/schema binding differs')
        return cls(config,state,info['observation_schema'],info['action_schema'],info['action_space'])
    def policy(self):
        width=sum(field['width'] for field in self.observation['fields'])
        policy=StructuredPolicy(width,self.action_space,fallback=self.action['fallbackDiscrete'])
        policy.load_state_dict(self.state['model']);policy.eval()
        if policy.distribution_id!=self.config.data['policy_distribution']:raise ValueError('Checkpoint action distribution differs')
        return policy


class ActorStep(nn.Module):
    """Deployment carries state externally. Reset means zero hidden and cell."""
    def __init__(self,policy):
        super().__init__();self.mlp=policy.mlp;self.lstm=policy.lstm;self.action_head=policy.action_head
        self.register_buffer('observation_mean',policy.observation_mean.clone());self.register_buffer('observation_scale',policy.observation_scale.clone())
        self.discrete=bool(policy.nvec)
        if not self.discrete:
            self.register_buffer('low',torch.tensor(policy.action_space['low'],dtype=torch.float32))
            self.register_buffer('high',torch.tensor(policy.action_space['high'],dtype=torch.float32))
    def forward(self,observation,hidden,cell):
        next_hidden,next_cell=self.lstm(self.mlp((observation-self.observation_mean)/self.observation_scale),(hidden,cell))
        scores=self.action_head(next_hidden)
        # Discrete legality remains fresh host input, using the shared decoder.
        action=scores if self.discrete else torch.maximum(self.low,torch.minimum(self.high,scores))
        return action,next_hidden,next_cell


def _spec(name,width):return {'name':name,'dtype':'float32','shape':[-1,width],'maxShape':[64,width]}


def export_actor(checkpoint,output_dir):
    """Write a candidate directory. Acceptance and publication are separate."""
    if not isinstance(checkpoint,ActorCheckpoint):raise ValueError('Verified ActorCheckpoint required')
    output=Path(output_dir)
    if output.exists():raise ValueError('Actor output identity already exists')
    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(tempfile.mkdtemp(prefix=output.name+'.',dir=output.parent))
    try:
        policy=checkpoint.policy();actor=ActorStep(policy).eval();name='logits' if policy.nvec else 'action';family='guard' if policy.nvec else 'vehicle'
        inputs=(torch.zeros(1,policy.width),torch.zeros(1,128),torch.zeros(1,128));names=['observation','hidden','cell'];outputs=[name,'next_hidden','next_cell']
        path=temporary/'actor.onnx'
        torch.onnx.export(actor,inputs,str(path),input_names=names,output_names=outputs,opset_version=17,dynamo=False,external_data=False,dynamic_axes={n:{0:'batch'} for n in names+outputs})
        model=onnx.load(path);onnx.checker.check_model(model,full_check=True);onnx.shape_inference.infer_shapes(model,check_type=True,strict_mode=True)
        if model.opset_import[0].version!=17 or any('value_head' in value.name or 'optimizer' in value.name for value in model.graph.initializer) or any(n.domain not in ('','ai.onnx') for n in model.graph.node):raise ValueError('Unsupported actor-only ONNX graph')
        if path.stat().st_size>8_388_608:raise ValueError('Actor model byte budget exceeded')
        session=ort.InferenceSession(str(path),providers=['CPUExecutionProvider'])
        with torch.no_grad():reference=actor(*inputs)
        actual=session.run(outputs,{n:t.numpy() for n,t in zip(names,inputs)})
        for left,right in zip(actual,reference):np.testing.assert_allclose(left,right.numpy(),atol=1e-5,rtol=1e-4)
        digest=hashlib.sha256(path.read_bytes()).hexdigest();width=sum(policy.nvec) if policy.nvec else len(policy.action_space['low'])
        normalization={'schema_version':1,'mode':'embedded-mean-scale-v1','mean':policy.observation_mean.tolist(),'scale':policy.observation_scale.tolist(),'source_hash':checkpoint.state['normalization']['source_hash'] if checkpoint.state['normalization'] is not None else hashlib.sha256(canonical_bytes({'mode':'identity','width':policy.width})).hexdigest()}
        manifest={'schemaVersion':1,'id':family+'-actor','modelFile':'actor.onnx','sha256':digest,'opset':17,'runtimeVersion':'1.23.2','providers':['cpu'],'maxModelBytes':8_388_608,'inputs':[_spec('observation',policy.width),_spec('hidden',128),_spec('cell',128)],'outputs':[_spec(name,width),_spec('next_hidden',128),_spec('next_cell',128)],'recurrent':{'hidden':'next_hidden','cell':'next_cell'},'provenance':'Locally trained actor; no downloaded weights.','preprocessing':{'normalization':'embedded-mean-scale-v1','sourceHash':normalization['source_hash']}}
        recurrent={'schema_version':1,'inputs':{'hidden':[128],'cell':[128]},'outputs':{'hidden':'next_hidden','cell':'next_cell'},'reset':'zero','max_batch':64,'dtype':'float32'}
        provenance={'schema_version':1,'source_checkpoint_sha256':checkpoint.state['_checkpoint_sha256'],'training_config_hash':checkpoint.config.hash,'training_source_pins':checkpoint.state['source_pins'],'training_worker_sha256':checkpoint.config.data['worker_sha256'],'training_native_sha256':checkpoint.config.data['worker_native_sha256'],'license':'LicenseRef-Repository-Authored','optimizer_exported':False,'critic_exported':False}
        for filename,value in [('model.json',manifest),('normalization.json',normalization),('recurrent.json',recurrent),('provenance.json',provenance)]: (temporary/filename).write_bytes(canonical_bytes(value))
        for filename,value in [('observation.json',checkpoint.observation),('action.json',checkpoint.action)]: (temporary/filename).write_text(json.dumps(value,separators=(',',':'),ensure_ascii=False,allow_nan=False))
        # A candidate has no bundle.json and cannot be mistaken for an accepted export.
        output.mkdir()
        try:
            for resource in temporary.iterdir():resource.rename(output/resource.name)
        except BaseException:
            shutil.rmtree(output);raise
        return {'model_sha256':digest,'family':family,'source_checkpoint_sha256':checkpoint.state['_checkpoint_sha256'],'path':str(output),'native_load_verified':False,'accepted':False}
    finally:
        if temporary.exists():shutil.rmtree(temporary)
