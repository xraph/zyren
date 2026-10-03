import 'dart:convert';
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'streaming.dart';
import 'dart:async';
import 'dart:io';
import 'zyren_studio.dart';

/// Local single-editor storage. Remote conflict handling belongs to the host.
/// A staging file on the same filesystem keeps a failed write off the saved file.
final class FileStudioStore implements StudioStore {
  final File file;
  final String documentId;
  Future<void> _pending = Future<void>.value();
  FileStudioStore({required this.file, required this.documentId});

  @override
  Future<StudioDocument?> read() async {
    await _pending;
    String source;
    try {
      if (await file.length() > StudioDocument.maxCharacters * 4) {
        throw const FormatException('Saved scene exceeds size limit.');
      }
      source = await file.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
    final document = StudioDocument.decode(source);
    _validate(document);
    return document;
  }

  void _validate(StudioDocument document) {
    if (document.id != documentId) {
      throw const FormatException('Saved scene belongs to another document.');
    }
  }

  @override
  Future<void> write(StudioDocument document) {
    _validate(document);
    final source = document.encode();
    final result = _pending.then((_) async {
      await file.parent.create(recursive: true);
      final staging = await file.parent.createTemp('.studio-save-');
      try {
        final next = File('${staging.path}/scene.json');
        await next.writeAsString(source, flush: true);
        await next.rename(file.path);
      } finally {
        await staging.delete(recursive: true);
      }
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// .zyren authoring manifests share the runtime's pinned, relative file layout.
/// Immutable companions are written first; the manifest is replaced atomically.
final class ZyrenFileStore implements StudioStore {
  final File file;
  final Future<Map<String, Uint8List>> Function(StudioDocument)? resources;
  Future<void> _pending = Future.value();
  ZyrenFileStore(this.file, {this.resources});
  static Future<Uint8List> readBytes(
    Uri uri,
    int maxBytes,
    LoadCancellation cancellation,
  ) async {
    if (uri.scheme != 'file') {
      throw ArgumentError('Use a host reader for non-file scenes.');
    }
    final input = File.fromUri(uri);
    if (await input.length() > maxBytes) {
      throw const FormatException('Scene file exceeds limit.');
    }
    final bytes = BytesBuilder();
    await for (final part in input.openRead()) {
      cancellation.throwIfCancelled();
      if (bytes.length + part.length > maxBytes) {
        throw const FormatException('Scene file exceeds limit.');
      }
      bytes.add(part);
    }
    return bytes.takeBytes();
  }

  Future<ZyrenSceneStream> openStream() =>
      ZyrenSceneStream.open(file.uri, read: readBytes);
  @override
  Future<StudioDocument?> read() async {
    await _pending;
    if (!await file.exists()) return null;
    final bytes = await readBytes(
      file.uri,
      16 * 1024 * 1024,
      StudioCancellation(),
    );
    final root = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    if (root['format'] != 'zyren.scene') {
      return StudioDocument.decode(utf8.decode(bytes));
    }
    final stream = await openStream();
    try {
      return await stream.readDocument();
    } finally {
      await stream.close();
    }
  }

  @override
  Future<void> write(StudioDocument document) =>
      _write(document, authoring: true);
  Future<void> export(StudioDocument document) =>
      _write(document, authoring: false);
  Future<void> _write(StudioDocument document, {required bool authoring}) {
    final result = _pending.then((_) async {
      final package = ZyrenScenePackage.compile(
        document,
        resources: await resources?.call(document) ?? {},
      );
      await file.parent.create(recursive: true);
      for (final entry in package.files.entries) {
        final target = File.fromUri(file.parent.uri.resolve(entry.key));
        await target.parent.create(recursive: true);
        await _atomic(target, entry.value);
      }
      var manifest = package.manifest;
      if (authoring) {
        final json = jsonDecode(utf8.decode(manifest)) as Map<String, dynamic>;
        json['source'] = jsonDecode(document.encode());
        manifest = Uint8List.fromList(utf8.encode(jsonEncode(json)));
      }
      await _atomic(file, manifest);
    });
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  static Future<void> _atomic(File file, List<int> bytes) async {
    final temporary = await file.parent.createTemp('.zyren-write-');
    try {
      final pending = File('${temporary.path}/data');
      await pending.writeAsBytes(bytes, flush: true);
      await pending.rename(file.path);
    } finally {
      await temporary.delete(recursive: true);
    }
  }
}
