import 'dart:math' as math;
import 'dart:typed_data';
import 'package:gpu3d/gpu3d.dart';
import 'package:gpu3d/rendering.dart';
import 'package:gpu3d_gltf/gpu3d_gltf.dart';
import 'package:gpu3d_native/gpu3d_native.dart';
import 'package:test/test.dart';
import '../../../gpu3d_gltf/test/support/fixtures.dart' show editModel;
import '../../../gpu3d_gltf/test/support/pbr_fixture.dart';
import 'deformation_checks.dart' show deformedReference;

final class _Source implements ByteSourceResolver {
  final Uint8List bytes;
  _Source(this.bytes);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async =>
      ResolvedSource(effectiveUri: uri, bytes: bytes);
}

Future<void> verifyMorphTangents(NativeGpuBackend backend) async {
  final camera = PerspectiveCamera(position: const Vec3(0, 0, 3));
  Future<ReadbackOutput> draw(Mesh mesh) async =>
      await backend.render(
            FrameSubmission.capture(
              scene: Scene()
                ..background = const Color3(0, 0, 0)
                ..add(mesh)
                ..add(
                  DirectionalLight(intensity: 2)
                    ..lookAt(const Vec3(-.2, .7, -1)),
                ),
              camera: camera,
              size: PhysicalSize(67, 67),
            ),
          )
          as ReadbackOutput;
  int differingPixels(ReadbackOutput a, ReadbackOutput b) {
    var count = 0;
    for (var i = 0; i < a.image.pixels.length; i += 4) {
      if (List.generate(
        4,
        (c) => (a.image.pixels[i + c] - b.image.pixels[i + c]).abs(),
      ).any((d) => d > 2)) {
        count++;
      }
    }
    return count;
  }

  for (final flat in [false, true]) {
    for (final uvSet in [0, 1]) {
      final scope = AssetScope(
        services: AssetServices(
          resolver: _Source(_fixture(flat: flat, uvSet: uvSet)),
          imageDecoder: const NativeImageDecoder(),
          tangentGenerator: const NativeTangentGenerator(),
        ),
      );
      try {
        final asset = await scope.load(Gltf.asset('morph-normal.glb')).result;
        final instance = asset.instantiate();
        final mesh = instance.morphTargets[0]!.single;
        final g = mesh.geometry.capture();
        expect(
          g.morphTargets.single.tangents!.any((v) => v.abs() > .1),
          isTrue,
        );
        mesh.morphWeights = [1];
        final absolute = deformedReference(mesh);
        // Recompute from the absolute positions/normals/UVs, without targets.
        final expected = await const NativeTangentGenerator().generate(
          GeometryData(
            attributes: absolute.attributes,
            indices: absolute.indices,
          ),
          uvSet: uvSet,
        );
        final actualFrame = await draw(mesh);
        final referenceFrame = await draw(
          Mesh(BufferGeometry.fromData(expected), mesh.material),
        );
        expect(
          differingPixels(actualFrame, referenceFrame),
          0,
          reason: 'Full morph pose, flat=$flat, UV$uvSet',
        );

        final broken = BufferGeometry.fromAttributes(
          attributes: g.attributes,
          indices: g.indices,
          morphTargets: [
            MorphTarget(
              positions: g.morphTargets.single.positions,
              normals: g.morphTargets.single.normals,
              tangents: List.filled(g.layout.vertexCount * 3, 0),
            ),
          ],
        );
        final brokenFrame = await draw(
          Mesh(broken, mesh.material)..morphWeights = [1],
        );
        expect(
          differingPixels(brokenFrame, referenceFrame),
          greaterThan(50),
          reason: 'The fixture must detect omitted morph tangent deltas',
        );
        for (final weight in [-.3, .45]) {
          mesh.morphWeights = [weight];
          final reference = deformedReference(mesh);
          expect(
            differingPixels(
              await draw(mesh),
              await draw(Mesh(reference, mesh.material)),
            ),
            0,
          );
        }
      } finally {
        await scope.close();
      }
    }
  }
}

Uint8List _fixture({required bool flat, required int uvSet}) {
  final source = pbrModel(
    material: {
      'pbrMetallicRoughness': {
        'baseColorFactor': [.5, .5, .5, 1],
        'metallicFactor': 0,
      },
      'normalTexture': {'index': 4, 'texCoord': uvSet},
    },
  );
  late List<double> positions;
  var offset = 0;
  editModel(source, (root) {
    final primitive = (root['meshes'] as List).first['primitives'][0];
    final accessor =
        (root['accessors'] as List)[primitive['attributes']['POSITION']];
    final view = (root['bufferViews'] as List)[accessor['bufferView']];
    final header = ByteData.sublistView(source);
    final start =
        28 +
        header.getUint32(12, Endian.little) +
        (view['byteOffset'] as int? ?? 0);
    positions = [
      for (var i = 0; i < 12; i++)
        header.getFloat32(start + i * 4, Endian.little),
    ];
    offset = ((root['buffers'] as List).first['byteLength'] as int) + 3 & ~3;
  });
  final deltas = <double>[];
  for (var i = 0; i < positions.length; i += 3) {
    final x = positions[i], y = positions[i + 1];
    deltas.addAll([
      x * (math.cos(.6) - 1) - y * math.sin(.6),
      x * math.sin(.6) + y * (math.cos(.6) - 1),
      0,
    ]);
  }
  final binary = ByteData(deltas.length * 4);
  for (var i = 0; i < deltas.length; i++) {
    binary.setFloat32(i * 4, deltas[i], Endian.little);
  }
  return editModel(source, (root) {
    final mesh = (root['meshes'] as List).first;
    final primitive = mesh['primitives'][0];
    final attributes = primitive['attributes'] as Map;
    attributes.remove('TANGENT');
    if (flat) attributes.remove('NORMAL');
    if (uvSet == 1) attributes['TEXCOORD_1'] = attributes.remove('TEXCOORD_0');
    final views = root['bufferViews'] as List,
        accessors = root['accessors'] as List;
    primitive['targets'] = [
      {'POSITION': accessors.length},
    ];
    accessors.add({
      'bufferView': views.length,
      'componentType': 5126,
      'count': 4,
      'type': 'VEC3',
      'min': [
        for (var c = 0; c < 3; c++)
          [for (var i = c; i < 12; i += 3) deltas[i]].reduce(math.min),
      ],
      'max': [
        for (var c = 0; c < 3; c++)
          [for (var i = c; i < 12; i += 3) deltas[i]].reduce(math.max),
      ],
    });
    views.add({
      'buffer': 0,
      'byteOffset': offset,
      'byteLength': binary.lengthInBytes,
    });
    (root['scenes'] as List).first['nodes'] = [0];
  }, appendBinary: binary.buffer.asUint8List());
}
