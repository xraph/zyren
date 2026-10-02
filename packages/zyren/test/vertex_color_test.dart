import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'package:zyren/rendering.dart';
import 'package:test/test.dart';

BufferGeometry coloredGeometry({
  VertexFormat format = VertexFormat.unorm8x4,
  TypedData? values,
}) => BufferGeometry.fromAttributes(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.color: VertexAttribute(
      values ??
          Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 128, 0, 0, 255, 0]),
      format: format,
    ),
  },
  indices: [0, 1, 2],
  dynamic: true,
);
void main() {
  test(
    'RGB and byte colors normalize once and keep captured revisions immutable',
    () {
      final rgb = coloredGeometry(
        format: VertexFormat.float32x3,
        values: Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1]),
      );
      expect(rgb.colors, [1, 0, 0, 1, 0, 1, 0, 1, 0, 0, 1, 1]);
      expect(identical(rgb.colors, rgb.colors), isTrue);
      final bytes = coloredGeometry();
      final frozen = bytes.capture();
      expect(bytes.colors![7], closeTo(128 / 255, 1e-7));
      expect(() => bytes.colors![0] = 0, throwsUnsupportedError);
      final input = Uint8List.fromList([64, 128, 255, 0]);
      bytes.updateAttribute(VertexSemantic.color, input, firstVertex: 1);
      input[0] = 255;
      expect(bytes.colors![4], closeTo(64 / 255, 1e-7));
      expect(frozen.colors!.sublist(4, 8), [
        0,
        1,
        closeTo(0, 1e-7),
        closeTo(128 / 255, 1e-7),
      ]);
      final revision = rgb.revision;
      for (final value in [-.01, 1.01, double.nan]) {
        expect(
          () => rgb.updateAttribute(
            VertexSemantic.color,
            Float32List.fromList([value, 0, 0]),
          ),
          throwsArgumentError,
        );
      }
      expect(rgb.revision, revision);
    },
  );
  test('built-in material copies retain the opt-in flag and neutral tint', () {
    final materials = <MeshMaterial>[
      UnlitMaterial(vertexColors: true).copyWith(opacity: .5),
      DiffuseMaterial(vertexColors: true).copyWith(opacity: .5),
      StandardMaterial(vertexColors: true).copyWith(opacity: .5),
      LineMaterial(vertexColors: true).copyWith(opacity: .5),
      PointsMaterial(vertexColors: true).copyWith(opacity: .5),
    ];
    for (final material in materials) {
      expect(material.vertexColors, isTrue);
      expect(material.color, const Color3(1, 1, 1));
    }
    expect(UnlitMaterial().vertexColors, isFalse);
    expect(
      UnlitMaterial(
        vertexColors: true,
      ).copyWith(vertexColors: false).vertexColors,
      isFalse,
    );
    expect(
      () => FrameSubmission.capture(
        scene: Scene()..add(Mesh(PlaneGeometry(), materials.first)),
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      ),
      throwsArgumentError,
    );
  });
  test(
    'color deltas charge normalized GPU rows and preserve older packets',
    () {
      for (final format in [VertexFormat.unorm8x4, VertexFormat.float32x3]) {
        final geometry = coloredGeometry(
          format: format,
          values: format == VertexFormat.float32x3
              ? Float32List.fromList([1, 0, 0, 0, 1, 0, 0, 0, 1])
              : null,
        );
        final mesh = Mesh(geometry, UnlitMaterial(vertexColors: true));
        final scene = Scene()..add(mesh);
        FrameSubmission capture() => FrameSubmission.capture(
          scene: scene,
          camera: PerspectiveCamera(),
          size: PhysicalSize(31, 31),
        );
        final encoder = ScenePacketEncoder(viewId: 1);
        final frozen = capture();
        encoder.accept(encoder.encode(frozen));
        geometry.updateAttribute(
          VertexSemantic.color,
          format == VertexFormat.float32x3
              ? Float32List.fromList([.25, .5, .75])
              : Uint8List.fromList([64, 128, 192, 255]),
          firstVertex: 2,
        );
        final patch = encoder.encode(capture());
        expect(patch.uploadedBytes, 16);
        expect(
          (frozen.toNativePacket()['geometries'] as List).single['colors'][2],
          [0, 0, 1, format == VertexFormat.float32x3 ? 1 : 0],
        );
        encoder.accept(patch);
        expect(encoder.encode(capture()).uploadedBytes, 0);
        mesh.material = UnlitMaterial(vertexColors: false);
        final changed = encoder.encode(capture());
        expect(changed.changedMeshes, 1);
        expect(changed.uploadedBytes, 0);
      }
    },
  );
  test('uncolored scenes keep the prior packet version', () {
    final frame = FrameSubmission.capture(
      scene: Scene()..add(Mesh(PlaneGeometry(), UnlitMaterial())),
      camera: PerspectiveCamera(),
      size: PhysicalSize(31, 31),
    );
    expect(
      ByteData.sublistView(
        ScenePacketEncoder(viewId: 1).encode(frame).bytes,
      ).getUint32(4, Endian.little),
      18,
    );
  });
  test(
    'color geometry reaches native packets without enabling material tint',
    () {
      final geometry = coloredGeometry();
      final frame = FrameSubmission.capture(
        scene: Scene()..add(Mesh(geometry, UnlitMaterial())),
        camera: PerspectiveCamera(),
        size: PhysicalSize(31, 31),
      );
      final packet = ScenePacketEncoder(viewId: 1).encode(frame);
      expect(
        ByteData.sublistView(packet.bytes).getUint32(4, Endian.little),
        23,
      );
      expect(packet.uploadedBytes, 3 * 24 + 3 * 16 + 3 * 4);
    },
  );
}
