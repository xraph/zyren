import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';

final class MemorySink implements GameDemonstrationSink {
  final chunks = <String, List<int>>{};
  Map<String, Object?>? manifest;
  @override
  void beginRecording(Map<String, Object?> metadata) {}
  @override
  void append(String name, Uint8List bytes) =>
      chunks.putIfAbsent(name, () => []).addAll(bytes);
  @override
  void finalizeManifest(Map<String, Object?> value) => manifest = value;
}

Map<String, Object?> metadata() => {
  'schema_version': 1,
  'session_id': 'session',
  'run_id': 'run',
  'environment_id': 'env',
  'source': 'player',
  'model_hash': 'none',
  'scenario_hash': 'scenario',
  'partition': 'train',
  'observation_schema_hash': 'obs',
  'action_schema_hash': 'act',
  'game_build_hash': 'build',
  'scenario': {
    'reward_terms': [
      {'id': 'task.progress', 'cap': 1.0},
    ],
  },
};
Map<String, Object?> row(int tick, {bool end = false}) => {
  'episode_id': 'episode',
  'tick': tick,
  'actor_generations': {'actor': 1},
  'observations': {
    'actor': [.5, 1.0],
  },
  'proposed_actions': {
    'actor': [1.0, 0.0],
  },
  'applied_actions': {
    'actor': [.5, 0.0],
  },
  'fallback': {'actor': false},
  'delay_ticks': {'actor': 1},
  'reward_terms': {'task.progress': .1},
  'terminated': end,
  'truncated': false,
};
void main() {
  test('records bounded append chunks and finalized episode hash receipts', () {
    final sink = MemorySink();
    final recorder = GameDemonstrationRecorder(
      sink: sink,
      metadata: metadata(),
      chunkRecords: 2,
    );
    recorder.append(row(1));
    recorder.append(row(2));
    recorder.append(row(3, end: true));
    final manifest = recorder.finalize();
    expect(sink.chunks.length, 2);
    expect((manifest['episodes'] as List).single['steps'], 3);
    expect((manifest['chunks'] as List).first['records'], 2);
    final record =
        jsonDecode(utf8.decode(sink.chunks.values.first).split('\n').first)
            as Map;
    expect(record['applied_actions'], {
      'actor': [.5, 0.0],
    });
    expect(() => recorder.append(row(4)), throwsStateError);
  });
  test('interrupted recording keeps bytes but has no completed manifest', () {
    final sink = MemorySink();
    final recorder = GameDemonstrationRecorder(
      sink: sink,
      metadata: metadata(),
    );
    recorder.append(row(1));
    recorder.abort();
    expect(sink.chunks.values.single, isNotEmpty);
    expect(sink.manifest, isNull);
  });
  test('profile/tick/width changes and empty episodes fail before append', () {
    final sink = MemorySink();
    final recorder = GameDemonstrationRecorder(
      sink: sink,
      metadata: metadata(),
    );
    expect(recorder.finalize, throwsStateError);
    recorder.append(row(1));
    expect(
      () => recorder.append({...row(2), 'observation_schema_hash': 'new'}),
      throwsFormatException,
    );
    expect(() => recorder.append(row(1)), throwsStateError);
    expect(
      () => recorder.append({
        ...row(2),
        'observations': {
          'actor': [1.0],
        },
      }),
      throwsFormatException,
    );
    recorder.append(row(2, end: true));
    recorder.finalize();
  });
}
