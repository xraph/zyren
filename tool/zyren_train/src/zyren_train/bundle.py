"""Validated policy directories. Pipeline owns archive packaging and import."""
from dataclasses import dataclass
from pathlib import Path
import hashlib,json,math,os,re,shutil,tempfile
import onnx
from .scenario import canonical_bytes,decode_json_bytes
from .report import EvaluationReport
from .export import runtime_schema_hash

ONNX_PROVIDERS=frozenset(('python-onnxruntime-1.23.2-cpu','native-onnxruntime-1.23.2-cpu'))

def _require_onnx_report(report):
    provider=report.data['provider']
    if not isinstance(provider,str) or any(part not in ONNX_PROVIDERS for part in provider.split(';')):raise ValueError('Exact ONNX inference provider required')

FILES=frozenset(('actor.onnx','model.json','observation.json','action.json','normalization.json','recurrent.json','provenance.json','evaluation.json'))
POLICY={'observation_input':'observation','continuous_output':None,'discrete_output':'logits','recurrent':{'hidden':'next_hidden','cell':'next_cell'},'cadence_ticks':1,'latency_ticks':1,'max_hold_ticks':0}


def _hash(raw):return hashlib.sha256(raw).hexdigest()
def _digest(value):return isinstance(value,str) and re.fullmatch('[0-9a-f]{64}',value) is not None


def _read(path,budget=16_777_216):
    descriptor=os.open(path,os.O_RDONLY|os.O_NOFOLLOW)
    with os.fdopen(descriptor,'rb') as stream:
        size=os.fstat(stream.fileno()).st_size
        if size<1 or size>budget:raise ValueError('Policy resource byte budget differs')
        data=stream.read(budget+1)
    if len(data)!=size:raise ValueError('Policy resource changed while reading')
    return data


@dataclass(frozen=True)
class ModelBundleManifest:
    encoded: bytes
    @classmethod
    def from_dict(cls,data):
        encoded=canonical_bytes(data,65536)
        required={'schema_version','id','family','model_sha256','source_checkpoint_sha256','observation_schema_hash','action_schema_hash','controller_mapping','evaluation_report_hash','evaluation_plan_hash','files','policy','precision','provider','accepted'}
        if not isinstance(data,dict) or set(data)!=required or type(data['schema_version']) is not int or data['schema_version']!=1 or data['accepted'] is not True or data['provider']!='cpu' or data['family'] not in ('guard','vehicle') or data['precision'] not in ('float32','int8','float16') or not isinstance(data['id'],str) or not re.fullmatch('[A-Za-z0-9_-]{1,80}',data['id']):raise ValueError('Policy bundle schema/acceptance differs')
        for key in ('model_sha256','source_checkpoint_sha256','observation_schema_hash','action_schema_hash','evaluation_report_hash','evaluation_plan_hash'):
            if not _digest(data[key]):raise ValueError('Policy bundle hash pin differs')
        expected=dict(POLICY)
        if data['family']=='vehicle':expected.update(continuous_output='action',discrete_output=None)
        if data['policy']!=expected or any(type(data['policy'][key]) is not int for key in ('cadence_ticks','latency_ticks','max_hold_ticks')) or data['controller_mapping']!=('character-discrete-v1' if data['family']=='guard' else 'vehicle-pedals-v1'):raise ValueError('Policy controller/timing binding differs')
        rows=data['files']
        if not isinstance(rows,list) or len(rows)!=8 or any(not isinstance(row,dict) or set(row)!={'path','sha256','bytes'} or row['path'] not in FILES or not _digest(row['sha256']) or type(row['bytes']) is not int or not 1<=row['bytes']<=16_777_216 for row in rows) or {row['path'] for row in rows}!=FILES or sum(row['bytes'] for row in rows)>33_554_432:raise ValueError('Policy resource paths/hashes/budget differ')
        return cls(encoded)
    @property
    def data(self):return json.loads(self.encoded)
    @property
    def hash(self):return _hash(self.encoded)
    @classmethod
    def load(cls,directory):
        folder=Path(directory)
        if folder.is_symlink() or not folder.is_dir() or {path.name for path in folder.iterdir()}!=FILES|{'bundle.json'}:raise ValueError('Policy directory has missing or extra resources')
        manifest=cls.from_dict(decode_json_bytes(_read(folder/'bundle.json',65536),65536));data=manifest.data
        resources={row['path']:_read(folder/row['path']) for row in data['files']}
        if any(len(resources[row['path']])!=row['bytes'] or _hash(resources[row['path']])!=row['sha256'] for row in data['files']):raise ValueError('Policy resource bytes/hash differ')
        _validate_resources(data,resources)
        return manifest


def _validate_resources(data,resources):
    model=decode_json_bytes(resources['model.json'],65536);observation=decode_json_bytes(resources['observation.json'],65536);action=decode_json_bytes(resources['action.json'],65536)
    normalization=decode_json_bytes(resources['normalization.json'],65536);recurrent=decode_json_bytes(resources['recurrent.json'],65536);provenance=decode_json_bytes(resources['provenance.json'],262144)
    if _hash(resources['actor.onnx'])!=data['model_sha256'] or model['sha256']!=data['model_sha256'] or model['modelFile']!='actor.onnx' or model['schemaVersion']!=1 or model['runtimeVersion']!='1.23.2' or model['providers']!=['cpu'] or model['opset']!=17 or model.get('customOperatorLibraries',[]) or model.get('externalData',[]):raise ValueError('Native model manifest differs')
    if runtime_schema_hash(observation)!=data['observation_schema_hash'] or runtime_schema_hash(action)!=data['action_schema_hash'] or action['id']!=data['controller_mapping']:raise ValueError('Policy schema/controller identity differs')
    width=sum(field['width'] for field in observation['fields']);outputs=sum(len(b['choices']) for b in action['branches']) if data['family']=='guard' else len(action['continuous'])
    expected_inputs=[{'name':name,'dtype':'float32','shape':[-1,n],'maxShape':[64,n]} for name,n in [('observation',width),('hidden',128),('cell',128)]]
    expected_outputs=[{'name':name,'dtype':'float32','shape':[-1,n],'maxShape':[64,n]} for name,n in [('logits' if data['family']=='guard' else 'action',outputs),('next_hidden',128),('next_cell',128)]]
    if any(type(v) is not int for spec in model['inputs']+model['outputs'] for key in ('shape','maxShape') for v in spec[key]) or model['inputs']!=expected_inputs or model['outputs']!=expected_outputs or model['recurrent']!=POLICY['recurrent']:raise ValueError('Native policy tensor layout differs')
    if set(normalization)!={'schema_version','mode','mean','scale','source_hash'} or normalization['schema_version']!=1 or normalization['mode']!='embedded-mean-scale-v1' or not _digest(normalization['source_hash']) or len(normalization['mean'])!=width or len(normalization['scale'])!=width or any(type(v) not in (int,float) or not math.isfinite(v) for v in normalization['mean']+normalization['scale']) or any(v<=0 for v in normalization['scale']):raise ValueError('Embedded normalization differs')
    if model.get('preprocessing')!={'normalization':'embedded-mean-scale-v1','sourceHash':normalization['source_hash']}:raise ValueError('Model normalization source pin differs')
    if recurrent!={'schema_version':1,'inputs':{'hidden':[128],'cell':[128]},'outputs':POLICY['recurrent'],'reset':'zero','max_batch':64,'dtype':'float32'}:raise ValueError('Recurrent reset/carry layout differs')
    if provenance.get('source_checkpoint_sha256')!=data['source_checkpoint_sha256'] or provenance.get('optimizer_exported') is not False or provenance.get('critic_exported') is not False or not _digest(provenance.get('training_config_hash')):raise ValueError('Actor provenance differs')
    parity=provenance.get('native_parity',{})
    if parity.get('model_sha256')!=data['model_sha256'] or parity.get('status')!='passed' or parity.get('provider')!='native-onnxruntime-1.23.2-cpu' or type(parity.get('steps')) is not int or parity['steps']<1000 or parity.get('completed_runs')!=parity['steps'] or parity.get('live_sessions')!=0 or parity.get('live_results')!=0 or not _digest(parity.get('native_worker_sha256')) or parity.get('typed_controller_steps')!=parity.get('steps') or parity.get('atol')!=1e-5 or parity.get('rtol')!=1e-4 or not _digest(parity.get('input_sequence_hash')) or type(parity.get('max_absolute_error')) not in (int,float) or not math.isfinite(parity['max_absolute_error']) or parity['max_absolute_error']<0 or not isinstance(parity.get('native_asset_sha256'),dict) or not parity['native_asset_sha256'] or any(not _digest(value) for value in parity['native_asset_sha256'].values()):raise ValueError('Native sequence qualification missing')
    report=EvaluationReport.from_dict(decode_json_bytes(resources['evaluation.json'],16_777_216))
    _require_onnx_report(report)
    if report.hash!=data['evaluation_report_hash'] or report.data['plan_hash']!=data['evaluation_plan_hash'] or report.data['status']!='passed' or report.data['family_model_hashes'][data['family']]!=data['model_sha256']:raise ValueError('Evaluated ONNX identity/acceptance differs')
    cases=[case for case in report.data['plan']['cases'] if case['family']==data['family']]
    if any(case['scenario']['observation_schema_hash']!=data['observation_schema_hash'] or case['scenario']['action_schema_hash']!=data['action_schema_hash'] for case in cases):raise ValueError('Evaluation schema binding differs')
    if data['precision']=='float16':raise ValueError('Float16 qualification is not implemented')
    if data['precision']=='int8':_validate_quantization(data,provenance,report)
    elif 'quantization' in provenance:raise ValueError('Float policy carries quantization metadata')
    graph=onnx.load_from_string(resources['actor.onnx']);onnx.checker.check_model(graph,full_check=True)
    for infos,specs in ((graph.graph.input,expected_inputs),(graph.graph.output,expected_outputs)):
        if len(infos)!=len(specs):raise ValueError('ONNX tensor count differs from native manifest')
        for info,spec in zip(infos,specs):
            shape=info.type.tensor_type.shape.dim
            if info.name!=spec['name'] or info.type.tensor_type.elem_type!=onnx.TensorProto.FLOAT or len(shape)!=2 or not shape[0].dim_param or shape[1].dim_value!=spec['shape'][1]:raise ValueError('ONNX tensor layout differs from native manifest')
    if any(value.data_location==onnx.TensorProto.EXTERNAL or 'value_head' in value.name or 'optimizer' in value.name for value in graph.graph.initializer):raise ValueError('External data or training-only weights in actor')
    tensors={value.name:onnx.numpy_helper.to_array(value).tolist() for value in graph.graph.initializer if value.name in ('observation_mean','observation_scale')}
    if tensors!={'observation_mean':normalization['mean'],'observation_scale':normalization['scale']}:raise ValueError('Normalization file differs from embedded actor buffers')


def publish_actor(candidate,output_dir,report,native_parity,*,precision='float32',baseline_bundle=None):
    folder=Path(candidate);output=Path(output_dir)
    if not isinstance(report,EvaluationReport) or report.data['status']!='passed':raise ValueError('Passed exact-actor evaluation required')
    if {path.name for path in folder.iterdir()}!=FILES-{'evaluation.json'}:raise ValueError('Candidate resource set differs')
    resources={name:_read(folder/name) for name in FILES-{'evaluation.json'}}
    model=decode_json_bytes(resources['model.json'],65536);observation=decode_json_bytes(resources['observation.json'],65536);action=decode_json_bytes(resources['action.json'],65536);provenance=decode_json_bytes(resources['provenance.json'],262144)
    family='guard' if action['branches'] else 'vehicle';digest=_hash(resources['actor.onnx']);policy=dict(POLICY)
    if family=='vehicle':policy.update(continuous_output='action',discrete_output=None)
    if precision=='int8':
        from .quantize import qualify_quantized
        if baseline_bundle is None:raise ValueError('Accepted float baseline proof required')
        baseline=ModelBundleManifest.load(baseline_bundle)
        if baseline.data['precision']!='float32' or baseline.data['family']!=family:raise ValueError('Accepted float baseline differs')
        baseline_report=EvaluationReport.from_dict(decode_json_bytes(_read(Path(baseline_bundle)/'evaluation.json'),16_777_216))
        qualification=qualify_quantized(baseline_report,report,family)
        quantization=provenance.get('quantization')
        if not isinstance(quantization,dict) or quantization.get('baseline_bundle_hash')!=baseline.hash or quantization.get('baseline_model_sha256')!=baseline.data['model_sha256']:raise ValueError('Quantization baseline identity differs')
        quantization.update(baseline_bundle_manifest=baseline.data,baseline_report=baseline_report.data,baseline_report_hash=baseline_report.hash,candidate_report_hash=report.hash,success_loss=qualification['success_loss'])
    provenance['native_parity']=native_parity;resources['provenance.json']=canonical_bytes(provenance,262144);resources['evaluation.json']=report.encoded
    manifest=ModelBundleManifest.from_dict({'schema_version':1,'id':family+'-'+precision+'-'+digest[:12],'family':family,'model_sha256':digest,'source_checkpoint_sha256':provenance['source_checkpoint_sha256'],'observation_schema_hash':runtime_schema_hash(observation),'action_schema_hash':runtime_schema_hash(action),'controller_mapping':action['id'],'evaluation_report_hash':report.hash,'evaluation_plan_hash':report.data['plan_hash'],'files':[{'path':name,'sha256':_hash(raw),'bytes':len(raw)} for name,raw in sorted(resources.items())],'policy':policy,'precision':precision,'provider':'cpu','accepted':True})
    _validate_resources(manifest.data,resources)
    output.parent.mkdir(parents=True,exist_ok=True);output.mkdir()
    try:
        for name,raw in resources.items():
            with (output/name).open('xb') as stream:stream.write(raw);stream.flush();os.fsync(stream.fileno())
        with (output/'bundle.json').open('xb') as stream:stream.write(manifest.encoded);stream.flush();os.fsync(stream.fileno())
        return ModelBundleManifest.load(output)
    except BaseException:
        for name in FILES|{'bundle.json'}:(output/name).unlink(missing_ok=True)
        output.rmdir();raise


def _validate_quantization(data,provenance,report):
    from .quantize import qualify_quantized
    quantization=provenance.get('quantization')
    required={'precision','format','operators','baseline_bundle_hash','baseline_model_sha256','calibration_partition','calibration_steps','calibration_manifest_hashes','calibration_sequence_hash','baseline_bundle_manifest','baseline_report','baseline_report_hash','candidate_report_hash','success_loss'}
    if not isinstance(quantization,dict) or set(quantization)!=required or quantization['precision']!='int8' or quantization['format']!='QDQ' or quantization['operators']!=['MatMul','Gemm'] or quantization['calibration_partition']!='train' or type(quantization['calibration_steps']) is not int or not 1<=quantization['calibration_steps']<=2000 or not _digest(quantization['calibration_sequence_hash']) or not isinstance(quantization['calibration_manifest_hashes'],list) or not quantization['calibration_manifest_hashes'] or any(not _digest(digest) for digest in quantization['calibration_manifest_hashes']):raise ValueError('Quantization calibration proof differs')
    baseline=ModelBundleManifest.from_dict(quantization['baseline_bundle_manifest']);baseline_data=baseline.data
    baseline_report=EvaluationReport.from_dict(quantization['baseline_report'])
    _require_onnx_report(baseline_report)
    if baseline_data['precision']!='float32' or baseline_data['family']!=data['family'] or baseline_data['model_sha256']!=quantization['baseline_model_sha256'] or baseline.hash!=quantization['baseline_bundle_hash'] or baseline_data['evaluation_report_hash']!=baseline_report.hash or baseline_report.hash!=quantization['baseline_report_hash'] or report.hash!=quantization['candidate_report_hash'] or baseline_data['evaluation_plan_hash']!=data['evaluation_plan_hash'] or baseline_data['observation_schema_hash']!=data['observation_schema_hash'] or baseline_data['action_schema_hash']!=data['action_schema_hash'] or baseline_report.data['family_model_hashes'][data['family']]!=baseline_data['model_sha256']:raise ValueError('Quantization baseline/evaluation identity differs')
    row=next(row for row in baseline_data['files'] if row['path']=='evaluation.json')
    if row['sha256']!=baseline_report.hash or row['bytes']!=len(baseline_report.encoded):raise ValueError('Baseline evaluation file proof differs')
    qualification=qualify_quantized(baseline_report,report,data['family'])
    if type(quantization['success_loss']) not in (int,float) or quantization['success_loss']!=qualification['success_loss']:raise ValueError('Quantization success loss differs')
