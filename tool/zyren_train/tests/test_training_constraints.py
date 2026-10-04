import pytest
import torch

from zyren_train.rewards import RewardLedger
from zyren_train.train import TrainingConfig, _ppo_update
from zyren_train.policies.cloning import DemonstrationRegularizer
from zyren_train.policies.structured import StructuredPolicy
from zyren_train.dataset import DatasetPartition
from training_support import configuration


def base_config(tmp_path):
    exe = tmp_path / 'bin/probe'
    exe.parent.mkdir()
    exe.write_bytes(b'pure-config-fixture')
    (tmp_path / 'lib').mkdir()
    (tmp_path / 'lib/probe').write_bytes(b'pure-native-pin-fixture')
    return configuration([str(exe)])


def row(tick=1, **values):
    return dict(episode_id='e', tick=tick, reward_terms={'task.progress': .25},
                collision=False, success=False, terminated=False, truncated=False, **values)


def test_optional_outcome_derivation_uses_current_typed_receipts_once():
    ledger = RewardLedger({'task.progress': 1, 'safety.collision': .5, 'task.completion': 5},
                          derived_rewards={'safety.collision': -.5, 'task.completion': 5})
    assert ledger.apply(row(), environment_id='env') == .25
    assert ledger.apply({**row(2), 'collision': True}, environment_id='env') == -.25
    assert ledger.apply({**row(3), 'success': True}, environment_id='env') == .25
    assert ledger.apply({**row(4), 'success': True, 'truncated': True}, environment_id='env') == 5.25
    assert ledger.apply({**row(5), 'success': True, 'truncated': True}, environment_id='env') == .25
    assert ledger.snapshot() == {'successes': 1, 'collisions': 1, 'progress': 1.25}
    assert ledger.apply({**row(1), 'episode_id': 'next', 'success': True, 'terminated': True}, environment_id='env') == 5.25


@pytest.mark.parametrize('derived', [None, {}, {'safety.collision': 1}, {'task.completion': -1},
                                    {'task.completion': float('nan')}, {'safety.collision': -2},
                                    {'time.step': -.1}, {'task.completion': True}])
def test_derived_reward_closed_signed_caps(derived):
    with pytest.raises(ValueError):
        RewardLedger({'safety.collision': 1, 'task.completion': 1}, derived_rewards=derived)


@pytest.mark.parametrize('bad', [{'collision': 1}, {'success': 'yes'}, {'terminated': None},
                                 {'truncated': 0}, {'reward_terms': {'safety.collision': -.5}},
                                 {'reward_terms': {'task.progress': float('nan')}},
                                 {'reward_terms': {'safety.collision': .5}}])
def test_bad_or_duplicate_host_reward_rejected_without_consuming_tick(bad):
    ledger = RewardLedger({'task.progress': 1, 'safety.collision': 1, 'task.completion': 1},
                          derived_rewards={'safety.collision': -.5, 'task.completion': 1})
    with pytest.raises(ValueError): ledger.apply({**row(), **bad}, environment_id='env')
    assert ledger.snapshot() == {'successes': 0, 'collisions': 0, 'progress': 0}
    assert ledger.apply(row(), environment_id='env') == .25
    with pytest.raises(ValueError): ledger.apply(row(), environment_id='env')


def test_config_defaults_and_optional_constraints_have_separate_hashes(tmp_path):
    original = base_config(tmp_path)
    assert TrainingConfig.from_dict(original.data).encoded == original.encoded
    derived = {**original.data, 'rewards': {'task.progress': 1, 'safety.collision': 1, 'task.completion': 5},
               'derived_rewards': {'safety.collision': -.5, 'task.completion': 5}}
    assert TrainingConfig.from_dict(derived).hash != original.hash
    regularized = {**original.data, 'datasets': {'train': ['TRAIN-source'], 'validation': [], 'test': []},
                   'demonstration_regularization': {'coefficient': .1, 'sequences_per_update': 1}}
    assert TrainingConfig.from_dict(regularized).hash != original.hash
    with pytest.raises(ValueError): TrainingConfig.from_dict({**regularized, 'datasets': original.data['datasets']})
    for pin in [{'coefficient': 0, 'sequences_per_update': 1},
                {'coefficient': float('inf'), 'sequences_per_update': 1},
                {'coefficient': .1, 'sequences_per_update': 5},
                {'coefficient': .1, 'sequences_per_update': True},
                {'coefficient': .1, 'sequences_per_update': 1, 'heads': [0, 1]}]:
        with pytest.raises(ValueError): TrainingConfig.from_dict({**regularized, 'demonstration_regularization': pin})


def test_regularizer_rejects_validation_and_missing_training_sources():
    policy = StructuredPolicy(4, {'kind': 'multi_discrete', 'nvec': [5, 5, 5, 3, 2, 2]}, fallback=[2, 2, 2, 1, 0, 0])
    for partition in [None, DatasetPartition('train', ()), DatasetPartition('validation', ())]:
        with pytest.raises(ValueError): DemonstrationRegularizer(partition, policy, {'coefficient': .1, 'sequences_per_update': 1})


def test_regularizer_cycles_full_sources_rechecks_bytes_and_restores_cursor(tmp_path):
    from test_dataset import row as record_row
    from test_scenario import spec
    from zyren_train.demonstration import DemonstrationRecorder
    paths = []
    for index in range(2):
        path = tmp_path / str(index)
        recorder = DemonstrationRecorder(path, scenario=spec(), session_id=f'source-{index}',
                                        run_id='fixture', environment_id='env', source='player', model_hash='none')
        for tick in range(1, 5):
            value = record_row(tick, end=tick == 4)
            value['observations']['actor'][0] += index
            recorder.append(value)
        recorder.finalize(); paths.append(path)
    part = DatasetPartition.from_recordings('train', paths)
    policy = StructuredPolicy(2, {'kind': 'box', 'low': [-1, 0], 'high': [1, 1]})
    settings = {'coefficient': .1, 'sequences_per_update': 1}
    regularizer = DemonstrationRegularizer(part, policy, settings)
    first = regularizer.sequences_for_update(0)[0]
    second = regularizer.sequences_for_update(1)[0]
    assert regularizer.cache._sequences is not None
    assert first[0].shape == (4, 1, 2) and first[2][:, 0].tolist() == [True, False, False, False]
    assert first[4].all() and not torch.equal(first[0], second[0])
    resumed = DemonstrationRegularizer(part, policy, settings)
    assert torch.equal(resumed.sequences_for_update(1)[0][0], second[0])
    first[0].fill_(999)
    assert not (regularizer.sequences_for_update(2)[0][0] == 999).any()
    chunk = paths[0] / part.recordings[0][1].chunks[0].file
    chunk.write_bytes(chunk.read_bytes() + b'x')
    with pytest.raises(ValueError, match='chunk'): regularizer.sequences_for_update(3)


def test_600_tick_visual_graph_carries_early_cue_to_final_hidden_state():
    from zyren_train.policies.visual import VisualPolicy
    torch.set_num_threads(1); torch.manual_seed(7)
    policy = VisualPolicy(2, 8, {'kind': 'multi_discrete', 'nvec': [5, 5, 5, 3, 2, 2]},
                          fallback=[2, 2, 2, 1, 0, 0], memory_horizon_ticks=600)
    obs = torch.full((600, 1, policy.width), .1, requires_grad=True)
    starts = torch.zeros(600, 1, dtype=torch.bool); starts[0] = True
    outputs, values, hidden = policy.sequence(obs, starts)
    hidden[0].square().sum().backward()
    assert outputs.shape == (600, 1, 22) and torch.isfinite(obs.grad).all()
    assert obs.grad[0].abs().sum() > 0


def test_real_worker_constraints_pin_cancel_and_resume_without_quality_claim(worker, worker_command, tmp_path):
    import numpy as np
    from zyren_train.gym_env import ZyrenEnv
    from zyren_train.scenario import ScenarioSpec
    from zyren_train.demonstration import DemonstrationRecorder, record_episode
    from zyren_train.run_manifest import RunDirectory
    from zyren_train.checkpoint import TrainingCheckpoint
    from zyren_train.train import WorkerPool, train
    from training_support import ROOT
    env = ZyrenEnv(worker, scenario='guard', observation_width=None)
    _, info = env.reset(seed=7); path = tmp_path / 'TRAIN'
    recorder = DemonstrationRecorder(path, scenario=ScenarioSpec.from_dict(info['scenario_spec']),
                                    session_id='constraint-fixture', run_id=worker.run_id,
                                    environment_id=env.environment_id, source='scripted', model_hash='baseline')
    record_episode(env, recorder, lambda _, receipt: np.asarray(receipt['baseline_action'], dtype=np.int64), seed=7)
    recorder.finalize(); env.close()
    data = configuration(worker_command, steps=16, datasets={'train': [str(path)], 'validation': [], 'test': []}).data
    data.update(rewards={'task.progress': 1, 'safety.collision': 1, 'task.completion': 5},
                derived_rewards={'safety.collision': -.5, 'task.completion': 5},
                demonstration_regularization={'coefficient': .1, 'sequences_per_update': 1})
    config = TrainingConfig.from_dict(data); run = RunDirectory(tmp_path / 'run', config.hash)
    pool = WorkerPool(worker_command, cwd=ROOT / 'examples/game_lab/training_worker', config=config)
    stopped = train(config, pool, run, stop_after_updates=1)
    assert stopped['state'] == 'cancelled' and stopped['worker_exit_codes'] == [0]
    checkpoint = TrainingCheckpoint.load(run, config.hash)
    wrong = TrainingConfig.from_dict({**data, 'demonstration_regularization': {'coefficient': .2, 'sequences_per_update': 1}})
    with pytest.raises(ValueError): TrainingCheckpoint.load(run, wrong.hash)
    resumed = RunDirectory(run.path, config.hash, resume=True)
    final = train(config, WorkerPool(worker_command, cwd=ROOT / 'examples/game_lab/training_worker', config=config), resumed, resume=True)
    assert final['state'] == 'completed' and final['steps'] == 16 and final['updates'] == 2
    assert final['worker_exit_codes'] == [0] and final['policy_quality'] is None
    receipts = resumed.read_receipts(); updates = [r for r in receipts if r.get('phase') == 'ppo-update']
    assert len(updates) == 2 and all(r['metrics']['demonstration_rows'] == 240 for r in updates)
    pins = [r for r in receipts if r.get('phase') == 'training-constraints']
    assert len(pins) == 2 and all(r['regularizer_source_pins'] == checkpoint['source_pins']['train'] for r in pins)


def test_wrong_sign_host_outcome_rejected_in_optional_training_mode():
    ledger = RewardLedger({'task.progress': 1, 'safety.collision': 1, 'task.completion': 1},
                          derived_rewards={'task.completion': 1})
    with pytest.raises(ValueError): ledger.apply({**row(), 'reward_terms': {'safety.collision': .5}}, environment_id='env')
    assert ledger.apply(row(), environment_id='env') == .25


def test_combined_update_regularizes_every_controllable_branch_before_one_step():
    torch.set_num_threads(1)
    torch.manual_seed(7)
    policy = StructuredPolicy(4, {'kind': 'multi_discrete', 'nvec': [5, 5, 5, 3, 2, 2]}, fallback=[2, 2, 2, 1, 0, 0])
    obs = torch.randn(4, 1, 4)
    starts = torch.tensor([[True], [False], [False], [False]])
    masks = [torch.ones(4, 1, n, dtype=torch.bool) for n in policy.nvec]
    with torch.no_grad():
        outputs, values, _ = policy.sequence(obs, starts)
        distribution = policy.distribution(outputs, masks)
        actions = distribution.sample(); old = distribution.log_prob(actions)
    batch = (obs, actions, starts, masks, old, values, torch.zeros_like(values),
             torch.zeros_like(starts), torch.zeros(1), policy.initial_state(1))
    # Every head is legal and deliberately gets a different target, including yaw/jump.
    labels = torch.tensor([[[4, 0, 4, 2, 1, 1]]] * 4)
    sequence = (obs, labels, starts, masks, torch.ones_like(starts))
    settings = dict(epochs=1, gamma=.99, gae_lambda=.95, clip=.2, entropy=0, value=0, max_grad_norm=10)
    optimizer = torch.optim.SGD(policy.parameters(), lr=.01)
    before = policy.action_head.bias.detach().clone()
    receipt = _ppo_update(policy, optimizer, batch, settings,
                          demonstrations=[sequence], regularization_coefficient=.5)
    assert receipt['demonstration_sequences'] == 1 and receipt['demonstration_rows'] == 4
    assert receipt['demonstration_loss'] > 0 and receipt['demonstration_coefficient'] == .5
    assert receipt['combined_loss'] == pytest.approx(receipt['loss'] + .5 * receipt['demonstration_loss'])
    offset = 0
    for size in policy.nvec:
        assert not torch.equal(before[offset:offset+size], policy.action_head.bias[offset:offset+size])
        offset += size
    assert all(torch.isfinite(p).all() for p in policy.parameters())


def test_later_nonfinite_demonstration_cannot_apply_partial_optimizer_step():
    torch.set_num_threads(1)
    policy = StructuredPolicy(2, {'kind': 'box', 'low': [-1, 0, 0], 'high': [1, 1, 1]})
    obs = torch.zeros(2, 1, 2); starts = torch.tensor([[True], [False]])
    with torch.no_grad():
        outputs, values, _ = policy.sequence(obs, starts); distribution = policy.distribution(outputs)
        action = distribution.sample(); old = distribution.log_prob(action)
    batch = (obs, action, starts, None, old, values, torch.zeros_like(values), torch.zeros_like(starts), torch.zeros(1), policy.initial_state(1))
    valid = (obs, torch.zeros(2, 1, 3), starts, None, torch.ones_like(starts))
    invalid = (obs * float('nan'), *valid[1:])
    optimizer = torch.optim.Adam(policy.parameters()); before = {k: v.clone() for k, v in policy.state_dict().items()}
    settings = dict(epochs=1, gamma=.99, gae_lambda=.95, clip=.2, entropy=0, value=.5, max_grad_norm=.5)
    with pytest.raises(ValueError): _ppo_update(policy, optimizer, batch, settings, demonstrations=[valid, invalid], regularization_coefficient=.1)
    assert optimizer.state == {} and all(torch.equal(before[k], v) for k, v in policy.state_dict().items())
