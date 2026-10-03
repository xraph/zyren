"""Local worker checks and repeatable renderer-free fixture reports."""
import argparse
import hashlib
import json
from pathlib import Path
import time
import numpy as np
from .doctor import doctor
from .gym_env import ZyrenEnv
from .worker import Worker
from .scenario import ScenarioSpec, decode_json_bytes
from .demonstration import DemonstrationRecorder, record_episode, replay_recording


def main(argv=None):
    parser = argparse.ArgumentParser(prog='zyren-train')
    commands = parser.add_subparsers(dest='command', required=True)
    check = commands.add_parser('doctor')
    check.add_argument('--worker')
    fixture = commands.add_parser('fixture')
    fixture.add_argument('--worker', required=True)
    fixture.add_argument('--cwd', type=Path, required=True)
    fixture.add_argument('--steps', type=int, default=1000)
    fixture.add_argument('--seed', type=int, default=7)
    fixture.add_argument('--output', type=Path)
    record=commands.add_parser('record')
    record.add_argument('--worker',required=True); record.add_argument('--cwd',type=Path,required=True)
    record.add_argument('--scenario-spec',type=Path,required=True); record.add_argument('--output',type=Path,required=True)
    record.add_argument('--source',choices=['player','scripted'],required=True); record.add_argument('--actions',type=Path)
    record.add_argument('--session-id',required=True)
    replay=commands.add_parser('replay')
    replay.add_argument('--worker',required=True); replay.add_argument('--cwd',type=Path,required=True)
    replay.add_argument('--recording',type=Path,required=True)
    args = parser.parse_args(argv)
    if args.command == 'doctor':
        print(json.dumps(doctor(args.worker), indent=2))
        return
    if args.command in ('record','replay'):
        worker=Worker([str(Path(args.worker).resolve())],cwd=args.cwd,run_id='demonstration')
        try:
            if args.command=='replay':
                print(json.dumps(replay_recording(worker,args.recording),indent=2)); return
            spec=ScenarioSpec.from_dict(decode_json_bytes(args.scenario_spec.read_bytes(),65536))
            if spec.id not in ('guard','vehicle'): parser.error('the supplied worker registers guard and vehicle')
            actions=None; settings={'input_source':'scripted-baseline','physical_device_qualified':None}
            if args.source=='player':
                if args.actions is None: parser.error('player recording requires a controller action trace')
                raw=args.actions.read_bytes(); actions=iter(decode_json_bytes(raw))
                settings={'input_source':'controller-trace','trace_sha256':hashlib.sha256(raw).hexdigest(),
                          'physical_device_qualified':None}
            env=ZyrenEnv(worker,scenario=spec.id,observation_width=None,
                         action_width=6 if spec.id=='guard' else 3,
                         purpose={'train':'training','validation':'validation','test':'test'}[spec.partition])
            recorder=DemonstrationRecorder(args.output,scenario=spec,session_id=args.session_id,
                run_id='demonstration',environment_id='env',source=args.source,model_hash='scripted-v1' if args.source=='scripted' else 'none',
                recording_settings=settings)
            try:
                def action_source(observation,info):
                    value=next(actions) if actions is not None else info['baseline_action']
                    if spec.id=='guard' and any(type(v) not in (int,float) or v!=int(v) for v in value):
                        raise ValueError('Discrete trace actions must be integers')
                    return np.asarray(value,dtype=np.int64 if spec.id=='guard' else np.float32)
                steps=record_episode(env,recorder,action_source,seed=spec.seed)
                manifest=recorder.finalize()
                print(json.dumps({'state':'completed','steps':steps,'manifest_hash':manifest.hash,'path':str(args.output)},indent=2))
            except BaseException:
                recorder.abort(); raise
            finally: env.close()
        finally: worker.close()
        return
    if not 1 <= args.steps <= 2000:
        parser.error('fixture steps must be within 1..2000')
    worker = Worker([str(Path(args.worker).resolve())], cwd=args.cwd, run_id='fixture')
    env = ZyrenEnv(worker)
    try:
        _, info = env.reset(seed=args.seed)
        started, count = time.perf_counter(), 0
        for _ in range(args.steps):
            _, _, terminated, truncated, info = env.step(np.array([.25, -.5], dtype=np.float32))
            if info.get('worker_failed'):
                raise RuntimeError(info['error'])
            count += 1
            if terminated or truncated:
                break
        elapsed = time.perf_counter() - started
        report = {'schema_version': 1, 'run_id': info['run_id'], 'environment_id': info['environment_id'],
                  'episode_id': info['episode_id'], 'scenario': info['scenario'], 'split': info['split'],
                  'build_id': info['build_id'], 'seed': args.seed, 'accepted_steps': count,
                  'elapsed_seconds': elapsed, 'steps_per_second': count / elapsed,
                  'observation_schema_hash': info['observation_schema_hash'],
                  'action_schema_hash': info['action_schema_hash'], 'worker_failed': False,
                  'renderer': None, 'gpu_qualified': None}
        text = json.dumps(report, indent=2)
        if args.output:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_text(text + '\n')
        print(text)
    finally:
        env.close()
        worker.close()


if __name__ == '__main__':
    main()
