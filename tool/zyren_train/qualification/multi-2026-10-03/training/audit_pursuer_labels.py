"""Measure teacher action classes and checkpoint fit on verified TRAIN sequences."""
import hashlib
import json
from pathlib import Path
from types import SimpleNamespace
import torch
from zyren_train.dataset import DatasetPartition
from zyren_train.export import ActorCheckpoint
from zyren_train.multi_dev import checkpoint_candidates,load_checkpoint_receipt
from zyren_train.multi_recording import multi_training_sequences
from zyren_train.multi_train import MultiTrainingConfig
from zyren_train.run_manifest import RunDirectory
from zyren_train.scenario import canonical_bytes

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[4]


def main():
    torch.set_num_threads(1);cfg=MultiTrainingConfig.load(HERE/'configs/competitive.json')
    run=SimpleNamespace(path=HERE/'frozen-main/competitive',config_hash=cfg.hash)
    chain=RunDirectory.read_receipts(run)
    candidates=checkpoint_candidates(chain,bc_epochs=[8,12,16],ppo_steps=[])
    partition=DatasetPartition.from_recordings('train',cfg.data['training']['datasets']['train'])
    src=HERE/'actors/competitive'
    observation=json.loads((src/'observation.json').read_bytes());action=json.loads((src/'action.json').read_bytes())
    profiles=json.loads((src/'model.json').read_bytes())['preprocessing']['multiProfile'];result=[]
    sources={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'tool/zyren_train/src/zyren_train').rglob('*.py'))}
    for receipt in candidates:
        state=load_checkpoint_receipt(run.path,cfg.hash,receipt)
        cp=ActorCheckpoint(SimpleNamespace(hash=cfg.hash,data=cfg.data['training']),state,observation,action,
                          {'kind':'multi_discrete','nvec':[5,5,5,3,2,2]},multi_profile=profiles)
        policy=cp.policy();groups={}
        for path,manifest in partition.recordings:
            if 'stationary-pursuer' in str(path):source='stationary-pursuer'
            elif 'stationary-evader' in str(path):source='stationary-evader'
            else:source='joint-teacher'
            single=DatasetPartition.from_recordings('train',[path])
            for obs,labels,starts,masks,valid in multi_training_sequences(single,policy):
                role='pursuer' if obs[0,0,26].item()==1 else 'evader';key=source+'/'+role
                stats=groups.setdefault(key,{'rows':0,'sequences':0,'correct':[0]*6,'labels':[[0]*n for n in policy.nvec],'predicted':[[0]*n for n in policy.nvec]})
                with torch.no_grad():scores,_,_=policy.sequence(obs,starts,valid=valid);predicted=policy.distribution(scores,masks).mode()
                count=int(valid.sum());stats['rows']+=count;stats['sequences']+=1
                for head,n in enumerate(policy.nvec):
                    target=labels[:,:,head][valid];chosen=predicted[:,:,head][valid]
                    stats['correct'][head]+=int((target==chosen).sum())
                    for i in range(n):stats['labels'][head][i]+=int((target==i).sum());stats['predicted'][head][i]+=int((chosen==i).sum())
        for stats in groups.values():stats['accuracy']=[n/stats['rows'] for n in stats['correct']]
        result.append({'checkpoint_sha256':receipt['checkpoint_sha256'],'checkpoint_sequence':receipt['sequence'],'groups':groups})
    after={str(p.relative_to(ROOT)):hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted((ROOT/'tool/zyren_train/src/zyren_train').rglob('*.py'))}
    value={'schema_version':1,'purpose':'verified-train-label-diagnosis','training_config_hash':cfg.hash,
           'source_hashes':sources,'source_inputs_stable':sources==after,'script_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
           'dataset_manifest_hashes':[m.hash for _,m in partition.recordings],'checkpoints':result,'quality':None}
    path=HERE/'training-diagnostics/pursuer-label-fit.json'
    if path.exists():raise ValueError('Immutable audit already exists')
    path.write_bytes(canonical_bytes(value)+b'\n')
    for row in result:
        print(row['checkpoint_sequence'],{key:stats['accuracy'][:2] for key,stats in row['groups'].items()},flush=True)


if __name__=='__main__':main()
