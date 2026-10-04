import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_game_lab_training_worker/sequence_observations.dart';

void main() {
  late Directory folder;
  late File request;
  late File sidecar;
  late Uint8List bytes;
  late Map<String, Object?> descriptor;
  setUp(() async {
    folder = await Directory.systemTemp.createTemp('zyren-sequence-test-');
    request = File('${folder.path}/sequence.json');
    sidecar = File('${folder.path}/observations.f32');
    final data = ByteData(24);
    for (var i = 0; i < 6; i++) {
      data.setFloat32(i * 4, i / 10, Endian.little);
    }
    bytes = data.buffer.asUint8List();
    await sidecar.writeAsBytes(bytes);
    descriptor = {
      'path': 'observations.f32',
      'dtype': 'float32-le',
      'shape': [2, 3],
      'bytes': 24,
      'sha256': sha256.convert(bytes).toString(),
    };
  });
  tearDown(() async {
    await folder.delete(recursive: true);
  });
  Future<SequenceObservations> load() =>
      SequenceObservations.load(request, descriptor, rows: 2, width: 3);
  test(
    'pinned rows use little endian and callers cannot mutate later rows',
    () async {
      final data = await load();
      expect(data.row(0)[1], closeTo(.1, 1e-7));
      expect(data.row(1)[2], closeTo(.5, 1e-7));
      data.row(1)[0] = 99;
      expect(data.row(1)[0], closeTo(.3, 1e-7));
      expect(() => data.row(2), throwsRangeError);
      expect(() => data.descriptor['bytes'] = 0, throwsUnsupportedError);
    },
  );
  for (final count in [20, 28]) {
    test(
      'truncated or trailing bytes reject before inference ($count)',
      () async {
        await sidecar.writeAsBytes(List.filled(count, 0));
        await expectLater(load(), throwsStateError);
      },
    );
  }
  test('nonfinite bytes reject even with matching SHA', () async {
    ByteData.sublistView(bytes).setFloat32(0, double.nan, Endian.little);
    await sidecar.writeAsBytes(bytes);
    descriptor['sha256'] = sha256.convert(bytes).toString();
    await expectLater(load(), throwsStateError);
  });
  test('changed content rejects its original pin', () async {
    bytes[0] = 1;
    await sidecar.writeAsBytes(bytes);
    await expectLater(load(), throwsStateError);
  });
  test('path traversal, shape confusion and symlink are closed', () async {
    for (final value in ['../observations.f32', '/tmp/observations.f32']) {
      descriptor['path'] = value;
      await expectLater(load(), throwsStateError);
    }
    descriptor['path'] = 'observations.f32';
    descriptor['shape'] = [2, 3.0];
    await expectLater(load(), throwsStateError);
    descriptor['shape'] = [2, 3];
    final target = File('${folder.path}/target.f32');
    await sidecar.rename(target.path);
    await Link(sidecar.path).create(target.path);
    await expectLater(load(), throwsStateError);
  });
}
