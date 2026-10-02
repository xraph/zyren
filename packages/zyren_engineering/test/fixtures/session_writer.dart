import 'dart:io';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

Future<void> main(List<String> args) async {
  final store = FileEngineeringSessionStore(
    file: File(args[0]),
    documentId: 'review',
  );
  try {
    await store.compareAndWrite(
      expectedVersion: args[1],
      document: EngineeringDocument(
        id: 'review',
        objects: [EngineeringObject(id: 'a', label: args[2])],
      ),
    );
    stdout.writeln('written');
  } on EngineeringVersionConflict {
    stdout.writeln('conflict');
  }
}
