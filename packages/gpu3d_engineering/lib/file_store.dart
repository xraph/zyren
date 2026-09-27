import 'dart:io';
import 'gpu3d_engineering.dart';

/// Optional filesystem adapter. The host chooses the document's location.
class FileEngineeringStore implements EngineeringStore {
  final File file;
  FileEngineeringStore(this.file);
  @override
  Future<String?> read() async {
    try {
      if (await file.length() > EngineeringDocument.maxCharacters * 4) {
        throw const FormatException('Review exceeds the document size limit.');
      }
      return await file.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
  }

  @override
  Future<void> write(String document) async {
    await file.parent.create(recursive: true);
    final staging = await file.parent.createTemp('.engineering-');
    try {
      final next = File('${staging.path}/review.json');
      await next.writeAsString(document, flush: true);
      await next.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }
}
