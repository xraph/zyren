import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'zyren_engineering.dart';

/// One review's host-managed credentials. Store token digests in configuration,
/// and deliver raw tokens to clients through your existing secret distribution.
final class EngineeringReviewAccess {
  final String documentId;
  final Map<String, bool> _grants;
  EngineeringReviewAccess._(this.documentId, this._grants);

  factory EngineeringReviewAccess.decode(String source) {
    if (source.length > 65536) {
      throw const FormatException('Access configuration is too large.');
    }
    final value = jsonDecode(source);
    if (value is! Map<String, dynamic> ||
        value['schemaVersion'] != 1 ||
        value['documentId'] is! String ||
        value['grants'] is! List) {
      throw const FormatException('Invalid review access configuration.');
    }
    final id = value['documentId'] as String;
    EngineeringDocument(id: id);
    final grants = <String, bool>{};
    for (final grant in value['grants'] as List) {
      if (grant is! Map<String, dynamic> ||
          grant['tokenSha256'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(grant['tokenSha256'] as String) ||
          !(grant['role'] == 'reader' || grant['role'] == 'writer') ||
          grants.containsKey(grant['tokenSha256'])) {
        throw const FormatException('Invalid or duplicate review grant.');
      }
      grants[grant['tokenSha256'] as String] = grant['role'] == 'writer';
    }
    if (grants.isEmpty || grants.length > 256) {
      throw const FormatException('Configure between 1 and 256 review grants.');
    }
    return EngineeringReviewAccess._(id, Map.unmodifiable(grants));
  }

  bool allows(String? authorization, {required bool write}) {
    if (authorization == null || !authorization.startsWith('Bearer ')) {
      return false;
    }
    final token = authorization.substring(7);
    if (token.length < 32 || token.length > 4096 || token.trim() != token) {
      return false;
    }
    final digest = sha256.convert(utf8.encode(token)).toString();
    var allowed = false;
    for (final entry in _grants.entries) {
      var difference = 0;
      for (var i = 0; i < digest.length; i++) {
        difference |= digest.codeUnitAt(i) ^ entry.key.codeUnitAt(i);
      }
      if (difference == 0 && (!write || entry.value)) allowed = true;
    }
    return allowed;
  }
}
