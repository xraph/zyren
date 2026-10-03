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
    training=commands.add_parser('train')
    training.add_argument('--config',type=Path,required=True); training.add_argument('--worker',required=True)
    training.add_argument('--cwd',type=Path,required=True); training.add_argument('--run',type=Path,required=True)
    training.add_argument('--resume',action='store_true'); training.add_argument('--stop-after-updates',type=int)
    configure=commands.add_parser('configure')
    configure.add_argument('--template',type=Path,required=True); configure.add_argument('--worker',required=True)
    configure.add_argument('--output',type=Path,required=True)
    evaluation=commands.add_parser('evaluate')
    evaluation.add_argument('--plan',type=Path,required=True);evaluation.add_argument('--worker',required=True)
    evaluation.add_argument('--cwd',type=Path,required=True);evaluation.add_argument('--guard-config',type=Path,required=True)
    evaluation.add_argument('--guard-run',type=Path,required=True);evaluation.add_argument('--vehicle-config',type=Path,required=True)
    evaluation.add_argument('--vehicle-run',type=Path,required=True);evaluation.add_argument('--output',type=Path,required=True)
    evaluation.add_argument('--baseline-output',type=Path,required=True);evaluation.add_argument('--comparison-output',type=Path,required=True)
    args = parser.parse_args(argv)
    if args.command=='evaluate':
        import signal,torch
        from .evaluate import EvaluationPlan,FamilyCandidate,StructuredCandidate,ScriptedCandidate,PreparedEvaluationWorker,evaluate,compare_baseline
        from .train import TrainingConfig
        from .scenario import canonical_bytes
        torch.set_num_threads(1);plan=EvaluationPlan.load(args.plan)
        candidate=FamilyCandidate({'guard':StructuredCandidate(TrainingConfig.load(args.guard_config),args.guard_run),'vehicle':StructuredCandidate(TrainingConfig.load(args.vehicle_config),args.vehicle_run)})
        factory=PreparedEvaluationWorker([str(Path(args.worker).resolve())],args.cwd,plan)
        stop=[False];prior={}
        def request_stop(signum,frame):stop[0]=True
        for signum in (signal.SIGINT,signal.SIGTERM):prior[signum]=signal.signal(signum,request_stop)
        try:
            report=evaluate(candidate,plan,factory,cancelled=lambda:stop[0]);report.write(args.output)
            baseline=evaluate(ScriptedCandidate(),plan,factory,cancelled=lambda:stop[0]);baseline.write(args.baseline_output)
            comparison=compare_baseline(report,baseline)
            args.comparison_output.parent.mkdir(parents=True,exist_ok=True)
            with args.comparison_output.open('xb') as stream:stream.write(canonical_bytes(comparison))
            print(json.dumps({'status':report.data['status'],'report_hash':report.hash,'baseline_report_hash':baseline.hash,'comparison':comparison},indent=2))
        finally:
            for signum,handler in prior.items():signal.signal(signum,handler)
        return
    if args.command=='configure':
        from .train import TrainingConfig,worker_native_hashes
        data=decode_json_bytes(args.template.read_bytes())
        data['worker_sha256']=hashlib.sha256(Path(args.worker).resolve().read_bytes()).hexdigest()
        data['worker_native_sha256']=worker_native_hashes(args.worker)
        config=TrainingConfig.from_dict(data)
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with args.output.open('xb') as stream: stream.write(config.encoded+b'\n')
        print(json.dumps({'config_hash':config.hash,'path':str(args.output)},indent=2)); return
    if args.command=='train':
        import signal
        from .train import TrainingConfig,WorkerPool,train
        from .run_manifest import RunDirectory
        if args.stop_after_updates is not None and args.stop_after_updates<1: parser.error('stop-after-updates must be positive')
        config=TrainingConfig.load(args.config); run=RunDirectory(args.run,config.hash,resume=args.resume)
        stop=[False]; prior={}
        def request_stop(signum,frame): stop[0]=True
        for signum in (signal.SIGINT,signal.SIGTERM):
            prior[signum]=signal.signal(signum,request_stop)
        pool=None
        try:
            pool=WorkerPool([str(Path(args.worker).resolve())],cwd=args.cwd,config=config)
            result=train(config,pool,run,resume=args.resume,stop_after_updates=args.stop_after_updates,cancelled=lambda:stop[0])
            print(json.dumps(result,indent=2))
        except BaseException as error:
            if pool is None: run.append('failed',error=str(error)[:4096],workers_closed=True,worker_exit_codes=[])
            raise
        finally:
            if pool is not None: pool.close()
            for signum,handler in prior.items(): signal.signal(signum,handler)
        return
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
