import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren_game/training.dart';

Map<String, Object?> header() => {
  'version': 1,
  'operation': 'step',
  'sequence': 1,
  'run_id': 'run',
  'environment_id': 'env',
  'episode_id': 'ep',
  'actor_ids': ['actor'],
  'actor_generations': {'actor': 1},
  'tick': 1,
};
void main() {
  test('partial stream tensor roundtrip preserves identities and layout', () {
    final frame = TrainingFrame.float32(header(), {
      'action': Float32List.fromList([1.5, -2, 4]),
    });
    final bytes = frame.encode();
    final decoder = TrainingFrameDecoder();
    final output = <TrainingFrame>[];
    for (final b in bytes) {
      output.addAll(decoder.add([b]));
    }
    decoder.finish();
    expect(output.single.float32('action'), [1.5, -2, 4]);
    expect(output.single.header['episode_id'], 'ep');
  });
  test(
    'truncation oversized lengths and malformed shape fail before allocation',
    () {
      final decoder = TrainingFrameDecoder();
      decoder.add([1]);
      expect(decoder.finish, throwsFormatException);
      final oversized = ByteData(4)..setUint32(0, 65537, Endian.little);
      expect(
        () => TrainingFrameDecoder().add(oversized.buffer.asUint8List()),
        throwsFormatException,
      );
      final metadata = {
        ...header(),
        'payload_bytes': 4,
        'tensors': [
          {
            'name': 'a',
            'dtype': 'f32',
            'shape': [-1],
            'offset': 0,
            'length': 4,
          },
        ],
      };
      final raw = utf8.encode(jsonEncode(metadata));
      final prefix = ByteData(4)..setUint32(0, raw.length, Endian.little);
      expect(
        () => TrainingFrameDecoder().add([
          ...prefix.buffer.asUint8List(),
          ...raw,
          0,
          0,
          0,
          0,
        ]),
        throwsFormatException,
      );
    },
  );
  test('large snapshots use raw byte blocks without growing JSON header', () {
    final bytes = Uint8List(70000);
    final frame = TrainingFrame.byteBlock(header(), 'snapshot', bytes);
    final encoded = frame.encode();
    expect(
      ByteData.sublistView(encoded).getUint32(0, Endian.little),
      lessThan(65536),
    );
    expect(
      TrainingFrameDecoder().add(encoded).single.bytes('snapshot').length,
      70000,
    );
  });
  test('deep and oversized metadata fail with typed errors before copying', () {
    Object? nested = 0;
    for (var i = 0; i < 1000; i++) {
      nested = [nested];
    }
    expect(
      () => TrainingFrame.float32({...header(), 'nested': nested}, {}),
      throwsFormatException,
    );
    final source = utf8.encode('{"nested":${'[' * 1000}0${']' * 1000}}');
    final prefix = ByteData(4)..setUint32(0, source.length, Endian.little);
    expect(
      () => TrainingFrameDecoder().add([
        ...prefix.buffer.asUint8List(),
        ...source,
      ]),
      throwsFormatException,
    );
    expect(
      () => TrainingFrame.float32({...header(), 'extra': 'x' * 65537}, {}),
      throwsFormatException,
    );
  });
}
