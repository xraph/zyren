"""Deterministic visual runtime fixture, never a trained or accepted policy."""
import hashlib
import json
from pathlib import Path
import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper
root = Path(__file__).resolve().parents[1] / 'fixtures'
width = 2 * 84 * 84 + 8
logits = np.zeros((1,22), np.float32)
logits[0,[2,9,12,16,18,20]] = 10
inputs = [helper.make_tensor_value_info(n,TensorProto.FLOAT,['batch',w]) for n,w in [('observation',width),('hidden',128),('cell',128)]]
outputs = [helper.make_tensor_value_info(n,TensorProto.FLOAT,['batch',w]) for n,w in [('logits',22),('next_hidden',128),('next_cell',128)]]
graph = helper.make_graph([
 helper.make_node('ReduceMean',['observation'],['mean'],axes=[1],keepdims=1),
 helper.make_node('MatMul',['mean','zero'],['zeros']),
 helper.make_node('Add',['zeros','bias'],['logits']),
 helper.make_node('Add',['hidden','one'],['next_hidden']),
 helper.make_node('Add',['cell','one'],['next_cell']),
], 'visual-runtime-probe',inputs,outputs,[numpy_helper.from_array(np.zeros((1,22),np.float32),'zero'),numpy_helper.from_array(logits,'bias'),numpy_helper.from_array(np.ones((1,128),np.float32),'one')])
model = helper.make_model(graph,opset_imports=[helper.make_opsetid('',17)],ir_version=9)
onnx.checker.check_model(model)
path=root/'visual_runtime_probe.onnx';onnx.save(model,path)
def spec(n,w):return {'name':n,'dtype':'float32','shape':[-1,w],'maxShape':[64,w]}
manifest={'schemaVersion':1,'id':'visual-runtime-probe','modelFile':path.name,'sha256':hashlib.sha256(path.read_bytes()).hexdigest(),'opset':17,'runtimeVersion':'1.23.2','providers':['cpu'],'maxModelBytes':1048576,'inputs':[spec('observation',width),spec('hidden',128),spec('cell',128)],'outputs':[spec('logits',22),spec('next_hidden',128),spec('next_cell',128)],'recurrent':{'hidden':'next_hidden','cell':'next_cell'},'provenance':'Deterministic visual runtime fixture, not a trained or accepted policy.'}
(root/'visual_runtime_probe.json').write_text(json.dumps(manifest,indent=2)+'\n')
