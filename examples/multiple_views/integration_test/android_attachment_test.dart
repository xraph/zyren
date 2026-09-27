import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gpu3d_native/surfaces.dart';
import 'package:integration_test/integration_test.dart';
import 'package:multiple_views/experimental/metal_proof_view.dart'
    show cornerPackets;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('gpu3d/android-proof');
  testWidgets('renderer survives attachment replacement and rejects stale work', (
    tester,
  ) async {
    await channel.invokeMethod<void>('connect', {
      'runtime': NativeSurfaces().runtimeToken,
    });
    final created = (await channel.invokeMapMethod<String, Object?>('create', {
      'deferredAttachment': true,
    }))!;
    final session = created['session'];
    Future<Map> stats() async =>
        (await channel.invokeMethod<Map>('diagnostics'))!;
    Future<Map> prepare(int attachment) async =>
        (await channel.invokeMethod<Map>('prepare', {
          'session': session,
          'attachment': attachment,
          'width': 63,
          'height': 47,
        }))!;
    final packets = cornerPackets();
    Future<Map> draw(
      int attachment,
      Map target,
      String packet,
      int frame,
    ) async => (await channel.invokeMethod<Map>('render', {
      'session': session,
      'attachment': attachment,
      'epoch': target['epoch'],
      'frame': frame,
      'width': 63,
      'height': 47,
      'scene': packet,
    }))!;
    try {
      expect((await stats())['surfaces'], 0);
      final first = await prepare(1);
      await tester.pumpWidget(
        MaterialApp(home: Texture(textureId: first['texture'] as int)),
      );
      final frame = await draw(1, first, packets['initial']!, 1);
      expect(frame['applied'], true);
      expect(frame['presented'], true);
      await channel.invokeMethod<void>('detach', {
        'session': session,
        'attachment': 1,
      });
      expect((await stats())['surfaces'], 0);
      expect((await stats())['renderers'], 1);
      final next = await prepare(2);
      expect(next['texture'], isNot(first['texture']));
      await tester.pumpWidget(
        MaterialApp(home: Texture(textureId: next['texture'] as int)),
      );
      await channel.invokeMethod<void>('detach', {
        'session': session,
        'attachment': 1,
      });
      expect((await stats())['surfaces'], 1);
      expect((await draw(1, first, packets['steady']!, 2))['presented'], false);
      final current = await draw(2, next, packets['steady']!, 3);
      expect(current['presented'], true);
      expect(current['readbackBytes'], 0);
      await expectLater(prepare(1), throwsA(isA<PlatformException>()));
      final before = (await stats())['presented'];
      await channel.invokeMethod<void>('debugArmPublication');
      final pending = draw(2, next, packets['steady']!, 4);
      try {
        var entered = false;
        for (var i = 0; i < 100; i++) {
          final gate = (await channel.invokeMethod<Map>(
            'debugPublicationState',
          ))!;
          if (gate['entered'] == true) {
            entered = true;
            break;
          }
          await tester.pump(const Duration(milliseconds: 10));
        }
        expect(entered, true);
        await channel.invokeMethod<void>('suspend', {
          'session': session,
          'attachment': 2,
          'suspended': true,
        });
      } finally {
        await channel.invokeMethod<void>('debugReleasePublication');
      }
      final revoked = await pending;
      expect(revoked['applied'], true);
      expect(revoked['presented'], false);
      expect(
        (await stats())['presented'],
        before,
        reason:
            'Revocation before publication must prevent Native.present, not just reject the Dart receipt.',
      );
    } finally {
      await tester.pumpWidget(const SizedBox());
      await channel.invokeMethod<void>('close', {'session': session});
    }
    final closed = await stats();
    expect(closed['sessions'], 0);
    expect(closed['surfaces'], 0);
    expect(closed['renderers'], 0);
    expect(closed['retiring'], 0);
    debugPrint('Android attachment ownership: $closed');
  });
}
