"""Record and replay the fixed TRAIN corpus with a separately frozen worker."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess
from zyren_train.multi_recording import record_multi_teacher, replay_multi_recording
from zyren_train.scenario import canonical_bytes
from zyren_train.train import worker_native_hashes
from zyren_train.worker import Worker

SEEDS=(7,17,29,41,53,67,79,97,109,127,139,151)
REQUESTS=(('cooperative-search','joint-teacher'),('competitive-pursuit','joint-teacher'),
          ('competitive-pursuit','stationary-pursuer'),('competitive-pursuit','stationary-evader'))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('worker',type=Path)
    parser.add_argument('output',type=Path)
    args=parser.parse_args();command=args.worker.resolve();output=args.output.resolve()
    output.mkdir(parents=True,exist_ok=False)
    pins={'worker_sha256':hashlib.sha256(command.read_bytes()).hexdigest(),
          'worker_native_sha256':worker_native_hashes(command)}
    specs=json.loads(subprocess.check_output([str(command),'--scenario-specs'],text=True))
    selected=[s for s in specs if s['id'] in {r[0] for r in REQUESTS}]
    if len(selected)!=2 or any(s['partition']!='train' for s in selected):
        raise ValueError('The pinned corpus needs exactly two native TRAIN tasks')
    plan={'schema_version':1,'purpose':'training','seeds':list(SEEDS),
          'requests':[{'scenario':s,'mode':m} for s,m in REQUESTS],
          'episode_count':48,'maximum_native_steps_recording':19200,
          'replay':'every observation, both typed controls, reward and terminal flags',
          'source_sha256':hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
          'scenarios':selected,**pins}
    (output/'recording-plan.json').write_bytes(canonical_bytes(plan)+b'\n')
    results=[];worker=Worker([str(command)],cwd=Path.cwd(),run_id='multi-corpus-v3',timeout=60)
    try:
        for scenario,mode in REQUESTS:
            for seed in SEEDS:
                path=output/'data'/f'{scenario}-{mode}-{seed}'
                receipt=record_multi_teacher(worker,scenario,path,seed=seed,mode=mode)
                replay=replay_multi_recording(worker,path)
                if replay['steps']!=receipt['steps']:raise ValueError('Replay step count differs')
                row={'scenario':scenario,'mode':mode,'seed':seed,
                     'path':path.relative_to(output).as_posix(),**receipt,'replay':replay}
                results.append(row)
                with (output/'recordings.jsonl').open('ab') as stream:
                    stream.write(canonical_bytes(row)+b'\n');stream.flush()
                print(f'{len(results)}/48 {scenario} {mode} seed={seed} steps={receipt["steps"]} replay=passed',flush=True)
    finally:worker.close()
    if worker.process.returncode!=0 or len(results)!=48 or any(
        hashlib.sha256(command.read_bytes()).hexdigest()!=pins['worker_sha256'] or
        worker_native_hashes(command)!=pins['worker_native_sha256'] for _ in [0]):
        raise ValueError('Frozen worker cleanup or corpus coverage differs')
    receipt={'schema_version':1,'status':'passed','purpose':'training',
             'recordings':len(results),'recorded_steps':sum(r['steps'] for r in results),
             'replayed_steps':sum(r['replay']['steps'] for r in results),
             'worker_exit_codes':[worker.process.returncode],
             'recordings_sha256':hashlib.sha256((output/'recordings.jsonl').read_bytes()).hexdigest(),
             'plan_sha256':hashlib.sha256((output/'recording-plan.json').read_bytes()).hexdigest(),
             'learned_quality':None,**pins}
    (output/'receipt.json').write_bytes(canonical_bytes(receipt)+b'\n')
    print(json.dumps(receipt),flush=True)


if __name__=='__main__':main()
