"""Local worker checks and repeatable renderer-free fixture reports."""
import argparse
import json
from pathlib import Path
import time
import numpy as np
from .doctor import doctor
from .gym_env import ZyrenEnv
from .worker import Worker


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
    args = parser.parse_args(argv)
    if args.command == 'doctor':
        print(json.dumps(doctor(args.worker), indent=2))
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
