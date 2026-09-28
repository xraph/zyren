import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
export '../../zyren_gltf/test/support/fixtures.dart'
    show triangleModel, texturedModel;

Map<String, Object?> tile({
  String? uri,
  String? refine,
  double error = 0,
  List<Map<String, Object?>> children = const [],
  List<double>? transform,
}) => {
  'boundingVolume': {
    'sphere': [0, 0, 0, 10],
  },
  'geometricError': error,
  if (uri != null) 'content': {'uri': uri},
  'refine': ?refine,
  if (children.isNotEmpty) 'children': children,
  'transform': ?transform,
};
Uint8List tilesetBytes(Map<String, Object?> root, {String version = '1.1'}) =>
    Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'asset': {'version': version},
          'geometricError': 1000,
          'root': root,
        }),
      ),
    );

class MemoryResolver implements ByteSourceResolver {
  final Map<String, Uint8List> files;
  final reads = <String>[];
  Future<void> Function(Uri, SourceReadContext)? beforeRead;
  MemoryResolver(this.files);
  @override
  Future<ResolvedSource> read(Uri uri, SourceReadContext context) async {
    reads.add(uri.path);
    await beforeRead?.call(uri, context);
    final data = files[uri.path];
    if (data == null) throw StateError('Fixture unavailable');
    return ResolvedSource(effectiveUri: uri, bytes: data);
  }
}

Uint8List b3dm(Uint8List glb, {List<double>? rtc, bool binaryRtc = false}) {
  final json = utf8.encode(
    jsonEncode({
      'BATCH_LENGTH': 0,
      if (rtc != null) 'RTC_CENTER': binaryRtc ? {'byteOffset': 0} : rtc,
    }),
  );
  final ftLength = ((28 + json.length + 7) & ~7) - 28;
  final binLength = binaryRtc ? 16 : 0;
  final start = 28 + ftLength + binLength;
  final bytes = Uint8List((start + glb.length + 7) & ~7),
      b = ByteData.sublistView(bytes);
  for (final (at, n) in [
    (0, 0x6d643362),
    (4, 1),
    (8, bytes.length),
    (12, ftLength),
    (16, binLength),
  ]) {
    b.setUint32(at, n, Endian.little);
  }
  bytes.fillRange(28, 28 + ftLength, 32);
  bytes.setRange(28, 28 + json.length, json);
  if (binaryRtc) {
    for (var i = 0; i < 3; i++) {
      b.setFloat32(28 + ftLength + i * 4, rtc![i], Endian.little);
    }
  }
  bytes.setRange(start, start + glb.length, glb);
  return bytes;
}
