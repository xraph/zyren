import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test('alpha modes resolve depth writes and preserve explicit overrides', () {
    final solid = UnlitMaterial();
    expect(solid.alphaMode, MaterialAlphaMode.opaque);
    expect(solid.opacity, 1);
    expect(solid.writesDepth, isTrue);
    final glass = solid.copyWith(
      alphaMode: MaterialAlphaMode.blend,
      opacity: .4,
    );
    expect(glass.writesDepth, isFalse);
    expect(
      glass.copyWith(alphaMode: MaterialAlphaMode.mask).writesDepth,
      isTrue,
    );
    final forced = glass.copyWith(depthWrite: DepthWrite.enabled);
    expect(forced.copyWith(opacity: .2).writesDepth, isTrue);
    expect(
      forced.copyWith(depthWrite: DepthWrite.automatic).writesDepth,
      isFalse,
    );
    final diffuse = DiffuseMaterial(
      alphaMode: MaterialAlphaMode.blend,
      opacity: .3,
      alphaCutoff: .7,
      depthTest: false,
    );
    final copy = diffuse.copyWith(color: const Color3(1, 0, 0));
    expect(copy.alphaMode, diffuse.alphaMode);
    expect(copy.opacity, .3);
    expect(copy.alphaCutoff, .7);
    expect(copy.depthTest, isFalse);
    for (final invalid in [-.1, 1.1, double.nan, double.infinity]) {
      expect(() => UnlitMaterial(opacity: invalid), throwsArgumentError);
    }
    expect(
      DiffuseMaterial(alphaCutoff: 1.1).copyWith(opacity: .5).alphaCutoff,
      1.1,
    );
    for (final invalid in [-.1, 1e39, double.nan, double.infinity]) {
      expect(() => DiffuseMaterial(alphaCutoff: invalid), throwsArgumentError);
    }
  });
  test(
    'captured material and ordering edits update records without uploads',
    () {
      final mesh = Mesh(PlaneGeometry(), UnlitMaterial());
      final scene = Scene()..add(mesh);
      final camera = PerspectiveCamera();
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(31, 31),
      );
      final before = capture();
      final encoder = ScenePacketEncoder(viewId: 1);
      encoder.accept(encoder.encode(before));
      final revision = scene.revision;
      mesh.material = UnlitMaterial(
        alphaMode: MaterialAlphaMode.blend,
        opacity: .25,
      );
      mesh.renderOrder = -10;
      expect(scene.revision, greaterThan(revision));
      final changed = encoder.encode(capture());
      expect(changed.changedMeshes, 1);
      expect(changed.uploadedBytes, 0);
      encoder.accept(changed);
      expect(encoder.encode(capture()).changedMeshes, 0);
      expect(encoder.encode(before).changedMeshes, 1);
      final unchanged = scene.revision;
      mesh.renderOrder = -10;
      expect(scene.revision, unchanged);
      expect(() => mesh.renderOrder = 0x80000000, throwsRangeError);
      expect(() => mesh.renderOrder = -0x80000001, throwsRangeError);
      expect(mesh.renderOrder, -10);
    },
  );
}
