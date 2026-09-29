import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:integration_test/integration_test.dart';

import 'package:multiple_views/experimental/metal_proof_view.dart'
    show cornerPackets;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('zyren/android-proof');
  testWidgets('Vulkan surfaces render, resize, replace and release', (
    tester,
  ) async {
    await channel.invokeMethod<void>('connect', {
      'runtime': NativeSurfaces().runtimeToken,
    });
    await expectLater(
      channel.invokeMethod<void>('connect', {'runtime': 1}),
      throwsA(isA<PlatformException>()),
    );
    final packets = cornerPackets();
    final uploaded = <Object>{};
    final first = (await channel.invokeMapMethod<String, Object?>('create'))!;
    final second = (await channel.invokeMapMethod<String, Object?>('create'))!;
    final id = first['session']!;
    Future<Map<String, Object?>> draw(
      Object session,
      int width,
      int height,
    ) async {
      final response = (await channel
          .invokeMapMethod<String, Object?>('render', {
            'session': session,
            'width': width,
            'height': height,
            'scene': packets[uploaded.contains(session) ? 'steady' : 'initial'],
          }))!;
      if (response['applied'] == true) uploaded.add(session);
      return response;
    }

    await tester.pumpWidget(
      MaterialApp(
        home: Column(
          children: [
            SizedBox(
              width: 127,
              height: 93,
              child: Texture(textureId: first['texture']! as int),
            ),
            SizedBox(
              width: 127,
              height: 93,
              child: Texture(textureId: second['texture']! as int),
            ),
          ],
        ),
      ),
    );
    var result = await draw(id, 127, 93);
    expect(result['presented'], isTrue);
    expect(result['backend'], 'Vulkan');
    expect(result['readbackBytes'], 0);
    final initialEpoch = result['epoch']! as int;
    for (var i = 0; i < 100; i++) {
      result = await draw(id, 127 + i % 2, 93 + i % 3);
      expect(result['presented'], isTrue);
      await tester.pump(const Duration(milliseconds: 20));
    }
    expect(result['epoch']! as int, greaterThan(initialEpoch));
    await channel.invokeMethod<void>('replace', {'session': id});
    final replacement = await draw(id, 127, 93);
    expect(replacement['presented'], isTrue);
    expect(replacement['epoch']! as int, greaterThan(result['epoch']! as int));
    expect(
      replacement['surfaceGeneration']! as int,
      greaterThan(result['surfaceGeneration']! as int),
    );
    for (final orientation in [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.portraitUp,
    ]) {
      await SystemChrome.setPreferredOrientations([orientation]);
      await tester.pump(const Duration(milliseconds: 300));
      expect((await draw(id, 127, 93))['presented'], isTrue);
    }
    await SystemChrome.setPreferredOrientations([]);
    await channel.invokeMethod<void>('suspend', {
      'session': id,
      'suspended': true,
    });
    expect((await draw(id, 127, 93))['presented'], isFalse);
    await channel.invokeMethod<void>('suspend', {
      'session': id,
      'suspended': false,
    });
    expect((await draw(id, 127, 93))['presented'], isTrue);
    await channel.invokeMethod<void>('close', {'session': id});
    expect((await draw(second['session']!, 127, 93))['presented'], isTrue);
    await tester.pumpWidget(const SizedBox());
    await channel.invokeMethod<void>('close', {'session': second['session']});
    for (var i = 0; i < 100; i++) {
      final value = (await channel.invokeMapMethod<String, Object?>('create'))!;
      await tester.pumpWidget(
        MaterialApp(
          home: SizedBox(
            width: 127,
            height: 93,
            child: Texture(textureId: value['texture']! as int),
          ),
        ),
      );
      expect((await draw(value['session']!, 127, 93))['presented'], isTrue);
      await tester.pumpWidget(const SizedBox());
      await channel.invokeMethod<void>('close', {'session': value['session']});
      final state = (await channel.invokeMapMethod<String, Object?>(
        'diagnostics',
      ))!;
      expect(state['sessions'], 0, reason: 'cycle $i');
      expect(state['renderers'], 0, reason: 'cycle $i');
      expect(state['retiring'], 0, reason: 'cycle $i');
    }
    final counters = (await channel.invokeMapMethod<String, Object?>(
      'diagnostics',
    ))!;
    expect(counters['sessions'], 0);
    expect(counters['renderers'], 0);
    expect(counters['retiring'], 0);
    debugPrint('Android Vulkan proof: $replacement; final: $counters');
  });
}
