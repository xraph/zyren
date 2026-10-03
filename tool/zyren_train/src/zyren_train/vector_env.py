"""Multiplex independent native environments through one prepared supervisor."""
from concurrent.futures import ThreadPoolExecutor
import numpy as np
import gymnasium as gym
from gymnasium.vector.utils import batch_space


class ZyrenVectorEnv(gym.vector.VectorEnv):
    metadata = {'render_modes': []}

    def __init__(self, environments):
        if not 1 <= len(environments) <= 256 or len({e.environment_id for e in environments}) != len(environments):
            raise ValueError('independent environment identities are required')
        self.envs, self.num_envs = list(environments), len(environments)
        self._refresh_spaces()
        self._pool = ThreadPoolExecutor(max_workers=min(32, self.num_envs))
        self.closed = False

    def _refresh_spaces(self):
        self.single_action_space = self.envs[0].action_space
        self.single_observation_space = self.envs[0].observation_space
        if any(e.action_space != self.single_action_space or e.observation_space != self.single_observation_space for e in self.envs):
            raise ValueError('vector spaces must match')
        self.action_space = batch_space(self.single_action_space, self.num_envs)
        self.observation_space = batch_space(self.single_observation_space, self.num_envs)

    def reset(self, *, seed=None, options=None):
        seeds = [None] * self.num_envs if seed is None else ([seed + i for i in range(self.num_envs)] if isinstance(seed, int) else list(seed))
        if len(seeds) != self.num_envs:
            raise ValueError('vector seed count differs')
        futures = [self._pool.submit(e.reset, seed=s, options=options) for e, s in zip(self.envs, seeds)]
        results = [f.result() for f in futures]
        self._refresh_spaces()
        return np.stack([r[0] for r in results]), {'individual': np.array([r[1] for r in results], dtype=object)}

    def step(self, actions):
        if len(actions) != self.num_envs:
            raise ValueError('vector action count differs')
        results = [f.result() for f in [self._pool.submit(e.step, a) for e, a in zip(self.envs, actions)]]
        return (np.stack([r[0] for r in results]), np.array([r[1] for r in results], dtype=np.float64),
                np.array([r[2] for r in results], dtype=bool), np.array([r[3] for r in results], dtype=bool),
                {'individual': np.array([r[4] for r in results], dtype=object)})

    def close(self):
        if self.closed:
            return
        self.closed = True
        for e in self.envs:
            e.close()
        self._pool.shutdown(wait=True, cancel_futures=True)
