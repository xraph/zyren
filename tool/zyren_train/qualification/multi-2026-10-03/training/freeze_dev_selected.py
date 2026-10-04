"""Export the DEV-selected checkpoints without accepting or publishing them."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
from zyren_train.export import ActorCheckpoint,export_actor
from zyren_train.multi_dev import load_checkpoint_receipt
from zyren_train.multi_train import MultiTrainingConfig
from zyren_train.scenario import canonical_bytes

HERE=Path(__file__).resolve().parent


def main():
    selection=json.loads((HERE/'dev-selection/selection.json').read_bytes());receipts={}
    if selection['worker_exit']!=0 or not selection['source_inputs_stable']:raise ValueError('DEV stability differs')
    for name,chosen in selection['selected'].items():
        if chosen is None:raise ValueError('No eligible DEV checkpoint')
        record=HERE/'dev-selection'/f'{name}-{chosen["checkpoint_sequence"]:06d}.json'
        data=json.loads(record.read_bytes());cfg=MultiTrainingConfig.load(HERE/'configs'/f'{name}.json')
        state=load_checkpoint_receipt(HERE/'frozen-main'/name,cfg.hash,data['checkpoint_receipt'])
        src=HERE/'actors'/name;output=HERE/'selected-candidates'/name
        cp=ActorCheckpoint(SimpleNamespace(hash=cfg.hash,data=cfg.data['training']),state,
            json.loads((src/'observation.json').read_bytes()),json.loads((src/'action.json').read_bytes()),
            {'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},multi_profile=json.loads((src/'model.json').read_bytes())['preprocessing']['multiProfile'])
        if output.exists():
            provenance=json.loads((output/'provenance.json').read_bytes());manifest=json.loads((output/'model.json').read_bytes())
            digest=hashlib.sha256((output/'actor.onnx').read_bytes()).hexdigest()
            if provenance['source_checkpoint_sha256']!=state['_checkpoint_sha256'] or provenance['training_config_hash']!=cfg.hash or manifest['sha256']!=digest:
                raise ValueError('Existing selected export differs')
            export={'model_sha256':digest,'family':cfg.data['task'],'source_checkpoint_sha256':state['_checkpoint_sha256'],
                    'path':str(output),'native_load_verified':False,'accepted':False}
        else:export=export_actor(cp,output)
        receipts[name]={'export':export,'checkpoint_receipt':data['checkpoint_receipt'],
            'dev_record_sha256':hashlib.sha256(record.read_bytes()).hexdigest(),'dev_summary':chosen}
        print(name,export['model_sha256'],flush=True)
    value=canonical_bytes({'schema_version':1,'purpose':'dev-selected-unaccepted-actors',
        'selection_sha256':hashlib.sha256((HERE/'dev-selection/selection.json').read_bytes()).hexdigest(),'actors':receipts,'qualification':None})+b'\n'
    path=HERE/'selected-candidates/selection-receipt.json'
    if path.exists():
        if path.read_bytes()!=value:raise ValueError('Selected receipt differs')
    else:
        with path.open('xb') as stream:stream.write(value)


if __name__=='__main__':main()
