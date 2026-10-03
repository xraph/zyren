"""Gymnasium adapter over the deployed Dart observation and action path."""
import json
import numpy as np
import gymnasium as gym
from .protocol import ProtocolError
from .worker import WorkerFailed


class ZyrenEnv(gym.Env):
    metadata = {'render_modes': []}

    def __init__(self, worker, *, environment_id='env', scenario='native-body',
                 purpose='training', actor_id='actor', observation_width=8, action_width=2):
        super().__init__()
        self.worker, self.environment_id, self.scenario = worker, environment_id, scenario
        self.purpose, self.actor_id = purpose, actor_id
        self.action_space = gym.spaces.Box(-1, 1, shape=(action_width,), dtype=np.float32)
        self.observation_space = gym.spaces.Box(-np.inf, np.inf, shape=(observation_width,), dtype=np.float32)
        self._info, self._observation, self._ready, self._closed = {}, None, False, False
        self.observation_schema_hash = None
        self.action_schema_hash = self.build_id = None

    def _update(self, frame):
        h = frame.header
        if h['actor_ids'] != [self.actor_id] or h['environment_id'] != self.environment_id:
            raise ProtocolError('environment actor identity differs')
        observation = frame.array(f'observation.{self.actor_id}')
        if observation.dtype != np.dtype('<f4') or observation.shape != self.observation_space.shape or not np.isfinite(observation).all():
            raise ProtocolError('observation dtype or shape differs')
        schema = h['observation_schema_hash']
        if self.observation_schema_hash is not None and schema != self.observation_schema_hash:
            raise ProtocolError('observation schema changed')
        for key in ('action_schema_hash', 'build_id'):
            pin = getattr(self, key)
            if not isinstance(h.get(key), str) or not h[key] or (pin is not None and pin != h[key]):
                raise ProtocolError('action schema or game build changed')
            setattr(self, key, h[key])
        self.observation_schema_hash = schema
        self._info, self._observation = dict(h), observation
        return observation.copy(), dict(h)

    def reset(self, *, seed=None, options=None):
        super().reset(seed=seed)
        if self._closed:
            raise WorkerFailed('environment closed')
        actual_seed = int(self.np_random.integers(0, 2**31)) if seed is None else int(seed)
        options = options or {}
        frame = self.worker.call('reset', environment_id=self.environment_id, episode_id='reset',
                                 actor_ids=[], tick=0, extra={'seed': actual_seed,
                                 'scenario': options.get('scenario', self.scenario), 'purpose': self.purpose})
        result = self._update(frame)
        if frame.header['action_width'] != self.action_space.shape[0]:
            raise ProtocolError('action schema width differs')
        self._ready = True
        return result

    def step(self, action):
        if not self._ready or self._closed:
            raise RuntimeError('reset is required before step')
        action = np.asarray(action, dtype=np.float32)
        if not self.action_space.contains(action) or not np.isfinite(action).all():
            raise ValueError('action is outside its declared space')
        before = self._info
        try:
            frame = self.worker.call('step', environment_id=self.environment_id,
                                     episode_id=before['episode_id'], actor_ids=before['actor_ids'],
                                     tick=before['tick'], actor_generations=before['actor_generations'], arrays={f'action.{self.actor_id}': action})
            if frame.header['episode_id'] != before['episode_id'] or frame.header['tick'] != before['tick'] + 1:
                raise ProtocolError('episode or tick response differs')
            obs, info = self._update(frame)
            reward = float(info['reward'])
            if not np.isfinite(reward) or type(info['terminated']) is not bool or type(info['truncated']) is not bool:
                raise ProtocolError('invalid episode outcome')
            terminated, truncated = info['terminated'], info['truncated']
            self._ready = not (terminated or truncated)
            return obs, reward, terminated, truncated, info
        except WorkerFailed as error:
            self._ready = False
            info = dict(before, worker_failed=True, success=False, error=str(error))
            return self._observation.copy(), 0.0, False, True, info

    def snapshot(self):
        frame = self.worker.call('snapshot', environment_id=self.environment_id,
                                episode_id=self._info['episode_id'], actor_ids=self._info['actor_ids'],
                                tick=self._info['tick'], actor_generations=self._info['actor_generations'])
        return json.loads(frame.array('snapshot').tobytes())

    def restore(self, snapshot):
        frame = self.worker.call('restore', environment_id=self.environment_id,
                                 episode_id=self._info['episode_id'], actor_ids=self._info['actor_ids'],
                                 tick=self._info['tick'], actor_generations=self._info['actor_generations'], arrays={'snapshot': np.frombuffer(json.dumps(snapshot, separators=(',', ':'), allow_nan=False).encode(), dtype=np.uint8)})
        result = self._update(frame)
        self._ready = not (frame.header['terminated'] or frame.header['truncated'])
        return result

    def close(self):
        if self._closed:
            return
        self._closed = True
        try:
            self.worker.call('close', environment_id=self.environment_id,
                             episode_id=self._info.get('episode_id', 'none'),
                             actor_ids=self._info.get('actor_ids', []), tick=self._info.get('tick', 0), actor_generations=self._info.get('actor_generations', {}))
        except (WorkerFailed, ProtocolError):
            pass
