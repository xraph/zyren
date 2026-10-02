part of '../zyren_3d_tiles.dart';

/// Scope-owned content template. Instances use ordinary core meshes and maps.
final class TileModel3D {
  final ModelAsset _model;
  final Vec3 _rtc;
  final ModelPropertyTable? _batch;
  final int decodedBytes, residentBytes;
  const TileModel3D._(
    this._model,
    this._rtc,
    this._batch,
    this.decodedBytes,
    this.residentBytes,
  );
  String? get copyright => _model.copyright;
  TileModelInstance3D instantiate({Mat4? transform}) {
    final model = _model.instantiate();
    final root = TileModelInstance3D._(
      transform ?? Mat4.identity(),
      model,
      _model.propertyTables,
      _batch,
    );
    final rtc = Group()..position = _rtc;
    final axis = Group()..rotateX(math.pi / 2);
    root.add(rtc).add(axis).add(model);
    return root;
  }
}

class _TransformGroup extends Group {
  final Mat4 _matrix;
  _TransformGroup(this._matrix);
  @override
  Mat4 get localMatrix => _matrix;
}

class _ContentLoader extends AssetLoader<TileModel3D> {
  final GltfOptions options;
  const _ContentLoader(this.options);
  @override
  Future<DecodedAsset<TileModel3D>> decode(
    ResolvedSource source,
    AssetDecodeContext context,
  ) async {
    var bytes = source.bytes, rtc = Vec3.zero;
    ModelPropertyTable? batch;
    if (bytes.length >= 4 &&
        ByteData.sublistView(bytes).getUint32(0, Endian.little) == 0x6d643362) {
      final decoded = _b3dm(bytes, context, options.limits);
      bytes = decoded.$1;
      rtc = decoded.$2;
      batch = decoded.$3;
    } else if (bytes.length < 4 ||
        ByteData.sublistView(bytes).getUint32(0, Endian.little) != 0x46546c67) {
      // JSON glTF is allowed; a nested tileset needs a different traversal path.
      final json = _json(
        bytes,
        options.limits.maxJsonBytes,
        options.limits.maxJsonDepth,
      );
      if (json.containsKey('root')) _unsupported();
    }
    final decoded = await Gltf.uri(source.effectiveUri, options: options).loader
        .decode(
          ResolvedSource(
            effectiveUri: source.effectiveUri,
            bytes: bytes,
            mediaType: source.mediaType,
          ),
          context,
        );
    // The template retains every decoded mesh, including unused meshes and
    // alternate scenes. The decoder's ledger covers all of them, and can
    // conservatively include temporary decode payloads too.
    final decodedReservation = context.decodedBytes;
    return DecodedAsset(
      create: () {
        final model = decoded.create();
        try {
          final instance = model.instantiate();
          TileModelInstance3D._(
            Mat4.identity(),
            instance,
            model.propertyTables,
            batch,
          );
          final size = _payload(instance);
          return TileModel3D._(
            model,
            rtc,
            batch,
            math.max(decodedReservation, size.$1),
            size.$2,
          );
        } catch (_) {
          decoded.release(model);
          rethrow;
        }
      },
      release: (model) => decoded.release(model._model),
      dispose: decoded.dispose,
    );
  }
}

(Uint8List, Vec3, ModelPropertyTable) _b3dm(
  Uint8List bytes,
  AssetDecodeContext context,
  GltfLimits limits,
) {
  if (bytes.length < 28 || bytes.length % 8 != 0) _invalid();
  final b = ByteData.sublistView(bytes);
  int uint(int at) => b.getUint32(at, Endian.little);
  if (uint(4) != 1) _unsupported();
  if (uint(8) != bytes.length) _invalid();
  final fj = uint(12), fb = uint(16), bj = uint(20), bb = uint(24);
  final start = 28 + fj + fb + bj + bb;
  if (fj == 0 ||
      bj == 0 && bb != 0 ||
      start > bytes.length - 12 ||
      start % 8 != 0) {
    _invalid();
  }
  final jsonLimit = limits.maxJsonBytes < 1024 * 1024
      ? limits.maxJsonBytes
      : 1024 * 1024;
  final depthLimit = limits.maxJsonDepth < 32 ? limits.maxJsonDepth : 32;
  final feature = _json(
    Uint8List.sublistView(bytes, 28, 28 + fj),
    jsonLimit,
    depthLimit,
  );
  var properties = <String, dynamic>{};
  if (bj > 0) {
    properties = _json(
      Uint8List.sublistView(bytes, 28 + fj + fb, 28 + fj + fb + bj),
      jsonLimit,
      depthLimit,
    );
  }
  final bin = Uint8List.sublistView(bytes, 28 + fj, 28 + fj + fb);
  List<double> values(Object? value, int count, {bool integer = false}) {
    if (value is List) return _numbers(value, count);
    final offset = _object(value)['byteOffset'];
    final length = count * 4;
    if (offset is! int ||
        offset < 0 ||
        offset % 4 != 0 ||
        offset > bin.length - length) {
      _invalid();
    }
    final data = ByteData.sublistView(bin);
    return [
      for (var i = 0; i < count; i++)
        integer
            ? data.getUint32(offset + i * 4, Endian.little).toDouble()
            : data.getFloat32(offset + i * 4, Endian.little),
    ];
  }

  final batch = feature['BATCH_LENGTH'];
  final batchLength = batch is int
      ? batch
      : values(batch, 1, integer: true).single;
  if (batchLength < 0 || batchLength > 0xffffffff) _invalid();
  var rtc = Vec3.zero;
  if (feature.containsKey('RTC_CENTER')) {
    rtc = Vec3.array(values(feature['RTC_CENTER'], 3));
  }
  if (!rtc.isFinite || rtc.storage.any((v) => v.abs() > 1e15)) _invalid();
  if (uint(start) != 0x46546c67) _invalid();
  final length = uint(start + 8);
  if (length < 12 ||
      length > bytes.length - start ||
      bytes.length - start - length > 7 ||
      bytes.skip(start + length).any((v) => v != 0)) {
    _invalid();
  }
  context.reserveDecodedBytes((fj + bj) * 2 + bb);
  final table = _batchProperties(
    properties,
    Uint8List.sublistView(bytes, start - bb, start),
    batchLength.toInt(),
    context,
    limits,
  );
  return (Uint8List.sublistView(bytes, start, start + length), rtc, table);
}

(int, int) _payload(Object3D root) {
  final geometries = <BufferGeometry>{}, images = <TextureImage>{};
  void visit(Object3D node) {
    if (node is Mesh) {
      geometries.add(node.geometry);
      final material = node.material;
      for (final map in [
        material.colorMap,
        if (material is StandardMaterial) ...[
          material.normalMap,
          material.metallicRoughnessMap,
          material.occlusionMap,
          material.emissiveMap,
        ],
      ]) {
        if (map != null) images.add(map.image);
      }
    }
    for (final child in node.children) {
      visit(child);
    }
  }

  visit(root);
  var cpu = 0, gpu = 0;
  for (final geometry in geometries) {
    cpu +=
        geometry.indices.length * geometry.indexFormat.bytesPerIndex +
        geometry.attributes.values.fold(0, (n, a) => n + a.data.lengthInBytes);
    gpu += geometry.capture().gpuByteLength;
  }
  for (final image in images) {
    cpu += image.levels.fold(0, (n, l) => n + l.length);
    gpu += image.descriptor.byteLength;
  }
  return (cpu, gpu);
}
