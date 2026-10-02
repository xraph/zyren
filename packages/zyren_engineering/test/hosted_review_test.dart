import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:zyren_engineering/review_access.dart';
import 'package:zyren_engineering/file_session_store.dart';
import 'package:zyren_engineering/http_session_store.dart';
import 'package:zyren_engineering/review_server.dart';
import 'package:zyren_engineering/zyren_engineering.dart';

const writerToken = 'writer-fixture-token-with-32-characters';
const readerToken = 'reader-fixture-token-with-32-characters';
String config() => jsonEncode({
  'schemaVersion': 1,
  'documentId': 'review',
  'grants': [
    {
      'tokenSha256': sha256.convert(utf8.encode(writerToken)).toString(),
      'role': 'writer',
    },
    {
      'tokenSha256': sha256.convert(utf8.encode(readerToken)).toString(),
      'role': 'reader',
    },
  ],
});

void main() {
  test(
    'access configuration enforces read/write grants and rejects ambiguous credentials',
    () {
      final access = EngineeringReviewAccess.decode(config());
      expect(access.allows('Bearer $writerToken', write: true), isTrue);
      expect(access.allows('Bearer $readerToken', write: false), isTrue);
      expect(access.allows('Bearer $readerToken', write: true), isFalse);
      expect(access.allows('Bearer unknown', write: false), isFalse);
      expect(access.allows(null, write: false), isFalse);
      final duplicate = jsonDecode(config()) as Map<String, dynamic>;
      (duplicate['grants'] as List).add((duplicate['grants'] as List).first);
      expect(
        () => EngineeringReviewAccess.decode(jsonEncode(duplicate)),
        throwsFormatException,
      );
      expect(
        () => EngineeringReviewAccess.decode(
          config().replaceAll('reader', 'owner'),
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'HTTPS verifies server certificate and enforces grants over the actual transport',
    () async {
      final temp = await Directory.systemTemp.createTemp('zyren-review-tls-');
      final cert = '${temp.path}/cert.pem', key = '${temp.path}/key.pem';
      final ca = '${temp.path}/ca.pem';
      Future<void> openssl(List<String> args) async {
        final result = await Process.run('openssl', args);
        expect(result.exitCode, 0, reason: result.stderr.toString());
      }

      await openssl([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        '${temp.path}/ca.key',
        '-out',
        ca,
        '-days',
        '1',
        '-subj',
        '/CN=Zyren test CA',
        '-addext',
        'basicConstraints=critical,CA:TRUE',
      ]);
      await openssl([
        'req',
        '-newkey',
        'rsa:2048',
        '-nodes',
        '-keyout',
        key,
        '-out',
        '${temp.path}/server.csr',
        '-subj',
        '/CN=localhost',
      ]);
      final extensions = File('${temp.path}/extensions');
      await extensions.writeAsString(
        'subjectAltName=IP:127.0.0.1,DNS:localhost\n'
        'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n'
        'extendedKeyUsage=serverAuth\n',
      );
      await openssl([
        'x509',
        '-req',
        '-in',
        '${temp.path}/server.csr',
        '-CA',
        ca,
        '-CAkey',
        '${temp.path}/ca.key',
        '-CAcreateserial',
        '-out',
        cert,
        '-days',
        '1',
        '-sha256',
        '-extfile',
        extensions.path,
      ]);
      final store = FileEngineeringSessionStore(
        file: File('${temp.path}/review.json'),
        documentId: 'review',
      );
      final initial = await store.initialize(EngineeringDocument(id: 'review'));
      final access = EngineeringReviewAccess.decode(config());
      final server = await EngineeringReviewServer.start(
        store: store,
        securityContext: SecurityContext()
          ..useCertificateChain(cert)
          ..usePrivateKey(key),
        authorize: (request, write) async => access.allows(
          request.headers.value(HttpHeaders.authorizationHeader),
          write: write,
        ),
      );
      final client = HttpClient(
        context: SecurityContext()..setTrustedCertificates(ca),
      );
      final untrusted = HttpClient();
      addTearDown(() async {
        client.close(force: true);
        untrusted.close(force: true);
        await server.close();
        await temp.delete(recursive: true);
      });
      var token = readerToken;
      final session = HttpEngineeringSessionStore(
        client: client,
        endpoint: server.endpoint,
        headers: () async => {'Authorization': 'Bearer $token'},
      );
      expect(server.endpoint.scheme, 'https');
      expect((await session.read()).version, initial.version);
      await expectLater(
        session.compareAndWrite(
          expectedVersion: initial.version,
          document: initial.document,
        ),
        throwsA(isA<HttpException>()),
      );
      token = writerToken;
      final next = await session.compareAndWrite(
        expectedVersion: initial.version,
        document: initial.document,
      );
      expect(next.version, isNot(initial.version));
      await expectLater(
        untrusted.getUrl(server.endpoint),
        throwsA(isA<HandshakeException>()),
      );
    },
  );
}
