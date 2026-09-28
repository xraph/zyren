import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// Synthetic buildings served over loopback HTTP. No provider credentials.
final class Tiles3DFixture {
  final HttpServer _server;
  bool failChildren = false;
  int requests = 0;
  Tiles3DFixture._(this._server);
  Uri get uri => Uri.parse('http://127.0.0.1:${_server.port}/tileset');
  Future<void> close() => _server.close(force: true);
  static Future<Tiles3DFixture> start({
    Duration latency = const Duration(milliseconds: 40),
    bool implicitTiling = false,
  }) async {
    final fixture = Tiles3DFixture._(
      await HttpServer.bind(InternetAddress.loopbackIPv4, 0),
    );
    final files = tiles3DFixtureFiles(implicitTiling: implicitTiling);
    fixture._server.listen((request) async {
      try {
        await Future<void>.delayed(latency);
        if (request.uri.path != '/tileset') fixture.requests++;
        final bytes = files[request.uri.path];
        if (fixture.failChildren && request.uri.path.startsWith('/child')) {
          request.response.statusCode = 503;
        } else if (bytes == null) {
          request.response.statusCode = 404;
        } else {
          request.response.add(bytes);
        }
        await request.response.close();
      } on SocketException {
        /* A cancelled request can close its socket. */
      } on HttpException {
        /* A closed fixture cannot complete the response. */
      }
    });
    return fixture;
  }
}

Map<String, Uint8List> tiles3DFixtureFiles({bool implicitTiling = false}) {
  final files = <String, Uint8List>{
    '/parent': _box(165, 12, [.25, .5, .75, 1]),
  };
  final children = <Map<String, Object?>>[];
  var i = 0;
  for (final (x, y) in [
    (-70.0, -70.0),
    (70.0, -70.0),
    (-70.0, 70.0),
    (70.0, 70.0),
  ]) {
    final glb = _box(28, 55 + i * 18, [.75, .65 + i * .04, .4, 1]);
    files['/child$i'] = _b3dm(glb, [x, y, 0]);
    files['/child/1/${i % 2}/${i ~/ 2}'] = files['/child$i']!;
    children.add({
      'boundingVolume': {
        'sphere': [x, y, 50, 85],
      },
      'geometricError': 0,
      'content': {'uri': 'child$i'},
    });
    i++;
  }
  const volume = {
    'box': [0, 0, 50, 180, 0, 0, 0, 180, 0, 0, 0, 85],
  };
  files['/buildings'] = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'asset': {'version': '1.1'},
        'geometricError': 1000,
        'root': {
          'boundingVolume': volume,
          'geometricError': 0,
          if (!implicitTiling) 'children': children,
          if (implicitTiling) ...{
            'content': {'uri': 'child/{level}/{x}/{y}'},
            'implicitTiling': {
              'subdivisionScheme': 'QUADTREE',
              'availableLevels': 2,
              'subtreeLevels': 2,
              'subtrees': {'uri': 'subtree/{level}/{x}/{y}'},
            },
          },
        },
      }),
    ),
  );
  files['/subtree/0/0/0'] = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'buffers': [
          {'uri': '../../../availability', 'byteLength': 1},
        ],
        'bufferViews': [
          {'buffer': 0, 'byteOffset': 0, 'byteLength': 1},
        ],
        'tileAvailability': {'constant': 1},
        'contentAvailability': [
          {'bitstream': 0, 'availableCount': 4},
        ],
        'childSubtreeAvailability': {'constant': 0},
      }),
    ),
  );
  files['/availability'] = Uint8List.fromList([0x1e]);
  files['/tileset'] = Uint8List.fromList(
    utf8.encode(
      jsonEncode({
        'asset': {'version': '1.1'},
        'geometricError': 1000,
        'root': {
          // East, north, up frame at longitude/latitude zero, in ECEF metres.
          'transform': [0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 6378137, 0, 0, 1],
          'boundingVolume': {
            'box': [0, 0, 50, 180, 0, 0, 0, 180, 0, 0, 0, 85],
          },
          'geometricError': 15,
          'refine': 'REPLACE',
          'content': {'uri': 'parent'},
          'children': [
            {
              'boundingVolume': volume,
              'geometricError': 0,
              'content': {'uri': 'buildings'},
            },
          ],
        },
      }),
    ),
  );
  return files;
}

Uint8List _box(double halfWidth, double height, List<double> color) {
  final vertices = <double>[];
  final corners = [
    [-halfWidth, 0.0, -halfWidth],
    [halfWidth, 0.0, -halfWidth],
    [halfWidth, 0.0, halfWidth],
    [-halfWidth, 0.0, halfWidth],
    [-halfWidth, height, -halfWidth],
    [halfWidth, height, -halfWidth],
    [halfWidth, height, halfWidth],
    [-halfWidth, height, halfWidth],
  ];
  for (final id in [
    0,
    2,
    1,
    0,
    3,
    2,
    4,
    5,
    6,
    4,
    6,
    7,
    0,
    1,
    5,
    0,
    5,
    4,
    1,
    2,
    6,
    1,
    6,
    5,
    2,
    3,
    7,
    2,
    7,
    6,
    3,
    0,
    4,
    3,
    4,
    7,
  ]) {
    vertices.addAll(corners[id]);
  }
  final binary = ByteData(vertices.length * 4);
  for (var i = 0; i < vertices.length; i++) {
    binary.setFloat32(i * 4, vertices[i], Endian.little);
  }
  final json = utf8.encode(
    jsonEncode({
      'asset': {'version': '2.0'},
      'buffers': [
        {'byteLength': binary.lengthInBytes},
      ],
      'bufferViews': [
        {'buffer': 0, 'byteLength': binary.lengthInBytes},
      ],
      'accessors': [
        {
          'bufferView': 0,
          'componentType': 5126,
          'count': vertices.length ~/ 3,
          'type': 'VEC3',
          'min': [-halfWidth, 0, -halfWidth],
          'max': [halfWidth, height, halfWidth],
        },
      ],
      'materials': [
        {
          'pbrMetallicRoughness': {
            'baseColorFactor': color,
            'metallicFactor': 0,
            'roughnessFactor': .8,
          },
          'doubleSided': true,
        },
      ],
      'meshes': [
        {
          'primitives': [
            {
              'attributes': {'POSITION': 0},
              'material': 0,
            },
          ],
        },
      ],
      'nodes': [
        {'mesh': 0},
      ],
      'scenes': [
        {
          'nodes': [0],
        },
      ],
      'scene': 0,
    }),
  );
  final jsonLength = (json.length + 3) & ~3;
  final bytes = Uint8List(28 + jsonLength + binary.lengthInBytes),
      data = ByteData.sublistView(bytes);
  for (final (at, n) in [
    (0, 0x46546c67),
    (4, 2),
    (8, bytes.length),
    (12, jsonLength),
    (16, 0x4e4f534a),
    (20 + jsonLength, binary.lengthInBytes),
    (24 + jsonLength, 0x004e4942),
  ]) {
    data.setUint32(at, n, Endian.little);
  }
  bytes.fillRange(20, 20 + jsonLength, 32);
  bytes.setRange(20, 20 + json.length, json);
  bytes.setRange(28 + jsonLength, bytes.length, binary.buffer.asUint8List());
  return bytes;
}

Uint8List _b3dm(Uint8List glb, List<double> rtc) {
  final json = utf8.encode(jsonEncode({'BATCH_LENGTH': 0, 'RTC_CENTER': rtc}));
  final length = ((28 + json.length + 7) & ~7) - 28, start = 28 + length;
  final bytes = Uint8List((start + glb.length + 7) & ~7),
      data = ByteData.sublistView(bytes);
  for (final (at, n) in [
    (0, 0x6d643362),
    (4, 1),
    (8, bytes.length),
    (12, length),
  ]) {
    data.setUint32(at, n, Endian.little);
  }
  bytes.fillRange(28, start, 32);
  bytes.setRange(28, 28 + json.length, json);
  bytes.setRange(start, start + glb.length, glb);
  return bytes;
}
