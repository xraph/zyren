import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';
import 'support/fakes.dart';

void main() {
  test('unsupported HDR rejects before legacy rendering', () async {
    final renderer = TestRenderer([]);
    final engine = await SceneEngine.create(
      scene: Scene(),
      camera: PerspectiveCamera(),
      rendererFactory: () async => renderer,
    );
    try {
      await expectLater(
        engine.renderFrame(
          elapsed: Duration.zero,
          width: 16,
          height: 16,
          colorPipeline: ColorPipeline(),
        ),
        throwsA(
          isA<SceneException>().having(
            (e) => e.issue.code,
            'code',
            SceneIssueCodes.unsupportedFeature,
          ),
        ),
      );
      expect(renderer.renders, 0);
    } finally {
      await engine.dispose();
    }
  });
  test('HDR texel sizes bound every mip and reject RGBA8 image ambiguity', () {
    final texture = TextureDescriptor(
      width: 3,
      height: 5,
      mipLevels: 3,
      format: TextureFormat.rgba16Float,
      usage: {TextureUsage.sampled, TextureUsage.storage},
    );
    expect(texture.mipByteLength(0), 120);
    expect(texture.mipByteLength(1), 16);
    expect(texture.byteLength, 144);
    expect(
      () => TextureDescriptor(
        width: 4096,
        height: 4096,
        format: TextureFormat.rgba16Float,
      ),
      throwsArgumentError,
    );
    expect(
      () => TextureImage.rgba(
        width: 1,
        height: 1,
        format: TextureFormat.rgba16Float,
        pixels: Uint8List(8),
      ),
      throwsArgumentError,
    );
  });

  test('color pipeline captures exposure and survives graph selection', () {
    final pipeline = ColorPipeline(
      toneMapping: ToneMapping.reinhard,
      exposure: .25,
    );
    final frame = FrameSubmission.capture(
      scene: Scene(),
      camera: PerspectiveCamera(),
      size: PhysicalSize(16, 16),
      colorPipeline: pipeline,
    );
    expect(frame.withGraph(null).colorPipeline, same(pipeline));
    final packet = ScenePacketEncoder(viewId: 1).encode(frame);
    expect(ByteData.sublistView(packet.bytes).getUint32(4, Endian.little), 21);
    expect(frame.toNativePacket()['color_pipeline'], {
      'tone_mapping': 1,
      'exposure': .25,
    });
    for (final value in [-1.0, double.nan, double.infinity, 1e7]) {
      expect(() => ColorPipeline(exposure: value), throwsArgumentError);
    }
  });
}
