import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'material_compiler_test.dart' as fixture;

class _BufferDevice extends fixture.Device {
  @override
  Future<Object> createBuffer(BufferDescriptor descriptor) async => Object();
}

void main() {
  test(
    'screen targets validate usage, format, aliases and ownership',
    () async {
      final device = fixture.Device(), foreignDevice = fixture.Device();
      final resources = ResourceScope(device),
          foreign = ResourceScope(foreignDevice);
      final shaders = ShaderCompiler(device),
          materials = MaterialCompiler(device);
      try {
        final program = await shaders.compile(ShaderSource.wgsl('valid'));
        final target = await resources.createTexture(
          TextureDescriptor(
            width: 2,
            height: 2,
            format: TextureFormat.rgba16Float,
            usage: {
              TextureUsage.sampled,
              TextureUsage.storage,
              TextureUsage.renderAttachment,
            },
          ),
        );
        final valid = await materials.compileEffect(
          PostProcessDescriptor(program: program, target: target),
        );
        expect(valid.isClosed, isFalse);
        for (final bindings in [
          ShaderBindings([TextureBinding.sampled(0, target, group: 1)]),
          ShaderBindings([TextureBinding.storage(0, target, group: 1)]),
        ]) {
          await expectLater(
            materials.compileEffect(
              PostProcessDescriptor(
                program: program,
                target: target,
                bindings: bindings,
              ),
            ),
            throwsA(
              isA<GraphException>().having(
                (v) => v.code,
                'code',
                GraphErrorCode.aliasConflict,
              ),
            ),
          );
        }
        for (final descriptor in [
          TextureDescriptor(
            width: 2,
            height: 2,
            format: TextureFormat.rgba8Unorm,
            usage: {TextureUsage.renderAttachment},
          ),
          TextureDescriptor(
            width: 2,
            height: 2,
            format: TextureFormat.rgba16Float,
          ),
          TextureDescriptor(
            width: 2,
            height: 2,
            depth: 2,
            dimension: TextureDimension.d3,
            format: TextureFormat.rgba16Float,
          ),
        ]) {
          final bad = await resources.createTexture(descriptor);
          await expectLater(
            materials.compileEffect(
              PostProcessDescriptor(program: program, target: bad),
            ),
            throwsA(
              isA<GraphException>().having(
                (v) => v.code,
                'code',
                GraphErrorCode.invalidBinding,
              ),
            ),
          );
        }
        final other = await foreign.createTexture(
          target.descriptor as TextureDescriptor,
        );
        await expectLater(
          materials.compileEffect(
            PostProcessDescriptor(program: program, target: other),
          ),
          throwsA(
            isA<GraphException>().having(
              (v) => v.code,
              'code',
              GraphErrorCode.foreignResource,
            ),
          ),
        );
        await resources.close();
        await expectLater(
          materials.compileEffect(
            PostProcessDescriptor(program: program, target: target),
          ),
          throwsA(
            isA<GraphException>().having(
              (v) => v.code,
              'code',
              GraphErrorCode.closedResource,
            ),
          ),
        );
      } finally {
        await materials.close();
        await shaders.close();
        await resources.close();
        await foreign.close();
      }
    },
  );
  test(
    'display stages remain after HDR despite caller order and retention',
    () async {
      final device = fixture.Device();
      final shaders = ShaderCompiler(device),
          owner = MaterialCompiler(device),
          keeper = MaterialCompiler(device);
      final program = await shaders.compile(ShaderSource.wgsl('valid'));
      final hdr = await owner.compileEffect(
        PostProcessDescriptor(program: program),
      );
      final display = await owner.compileEffect(
        PostProcessDescriptor(
          program: program,
          stage: PostProcessStage.display,
        ),
      );
      final retained = await keeper.retainEffect(display);
      final scene = Scene()
        ..renderSettings = RenderSettings(effects: [display, hdr]);
      scene.addEffect(retained, order: -100);
      expect(scene.effects, [hdr, retained, display]);
      await owner.close();
      expect(retained.stage, PostProcessStage.display);
      expect(retained.isClosed, isFalse);
      await keeper.close();
      await shaders.close();
      expect(device.materials, isEmpty);
    },
  );
  test(
    'ordered screen stages keep stable ties and replacement ownership',
    () async {
      final device = fixture.Device();
      final shaders = ShaderCompiler(device),
          materials = MaterialCompiler(device);
      final program = await shaders.compile(ShaderSource.wgsl('valid'));
      Future<ScreenEffect> make() =>
          materials.compileEffect(PostProcessDescriptor(program: program));
      final a = await make(),
          b = await make(),
          c = await make(),
          d = await make();
      final scene = Scene()..renderSettings = RenderSettings(effects: [a]);
      final last = scene.addEffect(b, order: 10);
      final first = scene.addEffect(c, order: -10);
      scene.addEffect(d);
      expect(scene.effects, [c, a, d, b]);
      first.replace(b);
      expect(scene.effects, [b, a, d, b]);
      last.dispose();
      expect(scene.effects, [b, a, d]);
      expect(() => scene.addEffect(c, order: 1 << 20), throwsArgumentError);
      first.dispose();
      expect(scene.effects, [a, d]);
      await materials.close();
      await shaders.close();
    },
  );
  test('only screen fragments may write storage texture outputs', () async {
    final device = _BufferDevice();
    final shaders = ShaderCompiler(device),
        materials = MaterialCompiler(device);
    final scope = ResourceScope(device);
    final program = await shaders.compile(ShaderSource.wgsl('valid'));
    final texture = await scope.createTexture(
      TextureDescriptor(
        width: 2,
        height: 2,
        format: TextureFormat.rgba8Unorm,
        usage: {TextureUsage.sampled, TextureUsage.storage},
      ),
    );
    final buffer = await scope.createBuffer(
      BufferDescriptor(size: 16, usage: {BufferUsage.storage}),
    );
    final output = TextureBinding.storage(0, texture, group: 1);
    final effect = await materials.compileEffect(
      PostProcessDescriptor(
        program: program,
        bindings: ShaderBindings([output]),
      ),
    );
    for (final bindings in [
      [
        TextureBinding.storage(
          0,
          texture,
          group: 1,
          visibility: {ShaderStage.vertex},
        ),
      ],
      [TextureBinding.storage(0, texture)],
      [BufferBinding.storageReadWrite(0, buffer, group: 1)],
      [output, TextureBinding.sampled(1, texture, group: 1)],
    ]) {
      await expectLater(
        materials.compileEffect(
          PostProcessDescriptor(
            program: program,
            bindings: ShaderBindings(bindings),
          ),
        ),
        throwsA(isA<GraphException>()),
      );
    }
    await expectLater(
      materials.compile(
        MeshShaderDescriptor(
          program: program,
          bindings: ShaderBindings([output]),
        ),
      ),
      throwsA(isA<GraphException>()),
    );
    expect(effect.isClosed, isFalse);
    expect(device.materials.length, 1);
    await materials.close();
    await shaders.close();
    await scope.close();
  });
  test(
    'effect frames capture output settings and reject stale owners',
    () async {
      final device = fixture.Device();
      final programs = ShaderCompiler(device),
          materials = MaterialCompiler(device);
      final effect = await materials.compileEffect(
        PostProcessDescriptor(
          program: await programs.compile(ShaderSource.wgsl('valid')),
        ),
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(
          effects: [effect],
          toneMapping: ToneMapping.aces,
          exposure: 2,
          backgroundAlpha: .5,
          historyEpoch: 3,
        );
      final frame = FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(32, 32),
      );
      final registration = scene.addEffect(effect);
      scene.renderSettings = scene.renderSettings.copyWith(exposure: 3);
      expect(scene.effects, hasLength(2));
      registration.dispose();
      expect(scene.effects, hasLength(1));
      final screenShader = await materials.compile(
        PostProcessDescriptor(
          program: await programs.compile(ShaderSource.wgsl('valid')),
        ),
      );
      expect(() => ShaderMaterial(screenShader), throwsArgumentError);
      scene.renderSettings = RenderSettings();
      expect(
        () => ScenePacketEncoder(viewId: 1).encode(frame),
        throwsUnsupportedError,
      );
      final encoder = ScenePacketEncoder(viewId: 1, materialDevice: device);
      expect(encoder.encode(frame).bytes, isNotEmpty);
      expect(frame.toNativePacket, throwsUnsupportedError);
      await materials.close();
      expect(() => encoder.encode(frame), throwsStateError);
      await programs.close();
    },
  );
  test(
    'effect replacement preserves order and an occupied final slot',
    () async {
      final device = fixture.Device();
      final programs = ShaderCompiler(device),
          materials = MaterialCompiler(device);
      final program = await programs.compile(ShaderSource.wgsl('valid'));
      final a = await materials.compileEffect(
        PostProcessDescriptor(program: program),
      );
      final b = await materials.compileEffect(
        PostProcessDescriptor(program: program),
      );
      final scene = Scene()
        ..renderSettings = RenderSettings(effects: List.filled(30, a));
      final registration = scene.addEffect(a);
      final last = scene.addEffect(a, requiresTransparentBackground: true);
      expect(scene.backgroundAlpha, 0);
      scene.renderSettings = scene.renderSettings.copyWith(backgroundAlpha: .4);
      expect(scene.backgroundAlpha, 0);
      registration.replace(b);
      expect(scene.effects, [...List.filled(30, a), b, a]);
      expect(() => scene.addEffect(a), throwsStateError);
      await materials.close();
      expect(() => registration.replace(a), throwsStateError);
      expect(scene.effects[30], same(b));
      registration.dispose();
      expect(() => registration.replace(b), throwsStateError);
      expect(scene.effects, hasLength(31));
      last.dispose();
      expect(scene.backgroundAlpha, .4);
      await programs.close();
    },
  );
  test('render settings bound exposure, alpha and effect counts', () {
    expect(() => RenderSettings(sampleCount: 2), throwsArgumentError);
    expect(RenderSettings(sampleCount: 4).enabled, isTrue);
    expect(RenderSettings(sampleCount: 4).copyWith(exposure: 2).sampleCount, 4);
    final packet = ScenePacketEncoder(viewId: 1).encode(
      FrameSubmission.capture(
        scene: Scene()..renderSettings = RenderSettings(sampleCount: 4),
        camera: PerspectiveCamera(),
        size: PhysicalSize(4, 4),
      ),
    );
    expect(ByteData.sublistView(packet.bytes).getUint32(4, Endian.little), 36);
    expect(() => RenderSettings(exposure: double.nan), throwsArgumentError);
    expect(() => RenderSettings(backgroundAlpha: 1.1), throwsArgumentError);
    expect(() => RenderSettings(historyEpoch: -1), throwsArgumentError);
  });
}
