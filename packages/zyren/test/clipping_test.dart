import 'dart:convert';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';

void main() {
  test('planes normalize, validate and preserve the retained half-space', () {
    final plane = ClippingPlane(normal: const Vec3(2, 0, 0), offset: 6);
    expect(plane.normal, const Vec3(1, 0, 0));
    expect(plane.offset, 3);
    expect(plane.distanceTo(const Vec3(4, 0, 0)), 1);
    expect(plane.flipped.distanceTo(const Vec3(4, 0, 0)), -1);
    expect(() => ClippingPlane(normal: Vec3.zero), throwsArgumentError);
    expect(
      () => ClippingPlane(normal: const Vec3(1, 0, 0), offset: double.nan),
      throwsArgumentError,
    );
    final scene = Scene();
    final revision = scene.revision;
    final planes = [plane];
    scene.clippingPlanes = planes;
    planes.clear();
    expect(scene.clippingPlanes, [plane]);
    expect(scene.revision, greaterThan(revision));
    expect(() => scene.clippingPlanes.clear(), throwsUnsupportedError);
    expect(
      () => scene.clippingPlanes = List.filled(7, plane),
      throwsArgumentError,
    );
    expect(scene.clippingPlanes, [plane]);
  });

  test(
    'picking continues behind a clipped face and respects inherited opt-out',
    () {
      final scene = Scene();
      final group = scene.add(Group()..position = const Vec3(1000000000, 0, 0));
      final mesh = group.add(Mesh(BoxGeometry(), UnlitMaterial()));
      scene.clippingPlanes = [ClippingPlane(normal: const Vec3(0, 0, -1))];
      final ray = CameraRay(const Vec3(1000000000, 0, 5), const Vec3(0, 0, -1));
      final caster = Raycaster();
      final clipped = caster.intersectScene(scene, ray);
      expect(clipped, isNotEmpty);
      expect(clipped.every((hit) => hit.point.z <= 0), isTrue);
      group.clippingEnabled = false;
      expect(caster.intersectScene(scene, ray).first.point.z, greaterThan(0));
      group.clippingEnabled = true;
      mesh.material = UnlitMaterial(side: MaterialSide.front);
      expect(caster.intersectScene(scene, ray), isEmpty);
    },
  );

  test('each instance is clipped in world coordinates', () {
    final scene = Scene();
    final mesh = scene.add(
      InstancedMesh(BoxGeometry(), UnlitMaterial(), count: 2),
    );
    mesh.setTransform(
      0,
      Mat4.compose(const Vec3(-2, 0, 0), Quat.identity, Vec3.one),
    );
    mesh.setTransform(
      1,
      Mat4.compose(const Vec3(2, 0, 0), Quat.identity, Vec3.one),
    );
    scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
    final caster = Raycaster();
    List<PickResult> pick(double x) => caster.intersectScene(
      scene,
      CameraRay(Vec3(x, 0, 5), const Vec3(0, 0, -1)),
    );
    expect(pick(-2), isEmpty);
    expect(pick(2).first.instanceIndex, 1);
  });

  test(
    'captured camera-relative planes survive edits and removal is a delta',
    () {
      final scene = Scene()
        ..clippingPlanes = [
          ClippingPlane(normal: const Vec3(1, 0, 0), offset: 1000000000.25),
        ];
      final mesh = scene.add(
        Mesh(BoxGeometry(), UnlitMaterial())
          ..position = const Vec3(1000000000, 0, 0),
      );
      final camera = PerspectiveCamera(
        position: const Vec3(1000000000, 0, 5),
        target: const Vec3(1000000000, 0, 0),
      );
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: camera,
        size: PhysicalSize(32, 32),
      );
      final encoder = ScenePacketEncoder(viewId: 1);
      final snapshot = capture();
      expect(snapshot.toNativePacket, throwsUnsupportedError);
      scene.clippingPlanes = [];
      final encoded = encoder.encode(snapshot);
      final bytes = ByteData.sublistView(encoded.bytes);
      expect(bytes.getUint32(4, Endian.little), 36);
      expect(
        utf8.decode(encoded.bytes, allowMalformed: true),
        contains('"clipping_planes":[[1.0,0.0,0.0,-0.25]]'),
      );
      encoder.accept(encoded);
      final cleared = encoder.encode(capture());
      expect(cleared.changedMeshes, 1);
      expect(cleared.uploadedBytes, 0);
      encoder.accept(cleared);
      expect(encoder.encode(capture()).changedMeshes, 0);
      scene.clippingPlanes = [ClippingPlane(normal: const Vec3(1, 0, 0))];
      mesh.clippingEnabled = false;
      expect(encoder.encode(capture()).changedMeshes, 0);
    },
  );
}
