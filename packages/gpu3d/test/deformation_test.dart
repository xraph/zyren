import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:test/test.dart';

BufferGeometry strip({List<MorphTarget> targets = const []}) =>
    BufferGeometry.fromAttributes(
      attributes: {
        VertexSemantic.position: VertexAttribute(
          Float32List.fromList([0, 0, 0, 0, 1, 0, 0, 2, 0]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.joints: VertexAttribute(
          Uint16List.fromList([0, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0]),
          format: VertexFormat.uint16x4,
        ),
        VertexSemantic.weights: VertexAttribute(
          Float32List.fromList([1, 0, 0, 0, .5, .5, 0, 0, 1, 0, 0, 0]),
          format: VertexFormat.float32x4,
        ),
      },
      indices: [0, 1, 2],
      morphTargets: targets,
    );

void main() {
  test('source revisions invalidate skin index validation', () {
    final source = strip();
    final geometry = BufferGeometry.fromAttributes(
      attributes: source.attributes,
      indices: source.indices,
      dynamic: true,
    );
    final a = Bone(), b = Bone();
    a.add(b);
    final mesh = SkinnedMesh(
      geometry,
      UnlitMaterial(),
      skin: Skin.fromBindPose(joints: [a, b]),
    );
    final frozen = mesh.captureDeformation();
    geometry.updateAttribute(
      VertexSemantic.joints,
      Uint16List.fromList([9, 0, 0, 0]),
      firstVertex: 0,
    );
    expect(mesh.captureDeformation, throwsArgumentError);
    expect(frozen!.vertexPosition(0), Vec3.zero);
  });
  test('morph bounds update the active instance union', () {
    final geometry = BufferGeometry(
      positions: [0, 0, 0, 1, 0, 0, 0, 1, 0],
      normals: [0, 0, 1, 0, 0, 1, 0, 0, 1],
      indices: [0, 1, 2],
      morphTargets: [
        MorphTarget(positions: [2, 0, 0, 2, 0, 0, 2, 0, 0]),
      ],
    );
    final mesh = InstancedMesh(geometry, UnlitMaterial(), count: 2);
    mesh.setTransform(
      1,
      Mat4.compose(const Vec3(10, 0, 0), Quat.identity, const Vec3(-1, 1, 1)),
    );
    expect(mesh.bounds.minimum.x, 0);
    expect(mesh.bounds.maximum.x, 10);
    mesh.setMorphWeight(0, 1);
    expect(mesh.bounds.minimum.x, 2);
    expect(mesh.bounds.maximum.x, 8);
    mesh.count = 1;
    expect(mesh.bounds.maximum.x, 3);
    mesh.setMorphWeight(0, -1);
    expect(mesh.bounds.minimum.x, -2);
    expect(mesh.bounds.maximum.x, -1);
  });
  test(
    'two-bone binding preserves rest pose and applies morph before skin',
    () {
      final root = Group();
      final hip = root.add(Bone());
      final knee = hip.add(Bone()..position = const Vec3(0, 1, 0));
      final target = MorphTarget(
        positions: Float32List.fromList([0, 0, 0, 0, 0, 0, 1, 0, 0]),
      );
      final mesh = root.add(
        SkinnedMesh(
          strip(targets: [target]),
          UnlitMaterial(),
          skin: Skin.fromBindPose(joints: [hip, knee]),
        ),
      );
      expect(mesh.vertexPosition(2), const Vec3(0, 2, 0));
      final rest = mesh.captureDeformation()!;
      knee.rotateZ(math.pi / 2);
      mesh.setMorphWeight(0, .5);
      final moved = mesh.vertexPosition(2);
      expect(moved.x, closeTo(-1, 1e-9));
      expect(moved.y, closeTo(1.5, 1e-9));
      expect(mesh.vertexPosition(1).x, closeTo(0, 1e-9));
      expect(rest.vertexPosition(2), const Vec3(0, 2, 0));
      final bounds = mesh.bounds;
      for (var i = 0; i < 3; i++) {
        expect(bounds.contains(mesh.vertexPosition(i)), isTrue);
      }
      final pose = mesh.captureDeformation()!;
      root.position = const Vec3(100, 20, 30);
      expect(mesh.captureDeformation()!.matrices, orderedEquals(pose.matrices));
      root.quaternion = Quat.axisAngle(const Vec3(0, 1, 0), .37);
      root.scale = const Vec3(-1.2, .7, 1.3);
      expect(mesh.captureDeformation(), same(pose));
      root.quaternion = Quat.identity;
      root.scale = Vec3.one;
      mesh.position = const Vec3(10, 0, 0);
      expect(mesh.vertexPosition(2).x, closeTo(-11, 1e-9));
      expect(
        mesh.worldMatrix
            .toVectorMath()
            .transform3(mesh.vertexPosition(2).toVectorMath())
            .x,
        closeTo(99, 1e-9),
      );
    },
  );
  test(
    'shared morph geometry keeps mesh weights independent and snapshots immutable',
    () {
      final input = Float32List.fromList([1, 0, 0, 1, 0, 0, 1, 0, 0]);
      final target = MorphTarget(positions: input, name: 'slide');
      input[0] = 99;
      final geometry = strip(targets: [target]);
      final a = Mesh(geometry, UnlitMaterial()),
          b = Mesh(geometry, UnlitMaterial());
      a.morphWeights = [-.5];
      expect(a.vertexPosition(0), const Vec3(-.5, 0, 0));
      expect(b.vertexPosition(0), Vec3.zero);
      final snapshot = a.captureDeformation()!;
      final revision = a.revision;
      a.setMorphWeight(0, -.5);
      expect(a.revision, revision);
      a.morphWeights = [2];
      expect(a.vertexPosition(0), const Vec3(2, 0, 0));
      expect(snapshot.vertexPosition(0), const Vec3(-.5, 0, 0));
      expect(() => a.morphWeights = [double.nan], throwsArgumentError);
      expect(() => a.morphWeights = [1, 2], throwsArgumentError);
      expect(a.morphWeights, [2]);
      expect(() => target.positions![0] = 100, throwsUnsupportedError);
    },
  );
  test(
    'skin and morph admission reject malformed bindings and missing attributes',
    () {
      final joint = Bone();
      expect(
        () => Skin(joints: [], inverseBindMatrices: []),
        throwsArgumentError,
      );
      expect(
        () => Skin(
          joints: [joint, joint],
          inverseBindMatrices: [Mat4.identity(), Mat4.identity()],
        ),
        throwsArgumentError,
      );
      expect(
        () => Skin(joints: [joint], inverseBindMatrices: []),
        throwsArgumentError,
      );
      expect(
        () => Skin(
          joints: [joint],
          inverseBindMatrices: [Mat4(List.filled(16, 0))],
        ),
        throwsArgumentError,
      );
      expect(
        () => Skin.fromBindPose(joints: List.generate(257, (_) => Bone())),
        throwsArgumentError,
      );
      expect(
        () => SkinnedMesh(
          BoxGeometry(),
          UnlitMaterial(),
          skin: Skin.fromBindPose(joints: [joint]),
        ),
        throwsArgumentError,
      );
      expect(
        () => SkinnedMesh(
          strip(),
          UnlitMaterial(),
          skin: Skin.fromBindPose(joints: [joint]),
        ),
        throwsArgumentError,
      );
      expect(() => MorphTarget(), throwsArgumentError);
      expect(
        () => MorphTarget(positions: Float32List.fromList([1, 2])),
        throwsArgumentError,
      );
      expect(
        () => strip(targets: [MorphTarget(positions: Float32List(6))]),
        throwsArgumentError,
      );
      expect(
        () => strip(
          targets: List.generate(
            65,
            (_) => MorphTarget(positions: Float32List(9)),
          ),
        ),
        throwsArgumentError,
      );
    },
  );
}
