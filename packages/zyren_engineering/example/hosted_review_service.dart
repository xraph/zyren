import 'dart:async';
import 'dart:io';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/review_access.dart';
import 'package:zyren_engineering/review_server.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

Future<void> main(List<String> args) async {
  if (args.length != 2) {
    stderr.writeln('Pass an access configuration file and a session file.');
    exitCode = 64;
    return;
  }
  final config = File(args[0]);
  if (await config.length() > 65536) {
    throw const FormatException('Access configuration is too large.');
  }
  final access = EngineeringReviewAccess.decode(await config.readAsString());
  final store = FileEngineeringSessionStore(
    file: File(args[1]),
    documentId: access.documentId,
  );
  await store.initialize(EngineeringDocument(id: access.documentId));
  final address = InternetAddress(
    Platform.environment['ZYREN_REVIEW_BIND'] ?? '127.0.0.1',
  );
  final port = int.parse(Platform.environment['ZYREN_REVIEW_PORT'] ?? '8080');
  final cert = Platform.environment['ZYREN_REVIEW_CERT'];
  final key = Platform.environment['ZYREN_REVIEW_KEY'];
  if ((cert == null) != (key == null)) {
    throw ArgumentError('Configure both TLS certificate and key.');
  }
  final tls = cert == null
      ? null
      : (SecurityContext()
          ..useCertificateChain(cert)
          ..usePrivateKey(key!));
  if (!address.isLoopback &&
      tls == null &&
      Platform.environment['ZYREN_REVIEW_PROXY'] != 'caddy') {
    throw ArgumentError(
      'Public binding requires TLS or the configured Caddy proxy.',
    );
  }
  final server = await EngineeringReviewServer.start(
    store: store,
    address: address,
    port: port,
    securityContext: tls,
    authorize: (request, write) async => access.allows(
      request.headers.value(HttpHeaders.authorizationHeader),
      write: write,
    ),
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
