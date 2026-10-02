import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'zyren_engineering.dart';

/// Verified output from the CAD converter. Parse the sidecar before instantiating
/// geometry, and verify its GLB digest before resolving hierarchy paths.
final class EngineeringCadBundle {
  final Uint8List bytes;
  final String sidecar, version;
  EngineeringCadBundle._(this.bytes, this.sidecar, this.version);

  factory EngineeringCadBundle.decode(Uint8List bytes, String sidecar) {
    if (bytes.length > 512 * 1024 * 1024 ||
        sidecar.length > EngineeringDocument.maxCharacters) {
      throw const FormatException('CAD bundle exceeds its size limit.');
    }
    final value = jsonDecode(sidecar);
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != 1 ||
        value['modelVersion'] is! String ||
        value['modelSha256'] != value['modelVersion'] ||
        !RegExp(r'^[a-f0-9]{64}$').hasMatch(value['modelVersion'] as String)) {
      throw const FormatException(
        'CAD sidecar must pin the GLB SHA-256 digest.',
      );
    }
    final version = value['modelVersion'] as String;
    if (sha256.convert(bytes).toString() != version) {
      throw const FormatException('Model and identity sidecar do not match.');
    }
    return EngineeringCadBundle._(Uint8List.fromList(bytes), sidecar, version);
  }

  static Future<EngineeringCadBundle> read(Directory directory) async {
    final model = File('${directory.path}/model.glb');
    final review = File('${directory.path}/review.json');
    if (await model.length() > 512 * 1024 * 1024 ||
        await review.length() > EngineeringDocument.maxCharacters * 4) {
      throw const FormatException('CAD bundle exceeds its size limit.');
    }
    return EngineeringCadBundle.decode(
      await model.readAsBytes(),
      await review.readAsString(),
    );
  }
}
