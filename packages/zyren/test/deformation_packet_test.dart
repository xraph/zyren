import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';
import 'deformation_test.dart' show strip;
import 'engine_output_test.dart' show SurfaceBackend;

void main() {
  test(
    'deformation capabilities reject unsupported and undersized backends before submission',
    () async {
      for (final supported in [false, true]) {
        final root = Bone(), tip = Bone();
        root.add(tip);
        final scene = Scene()
          ..add(root)
          ..add(
            SkinnedMesh(
              strip(),
              UnlitMaterial(),
              skin: Skin.fromBindPose(joints: [root, tip]),
            ),
          );
        final engine = await SceneEngine.create(
          scene: scene,
          camera: PerspectiveCamera(),
          backendFactory: () async => _LimitedBackend(supported),
        );
        try {
          await expectLater(
            engine.renderFrame(elapsed: Duration.zero, width: 1, height: 1),
            throwsA(
              isA<SceneException>().having(
                (e) => e.issue.requiredFeatures,
                'requiredFeatures',
                contains(RenderFeature.skinning),
              ),
            ),
          );
        } finally {
          await engine.dispose();
        }
      }
    },
  );
  test(
    'poses own immutable versions and upload independently of shared geometry',
    () {
      final geometry = strip();
      final root = Bone(), tip = Bone()..position = const Vec3(0, 1, 0);
      root.add(tip);
      final skin = Skin.fromBindPose(joints: [root, tip]);
      final mesh = SkinnedMesh(geometry, UnlitMaterial(), skin: skin);
      final scene = Scene()
        ..add(root)
        ..add(mesh);
      final camera = PerspectiveCamera();
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(32, 32),
      );
      final encoder = ScenePacketEncoder(viewId: 701);
      final frozen = capture(),
          poseBytes = mesh.captureDeformation()!.gpuByteLength;
      final initial = encoder.encode(frozen);
      expect(
        ByteData.sublistView(initial.bytes).getUint32(4, Endian.little),
        25,
      );
      expect(
        initial.uploadedBytes,
        geometry.capture().gpuByteLength + poseBytes,
      );
      expect(() => frozen.toNativePacket(), throwsUnsupportedError);
      encoder.accept(initial);
      tip.position = const Vec3(1, 1, 0);
      final changed = encoder.encode(capture());
      expect(changed.changedMeshes, 1);
      expect(changed.uploadedBytes, poseBytes);
      encoder.accept(changed);
      camera.position = const Vec3(0, 0, 6);
      final moved = encoder.encode(capture());
      expect(moved.uploadedBytes, 0);
      encoder.accept(moved);
      mesh.visible = false;
      tip.position = const Vec3(2, 1, 0);
      final hidden = encoder.encode(capture());
      expect(hidden.uploadedBytes, 0);
      encoder.accept(hidden);
      mesh.visible = true;
      final shown = encoder.encode(capture());
      expect(shown.uploadedBytes, poseBytes);
      encoder.accept(shown);
      expect(encoder.encode(frozen).uploadedBytes, poseBytes);
      scene.remove(root);
      expect(capture, throwsArgumentError);
    },
  );
}

class _LimitedBackend extends SurfaceBackend {
  final bool supported;
  _LimitedBackend(this.supported);
  @override
  DeviceCapabilities get capabilities => DeviceCapabilities(
    name: 'limited deformation',
    features: {if (supported) RenderFeature.skinning},
    limits: DeviceLimits(
      maxTextureDimension2D: 64,
      maxGeometryBytes: 1024,
      maxJoints: 1,
    ),
  );
}
