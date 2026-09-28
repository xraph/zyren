import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_gltf/src/document.dart';
import 'package:gpu3d_gltf/src/worker.dart';
import 'package:test/test.dart';

class Cancellation implements LoadCancellation {
  final callbacks = <void Function()>{};
  @override
  bool isCancelled = false;
  @override
  void throwIfCancelled() {
    if (isCancelled) throw LoadCancelled();
  }

  @override
  Registration onCancel(void Function() callback) {
    if (isCancelled) {
      callback();
      return Registration(() {});
    }
    callbacks.add(callback);
    return Registration(() => callbacks.remove(callback));
  }

  void cancel() {
    if (isCancelled) return;
    isCancelled = true;
    for (final callback in List.of(callbacks)) {
      callback();
    }
  }
}

void main() {
  test(
    'worker queue admission is bounded and recovers after cancellation',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode('{"asset":{"version":"2.0"}}'),
      );
      final tokens = List.generate(18, (_) => Cancellation());
      final tasks = [
        for (final token in tokens)
          GltfWorkers.parse(bytes, const GltfLimits(), token),
      ];
      final overflow = GltfWorkers.parse(
        bytes,
        const GltfLimits(),
        Cancellation(),
      );
      final outcomes = [
        for (final task in tasks)
          expectLater(task, throwsA(isA<LoadCancelled>())),
      ];
      final rejected = expectLater(
        overflow,
        throwsA(
          isA<AssetLoadException>().having(
            (e) => e.code,
            'code',
            AssetLoadError.limitExceeded,
          ),
        ),
      );
      for (final token in tokens) {
        token.cancel();
      }
      await Future.wait([...outcomes, rejected]);
    },
  );
  test(
    'worker returns checked documents and field errors across isolate boundaries',
    () async {
      final cancellation = Cancellation();
      final bytes = Uint8List.fromList(
        utf8.encode('{"asset":{"version":"2.0"}}'),
      );
      final document = await GltfWorkers.parse(
        bytes,
        const GltfLimits(),
        cancellation,
      );
      expect(document, isA<GltfDocument>());
      await expectLater(
        GltfWorkers.parse(
          Uint8List.fromList([123]),
          const GltfLimits(),
          cancellation,
        ),
        throwsA(
          isA<AssetLoadException>().having((e) => e.fieldPath, 'path', r'$'),
        ),
      );
      expect(cancellation.callbacks, isEmpty);
    },
  );
  test(
    'parsing large metadata leaves the caller event loop responsive',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'asset': {'version': '2.0'},
            'extras': List.generate(120000, (i) => {'key': i}),
          }),
        ),
      );
      final cancellation = Cancellation();
      var ticks = 0;
      final timer = Timer.periodic(
        const Duration(milliseconds: 1),
        (_) => ticks++,
      );
      try {
        await GltfWorkers.parse(
          bytes,
          const GltfLimits(maxJsonTokens: 1000000),
          cancellation,
        );
        expect(ticks, greaterThan(1));
      } finally {
        timer.cancel();
      }
    },
  );
  test(
    'active and queued worker cancellation settles and frees admission',
    () async {
      final bytes = Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'asset': {'version': '2.0'},
            'extras': List.generate(100000, (i) => {'key': i}),
          }),
        ),
      );
      final cancellations = List.generate(5, (_) => Cancellation());
      final tasks = [
        for (final cancellation in cancellations)
          GltfWorkers.parse(bytes, const GltfLimits(), cancellation),
      ];
      final outcomes = [
        for (final task in tasks)
          expectLater(task, throwsA(isA<LoadCancelled>())),
      ];
      for (final cancellation in cancellations) {
        cancellation.cancel();
      }
      await Future.wait(outcomes);
      final next = await GltfWorkers.parse(
        Uint8List.fromList(utf8.encode('{"asset":{"version":"2.0"}}')),
        const GltfLimits(),
        Cancellation(),
      );
      expect(next.root['asset'], {'version': '2.0'});
      expect(cancellations.every((c) => c.callbacks.isEmpty), isTrue);
    },
  );
  test(
    'worker transfers normalized typed accessor data without losing values',
    () async {
      final root = <String, Object?>{
        'buffers': [
          {'byteLength': 4},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteLength': 4},
        ],
        'accessors': [
          {
            'bufferView': 0,
            'componentType': 5121,
            'normalized': true,
            'type': 'VEC4',
            'count': 1,
          },
        ],
      };
      final decoded = await GltfWorkers.accessors(
        root,
        [
          Uint8List.fromList([0, 64, 128, 255]),
        ],
        const GltfLimits(),
        16,
        Cancellation(),
      );
      expect(decoded.single.values, [
        0,
        closeTo(64 / 255, 1e-6),
        closeTo(128 / 255, 1e-6),
        1,
      ]);
      expect(() => decoded.single.values[0] = 1.0, throwsUnsupportedError);
    },
  );
}
