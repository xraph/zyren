import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_geospatial/zyren_geospatial.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  for (final pause in ['hook', 'backend', 'receipt', 'aborted']) {
    test(
      'cloud replacement during $pause keeps the captured candidate alive',
      () async {
        final f = await _Fixture.create();
        try {
          await f.compare(await f.render(f.actual));
          if (pause != 'hook') {
            await f.subject.controller.setQualitySettings(_settings(24));
            await f.reference.controller.setQualitySettings(_settings(24));
          }
          final gate = pause == 'hook' || pause == 'aborted'
              ? f.hook.pause
              : f.backend.pause;
          gate.arm();
          final pending = f.render(f.actual);
          await gate.entered.future;
          // In the hook case A has been prepared but capture has not happened.
          // In the backend case B has rendered, but its receipt is still pending.
          await f.subject.controller.setQualitySettings(_settings(16));
          if (pause == 'receipt') f.receipt.fail = true;
          if (pause == 'aborted') f.hook.fail = true;
          gate.release.complete();
          if (pause == 'aborted') {
            await expectLater(pending, throwsStateError);
            f.hook.fail = false;
            f.controlHook.fail = true;
            await expectLater(f.render(f.control), throwsStateError);
            f.controlHook.fail = false;
            f.number++;
            await f.reference.controller.setQualitySettings(
              CloudQualitySettings(
                preset: CloudQualityPreset.low,
                maxResolution: 32,
                shadowMapSize: 8,
              ),
            );
          } else if (pause == 'receipt') {
            await expectLater(pending, throwsStateError);
            f.receipt.fail = false;
            await f.compare(f.backend.lastOutput! as ReadbackOutput);
          } else {
            await f.compare(await pending);
          }
          expect(
            f.subject.controller.adaptiveDiagnostics['effectiveWidth'],
            pause == 'hook' || pause == 'aborted' ? 32 : 24,
          );
          expect(f.subject.controller.width, 16);
          f.addUploads();
          for (var i = 0; i < 16; i++) {
            f.camera.position += const Vec3(0, 0, 1);
            f.camera.target += const Vec3(.1, 0, 1);
            final output = await f.render(f.actual);
            if (output.stats.admission!.candidateReady &&
                f.reference.controller.width != 16) {
              await f.reference.controller.setQualitySettings(_settings(16));
            }
            await f.compare(output);
          }
          expect(
            f.records.where((r) => r['ready'] == false).length,
            greaterThanOrEqualTo(8),
          );
          expect(
            f.subject.controller.adaptiveDiagnostics['effectiveWidth'],
            16,
          );
          await f.save(pause);
        } finally {
          await f.close();
        }
      },
    );
  }
}

CloudQualitySettings _settings(int width) => CloudQualitySettings(
  preset: width == 24 ? CloudQualityPreset.medium : CloudQualityPreset.high,
  maxResolution: width,
  shadowMapSize: 8,
);

final class _Pause {
  bool armed = false;
  Completer<void> entered = Completer<void>(), release = Completer<void>();
  void arm() {
    armed = true;
    entered = Completer<void>();
    release = Completer<void>();
  }

  Future<void> wait() async {
    if (!armed) return;
    armed = false;
    entered.complete();
    await release.future;
  }

  void unblock() {
    if (!release.isCompleted) release.complete();
  }
}

final class _Hook extends ScenePlugin {
  final pause = _Pause();
  bool fail = false;
  @override
  String get id => 'cloud-delayed-hook';
  @override
  Set<String> get dependencies => {'clouds'};
  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) async {
    await pause.wait();
    if (fail) throw StateError('intentional pre-capture failure');
  }
}

final class _ReceiptHook extends ScenePlugin {
  bool fail = false;
  @override
  String get id => 'cloud-receipt-failure';
  @override
  Set<String> get dependencies => {'atmosphere'};
  @override
  void afterRender(PluginContext context, FrameInfo frame, FrameStats stats) {
    if (fail) throw StateError('intentional post-publication failure');
  }
}

final class _PausedBackend implements MaterialBackend {
  final NativeBackend native;
  final pause = _Pause();
  FrameOutput? lastOutput;
  _PausedBackend(this.native);
  @override
  DeviceCapabilities get capabilities => native.capabilities;
  @override
  ResourceScope createResourceScope({String label = ''}) =>
      native.createResourceScope(label: label);
  @override
  ShaderCompiler createShaderCompiler({String label = ''}) =>
      native.createShaderCompiler(label: label);
  @override
  GraphCompiler createGraphCompiler({String label = ''}) =>
      native.createGraphCompiler(label: label);
  @override
  MaterialCompiler createMaterialCompiler({String label = ''}) =>
      native.createMaterialCompiler(label: label);
  @override
  Future<FrameOutput> render(FrameSubmission submission) async {
    final output = lastOutput = await native.render(submission);
    await pause.wait();
    return output;
  }

  @override
  Future<void> close() => native.close();
}

final class _Fixture {
  final NativeBackend device;
  final GpuScope owner;
  final Scene scene;
  final PerspectiveCamera camera;
  final CloudPlugin subject, reference;
  final SceneEngine actual, control;
  final _Hook hook, controlHook;
  final _ReceiptHook receipt;
  final _PausedBackend backend;
  final records = <Map<String, Object?>>[];
  final images = <(Uint8List, Uint8List)>[];
  int number = 0;
  _Fixture(
    this.device,
    this.owner,
    this.scene,
    this.camera,
    this.subject,
    this.reference,
    this.actual,
    this.control,
    this.hook,
    this.controlHook,
    this.receipt,
    this.backend,
  );
  static Future<_Fixture> create() async {
    final device = await NativeBackend.create(),
        owner = GpuScope.fromBackend(device);
    final maps = await CloudTextures.generate(owner, size: 8);
    final date = DateTime.utc(2026, 3, 20, 12),
        sun = CelestialDirections.at(DateTime.utc(2026, 3, 20, 12)).sunECEF;
    final camera = PerspectiveCamera(
      position: sun * 6360100,
      target: sun * 6363000,
      up: const Vec3(0, 0, 1),
      near: 1,
      far: 1e7,
    );
    CloudPlugin clouds() => CloudPlugin(
      textures: maps.textures,
      parameters: CloudParameters(
        coverage: .8,
        localWeatherVelocity: (.003, .001),
        shapeVelocity: const Vec3(1, 0, 0),
      ),
      quality: CloudQualityPreset.low,
      maxResolution: 32,
      shadowMapSize: 8,
      appearance: CloudAppearance(hazeDensityScale: 0),
    );
    AtmospherePlugin air() => AtmospherePlugin(
      date: date,
      parameters: AtmosphereParameters.legacy(),
      correctAltitude: false,
      maxStarResolution: 16,
      appearance: AtmosphereAppearance(sky: false, haze: false),
    );
    final subject = clouds(),
        reference = clouds(),
        hook = _Hook(),
        controlHook = _Hook(),
        receipt = _ReceiptHook();
    final backend = _PausedBackend(
      device.createView()..configureSceneUploadBudget(1500),
    );
    final scene = Scene()..renderSettings = RenderSettings(hdr: true);
    final actual = await SceneEngine.create(
      scene: scene,
      camera: camera,
      backendFactory: () async => backend,
      plugins: [air(), receipt, subject, hook],
    );
    final control = await SceneEngine.create(
      scene: Scene()..renderSettings = RenderSettings(hdr: true),
      camera: camera,
      backendFactory: () async => device.createView(),
      plugins: [air(), reference, controlHook],
    );
    return _Fixture(
      device,
      owner,
      scene,
      camera,
      subject,
      reference,
      actual,
      control,
      hook,
      controlHook,
      receipt,
      backend,
    );
  }

  Future<ReadbackOutput> render(SceneEngine engine) async =>
      await engine.renderFrame(
            elapsed: Duration(milliseconds: number * 16),
            width: 33,
            height: 33,
          )
          as ReadbackOutput;
  Future<void> compare(ReadbackOutput output) async {
    final expected = await render(control);
    var difference = 0;
    for (var i = 0; i < output.image.pixels.length; i++) {
      difference = math.max(
        difference,
        (output.image.pixels[i] - expected.image.pixels[i]).abs(),
      );
    }
    records.add({
      'frame': number++,
      'ready': output.stats.admission!.candidateReady,
      'maxDifference': difference,
      'subject': subject.controller.adaptiveDiagnostics,
      'reference': reference.controller.adaptiveDiagnostics,
    });
    images.add((output.image.pixels, expected.image.pixels));
    expect(
      difference,
      lessThanOrEqualTo(2),
      reason: 'captured candidate and uniforms must match the control',
    );
    expect(
      subject.controller.adaptiveDiagnostics['presentedHistoryFrames'],
      reference.controller.history.accumulatedFrames,
    );
  }

  void addUploads() {
    final sun = (camera.target - camera.position).normalized();
    for (var i = 0; i < 12; i++) {
      scene.add(
        Mesh(
          PlaneGeometry(width: .01, height: .01),
          UnlitMaterial(
            colorMap: TextureMap(
              image: TextureImage.rgba(
                width: 32,
                height: 32,
                pixels: Uint8List(4096),
              ),
            ),
          ),
        )..position = camera.position + sun * 90000 + const Vec3(0, 0, 100),
      );
    }
  }

  Future<void> save(String name) async {
    final path = Platform.environment['CLOUD_EVIDENCE_DIR'];
    if (path == null) return;
    await File('$path/inflight-$name.json').writeAsString(jsonEncode(records));
    for (var i = 0; i < images.length; i++) {
      await File('$path/inflight-$name-$i.rgba').writeAsBytes(images[i].$1);
      await File(
        '$path/inflight-$name-reference-$i.rgba',
      ).writeAsBytes(images[i].$2);
    }
  }

  Future<void> close() async {
    hook.pause.unblock();
    backend.pause.unblock();
    await actual.dispose();
    await control.dispose();
    await owner.close();
    expect((await device.resourceStats()).residentBytes, 0);
    await device.close();
  }
}
