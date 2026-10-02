import 'dart:convert';
import 'dart:typed_data';

import 'package:zyren/zyren.dart';
import 'package:zyren_pipeline/zyren_pipeline.dart';

/// A reproducible source with an external buffer and a source-owned node ID.
final class TriangleSource implements ByteSourceResolver {
  static final modelUri = Uri.parse('memory:///triangle/model.gltf');
  static final bufferUri = modelUri.resolve('positions.bin');
  final Map<Uri, Uint8List> files;
  TriangleSource({double width = 1})
    : files = {
        modelUri: Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'asset': {'version': '2.0'},
              'buffers': [
                {'uri': 'positions.bin', 'byteLength': 36},
              ],
              'bufferViews': [
                {'buffer': 0, 'byteLength': 36},
              ],
              'accessors': [
                {
                  'bufferView': 0,
                  'componentType': 5126,
                  'count': 3,
                  'type': 'VEC3',
                  'min': [0, 0, 0],
                  'max': [width, 1, 0],
                },
              ],
              'meshes': [
                {
                  'primitives': [
                    {
                      'attributes': {'POSITION': 0},
                    },
                  ],
                },
              ],
              'nodes': [
                {
                  'name': 'Triangle',
                  'mesh': 0,
                  'extras': {'sourceId': 'part:triangle'},
                },
              ],
              'scenes': [
                {
                  'nodes': [0],
                },
              ],
              'scene': 0,
            }),
          ),
        ),
        bufferUri: _positions(width),
      };

  List<PipelineSource> get sources => [
    PipelineSource(sourceId: 'model', revision: 'drawing-r1', uri: modelUri),
    PipelineSource(sourceId: 'positions', revision: 'mesh-r1', uri: bufferUri),
  ];

  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    context.cancellation.throwIfCancelled();
    final bytes = files[uri];
    if (bytes == null) {
      throw AssetLoadException(
        AssetLoadError.sourceUnavailable,
        'Missing source.',
        sourceUri: uri,
      );
    }
    context.reportProgress(bytes.length, bytes.length);
    return ResolvedSource(effectiveUri: uri, bytes: bytes);
  }
}

Uint8List _positions(double width) {
  final bytes = ByteData(36);
  final values = [0.0, 0.0, 0.0, width, 0.0, 0.0, 0.0, 1.0, 0.0];
  for (var i = 0; i < values.length; i++) {
    bytes.setFloat32(i * 4, values[i], Endian.little);
  }
  return bytes.buffer.asUint8List();
}
