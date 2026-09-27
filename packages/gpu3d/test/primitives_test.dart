import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test(
    'line and point recipes preserve topology and validate material pairing',
    () {
      final line = LineGeometry(
        points: [Vec3.zero, const Vec3(1, 0, 0), const Vec3(1, 1, 0)],
      );
      expect(line.topology, GeometryTopology.lineStrip);
      expect(line.capture().primitiveCount, 2);
      expect(
        LineGeometry(
          points: [Vec3.zero, const Vec3(1, 0, 0)],
          closed: true,
        ).indices,
        [0, 1, 0],
      );
      expect(
        () => LineGeometry.segments(points: [Vec3.zero]),
        throwsArgumentError,
      );
      expect(() => LineGeometry(points: [Vec3.zero]), throwsArgumentError);
      expect(() => PointGeometry(points: []), throwsArgumentError);
      expect(() => LineMaterial(width: 0), throwsArgumentError);
      expect(() => LineMaterial(width: 1e-100), throwsArgumentError);
      expect(() => PointsMaterial(size: double.infinity), throwsArgumentError);
      expect(() => Mesh(line, UnlitMaterial()), throwsArgumentError);
      expect(() => Mesh(PlaneGeometry(), LineMaterial()), throwsArgumentError);
      final node = Line(line, LineMaterial(width: 5));
      expect(node.material.width, 5);
      final old = node.material;
      expect(
        () => (node as Mesh).material = UnlitMaterial(),
        throwsA(isA<Error>()),
      );
      expect(identical(node.material, old), isTrue);
      expect(old.copyWith(widthUnits: SizeUnits.world).width, 5);
      expect(PointsMaterial().shape, PointShape.circle);
      expect(PointsMaterial().size, 4);
    },
  );
  test(
    'captures and size edits preserve resources; dynamic primitives replace recipes',
    () {
      final geometry = LineGeometry(
        points: [Vec3.zero, const Vec3(1, 0, 0)],
        dynamic: true,
      );
      final node = Line(geometry, LineMaterial(width: 5));
      final scene = Scene()..add(node);
      final encoder = ScenePacketEncoder(viewId: 123);
      FrameSubmission capture() => FrameSubmission.capture(
        scene: scene,
        camera: PerspectiveCamera(),
        size: PhysicalSize(64, 64),
      );
      final firstFrame = capture();
      expect(firstFrame.scene.triangles, 2);
      final first = encoder.encode(firstFrame);
      expect(ByteData.sublistView(first.bytes).getUint32(4, Endian.little), 16);
      expect(first.uploadedBytes, 120);
      encoder.accept(first);
      node.material = node.material.copyWith(width: 9);
      final changed = encoder.encode(capture());
      expect(changed.changedMeshes, 1);
      expect(changed.uploadedBytes, 0);
      encoder.accept(changed);
      final old = geometry.capture();
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([2, 0, 0]),
        firstVertex: 1,
      );
      expect(old.positions[3], 1);
      expect(geometry.capture().topology, GeometryTopology.lineStrip);
      expect(encoder.encode(capture()).uploadedBytes, 120);
    },
  );
}
