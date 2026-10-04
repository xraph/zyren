import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';
import 'aerial_perspective_test.dart' show center, encoded;

void main() {
  test(
    'invalid frame during cloud replacement preserves the active composition',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      Future<GpuResource<Texture>> image(List<double> values) async {
        final texture = await owner.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
          ),
        );
        await owner.resources.writeTexture(
          texture,
          Float32List.fromList(values).buffer.asUint8List(),
        );
        return texture;
      }

      final red = await image([.2, 0, 0, .5]),
          green = await image([0, .2, 0, .5]),
          data = await image([1000, 0, 0, 0]),
          trans = await image([1, 0, 0, 0]);
      final plugin = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final camera = PerspectiveCamera(
        position: const Vec3(0, 0, 6361000),
        target: const Vec3(0, 0, 6362000),
        near: 1,
        far: 1e7,
      );
      final publisher = _CloudPublisher();
      final engine = await SceneEngine.create(
        scene: Scene()..renderSettings = RenderSettings(hdr: true),
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [plugin, publisher],
      );
      Future<List<int>> render() async => center(
        await engine.render(elapsed: Duration.zero, width: 17, height: 17),
      );
      try {
        final reg = await plugin.controller.registerCloudInputs(
          AtmosphereCloudInputs(
            color: red,
            depthVelocityShadow: data,
            transmittance: trans,
          ),
        );
        final before = await render(), position = camera.position;
        camera.position = Vec3.zero;
        await expectLater(
          reg.replace(
            AtmosphereCloudInputs(
              color: green,
              depthVelocityShadow: data,
              transmittance: trans,
            ),
          ),
          throwsArgumentError,
        );
        camera.position = position;
        expect(await render(), before);
        final replacement = AtmosphereCloudInputs(
          color: green,
          depthVelocityShadow: data,
          transmittance: trans,
        );
        final discarded = await reg.prepare(replacement);
        expect(await render(), before);
        await expectLater(
          discarded.publish(publisher.lastFrame!),
          throwsStateError,
        );
        await discarded.close();
        await discarded.close();
        expect(discarded.isClosed, isTrue);
        final prepared = await reg.prepare(replacement);
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(overlay: red),
        );
        publisher.pending = prepared;
        final changed = await render();
        expect(changed[0], greaterThan(0));
        expect(changed[1], greaterThan(0));
        expect(prepared.isClosed, isTrue);
        publisher.pending = prepared;
        await expectLater(render(), throwsStateError);
        await prepared.close();
        final closing = await reg.prepare(replacement);
        final beforeClose = (await backend.resourceStats()).uploadedBytes;
        await reg.close();
        final closeWithPrepared =
            (await backend.resourceStats()).uploadedBytes - beforeClose;
        expect(closing.isClosed, isTrue);
        await closing.close();
        final again = await plugin.controller.registerCloudInputs(replacement);
        final beforePlainClose = (await backend.resourceStats()).uploadedBytes;
        await again.close();
        final closeWithoutPrepared =
            (await backend.resourceStats()).uploadedBytes - beforePlainClose;
        expect(
          closeWithPrepared,
          closeWithoutPrepared,
          reason: 'Closing must not upload replacements for doomed tokens',
        );
        final last = await plugin.controller.registerCloudInputs(replacement);
        // Leave a live pending token to prove controller disposal owns it.
        await last.prepare(replacement);
      } finally {
        await engine.dispose();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
  test(
    'cloud transmission shadows direct aerial light while retaining skylight',
    () async {
      final backend = await NativeBackend.create();
      final owner = GpuScope.fromBackend(backend);
      Future<GpuResource<Texture>> image(List<double> values) async {
        final texture = await owner.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
          ),
        );
        await owner.resources.writeTexture(
          texture,
          Float32List.fromList(values).buffer.asUint8List(),
        );
        return texture;
      }

      final color = await image([0, 0, 0, 0]),
          data = await image([1000, 0, 0, 0]),
          trans = await image([1, 0, 0, 0]);
      final date = DateTime.utc(2026, 3, 20, 12),
          sun = CelestialDirections.at(DateTime.utc(2026, 3, 20, 12)).sunECEF;
      final camera = PerspectiveCamera(
        position: sun * 6361000,
        target: sun * 6360000,
        up: const Vec3(0, 0, 1),
        near: 1,
        far: 1e7,
      );
      final mesh = Mesh(
        PlaneGeometry(width: 2000, height: 2000),
        UnlitMaterial(color: const Color3(.4, .4, .4)),
      )..position = sun * 6360000;
      mesh.lookAt(camera.position);
      final scene = Scene()
        ..renderSettings = RenderSettings(hdr: true)
        ..add(mesh);
      final plugin = AtmospherePlugin(
        date: date,
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 32,
        appearance: AtmosphereAppearance(
          sky: false,
          haze: false,
          sunLight: true,
        ),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: camera,
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      Future<List<int>> render() async => center(
        await engine.render(elapsed: Duration.zero, width: 17, height: 17),
      );
      try {
        final reg = await plugin.controller.registerCloudInputs(
          AtmosphereCloudInputs(
            color: color,
            depthVelocityShadow: data,
            transmittance: trans,
          ),
        );
        for (final strategy in DepthStrategy.values) {
          camera.depthStrategy = strategy;
          await owner.resources.writeTexture(
            trans,
            Float32List.fromList([1, 0, 0, 0]).buffer.asUint8List(),
          );
          plugin.controller.appearance = plugin.controller.appearance.copyWith(
            skyLight: false,
          );
          final lit = await render();
          expect(lit[0], greaterThan(40));
          await owner.resources.writeTexture(
            trans,
            Float32List(4).buffer.asUint8List(),
          );
          final dark = await render();
          expect(dark.take(3), everyElement(0));
          expect(dark[3], 255);
          plugin.controller.appearance = plugin.controller.appearance.copyWith(
            skyLight: true,
          );
          final sky = await render();
          expect(sky[0], greaterThan(0));
          expect(sky[0], lessThan(lit[0]));
        }
        await reg.close();
        expect((await render())[0], greaterThan(40));
      } finally {
        await owner.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );

  test(
    'cloud composition has independent retained ownership and atomic replacement',
    () async {
      final backend = await NativeBackend.create();
      final caller = GpuScope.fromBackend(backend);
      Future<GpuResource<Texture>> image(List<double> values) async {
        final texture = await caller.resources.createTexture(
          TextureDescriptor(
            width: 1,
            height: 1,
            format: TextureFormat.rgba32Float,
          ),
        );
        await caller.resources.writeTexture(
          texture,
          Float32List.fromList(values).buffer.asUint8List(),
        );
        return texture;
      }

      final clouds = await image([.2, 0, 0, .5]),
          data = await image([1000, 0, 0, 0]),
          transmission = await image([0, 0, 0, 0]),
          overlay = await image([0, 0, .1, .25]);
      final inputs = AtmosphereCloudInputs(
        color: clouds,
        depthVelocityShadow: data,
        transmittance: transmission,
      );
      final scene = Scene()..renderSettings = RenderSettings(hdr: true);
      final plugin = AtmospherePlugin(
        date: DateTime.utc(2026, 3, 20, 12),
        parameters: AtmosphereParameters.legacy(),
        correctAltitude: false,
        maxStarResolution: 64,
        appearance: AtmosphereAppearance(sky: false, haze: false),
      );
      final engine = await SceneEngine.create(
        scene: scene,
        camera: PerspectiveCamera(
          position: const Vec3(0, 0, 6361000),
          target: const Vec3(0, 0, 6362000),
          near: 1,
          far: 1e7,
        ),
        backendFactory: () async => backend.createView(),
        plugins: [plugin],
      );
      Future<List<int>> render([int size = 17]) async => center(
        await engine.render(elapsed: Duration.zero, width: size, height: size),
      );
      try {
        await plugin.controller.setAerialInputs(
          AerialPerspectiveInputs(overlay: overlay),
        );
        final reg = await plugin.controller.registerCloudInputs(inputs);
        await expectLater(
          plugin.controller.registerCloudInputs(inputs),
          throwsStateError,
        );
        await caller.close();
        for (final size in [17, 31, 17]) {
          final pixel = await render(size);
          expect(pixel[0], closeTo(encoded(.15 / .625) * .625, 2));
          expect(pixel[2], closeTo(encoded(.1 / .625) * .625, 2));
          expect(pixel[3], closeTo(255 * .625, 1));
        }
        final before = (await backend.resourceStats()).residentBytes;
        await expectLater(reg.replace(inputs), throwsStateError);
        expect((await backend.resourceStats()).residentBytes, before);
        expect((await render())[0], greaterThan(0));
        await reg.close();
        await reg.close();
        expect(reg.isClosed, isTrue);
        final pixel = await render();
        expect(pixel[0], 0);
        expect(pixel[2], closeTo(encoded(.4) * .25, 2));
        expect(pixel[3], closeTo(255 * .25, 1));
        await expectLater(reg.replace(inputs), throwsStateError);
      } finally {
        await caller.close();
        await engine.dispose();
        expect((await backend.resourceStats()).residentBytes, 0);
        await backend.close();
      }
    },
  );
}

final class _CloudPublisher extends ScenePlugin {
  PreparedAtmosphereCloudInputs? pending;
  FrameInfo? lastFrame;
  @override
  String get id => 'prepared-cloud-publisher';
  @override
  Set<String> get dependencies => {'atmosphere'};
  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    lastFrame = frame;
    final value = pending;
    pending = null;
    if (value != null) await value.publish(frame);
  }
}
