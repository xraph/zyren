import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import '../test_support/asset_fingerprints.dart';

void main() {
  final pinned = Uri.parse('https://assets.example/revision/map.bin');
  final context = SourceReadContext(
    maxBytes: 100,
    cancellation: _Cancellation(),
    policy: const SourcePolicy(),
    onProgress: (_, _) {},
  );

  test(
    'fingerprints the returned bytes and preserves transport context',
    () async {
      final source = _Source();
      final recorder = AssetFingerprints(source, {pinned});
      final result = await recorder.read(pinned, context);
      expect(identical(result, source.lastResult), isTrue);
      expect(identical(context, source.lastContext), isTrue);
      expect(recorder.records, [
        {
          'uri': pinned.toString(),
          'bytes': 3,
          'sha256':
              'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
        },
      ]);
      await recorder.read(pinned, context);
      expect(recorder.records, hasLength(1));
      expect(
        recorder.wrap(SceneRuntime.defaultAssetServices).imageDecoder,
        same(SceneRuntime.defaultAssetServices.imageDecoder),
      );
    },
  );

  test(
    'provider reads and query credentials never enter asset records',
    () async {
      final recorder = AssetFingerprints(_Source(), {pinned});
      await recorder.read(
        Uri.parse('https://tiles.example/model?key=private'),
        context,
      );
      await recorder.read(pinned.replace(query: 'token=private'), context);
      expect(recorder.records, isEmpty);
    },
  );

  test('failed reads produce no successful fingerprint', () async {
    final recorder = AssetFingerprints(_Source(fail: true), {pinned});
    await expectLater(recorder.read(pinned, context), throwsStateError);
    expect(recorder.records, isEmpty);
  });
}

class _Source implements ByteSourceResolver {
  final bool fail;
  SourceReadContext? lastContext;
  ResolvedSource? lastResult;
  _Source({this.fail = false});
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    lastContext = context;
    if (fail) throw StateError('fixture');
    return lastResult = ResolvedSource(
      effectiveUri: uri,
      bytes: Uint8List.fromList([97, 98, 99]),
    );
  }
}

class _Cancellation implements LoadCancellation {
  @override
  bool get isCancelled => false;
  @override
  void throwIfCancelled() {}
  @override
  Registration onCancel(void Function() callback) => Registration(() {});
}
