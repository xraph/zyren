import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test('fragment coverage validates intervals and captures delta updates', () {
    for (final range in [(-.1, 1.0), (0.0, 1.1), (.8, .2), (double.nan, 1.0)]) {
      expect(
        () => FragmentCoverage(lower: range.$1, upper: range.$2),
        throwsArgumentError,
      );
    }
    final scene = Scene();
    final mesh = scene.add(Mesh(PlaneGeometry(), UnlitMaterial()));
    final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: camera,
      size: PhysicalSize(32, 32),
    );
    final encoder = ScenePacketEncoder(viewId: 1);
    final first = encoder.encode(capture());
    encoder.accept(first);
    final revision = scene.revision;
    mesh.fragmentCoverage = FragmentCoverage(upper: .5);
    expect(scene.revision, greaterThan(revision));
    final frozen = capture();
    mesh.fragmentCoverage = const FragmentCoverage.full();
    final faded = encoder.encode(frozen);
    expect(ByteData.sublistView(faded.bytes).getUint32(4, Endian.little), 31);
    expect(faded.uploadedBytes, 0);
    expect(faded.changedMeshes, 1);
    encoder.accept(faded);
    final reset = encoder.encode(capture());
    expect(reset.changedMeshes, 1);
    expect(reset.uploadedBytes, 0);
    mesh.fragmentCoverage = FragmentCoverage(upper: 0);
    expect(
      Raycaster().intersectScene(
        scene,
        CameraRay(const Vec3(0, 0, 3), const Vec3(0, 0, -1)),
      ),
      isEmpty,
    );
  });
}
