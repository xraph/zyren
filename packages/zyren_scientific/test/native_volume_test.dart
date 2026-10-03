import 'dart:io';
import 'dart:math' as math;
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_native/zyren_native.dart';
import 'package:zyren_scientific/zyren_scientific.dart';
import 'package:zyren_scientific/timeline.dart';
import 'package:zyren_timeline/zyren_timeline.dart';
import 'scientific_test.dart' show grid, transfer, kelvin;

ScientificVolumeSettings volumeSettings({
  ScalarGrid3D? field,
  double step = .1,
  VolumeTransferFunction? transfer,
}) => ScientificVolumeSettings(
  grid: field ?? grid(x: 2, y: 2, z: 2, values: List.filled(8, 1)),
  transfer:
      transfer ??
      VolumeTransferFunction(
        unit: kelvin,
        minimum: 0,
        maximum: 2,
        stops: [
          VolumeStop(0, const Color3(1, 0, 0), .5),
          VolumeStop(1, const Color3(1, 0, 0), .5),
        ],
      ),
  sampleDistance: step,
  referenceDistance: 1,
  coordinateTolerance: 1e-5,
  scalarTolerance: 1e-6,
);
void main({bool? native}) {
  test(
    'volume validates work, float precision and physical sampling limits',
    () {
      expect(() => volumeSettings(step: 1e-6), throwsArgumentError);
      expect(
        () => volumeSettings().checkViewport(100000, 100000),
        throwsArgumentError,
      );
      expect(
        () => ScientificVolumeSettings(
          grid: grid(),
          transfer: VolumeTransferFunction(
            unit: kelvin,
            minimum: 1e100,
            maximum: 2e100,
            stops: [
              VolumeStop(0, const Color3(1, 0, 0), 0),
              VolumeStop(1, const Color3(1, 0, 0), 1),
            ],
          ),
          sampleDistance: .1,
          referenceDistance: 1,
          coordinateTolerance: 1e-5,
          scalarTolerance: 0,
        ),
        throwsArgumentError,
      );
    },
  );
  test(
    'native volume analytic opacity, ramp, depth, clipping and resource lifetime',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      final scene = Scene()..background = null;
      Camera camera = OrthographicCamera(
        position: const Vec3(.5, .5, 5),
        target: const Vec3(.5, .5, 0),
        left: -.5,
        right: .5,
        bottom: -.5,
        top: .5,
        near: .1,
        far: 20,
      );
      ScientificVolumeEffect? active;
      EffectRegistration? slot;
      Future<List<int>> render(ScientificVolumeSettings settings) async {
        slot?.dispose();
        await active?.close();
        active = await ScientificVolumeEffect.create(owner, settings: settings);
        await active!.update(
          camera: camera,
          scene: scene,
          width: 65,
          height: 65,
        );
        slot = scene.addEffect(active!.effect);
        final output =
            await backend.render(
                  FrameSubmission.capture(
                    scene: scene,
                    camera: camera,
                    size: PhysicalSize(65, 65),
                  ),
                )
                as ReadbackOutput;
        return output.image.pixels.sublist(
          (32 * 65 + 32) * 4,
          (32 * 65 + 32) * 4 + 4,
        );
      }

      double srgb(double v) =>
          v <= .0031308 ? v * 12.92 : 1.055 * math.pow(v, 1 / 2.4) - .055;
      try {
        final first = await render(volumeSettings());
        final second = await render(volumeSettings(step: .07));
        expect(first[3], closeTo(128, 1));
        expect(first[0], closeTo(128, 1));
        expect(first[1], 0);
        for (var i = 0; i < 4; i++) {
          expect(second[i], closeTo(first[i], 1));
        }
        final ramp = await render(
          volumeSettings(
            field: grid(x: 2, y: 2, z: 2, values: [0, 1, 0, 1, 0, 1, 0, 1]),
            transfer: VolumeTransferFunction(
              unit: kelvin,
              minimum: 0,
              maximum: 1,
              stops: [
                VolumeStop(0, const Color3(0, 0, 1), .5),
                VolumeStop(1, const Color3(1, 0, 0), .5),
              ],
            ),
          ),
        );
        expect(ramp[0], closeTo(srgb(.5) * .5 * 255, 2));
        expect(ramp[2], ramp[0]);
        final plane = scene.add(
          Mesh(
            PlaneGeometry(width: 1, height: 1),
            UnlitMaterial(color: const Color3(0, 0, 1)),
          )..position = const Vec3(.5, .5, .5),
        );
        for (final depth in [DepthStrategy.standard, DepthStrategy.reversed]) {
          camera.depthStrategy = depth;
          final occluded = await render(volumeSettings());
          final alpha = 1 - math.sqrt(.5);
          expect(occluded[0], closeTo(srgb(alpha) * 255, 2));
          expect(occluded[2], closeTo(srgb(1 - alpha) * 255, 2));
          expect(occluded[3], 255);
        }
        scene.remove(plane);
        scene.clippingPlanes = [
          ClippingPlane(normal: const Vec3(0, 0, 1), offset: .5),
        ];
        final clipped = await render(volumeSettings());
        expect(clipped[3], closeTo((1 - math.sqrt(.5)) * 255, 2));
        scene.clippingPlanes = [];
        camera = PerspectiveCamera(
          position: const Vec3(.5, .5, .75),
          target: const Vec3(.5, .5, 0),
          near: .05,
          far: 10,
        );
        final inside = await render(volumeSettings());
        expect(inside[3], closeTo((1 - math.pow(.5, .7)) * 255, 2));

        final missing = await render(
          volumeSettings(
            field: grid(x: 2, y: 2, z: 2, values: [null, 1, 1, 1, 1, 1, 1, 1]),
          ),
        );
        expect(missing, [0, 0, 0, 0]);
        slot?.dispose();
        slot = null;
        await active?.close();
        active = null;
        final token = ScientificCancellation()..cancel();
        await expectLater(
          ScientificVolumeEffect.create(
            owner,
            settings: volumeSettings(),
            cancellation: token,
          ),
          throwsA(isA<ScientificCancelled>()),
        );
        await owner.close();
        final resources = await backend.resourceStats(),
            shaders = await backend.shaderStats();
        expect(resources.residentBytes, 0);
        expect(shaders.livePrograms, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
        print(
          'SCIENTIFIC_VOLUME backend=${backend.capabilities.backend} adapter=${backend.capabilities.adapterName} homogeneous=$first stepInvariant=$second ramp=$ramp clipped=$clipped owned resources/programs/materials=0',
        );
      } finally {
        slot?.dispose();
        await owner.close();
        await backend.close();
      }
    },
    skip: !(native ?? (Platform.environment['RUN_NATIVE_GPU'] == '1')),
  );
  test(
    'native scientific timeline releases demand and volume plugin detaches',
    () async {
      final backend = await NativeBackend.create();
      final scene = Scene();
      final parent = scene.add(Group());
      final seconds = ScientificUnit(quantity: 'time', symbol: 's');
      ScientificFrame f(int i) => ScientificFrame(
        ScientificFrameKey(id: 'f$i', version: '1', time: i.toDouble()),
        grid(x: 2, y: 2, z: 2, values: List.filled(8, i.toDouble())),
      );
      final track = ScientificSliceTrack(
        target: parent,
        window: TemporalScalarWindow(
          first: f(0),
          last: f(1),
          timeUnit: seconds,
        ),
        transfer: transfer(min: 0, max: 1),
        axis: SliceAxis.z,
        index: 0,
        coordinateTolerance: 0,
      );
      final timeline = SceneTimelinePlugin(
        duration: const Duration(seconds: 1),
        tracks: [track],
      );
      final volume = ScientificVolumePlugin();
      var demands = 0;
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(.5, .5, 5),
          target: const Vec3(.5, .5, 0),
        ),
        backendFactory: () async => backend,
        plugins: [timeline, volume],
        acquireFrameDemand: () {
          demands++;
          return Registration(() => demands--);
        },
      );
      try {
        timeline.play();
        expect(demands, 1);
        await engine.renderFrame(elapsed: Duration.zero, width: 64, height: 64);
        timeline.seek(const Duration(milliseconds: 500));
        expect(track.sample!.grid.valueAt(0, 0, 0), .5);
        await engine.renderFrame(
          elapsed: const Duration(milliseconds: 500),
          width: 64,
          height: 64,
        );
        timeline.pause();
        expect(demands, 0);
        await volume.controller.setVolume(volumeSettings());
        await engine.renderFrame(
          elapsed: const Duration(milliseconds: 600),
          width: 64,
          height: 64,
        );
        expect(scene.effects.length, 1);
        await volume.controller.setVolume(null);
        expect(scene.effects, isEmpty);
        timeline.play();
        expect(demands, 1);
      } finally {
        await engine.dispose();
        track.dispose();
      }
      expect(demands, 0);
      expect(parent.children, isEmpty);
      expect(volume.controller.isClosed, isTrue);
    },
    skip: !(native ?? (Platform.environment['RUN_NATIVE_GPU'] == '1')),
  );
}
