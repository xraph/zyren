import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/experimental/metal_proof_view.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  Future<Map<Object?, Object?>> until(
    WidgetTester tester,
    bool Function(Map<Object?, Object?>) ready,
  ) async {
    for (var i = 0; i < 150; i++) {
      await tester.pump(const Duration(milliseconds: 20));
      final value = await metalProofDiagnostics();
      if (ready(value)) return value;
    }
    fail(
      'Metal view did not reach the expected state: ${await metalProofDiagnostics()}',
    );
  }

  testWidgets(
    'two Metal views turn over drawables, resize and release renderers',
    (tester) async {
      await connectMetalProof();
      await expectLater(
        metalProofChannel.invokeMethod<void>('connect', {'runtime': 0}),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'runtimeMismatch',
          ),
        ),
      );
      final baseline = await metalProofDiagnostics();
      final packets = cornerPackets();
      int? firstId, secondId;
      final size = ValueNotifier<Size>(const Size(127, 93));
      await tester.pumpWidget(
        MaterialApp(
          home: Center(
            child: ValueListenableBuilder<Size>(
              valueListenable: size,
              builder: (_, size, _) => Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  SizedBox(
                    width: size.width,
                    height: size.height,
                    child: MetalProofView(
                      packets: packets,
                      onCreated: (id) => firstId = id,
                    ),
                  ),
                  SizedBox(
                    width: 87,
                    height: 63,
                    child: Opacity(
                      opacity: .5,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Transform.rotate(
                          angle: .12,
                          child: MetalProofView(
                            packets: packets,
                            onCreated: (id) => secondId = id,
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      Map view(Map stats, int? id) => (stats['views'] as Map)[id] as Map? ?? {};
      final first = await until(
        tester,
        (s) =>
            (view(s, firstId)['frames'] as int? ?? 0) > 30 &&
            (view(s, secondId)['frames'] as int? ?? 0) > 30,
      );
      expect(first['errors'], baseline['errors']);
      expect(first['renderers'], (baseline['renderers'] as int) + 2);
      expect(first['sessions'], 2);
      expect(first['readbackBytes'], 0);
      await metalProofChannel.invokeMethod<void>('suspend', {
        'view': firstId,
        'suspended': true,
      });
      final paused = await metalProofDiagnostics();
      final pausedFrames = view(paused, firstId)['frames'];
      await until(
        tester,
        (s) =>
            (view(s, secondId)['frames'] as int) >
            (view(paused, secondId)['frames'] as int) + 10,
      );
      expect(
        view(await metalProofDiagnostics(), firstId)['frames'],
        pausedFrames,
      );
      await metalProofChannel.invokeMethod<void>('suspend', {
        'view': firstId,
        'suspended': false,
      });
      final oldWidth = view(first, firstId)['width'] as int;
      size.value = const Size(173, 111);
      final resized = await until(
        tester,
        (s) => (view(s, firstId)['width'] as int? ?? 0) > oldWidth,
      );
      expect(view(resized, firstId)['width'], (oldWidth / 127 * 173).round());
      expect(view(resized, firstId)['height'], (oldWidth / 127 * 111).round());
      await tester.pumpWidget(const SizedBox());
      final closed = await until(
        tester,
        (s) =>
            s['renderers'] == baseline['renderers'] &&
            s['drawables'] == 0 &&
            s['retiring'] == 0 &&
            s['sessions'] == 0,
      );
      expect(closed['errors'], baseline['errors']);
      debugPrint('Metal view turnover: $closed');
      size.dispose();
    },
  );

  testWidgets(
    '100 native view mount/unmount cycles return to the ownership baseline',
    (tester) async {
      await connectMetalProof();
      final baseline = await metalProofDiagnostics();
      final packets = cornerPackets();
      for (var i = 0; i < 100; i++) {
        int? identity;
        await tester.pumpWidget(
          MaterialApp(
            home: Center(
              child: SizedBox(
                width: 63,
                height: 47,
                child: MetalProofView(
                  key: ValueKey(i),
                  packets: packets,
                  onCreated: (id) => identity = id,
                ),
              ),
            ),
          ),
        );
        await until(tester, (s) {
          final view = (s['views'] as Map)[identity] as Map?;
          return (view?['frames'] as int? ?? 0) > 0;
        });
        await tester.pumpWidget(const SizedBox());
        final closed = await until(
          tester,
          (s) =>
              s['renderers'] == baseline['renderers'] &&
              s['drawables'] == 0 &&
              s['retiring'] == 0 &&
              s['sessions'] == 0,
        );
        expect(closed['errors'], baseline['errors'], reason: 'route $i');
      }
      final result = await metalProofDiagnostics();
      expect(result['readbackBytes'], 0);
      debugPrint('Metal view mount/unmount cycles: $result');
    },
  );

  testWidgets('a rejected scene closes GPU ownership and exposes the failure', (
    tester,
  ) async {
    await connectMetalProof();
    final baseline = await metalProofDiagnostics();
    final packets = cornerPackets();
    final invalid = jsonDecode(packets['initial']!) as Map<String, dynamic>;
    invalid['geometries'] = []; // Meshes now refer to absent geometry.
    int? identity;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: SizedBox(
            width: 63,
            height: 47,
            child: MetalProofView(
              packets: {...packets, 'initial': jsonEncode(invalid)},
              onCreated: (id) => identity = id,
            ),
          ),
        ),
      ),
    );
    final failed = await until(
      tester,
      (s) =>
          s['errors'] == (baseline['errors'] as int) + 1 &&
          s['renderers'] == baseline['renderers'] &&
          s['drawables'] == 0 &&
          s['retiring'] == 0,
    );
    expect(
      ((failed['views'] as Map)[identity] as Map)['error'],
      contains('geometry'),
    );
    await tester.pumpWidget(const SizedBox());
    await until(tester, (s) => s['sessions'] == 0);
  });
}
