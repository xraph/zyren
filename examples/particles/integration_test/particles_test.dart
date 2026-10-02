import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:particle_lab/main.dart';
import 'package:zyren_particles/zyren_particles.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'native examples render and playback controls work at desktop and narrow widths',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        final layout = ValueNotifier<Size?>(null);
        await tester.pumpWidget(
          ValueListenableBuilder<Size?>(
            valueListenable: layout,
            child: const ParticleLab(),
            builder: (context, size, child) => Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: size?.width,
                height: size?.height,
                child: child,
              ),
            ),
          ),
        );
        final state = tester.state<ParticleWorkbenchState>(
          find.byType(ParticleWorkbench),
        );
        for (var i = 0; i < 200 && !state.ready && state.error == null; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(state.error, isNull);
        expect(state.ready, isTrue);
        for (var i = 0; i < 600 && state.frameStats == null; i++) {
          await tester.pump(const Duration(milliseconds: 25));
        }
        expect(state.frameStats, isNotNull);
        expect(state.frameStats!.readbackBytes, 0);
        expect(
          find.bySemanticsLabel(
            'Native particle viewport. Drag to orbit and scroll to zoom.',
          ),
          findsOneWidget,
        );
        Future<void> press(String label) async {
          await tester.tap(find.text(label));
          for (var i = 0; i < 200; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            if (!state.busy) break;
          }
          expect(state.busy, isFalse, reason: label);
          expect(state.error, isNull, reason: label);
        }

        for (final name in ['Sparks', 'Sprites', 'Trails', 'Flow', 'Meshes']) {
          if (name != state.selected) {
            await press(name);
          }
          for (var i = 0; i < 30; i++) {
            await tester.pump(const Duration(milliseconds: 20));
          }
          expect(state.error, isNull);
          final particles = await state.particles.controller.inspect(name);
          expect(particles, isNotEmpty, reason: name);
          await press('Pause');
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            state.particles.controller.playback(name),
            ParticlePlayback.paused,
          );
          final frozen = await state.particles.controller.inspect(name);
          await tester.pump(const Duration(milliseconds: 100));
          expect(
            (await state.particles.controller.inspect(
              name,
            )).map((p) => p.position),
            frozen.map((p) => p.position),
          );
          await press('Resume');
          await tester.pump(const Duration(milliseconds: 100));
          await press('Reset');
          await tester.pump(const Duration(milliseconds: 100));
          expect(await state.particles.controller.inspect(name), isEmpty);
          await press('Burst');
          await tester.pump(const Duration(milliseconds: 100));
          for (var i = 0; i < 100; i++) {
            await tester.pump(const Duration(milliseconds: 20));
            if ((await state.particles.controller.inspect(name)).isNotEmpty) {
              break;
            }
          }
          expect(
            await state.particles.controller.inspect(name),
            isNotEmpty,
            reason: 'burst $name',
          );
          expect(tester.takeException(), isNull, reason: 'mode $name');
        }
        for (final size in [const Size(1200, 760), const Size(390, 740)]) {
          layout.value = size;
          await tester.pump(const Duration(milliseconds: 150));
          expect(tester.takeException(), isNull);
          expect(find.text('Play'), findsOneWidget);
          expect(find.text('Inspect count'), findsOneWidget);
          await press('Inspect count');
          await tester.pump(const Duration(milliseconds: 100));
          expect(state.inspectedCount, isNotNull);
          expect(state.error, isNull);
        }
        debugPrint(
          'PARTICLE_QUALIFICATION effects=5 pause=passed reset=passed burst=passed '
          'layouts=passed semantics=passed readbackBytes=${state.frameStats!.readbackBytes}',
        );
        layout.value = null;
        final disposed = state.viewport.whenDisposed;
        await tester.pumpWidget(const SizedBox.shrink());
        await disposed;
        layout.dispose();
      } finally {
        semantics.dispose();
      }
    },
  );
}
