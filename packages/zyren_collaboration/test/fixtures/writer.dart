import 'dart:convert';
import 'dart:io';
import 'package:zyren_collaboration/file_store.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';

Future<void> main(List<String> args) async {
  final authority = DurableSceneAuthority(
    store: FileSceneDocumentStore(File(args[0])),
    canRead: (_, _) => true,
    canWrite: (_, _, _) => true,
  );
  stdout.writeln('ready');
  await stdin.transform(utf8.decoder).transform(const LineSplitter()).first;
  final connection = authority.connect(args[1]);
  final snapshot = await connection.read();
  final result = await connection.submit(
    SceneOperation(
      sceneId: snapshot.sceneId,
      epoch: snapshot.epoch,
      operationId: args[1],
      objectId: snapshot.objects.keys.single,
      expectedRevision: 0,
      field: SceneField.visibility,
      visible: false,
    ),
  );
  stdout.writeln(result is SceneOperationAccepted ? 'accepted' : 'conflict');
}
