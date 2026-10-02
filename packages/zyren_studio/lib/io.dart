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
