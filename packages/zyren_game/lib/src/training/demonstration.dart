part of '../../training.dart';

/// Storage appends bytes without replacing chunks and publishes a manifest
/// atomically. A failed append leaves an interrupted recording for recovery.
abstract interface class GameDemonstrationSink {
  void beginRecording(Map<String, Object?> metadata);
  void append(String name, Uint8List bytes);
  void finalizeManifest(Map<String, Object?> manifest);
}

/// The player and scripted adapters record the same observed/controller values.
/// Storage stays host-owned, so Studio can stream chunks without a core IO import.
final class GameDemonstrationRecorder {
  final GameDemonstrationSink sink;
  final Map<String, Object?> metadata;
  final int chunkRecords, chunkBytes;
  final _chunks = <Map<String, Object?>>[],
      _episodes = <Map<String, Object?>>[];
  final _episodeIds = <String>{};
  final _widths = <String, int>{};
  final _bytes = BytesBuilder(copy: true);
  int _records = 0, _episodeSteps = 0, _lastTick = -1;
  String? _episode;
  bool _ended = true, _closed = false, _faulted = false;
  GameDemonstrationRecorder({
    required this.sink,
    required Map<String, Object?> metadata,
    this.chunkRecords = 256,
    this.chunkBytes = 8388608,
  }) : metadata = _demoFreeze(metadata) {
    _boundedInt(chunkRecords, 1024, min: 1);
    _boundedInt(chunkBytes, 8388608, min: 1048577);
    final keys = {
      'schema_version',
      'session_id',
      'run_id',
      'environment_id',
      'source',
      'model_hash',
      'scenario_hash',
      'partition',
      'observation_schema_hash',
      'action_schema_hash',
      'game_build_hash',
      'scenario',
    };
    if (metadata.keys.toSet().difference({
          ...keys,
          'recording_settings',
        }).isNotEmpty ||
        !keys.every(metadata.containsKey) ||
        metadata['schema_version'] != 1 ||
        !{'train', 'validation', 'test'}.contains(metadata['partition']) ||
        !{'player', 'scripted', 'policy'}.contains(metadata['source']) ||
        metadata['scenario'] is! Map ||
        metadata.containsKey('recording_settings') &&
            metadata['recording_settings'] is! Map) {
      throw const FormatException('Invalid demonstration metadata.');
    }
    for (final key in keys.difference({'schema_version', 'scenario'})) {
      _wireId(metadata[key]);
    }
    if (_demoEncode(metadata).length > 65536) {
      throw const FormatException('Recording metadata exceeds budget.');
    }
    _rewardCaps();
    sink.beginRecording(this.metadata);
  }
  Map<String, double> _rewardCaps() {
    final terms = (metadata['scenario'] as Map)['reward_terms'];
    if (terms is! List || terms.isEmpty || terms.length > 64) {
      throw const FormatException('Missing registered reward terms.');
    }
    final result = <String, double>{};
    for (final term in terms) {
      if (term is! Map ||
          term.keys.toSet().difference({'id', 'cap'}).isNotEmpty ||
          term['cap'] is! num ||
          !(term['cap'] as num).isFinite ||
          (term['cap'] as num) <= 0 ||
          (term['cap'] as num) > 1000) {
        throw const FormatException('Invalid reward cap.');
      }
      final id = _wireId(term['id']);
      if (result.containsKey(id)) {
        throw const FormatException('Duplicate reward term.');
      }
      result[id] = (term['cap'] as num).toDouble();
    }
    return result;
  }

  void append(Map<String, Object?> record) {
    if (_closed || _faulted) {
      throw StateError('Recording is closed or faulted.');
    }
    final required = {
      'episode_id',
      'tick',
      'actor_generations',
      'observations',
      'proposed_actions',
      'applied_actions',
      'fallback',
      'delay_ticks',
      'reward_terms',
      'terminated',
      'truncated',
    };
    final pins = {
      'observation_schema_hash',
      'action_schema_hash',
      'game_build_hash',
      'model_hash',
    };
    final maskKeys = {'legality', 'execution_legality'};
    if (!required.every(record.containsKey) ||
        record.keys.toSet().difference({
          ...required,
          ...pins,
          ...maskKeys,
        }).isNotEmpty ||
        pins.any((p) => record.containsKey(p) && record[p] != metadata[p])) {
      throw const FormatException('Recording shape or schema pins differ.');
    }
    final episode = _wireId(record['episode_id']);
    final tick = _boundedInt(record['tick'], 9007199254740991);
    if (record['terminated'] is! bool ||
        record['truncated'] is! bool ||
        record['terminated'] == true && record['truncated'] == true) {
      throw const FormatException('Invalid episode outcome.');
    }
    if (episode != _episode) {
      if (!_ended || _episodeIds.contains(episode)) {
        throw StateError('Episode boundary is missing or reused.');
      }
    } else if (_ended || tick <= _lastTick) {
      throw StateError('Episode ended or tick did not advance.');
    }
    final actors = record['actor_generations'];
    if (actors is! Map || actors.isEmpty || actors.length > 256) {
      throw const FormatException('Invalid recording actors.');
    }
    for (final e in actors.entries) {
      _wireId(e.key);
      _boundedInt(e.value, 9007199254740991, min: 1);
    }
    final nextWidths = <String, int>{};
    for (final key in [
      'observations',
      'proposed_actions',
      'applied_actions',
      'fallback',
      'delay_ticks',
    ]) {
      final values = record[key];
      if (values is! Map ||
          values.length != actors.length ||
          !actors.keys.every(values.containsKey)) {
        throw const FormatException('Actor record identity differs.');
      }
      for (final value in values.values) {
        if (key == 'fallback') {
          if (value is! bool) {
            throw const FormatException('Invalid fallback flag.');
          }
        } else if (key == 'delay_ticks') {
          _boundedInt(value, 1000);
        } else {
          if (value is! List ||
              value.isEmpty ||
              value.length > 16384 ||
              value.any((v) => v is! num || !v.isFinite) ||
              nextWidths.containsKey(key) && nextWidths[key] != value.length ||
              _widths.containsKey(key) && _widths[key] != value.length) {
            throw const FormatException(
              'Sensor/action values or width differ.',
            );
          }
          nextWidths[key] = value.length;
        }
      }
    }
    for (final key in maskKeys) {
      if (!record.containsKey(key)) continue;
      final masks = record[key];
      if (masks is! Map ||
          masks.length != actors.length ||
          !actors.keys.every(masks.containsKey)) {
        throw const FormatException('Legality actor identity differs.');
      }
      for (final mask in masks.values) {
        if (mask is! List ||
            mask.length > 128 ||
            mask.any(
              (b) =>
                  b is! List ||
                  b.isEmpty ||
                  b.length > 256 ||
                  b.any((v) => v is! bool) ||
                  !b.contains(true),
            )) {
          throw const FormatException('Invalid recorded legality mask.');
        }
      }
    }
    final caps = _rewardCaps(), rewards = record['reward_terms'];
    if (rewards is! Map ||
        rewards.length != caps.length ||
        !caps.keys.every(rewards.containsKey) ||
        rewards.entries.any(
          (e) =>
              e.value is! num ||
              !(e.value as num).isFinite ||
              (e.value as num).abs() > caps[e.key]!,
        )) {
      throw const FormatException('Reward term or cap differs.');
    }
    final encoded = Uint8List.fromList([..._demoEncode(record), 10]);
    if (_records > 0 &&
        (_records >= chunkRecords ||
            _bytes.length + encoded.length > chunkBytes)) {
      _seal();
    }
    try {
      sink.append(
        'chunk-${_chunks.length.toString().padLeft(6, '0')}.jsonl',
        encoded,
      );
    } catch (_) {
      _faulted = true;
      rethrow;
    }
    _bytes.add(encoded);
    _records++;
    _widths.addAll(nextWidths);
    if (episode != _episode) {
      _episode = episode;
      _episodeSteps = 0;
    }
    _episodeSteps++;
    _lastTick = tick;
    _ended = record['terminated'] == true || record['truncated'] == true;
    if (_ended) {
      _episodeIds.add(episode);
      _episodes.add({
        'episode_id': episode,
        'scenario_hash': metadata['scenario_hash'],
        'session_id': metadata['session_id'],
        'steps': _episodeSteps,
        'observation_schema_hash': metadata['observation_schema_hash'],
        'action_schema_hash': metadata['action_schema_hash'],
        'game_build_hash': metadata['game_build_hash'],
        'partition': metadata['partition'],
        'source': metadata['source'],
      });
    }
    if (_chunks.length >= 100000 || _episodes.length > 100000) {
      _faulted = true;
      throw StateError('Recording manifest budget exceeded.');
    }
  }

  void _seal() {
    if (_records == 0) return;
    final bytes = _bytes.takeBytes();
    _chunks.add({
      'file': 'chunk-${_chunks.length.toString().padLeft(6, '0')}.jsonl',
      'sha256': crypto.sha256.convert(bytes).toString(),
      'records': _records,
      'bytes': bytes.length,
    });
    _records = 0;
  }

  Map<String, Object?> finalize() {
    if (_closed || _faulted || _episodes.isEmpty || !_ended) {
      throw StateError('No completed recording.');
    }
    _seal();
    final manifest = _demoFreeze({
      'schema_version': 1,
      'partition': metadata['partition'],
      'observation_schema_hash': metadata['observation_schema_hash'],
      'action_schema_hash': metadata['action_schema_hash'],
      'game_build_hash': metadata['game_build_hash'],
      'session_id': metadata['session_id'],
      'scenario_hash': metadata['scenario_hash'],
      'chunks': _chunks,
      'episodes': _episodes,
      'recording': metadata,
    });
    _closed = true;
    sink.finalizeManifest(manifest);
    return manifest;
  }

  void abort() {
    _closed = true;
    _bytes.clear();
  }
}

Uint8List _demoEncode(Object? value) {
  final pending = <(Object?, int)>[(value, 0)];
  var nodes = 0;
  while (pending.isNotEmpty) {
    final (current, depth) = pending.removeLast();
    if (depth > 32 || ++nodes > 100000) {
      throw const FormatException('Recording tree exceeds budget.');
    }
    if (current is Map) {
      if (current.keys.any((k) => k is! String)) {
        throw const FormatException('Recording keys must be strings.');
      }
      for (final v in current.values) {
        pending.add((v, depth + 1));
      }
    } else if (current is List) {
      for (final v in current) {
        pending.add((v, depth + 1));
      }
    } else if (current != null &&
            current is! String &&
            current is! bool &&
            current is! num ||
        current is num && !current.isFinite) {
      throw const FormatException('Invalid recording JSON value.');
    }
  }
  Object? sort(Object? v) {
    if (v is Map) {
      final keys = v.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: sort(v[k])};
    }
    if (v is List) return v.map(sort).toList();
    return v;
  }

  final bytes = Uint8List.fromList(utf8.encode(jsonEncode(sort(value))));
  if (bytes.length > 1048576) {
    throw const FormatException('Recording bytes exceed budget.');
  }
  return bytes;
}

Map<String, Object?> _demoFreeze(Map<String, Object?> value) {
  final copied =
      jsonDecode(utf8.decode(_demoEncode(value))) as Map<String, dynamic>;
  Object? freeze(Object? v) {
    if (v is Map) {
      return Map<String, Object?>.unmodifiable(
        v.map((k, v) => MapEntry(k as String, freeze(v))),
      );
    }
    if (v is List) return List<Object?>.unmodifiable(v.map(freeze));
    return v;
  }

  return freeze(copied) as Map<String, Object?>;
}
