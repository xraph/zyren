import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('transparent default and fractional backgrounds are captured once', () {
    final scene = Scene();
    final camera = PerspectiveCamera();
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(8, 8),
    );
    expect(scene.background, isNull);
    expect(scene.backgroundOpacity, 1);
    expect(capture().toNativePacket()['background_alpha'], 0);
    scene.background = const Color3(.2, .4, .6);
    expect(capture().toNativePacket()['background_alpha'], 1);
    final revision = scene.revision;
    scene.backgroundOpacity = .5;
    expect(scene.revision, greaterThan(revision));
    final frozen = capture();
    scene.backgroundOpacity = 1;
    scene.background = null;
    expect(frozen.toNativePacket()['background_alpha'], .5);
    expect(frozen.toNativePacket()['background'], [.2, .4, .6]);
    expect(scene.snapshot(camera, 1)['background_alpha'], 0);
    scene.background = const Color3(0, 0, 0);
    scene.backgroundOpacity = 1 - 1e-9;
    expect(capture().scene.alphaResolveDraws, 0);
    for (final invalid in [-.1, 1.1, double.nan, double.infinity]) {
      expect(() => scene.backgroundOpacity = invalid, throwsArgumentError);
    }
  });
  test('alpha uses opcode 18 and opaque deltas retain the older protocol', () {
    final scene = Scene();
    final encoder = ScenePacketEncoder(viewId: 1);
    EncodedScenePacket packet() => encoder.encode(
      FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(8, 8),
      ),
    );
    final clear = packet();
    final bytes = ByteData.sublistView(clear.bytes);
    expect(bytes.getUint32(4, Endian.little), 18);
    expect(bytes.getFloat32(148, Endian.little), 0);
    encoder.accept(clear);
    scene.background = const Color3(0, 0, 0);
    final opaque = packet();
    expect(ByteData.sublistView(opaque.bytes).getUint32(4, Endian.little), 11);
    expect(opaque.changedMeshes, 0);
  });
}
