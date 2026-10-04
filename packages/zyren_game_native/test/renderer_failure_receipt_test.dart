import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_game/zyren_game.dart';
import 'package:zyren_game_native/runtime.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_native/surfaces.dart';
import 'package:zyren_native/src/bindings.dart' as native;
import 'package:zyren_native/src/surface_bindings.g.dart' as surface_abi;
import 'package:zyren_physics/zyren_physics.dart';
import 'runtime_test.dart' as fixture;

@Native<Size Function()>(
  symbol: 'fg_retiring_renderer_count',
  assetId: 'package:zyren_native/src/bindings.dart',
)
external int _retiringRenderers();

Map<String, int> _counts() => {
  ...PhysicsWorld.nativeCounts,
  'owners': native.liveRendererCount(),
  'retiringRenderers': _retiringRenderers(),
  'surfaceBuffers': surface_abi.fg2_apple_live_buffers(),
};

final class _Host {
  final GameLevelRuntime runtime;
  final NativeBackend backend;
  final SceneEngine engine;
  final NativeSurfaceSnapshot surface;
  _Host(this.runtime, this.backend, this.engine, this.surface);

  static Future<_Host> create() async {
    final scene = Scene(), camera = PerspectiveCamera();
    final objects = fixture.objects(scene);
    for (final object in objects.values) {
      object.add(Mesh(BoxGeometry(), UnlitMaterial()));
    }
    final runtime = GameLevelRuntime(
      project: fixture.project(),
      scene: scene,
      camera: camera,
      objects: objects,
    );
    NativeBackend? backend;
    SceneEngine? engine;
    try {
      await runtime.initialize();
      backend = await NativeBackend.create(experimentalAppleSurfaces: true);
      expect(backend.capabilities.backend, 'Metal');
      engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend!,
        plugins: runtime.plugins,
      );
      runtime.simulation!.step();
      final surface = await backend.openSurface(PhysicalSize(63, 47));
      return _Host(runtime, backend, engine, surface);
    } catch (_) {
      if (engine != null) {
        await engine.dispose();
      } else {
        await backend?.close();
      }
      await runtime.close();
      rethrow;
    }
  }

  FrameSubmission submission() => FrameSubmission.capture(
    scene: runtime.scene,
    camera: runtime.camera,
    size: PhysicalSize(63, 47),
    target: SurfaceTarget(surface.key, surface.epoch),
  );

  Future<void> close() async {
    await engine.dispose();
    await runtime.close();
  }
}

void main() {
  test(
    'real Metal surface loss preserves the paused game and recreates from checkpoint',
    () async {
      if (!Platform.isMacOS || Platform.environment['RUN_NATIVE_GPU'] != '1') {
        fail('This receipt requires macOS and RUN_NATIVE_GPU=1.');
      }
      final baseline = _counts();
      _Host? failed, recovered;
      late Map<String, Object?> before, after;
      late GameSave checkpoint;
      late int rejectedCode;
      late int witnessedBuffers;
      late List<int> revokedKey, recoveredKey;
      try {
        failed = await _Host.create();
        final runtime = failed.runtime;
        runtime.actions!.setAxis(
          deviceId: 'receipt',
          action: 'move.z',
          value: 1,
        );
        for (var i = 0; i < 4; i++) {
          runtime.simulation!.step();
        }
        runtime.pause();
        checkpoint = runtime.save();
        Map<String, Object?> identity() => {
          'identity': {
            'buildId': runtime.project.buildId,
            'epoch': runtime.simulation!.session.epoch,
            'handles': runtime.simulation!.session.entities.entities
                .map(
                  (e) => {'id': e.handle.id, 'generation': e.handle.generation},
                )
                .toList(),
            'controlled': runtime.controlledActor?.id,
            'checkpoint': runtime.save().toJson(),
          },
        };
        final first = await failed.backend.render(failed.submission());
        expect(first, isA<PresentedOutput>());
        expect(first.stats.readbackBytes, 0);
        expect(first.stats.residentBytes, greaterThan(0));
        final geometry = BoxGeometry();
        for (var i = 0; i < 1000; i++) {
          runtime.scene.add(Mesh(geometry, UnlitMaterial()));
        }
        before = identity();
        final buffersBefore = surface_abi.fg2_apple_live_buffers();
        final drawing = failed.backend.render(failed.submission());
        final timer = Stopwatch()..start();
        while (surface_abi.fg2_apple_live_buffers() <= buffersBefore &&
            timer.elapsed < const Duration(seconds: 5)) {}
        witnessedBuffers = surface_abi.fg2_apple_live_buffers();
        expect(
          witnessedBuffers,
          greaterThan(buffersBefore),
          reason:
              'Witness actual in-flight Metal producer allocation before revoking the surface.',
        );
        revokedKey = failed.surface.key.toMessage();
        NativeSurfaces().close(failed.surface);
        await expectLater(
          drawing,
          throwsA(
            isA<SceneException>().having(
              (e) {
                expect(e.issue.cause, isA<NativeSurfaceException>());
                rejectedCode = (e.issue.cause as NativeSurfaceException).code;
                return e.issue.code;
              },
              'typed failure',
              anyOf(
                SceneIssueCodes.renderFailed,
                SceneIssueCodes.frameDeferred,
              ),
            ),
          ),
        );
        after = identity();
        expect(after, before);
        await failed.close();
        failed = null;
        expect(_counts(), baseline);

        recovered = await _Host.create();
        recovered.runtime.restore(GameSave.decode(checkpoint.encode()));
        expect(recovered.runtime.save().encode(), checkpoint.encode());
        expect(
          recovered.runtime
              .resolveBody(recovered.runtime.inputActor!)!
              .state
              .pose
              .position
              .z,
          greaterThan(0),
        );
        recoveredKey = recovered.surface.key.toMessage();
        expect(recoveredKey, isNot(revokedKey));
        recovered.runtime.resume();
        recovered.runtime.simulation!.step();
        expect(recovered.runtime.tick, checkpoint.tick + 1);
        final output = await recovered.backend.render(recovered.submission());
        expect(output, isA<PresentedOutput>());
        expect(output.stats.readbackBytes, 0);
        expect(output.stats.profile!.status, 'complete');
        expect(output.stats.residentBytes, greaterThan(0));
      } finally {
        await failed?.close();
        await recovered?.close();
      }
      final cleanup = _counts();
      expect(cleanup, baseline);
      final destination = Platform.environment['GAME_FAILURE_RECEIPT_PATH'];
      if (destination != null) {
        final file = File(destination);
        await file.parent.create(recursive: true);
        await file.writeAsString(
          const JsonEncoder.withIndent('  ').convert({
            'schemaVersion': 1,
            'cases': {
              'renderer.loss': {
                'status': 'passed',
                'actualStatus': 'rejected',
                'before': before,
                'after': after,
                'cleanupCounters': {'before': baseline, 'after': cleanup},
                'recovery': {'action': 'retry', 'status': 'passed'},
                'execution': {
                  'kind': 'native',
                  'exitCode': 0,
                  'command':
                      'cd packages/zyren_game_native && RUN_NATIVE_GPU=1 fvm dart test --concurrency=1 test/renderer_failure_receipt_test.dart test/save_test.dart test/gameplay_topology_test.dart test/topology_test.dart',
                  'backend': 'Metal',
                  'fault':
                      'real IOSurface revocation while native GPU owners are in flight',
                  'physicalDeviceLossInjected': false,
                  'nativeFailureCode': rejectedCode,
                  'witnessedProducerBuffers': witnessedBuffers,
                  'revokedSurfaceKey': revokedKey,
                  'recoveredSurfaceKey': recoveredKey,
                  'readbackBytes': 0,
                },
              },
            },
          }),
        );
      }
    },
    tags: 'native-gpu',
  );
}
