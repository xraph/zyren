import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:test/test.dart';

void main() {
  test(
    'typed layouts reject mismatched counts and invalid tangent handedness',
    () {
      final attributes = {
        VertexSemantic.position: VertexAttribute(
          Float32List.fromList([0, 0, 0, 1, 0, 0, 0, 1, 0]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.normal: VertexAttribute(
          Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
          format: VertexFormat.float32x3,
        ),
        VertexSemantic.tangent: VertexAttribute(
          Float32List.fromList([1, 0, 0, -1, 1, 0, 0, -1, 1, 0, 0, -1]),
          format: VertexFormat.float32x4,
        ),
      };
      final geometry = BufferGeometry.fromAttributes(
        attributes: attributes,
        indices: [0, 1, 2],
        dynamic: true,
      );
      expect(geometry.vertexCount, 3);
      expect(
        () => geometry.updateAttribute(
          VertexSemantic.tangent,
          Float32List.fromList([1, 0, 0, 0]),
        ),
        throwsArgumentError,
      );
      expect(
        () => BufferGeometry.fromAttributes(
          attributes: {
            ...attributes,
            VertexSemantic.normal: VertexAttribute(
              Float32List.fromList([0, 0, 1]),
              format: VertexFormat.float32x3,
            ),
          },
          indices: [0, 1, 2],
        ),
        throwsArgumentError,
      );
      expect(
        () => VertexAttribute(Uint16List(4), format: VertexFormat.float32x4),
        throwsArgumentError,
      );
    },
  );
  test('dynamic ranges own input and preserve already captured frames', () {
    final geometry = PlaneGeometry(dynamic: true);
    final scene = Scene()..add(Mesh(geometry, UnlitMaterial()));
    final captured = FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    final id = geometry.id;
    final revision = geometry.revision;
    final input = Float32List.fromList([2, 3, 4]);
    geometry.updateAttribute(VertexSemantic.position, input, firstVertex: 1);
    input[0] = 99;
    expect(geometry.id, id);
    expect(geometry.revision, greaterThan(revision));
    expect(geometry.positions.sublist(3, 6), [2, 3, 4]);
    expect(() => geometry.positions[3] = 0, throwsUnsupportedError);
    final old = (captured.toNativePacket()['geometries'] as List).single as Map;
    expect((old['positions'] as List)[1], [.5, -.5, 0]);
  });
  test('invalid updates are atomic and static geometry rejects edits', () {
    final geometry = BoxGeometry(dynamic: true);
    final revision = geometry.revision;
    final before = geometry.positions.toList();
    expect(
      () => BoxGeometry().updateAttribute(
        VertexSemantic.position,
        Float32List(3),
      ),
      throwsStateError,
    );
    expect(
      () => geometry.updateAttribute(
        VertexSemantic.position,
        Float32List(3),
        firstVertex: geometry.vertexCount,
      ),
      throwsRangeError,
    );
    expect(
      () => geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([double.nan, 0, 0]),
      ),
      throwsArgumentError,
    );
    expect(
      () => geometry.updateAttribute(VertexSemantic.normal, Float32List(3)),
      throwsArgumentError,
    );
    expect(
      () => geometry.updateAttribute(VertexSemantic.position, Float32List(2)),
      throwsArgumentError,
    );
    expect(
      () => geometry.updateAttribute(VertexSemantic.position, Uint32List(3)),
      throwsArgumentError,
    );
    expect(
      () => geometry.updateAttribute(VertexSemantic.uv1, Float32List(2)),
      throwsArgumentError,
    );
    expect(geometry.positions, before);
    expect(geometry.revision, revision);
  });
  test(
    'an edit invalidates every scene sharing geometry and batches notifications',
    () async {
      final geometry = PlaneGeometry(dynamic: true);
      final first = Scene()..add(Mesh(geometry, UnlitMaterial()));
      final second = Scene()..add(Mesh(geometry, UnlitMaterial()));
      final a = <int>[], b = <int>[];
      final subscriptions = [
        first.changes.listen(a.add),
        second.changes.listen(b.add),
      ];
      await Future<void>.delayed(Duration.zero);
      a.clear();
      b.clear();
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([-1, -1, 0]),
      );
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([1, -1, 0]),
        firstVertex: 1,
      );
      await Future<void>.delayed(Duration.zero);
      expect(a, hasLength(1));
      expect(b, hasLength(1));
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
    },
  );
  test('dirty ranges merge and each view advances only after acceptance', () {
    final geometry = PlaneGeometry(dynamic: true);
    final mesh = Mesh(geometry, UnlitMaterial());
    final scene = Scene()..add(mesh);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    final first = ScenePacketEncoder(viewId: 1),
        second = ScenePacketEncoder(viewId: 2);
    first.accept(first.encode(capture()));
    second.accept(second.encode(capture()));
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([-1, -1, 0]),
    );
    geometry.updateAttribute(
      VertexSemantic.normal,
      Float32List.fromList([0, 1, 0]),
    );
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([1, -1, 0]),
      firstVertex: 1,
    );
    final changed = first.encode(capture());
    // Two vertices in the native interleaved position/normal buffer, once each.
    expect(changed.uploadedBytes, 48);
    expect(first.encode(capture()).uploadedBytes, 48);
    first.accept(first.encode(capture()));
    expect(first.encode(capture()).uploadedBytes, 0);
    expect(second.encode(capture()).uploadedBytes, 48);
    mesh.visible = false;
    second.accept(second.encode(capture()));
    geometry.updateAttribute(
      VertexSemantic.uv0,
      Float32List.fromList([.25, .5]),
    );
    second.accept(second.encode(capture()));
    mesh.visible = true;
    expect(second.encode(capture()).uploadedBytes, 64);
  });
  test('a lagging view falls back to a full bounded snapshot', () {
    final geometry = BoxGeometry(dynamic: true);
    final scene = Scene()..add(Mesh(geometry, UnlitMaterial()));
    final encoder = ScenePacketEncoder(viewId: 1);
    FrameSubmission capture() => FrameSubmission.capture(
      scene: scene,
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    encoder.accept(encoder.encode(capture()));
    for (var i = 1; i <= 80; i++) {
      geometry.updateAttribute(
        VertexSemantic.position,
        Float32List.fromList([i.toDouble(), 0, 0]),
      );
    }
    expect(geometry.capture().history, hasLength(64));
    final latest = encoder.encode(capture());
    expect(latest.uploadedBytes, 1104);
    encoder.accept(latest);
    expect(encoder.encode(capture()).uploadedBytes, 0);
    final revision = geometry.revision;
    geometry.updateAttribute(
      VertexSemantic.position,
      Float32List.fromList([80, 0, 0]),
    );
    expect(geometry.revision, revision);
  });
}
