import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  final scene = Scene()
    ..background = const Color3(0, 0, 0)
    ..renderSettings = RenderSettings(
      hdr: true,
      toneMapping: ToneMapping.reinhard,
    )
    ..clippingPlanes = [
      ClippingPlane(normal: const Vec3(1, 0, 0), offset: 6378137.25),
    ];
  final mesh = scene.add(
    Mesh(
      PlaneGeometry(),
      PhysicalMaterial(
        normalScaleX: .5,
        normalScaleY: -.75,
        iridescence: .5,
        dispersion: .2,
      ),
    ),
  );
  scene.outline = SceneOutline(objects: [mesh], width: 2);
  mesh.fragmentCoverage = FragmentCoverage(upper: .5);
  final camera = PerspectiveCamera(
    depthStrategy: DepthStrategy.reversed,
    position: const Vec3(6378137, 0, 3),
    target: const Vec3(6378137, 0, 0),
  );
  scene.position = const Vec3(6378137, 0, 0);
  final submission = FrameSubmission.capture(
    scene: scene,
    camera: camera,
    size: PhysicalSize(32, 32),
  );
  final packet = ScenePacketEncoder(viewId: 1).encode(submission);
  File.fromUri(
      Platform.script.resolve(
        '../native/tests/fixtures/integrated-scene-v36.bin',
      ),
    )
    ..parent.createSync(recursive: true)
    ..writeAsBytesSync(packet.bytes);
}
