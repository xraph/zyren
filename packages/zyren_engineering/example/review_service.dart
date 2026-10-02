import 'dart:async';
import 'dart:io';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/review_server.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

/// Run with a host-provided token. No credentials are generated or printed.
Future<void> main(List<String> args) async {
  final token = Platform.environment['ZYREN_REVIEW_TOKEN'];
  if (token == null || token.trim().isEmpty || args.length != 2) {
    stderr.writeln(
      'Set ZYREN_REVIEW_TOKEN and pass a session file and document ID.',
    );
    exitCode = 64;
    return;
  }
  final store = FileEngineeringSessionStore(
    file: File(args[0]),
    documentId: args[1],
  );
  await store.initialize(EngineeringDocument(id: args[1]));
  final server = await EngineeringReviewServer.start(
    store: store,
    authorize: (request, write) async =>
        request.headers.value(HttpHeaders.authorizationHeader) ==
        'Bearer $token',
  );
  final stopped = Completer<void>();
  void stop(ProcessSignal _) {
    if (!stopped.isCompleted) stopped.complete();
  }

  final interrupt = ProcessSignal.sigint.watch().listen(stop);
  final terminate = Platform.isWindows
      ? null
      : ProcessSignal.sigterm.watch().listen(stop);
  stdout.writeln('Review endpoint: ${server.endpoint}');
  await stdout.flush();
  await stopped.future;
  await interrupt.cancel();
  await terminate?.cancel();
  await server.close();
}
