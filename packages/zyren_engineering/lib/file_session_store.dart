import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'zyren_engineering.dart';

/// Versioned review storage with atomic replacement and advisory file locking.
/// Use one owning isolate per process for a file. All writers must use this
/// adapter and retain its sibling lock file; plain file stores do not cooperate.
final class FileEngineeringSessionStore implements EngineeringSessionStore {
  static final _queues = <String, Future<void>>{};
  final File file;
  final String documentId;
  FileEngineeringSessionStore({required this.file, required this.documentId}) {
    // Apply the same document identity bounds as review JSON.
    EngineeringDocument(id: documentId);
  }

  /// Creates a missing session without replacing an existing review.
  Future<EngineeringRevision> initialize(EngineeringDocument document) {
    _validate(document);
    return _locked(() async {
      final existing = await _read();
      if (existing != null) return existing;
      final initial = _revision(document);
      await _write(initial);
      return initial;
    });
  }

  @override
  Future<EngineeringRevision> read() => _locked(
    () async =>
        await _read() ??
        (throw StateError('Initialize the review session first.')),
  );

  @override
  Future<EngineeringRevision> compareAndWrite({
    required String expectedVersion,
    required EngineeringDocument document,
  }) {
    _validate(document);
    return _locked(() async {
      final current = await _read();
      if (current == null || current.version != expectedVersion) {
        throw const EngineeringVersionConflict();
      }
      final next = _revision(document);
      await _write(next);
      return next;
    });
  }

  void _validate(EngineeringDocument document) {
    if (document.id != documentId) {
      throw const FormatException('Review belongs to another document.');
    }
    document.encode();
  }

  EngineeringRevision _revision(EngineeringDocument document) {
    final random = Random.secure();
    final token = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return EngineeringRevision(version: '"$token"', document: document);
  }

  Future<EngineeringRevision?> _read() async {
    String source;
    try {
      if (await file.length() > EngineeringDocument.maxCharacters * 4 + 1024) {
        throw const FormatException('Session exceeds the size limit.');
      }
      source = await file.readAsString();
    } on FileSystemException catch (error) {
      if (error.osError?.errorCode == 2) return null;
      rethrow;
    }
    final root = jsonDecode(source);
    if (root is! Map<String, dynamic> ||
        root['schemaVersion'] != 1 ||
        root['version'] is! String ||
        !RegExp(r'^"[0-9a-f]{32}"$').hasMatch(root['version'] as String) ||
        root['document'] is! Map<String, dynamic>) {
      throw const FormatException('Invalid review session envelope.');
    }
    final document = EngineeringDocument.decode(jsonEncode(root['document']));
    _validate(document);
    return EngineeringRevision(
      version: root['version'] as String,
      document: document,
    );
  }

  Future<void> _write(EngineeringRevision revision) async {
    final staging = await file.parent.createTemp('.engineering-session-');
    try {
      final next = File('${staging.path}/session.json');
      await next.writeAsString(
        jsonEncode({
          'schemaVersion': 1,
          'version': revision.version,
          'document': jsonDecode(revision.document.encode()),
        }),
        flush: true,
      );
      await next.rename(file.path);
    } finally {
      await staging.delete(recursive: true);
    }
  }

  Future<T> _locked<T>(Future<T> Function() operation) async {
    await file.parent.create(recursive: true);
    final lockFile = File('${file.path}.lock');
    final key = await lockFile.exists()
        ? await lockFile.resolveSymbolicLinks()
        : '${await file.parent.resolveSymbolicLinks()}/${lockFile.uri.pathSegments.last}';
    final previous = _queues[key] ?? Future<void>.value();
    final gate = Completer<void>();
    _queues[key] = gate.future;
    RandomAccessFile? handle;
    var acquired = false;
    try {
      await previous;
      // Open only after the isolate queue. On POSIX, closing another descriptor
      // for this inode would release the process's active advisory lock.
      handle = await lockFile.open(mode: FileMode.append);
      await handle.lock(FileLock.blockingExclusive);
      acquired = true;
      return await operation();
    } finally {
      try {
        if (acquired) await handle!.unlock();
      } finally {
        try {
          await handle?.close();
        } finally {
          gate.complete();
          if (identical(_queues[key], gate.future)) _queues.remove(key);
        }
      }
    }
  }
}
