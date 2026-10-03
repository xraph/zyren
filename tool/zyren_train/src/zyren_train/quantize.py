"""Separate int8 candidates calibrated only from verified training recordings."""
from pathlib import Path
import hashlib,json,shutil,tempfile
import numpy as np
import onnx
import onnxruntime as ort
from onnxruntime.quantization import CalibrationDataReader,QuantFormat,QuantType,quantize_static
from .bundle import ModelBundleManifest,FILES
from .dataset import DatasetPartition
from .parity import recorded_rows
from .scenario import canonical_bytes


class _Calibration(CalibrationDataReader):
    def __init__(self,model,rows):
        self.session=ort.InferenceSession(str(model),providers=['CPUExecutionProvider']);self.rows=iter(rows)
        self.hidden=np.zeros((1,128),np.float32);self.cell=self.hidden.copy()
    def get_next(self):
        row=next(self.rows,None)
        if row is None:return None
        if row['reset']:self.hidden.fill(0);self.cell.fill(0)
        inputs={'observation':np.asarray([row['observation']],dtype=np.float32),'hidden':self.hidden,'cell':self.cell}
        _,self.hidden,self.cell=self.session.run(None,inputs)
        return inputs


def quantize_candidate(float_bundle,output_dir,calibration,*,steps=1000):
    base=Path(float_bundle);manifest=ModelBundleManifest.load(base);output=Path(output_dir)
    if manifest.data['precision']!='float32':raise ValueError('Accepted float baseline required')
    if not isinstance(calibration,DatasetPartition) or calibration.name!='train':raise ValueError('Training-only calibration required')
    if any(m.observation_schema_hash!=manifest.data['observation_schema_hash'] or m.action_schema_hash!=manifest.data['action_schema_hash'] for _,m in calibration.recordings):raise ValueError('Calibration schema binding differs')
    rows=recorded_rows(calibration,steps)
    if output.exists():raise ValueError('Quantized candidate identity already exists')
    output.parent.mkdir(parents=True,exist_ok=True)
    temporary=Path(tempfile.mkdtemp(prefix='quantized-',dir=output.parent))
    try:
        for name in FILES-{'evaluation.json'}:shutil.copyfile(base/name,temporary/name)
        graph=onnx.load(base/'actor.onnx');eligible=[n.name for n in graph.graph.node if n.op_type in ('MatMul','Gemm')]
        if not eligible:raise ValueError('Actor has no supported quantizable operators')
        quantize_static(str(base/'actor.onnx'),str(temporary/'actor.onnx'),_Calibration(base/'actor.onnx',rows),quant_format=QuantFormat.QDQ,activation_type=QuantType.QInt8,weight_type=QuantType.QInt8,nodes_to_quantize=eligible,per_channel=True)
        graph=onnx.load(temporary/'actor.onnx');onnx.checker.check_model(graph,full_check=True)
        ort.InferenceSession(str(temporary/'actor.onnx'),providers=['CPUExecutionProvider'])
        digest=hashlib.sha256((temporary/'actor.onnx').read_bytes()).hexdigest()
        model=json.loads((temporary/'model.json').read_bytes());model['sha256']=digest;model['id']=manifest.data['family']+'-actor-int8'
        (temporary/'model.json').write_bytes(canonical_bytes(model))
        provenance=json.loads((temporary/'provenance.json').read_bytes());provenance.pop('native_parity',None)
        provenance['quantization']={'precision':'int8','format':'QDQ','operators':['MatMul','Gemm'],'baseline_bundle_hash':manifest.hash,'baseline_model_sha256':manifest.data['model_sha256'],'calibration_partition':'train','calibration_steps':len(rows),'calibration_manifest_hashes':sorted(m.hash for _,m in calibration.recordings),'calibration_sequence_hash':hashlib.sha256(canonical_bytes(rows)).hexdigest()}
        (temporary/'provenance.json').write_bytes(canonical_bytes(provenance))
        output.mkdir()
        try:
            for file in temporary.iterdir():file.rename(output/file.name)
        except BaseException:shutil.rmtree(output);raise
        return {'accepted':False,'precision':'int8','model_sha256':digest,'baseline_model_bytes':(base/'actor.onnx').stat().st_size,'model_bytes':(output/'actor.onnx').stat().st_size,'model_delta_bytes':(output/'actor.onnx').stat().st_size-(base/'actor.onnx').stat().st_size,'app_binary_delta_bytes':None,'working_memory_delta_bytes':None,'path':str(output)}
    finally:shutil.rmtree(temporary)


def qualify_quantized(baseline,candidate_report,family):
    from .report import EvaluationReport
    if not isinstance(baseline,EvaluationReport) or not isinstance(candidate_report,EvaluationReport) or baseline.data['status']!='passed' or candidate_report.data['status']!='passed':raise ValueError('Passed float and candidate evaluations required')
    if baseline.data['plan_hash']!=candidate_report.data['plan_hash']:raise ValueError('Quantization evaluation plan differs')
    left=baseline.data['metrics'][family]['success_rate'];right=candidate_report.data['metrics'][family]['success_rate']
    if left-right>0.020000000001:raise ValueError('Quantization success loss exceeds two percentage points')
    return {'baseline_report_hash':baseline.hash,'candidate_report_hash':candidate_report.hash,'family':family,'success_loss':left-right,'status':'passed'}
