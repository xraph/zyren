import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'checked.dart';
import 'limits.dart';

final class GltfDocument {
  final Map<String, Object?> root;
  final Uint8List? binary;
  final List<SceneIssue> issues;
  GltfDocument._(this.root, this.binary, this.issues);
  static GltfDocument parse(
    Uint8List bytes, {
    GltfLimits limits = const GltfLimits(),
    Set<String> supportedExtensions = const {},
  }) {
    limits.validate();
    try {
      Uint8List json = bytes;
      Uint8List? binary;
      if (bytes.length >= 4 &&
          ByteData.sublistView(bytes).getUint32(0, Endian.little) ==
              0x46546c67) {
        if (bytes.length < 20) {
          fail('glb.header', 'GLB header or first chunk is truncated.');
        }
        final data = ByteData.sublistView(bytes);
        if (data.getUint32(4, Endian.little) != 2) {
          fail(
            'glb.version',
            'Only GLB version 2 is supported.',
            AssetLoadError.unsupportedFeature,
          );
        }
        if (data.getUint32(8, Endian.little) != bytes.length) {
          fail('glb.length', 'GLB length does not match the source length.');
        }
        var offset = 12, chunk = 0;
        while (offset < bytes.length) {
          if (bytes.length - offset < 8) {
            fail('glb.chunks[$chunk]', 'Chunk header is truncated.');
          }
          final length = data.getUint32(offset, Endian.little),
              type = data.getUint32(offset + 4, Endian.little);
          if (length % 4 != 0 || length > bytes.length - offset - 8) {
            fail('glb.chunks[$chunk]', 'Chunk extent or alignment is invalid.');
          }
          final body = Uint8List.sublistView(
            bytes,
            offset + 8,
            offset + 8 + length,
          ).asUnmodifiableView();
          if (chunk == 0 && type != 0x4e4f534a) {
            fail('glb.chunks[0]', 'The first chunk must contain JSON.');
          }
          if (type == 0x4e4f534a) {
            if (chunk != 0) {
              fail(
                'glb.chunks[$chunk]',
                'The JSON chunk occurs more than once.',
              );
            }
            json = body;
          } else if (type == 0x004e4942) {
            if (chunk != 1) {
              fail(
                'glb.chunks[$chunk]',
                'The binary chunk must be the second chunk.',
              );
            }
            binary = body;
          }
          offset += 8 + length;
          chunk++;
        }
      }
      _preflight(json, limits);
      final root = object(jsonDecode(utf8.decode(json)), r'$');
      final asset = object(root['asset'], 'asset');
      final version = _version(asset['version'], 'asset.version');
      if (version.$1 != 2) {
        fail(
          'asset.version',
          'Only glTF 2.x assets are supported.',
          AssetLoadError.unsupportedFeature,
        );
      }
      if (asset.containsKey('minVersion')) {
        final minimum = _version(asset['minVersion'], 'asset.minVersion');
        if (minimum.$1 > 2 || minimum.$1 == 2 && minimum.$2 > 0) {
          fail(
            'asset.minVersion',
            'The asset requires a newer glTF version.',
            AssetLoadError.unsupportedFeature,
          );
        }
        if (minimum.$1 > version.$1 ||
            minimum.$1 == version.$1 && minimum.$2 > version.$2) {
          fail(
            'asset.minVersion',
            'Minimum version exceeds the asset version.',
          );
        }
      }
      var objects = 0;
      for (final key in [
        'accessors',
        'animations',
        'buffers',
        'bufferViews',
        'cameras',
        'images',
        'materials',
        'meshes',
        'nodes',
        'samplers',
        'scenes',
        'skins',
        'textures',
      ]) {
        if (!root.containsKey(key)) continue;
        final entries = array(root[key], key);
        if (entries.isEmpty) {
          fail(key, 'An optional object array must be omitted when empty.');
        }
        objects += entries.length;
        if (objects > limits.maxObjects) {
          fail(
            key,
            'Object count exceeds its limit.',
            AssetLoadError.limitExceeded,
          );
        }
        for (var i = 0; i < entries.length; i++) {
          object(entries[i], '$key[$i]');
        }
      }
      final used = root.containsKey('extensionsUsed')
          ? _extensions(root['extensionsUsed'], 'extensionsUsed')
          : <String>[];
      final required = root.containsKey('extensionsRequired')
          ? _extensions(root['extensionsRequired'], 'extensionsRequired')
          : <String>[];
      for (var i = 0; i < required.length; i++) {
        final name = required[i];
        if (!used.contains(name)) {
          fail(
            'extensionsRequired[$i]',
            'Required extension is absent from extensionsUsed.',
          );
        }
        if (!supportedExtensions.contains(name)) {
          fail(
            'extensionsRequired[$i]',
            'Required extension $name is unsupported.',
            AssetLoadError.unsupportedFeature,
          );
        }
      }
      final issues = <SceneIssue>[];
      for (var i = 0; i < used.length; i++) {
        if (!supportedExtensions.contains(used[i])) {
          issues.add(
            SceneIssue(
              code: 'gltf.unsupportedOptionalExtension',
              message: 'Optional extension ${used[i]} is not applied.',
              operation: 'load',
              resourceLabel: 'extensionsUsed[$i]',
              severity: IssueSeverity.warning,
            ),
          );
        }
      }
      return GltfDocument._(root, binary, List.unmodifiable(issues));
    } on AssetLoadException {
      rethrow;
    } on FormatException catch (error) {
      fail(r'$', 'Malformed glTF JSON: ${error.message}');
    }
  }
}

(int, int) _version(Object? value, String path) {
  final match = RegExp(
    r'^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$',
  ).firstMatch(string(value, path));
  if (match == null) fail(path, 'Expected a major.minor version.');
  final major = int.tryParse(match.group(1)!),
      minor = int.tryParse(match.group(2)!);
  if (major == null || minor == null) {
    fail(path, 'Version number is too large.');
  }
  return (major, minor);
}

List<String> _extensions(Object? value, String path) {
  final values = array(value, path);
  if (values.isEmpty || values.length > 128) {
    fail(path, 'Expected 1 to 128 extension names.');
  }
  final names = <String>[];
  for (var i = 0; i < values.length; i++) {
    final name = string(values[i], '$path[$i]');
    if (name.isEmpty || names.contains(name)) {
      fail('$path[$i]', 'Extension names must be nonempty and unique.');
    }
    names.add(name);
  }
  return names;
}

void _preflight(Uint8List bytes, GltfLimits limits) {
  if (bytes.length > limits.maxJsonBytes) {
    fail(r'$', 'JSON exceeds its byte limit.', AssetLoadError.limitExceeded);
  }
  final stack = <(int, Set<String>)>[];
  var tokens = 0, scalar = false;
  bool whitespace(int value) =>
      value == 0x20 || value == 0x09 || value == 0x0a || value == 0x0d;
  for (var i = 0; i < bytes.length; i++) {
    final value = bytes[i];
    if (value == 0x22) {
      tokens++;
      scalar = false;
      final start = i;
      for (i++; i < bytes.length && bytes[i] != 0x22; i++) {
        if (bytes[i] == 0x5c) i++;
      }
      if (i >= bytes.length) fail(r'$', 'JSON string is truncated.');
      var next = i + 1;
      while (next < bytes.length && whitespace(bytes[next])) {
        next++;
      }
      if (next < bytes.length &&
          bytes[next] == 0x3a &&
          stack.isNotEmpty &&
          stack.last.$1 == 0x7b) {
        final key =
            jsonDecode(utf8.decode(Uint8List.sublistView(bytes, start, i + 1)))
                as String;
        if (!stack.last.$2.add(key)) {
          fail(r'$', 'JSON object contains a duplicate property.');
        }
      }
    } else if (value == 0x7b || value == 0x5b) {
      tokens++;
      scalar = false;
      stack.add((value, <String>{}));
      if (stack.length > limits.maxJsonDepth) {
        fail(
          r'$',
          'JSON nesting exceeds its limit.',
          AssetLoadError.limitExceeded,
        );
      }
    } else if (value == 0x7d || value == 0x5d) {
      scalar = false;
      if (stack.isEmpty ||
          stack.removeLast().$1 != (value == 0x7d ? 0x7b : 0x5b)) {
        fail(r'$', 'JSON containers do not match.');
      }
    } else if (whitespace(value) || value == 0x2c || value == 0x3a) {
      scalar = false;
    } else if (!scalar) {
      tokens++;
      scalar = true;
    }
    if (tokens > limits.maxJsonTokens) {
      fail(
        r'$',
        'JSON token count exceeds its limit.',
        AssetLoadError.limitExceeded,
      );
    }
  }
  if (stack.isNotEmpty) fail(r'$', 'JSON container is truncated.');
}
