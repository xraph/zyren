import 'dart:io';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:zyren_effects/zyren_effects.dart';
import 'package:zyren_native/zyren_native.dart';

void main() {
  test('lens settings preserve source defaults and reject invalid values', () {
    final settings = LensFlareSettings();
    expect(settings.intensity, .005);
    expect(settings.resolutionScale, .5);
    expect(settings.thresholdLevel, 10);
    expect(settings.thresholdRange, 1);
    expect(settings.ghostAmount, .001);
    expect(settings.haloAmount, .001);
    expect(settings.chromaticAberration, 10);
    for (final value in [-1.0, double.nan, double.infinity]) {
      expect(() => LensFlareSettings(intensity: value), throwsArgumentError);
      expect(() => LensFlareSettings(ghostAmount: value), throwsArgumentError);
      expect(() => LensFlareSettings(haloAmount: value), throwsArgumentError);
      expect(
        () => LensFlareSettings(thresholdLevel: value),
        throwsArgumentError,
      );
      expect(
        () => LensFlareSettings(thresholdRange: value),
        throwsArgumentError,
      );
      expect(
        () => LensFlareSettings(chromaticAberration: value),
        throwsArgumentError,
      );
    }
    expect(() => LensFlareSettings(thresholdRange: 0), throwsArgumentError);
    expect(() => LensFlareSettings(resolutionScale: 0), throwsArgumentError);
    expect(() => LensFlareSettings(resolutionScale: 1.1), throwsArgumentError);
    expect(() => LensFlareSettings(maxResolution: 1025), throwsArgumentError);
  });
  test(
    'native lens composes, replaces, resizes and loses an occluded source',
    () async {
      final backend = await NativeBackend.create(),
          owner = GpuScope.fromBackend(backend);
      try {
        final image = await owner.resources.createTexture(
          TextureDescriptor(
            width: 64,
            height: 48,
            format: TextureFormat.rgba32Float,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        final pixels = Float32List(64 * 48 * 4);
        for (var y = 0; y < 48; y++) {
          for (var x = 0; x < 64; x++) {
            final i = (y * 64 + x) * 4,
                bright = x >= 8 && x < 16 && y >= 8 && y < 16;
            pixels.setRange(
              i,
              i + 4,
              bright ? [32, 16, 8, 1] : [.02, .02, .02, 1],
            );
          }
        }
        await owner.resources.writeTexture(image, pixels);
        final inject = await owner.materials.compileEffect(
          PostProcessDescriptor(
            program: await owner.shaders.compile(
              ShaderSource.wgsl(
                '${PostProcessDescriptor.interfaceWgsl}\n@group(1) @binding(0) var inputImage:texture_2d<f32>;\n@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32>{return textureLoad(inputImage,vec2<i32>(v.uv*vec2<f32>(textureDimensions(inputImage))),0);}',
              ),
            ),
            bindings: ShaderBindings([
              TextureBinding.sampled(0, image, group: 1),
            ]),
          ),
        );
        final scene = Scene()
          ..renderSettings = RenderSettings(
            effects: [inject],
            toneMapping: ToneMapping.reinhard,
          );
        Future<Uint8List> render(int w, int h) async =>
            (await backend.render(
                      FrameSubmission.capture(
                        scene: scene,
                        camera: PerspectiveCamera(),
                        size: PhysicalSize(w, h),
                      ),
                    )
                    as ReadbackOutput)
                .image
                .pixels;
        final baseline = await render(64, 48);
        final lens = await LensFlareEffect.create(
          owner,
          PhysicalSize(64, 48),
          settings: LensFlareSettings(
            thresholdLevel: .1,
            thresholdRange: .1,
            intensity: .2,
            ghostAmount: .3,
            haloAmount: .2,
          ),
        );
        expect(lens.stages.length, 22);
        final crowded = Scene()
          ..renderSettings = RenderSettings(effects: List.filled(11, inject));
        expect(() => lens.attach(crowded), throwsStateError);
        expect(crowded.effects.length, 11);
        expect(() => lens.attach(scene, order: 32767), throwsRangeError);
        expect(scene.effects, [inject]);
        final attachment = lens.attach(scene);
        final glow = await render(64, 48);
        expect(glow, isNot(baseline));
        expect(
          [
            for (var i = 0; i < glow.length; i += 4)
              if (glow[i] > baseline[i] + 1) i,
          ].length,
          greaterThan(100),
        );
        final replaced = await LensFlareEffect.create(
          owner,
          PhysicalSize(65, 49),
          settings: LensFlareSettings(intensity: 0),
        );
        attachment.replace(replaced);
        await lens.close();
        expect(await render(64, 48), baseline);
        await render(65, 49);
        final closed = await LensFlareEffect.create(owner, PhysicalSize(8, 8));
        await closed.close();
        expect(() => attachment.replace(closed), throwsStateError);
        expect(await render(64, 48), baseline);
        attachment.dispose();
        expect(() => attachment.replace(replaced), throwsStateError);
        await replaced.close();
        final odd = await LensFlareEffect.create(
          owner,
          PhysicalSize(65, 49),
          settings: LensFlareSettings(
            thresholdLevel: 0,
            thresholdRange: .01,
            intensity: .2,
            haloAmount: 1,
          ),
        );
        final slot = odd.attach(scene);
        await render(65, 49);
        final reader = owner.createChild(),
            readable = await reader.resources.retain(odd.features);
        final values = ByteData.sublistView(
          await reader.resources.readTexture(readable),
        );
        for (var i = 0; i < values.lengthInBytes; i += 2) {
          expect(values.getUint16(i, Endian.little) & 0x7c00, isNot(0x7c00));
        }
        for (var i = 0; i < pixels.length; i += 4) {
          pixels.setRange(i, i + 4, [0, 0, 0, 1]);
        }
        await owner.resources.writeTexture(image, pixels);
        final hidden = await render(65, 49);
        for (var i = 0; i < hidden.length; i += 4) {
          expect(hidden.sublist(i, i + 4), [0, 0, 0, 255]);
        }
        slot.dispose();
        await odd.close();
        await reader.close();
        await owner.close();
        expect((await backend.resourceStats()).residentBytes, 0);
        expect((await backend.graphStats()).liveMaterials, 0);
      } finally {
        await owner.close();
        await backend.close();
      }
    },
    skip: Platform.environment['RUN_NATIVE_GPU'] != '1',
  );
}
