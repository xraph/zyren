import json
from pathlib import Path
import numpy as np
import pytest

from zyren_train.distill import record_dagger
from zyren_train.dataset import DatasetManifest


@pytest.mark.parametrize('windows', [[], [[True, 4]], [[-1, 4]], [[3, 3]], [[0, 1025]],
                                     [[0, 4], [3, 7]], [[5, 7], [0, 3]], [[0, 4, 7]], 'schedule'])
def test_invalid_windows_reject_before_worker_or_output(monkeypatch, tmp_path, windows):
    import zyren_train.distill as distill
    monkeypatch.setattr(distill, 'ZyrenEnv', lambda *a, **kw: pytest.fail('worker must not be accessed'))
    class Student: model_hash = 'a' * 64
    with pytest.raises(ValueError): record_dagger(None, Student(), scenario='guard-visual-depth', seed=7,
                                                 output=tmp_path / 'bad', session_id='bad', student_windows=windows)
    assert not (tmp_path / 'bad').exists()


def test_fixed_control_blocks_record_independent_labels_and_restrict_actor_context(monkeypatch, tmp_path):
    import zyren_train.distill as distill
    from test_scenario import spec
    profile = json.loads((Path(__file__).parent / 'fixtures/visual-profiles.json').read_text())['guard-visual-depth']
    value = spec().to_dict(); value.update(max_steps=10, observation_schema_hash=profile['observation_hash'],
                                         action_schema_hash=profile['action_hash'], settings={'visual': True})
    schema = profile['observation']; supplied = []
    class FakeEnv:
        environment_id = 'fixture'; actor_id = 'actor'
        def __init__(self, *args, **kwargs): self.step_index = 0
        def info(self):
            # Metadata is a protocol fixture, never native camera qualification.
            teacher = [1, 4, 2, 1, 0, 0] if self.step_index < 5 else [3, 2, 2, 1, 0, 0]
            return dict(scenario_spec=value, visual_source='actual-native-readback', teacher_source='privileged-training-only-route',
                        observation_schema=schema, visual_profile=profile['visual_profile'], observation_schema_hash=profile['observation_hash'],
                        action_schema_hash=profile['action_hash'], action_schema={'fallbackDiscrete': [2, 2, 2, 1, 0, 0]},
                        action_space={'kind': 'multi_discrete', 'nvec': [5, 5, 5, 3, 2, 2]},
                        teacher_action=teacher, teacher_observation=[999], physics_position=[999, 999, 999],
                        task_remaining_distance=999, episode_id='episode', tick=self.step_index+1,
                        actor_generations={'actor': 1}, build_id=value['game_build_hash'],
                        legality=[[True] * n for n in [5, 5, 5, 3, 2, 2]], collision=False, success=False)
        def reset(self, **kwargs): self.step_index = 0; return np.zeros(14120), self.info()
        def step(self, action):
            self.step_index += 1; info = self.info(); supplied.append(action.tolist())
            info.update(accepted_action=action.tolist(), delay_ticks=1, fallback=False, reward_terms={'task.progress': 0})
            return np.zeros(14120), 0, self.step_index == 10, False, info
        def close(self): pass
    class Student:
        model_hash = 'a' * 64; calls = 0
        def reset(self): self.calls = 0
        def act(self, observation, info):
            assert len(observation) == 14120
            assert not {'teacher_action', 'teacher_observation', 'physics_position', 'task_remaining_distance'} & info.keys()
            self.calls += 1
            return np.asarray([2, 2, 2, 1, 0, 0])
    monkeypatch.setattr(distill, 'ZyrenEnv', FakeEnv)
    class Worker: run_id = 'fixture'
    student = Student(); path = tmp_path / 'blocks'
    result = record_dagger(Worker(), student, scenario='guard-visual-depth', seed=7, output=path,
                           session_id='blocks', student_windows=[[2, 7]])
    rows = list(DatasetManifest.load(path).records(path)); settings = DatasetManifest.load(path).recording['recording_settings']
    assert student.calls == 10 and result['student_steps'] == 5
    assert settings['intervention_mode'] == 'fixed-student-windows-v1'
    assert settings['control_index_basis'] == 'zero-based-proposed-control'
    assert settings['student_windows'] == ((2, 7),)
    assert 'teacher_probability' not in settings
    assert all(supplied[i] == [2, 2, 2, 1, 0, 0] for i in range(2, 7))
    assert rows[2]['teacher_labels']['actor'] != rows[2]['applied_actions']['actor']
    assert rows[5]['teacher_labels']['actor'] == [3, 2, 2, 1, 0, 0]
    assert result['student_windows'] == [[2, 7]] and result['max_uninterrupted_student_steps'] == 5


def test_random_intervention_cannot_be_mixed_with_fixed_windows(tmp_path):
    class Student: model_hash = 'a' * 64
    with pytest.raises(ValueError): record_dagger(None, Student(), scenario='guard-visual-depth', seed=7,
                                                 output=tmp_path / 'bad', session_id='bad',
                                                 student_windows=[[60, 240]], teacher_probability=.75)


def test_fixed_student_window_uses_real_native_applied_controls(worker, tmp_path):
    class StationaryFixture:
        model_hash = 'a' * 64
        def reset(self): pass
        def act(self, observation, info):
            assert not {'teacher_action', 'teacher_observation', 'physics_position', 'task_remaining_distance'} & info.keys()
            return np.asarray([2, 2, 2, 1, 0, 0], dtype=np.int64)
    path = tmp_path / 'native-block'
    result = record_dagger(worker, StationaryFixture(), scenario='guard-visual-depth', seed=7,
                           output=path, session_id='native-block', student_windows=[[60, 240]])
    assert result['steps'] == 600 and result['student_steps'] == result['max_uninterrupted_student_steps'] == 180
    block = result['student_block_outcomes'][0]
    assert block['steps'] == 180 and block['collision_steps'] == 0 and not block['new_success_during_block']
    rows = DatasetManifest.load(path).records(path)
    for ordinal, row in enumerate(rows):
        if 60 <= ordinal < 240:
            assert row['proposed_actions']['actor'] == row['applied_actions']['actor'] == [2, 2, 2, 1, 0, 0]
    # This stationary fixture verifies the native boundary, never student quality.
    with pytest.raises(ValueError): record_dagger(worker, StationaryFixture(), scenario='guard-visual-depth', seed=7,
                                                 output=tmp_path / 'too-long', session_id='too-long', student_windows=[[60, 601]])
    assert not (tmp_path / 'too-long').exists()
