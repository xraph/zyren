import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_collaboration/zyren_collaboration.dart';
import 'package:zyren_collaboration/file_store.dart';
import 'package:zyren_collaboration/network.dart';

void main() {
  final id = SceneObjectId(source: 'asset', key: 'one');
  SceneSnapshot initial() => SceneSnapshot(
    sceneId: 'scene',
    epoch: 'one',
    objects: [SceneObjectState(id: id)],
  );
  test('independent processes contend on the same durable scene', () async {
    final dir = await Directory.systemTemp.createTemp('scene-process-');
    addTearDown(() => dir.delete(recursive: true));
    final file = File('${dir.path}/scene');
    final host = DurableSceneAuthority(
      store: FileSceneDocumentStore(file),
      canRead: (_, _) => true,
      canWrite: (_, _, _) => true,
    );
    await host.initialize(initial());
    final fixture = File(
      'packages/zyren_collaboration/test/fixtures/writer.dart',
    ).absolute.path;
    final children = await Future.wait([
      for (final who in ['alice', 'bob'])
        Process.start(Platform.resolvedExecutable, [fixture, file.path, who]),
    ]);
    final lines = children
        .map(
          (p) => p.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .asBroadcastStream(),
        )
        .toList();
    final endings = [for (final stream in lines) stream.skip(1).first];
    await Future.wait(
      lines.map((s) => s.first.then((v) => expect(v, 'ready'))),
    );
    for (final p in children) {
      p.stdin.writeln('go');
      await p.stdin.close();
    }
    expect(
      await Future.wait(endings),
      unorderedEquals(['accepted', 'conflict']),
    );
    for (final p in children) {
      expect(
        await p.exitCode,
        0,
        reason: await p.stderr.transform(utf8.decoder).join(),
      );
    }
    expect((await host.connect('a').read()).revision, 1);
  });
  test(
    'HTTPS and WSS validate a trusted certificate and reject an untrusted peer',
    () async {
      final dir = await Directory.systemTemp.createTemp('scene-tls-');
      addTearDown(() => dir.delete(recursive: true));
      Future<void> openssl(List<String> args) async {
        final result = await Process.run(
          'openssl',
          args,
          workingDirectory: dir.path,
        );
        expect(result.exitCode, 0, reason: '${result.stderr}');
      }

      await File('${dir.path}/root.cnf').writeAsString(
        '[req]\ndistinguished_name=dn\nx509_extensions=ext\nprompt=no\n[dn]\nCN=Scene Test Root\n[ext]\nbasicConstraints=critical,CA:TRUE\nkeyUsage=critical,keyCertSign,cRLSign\n',
      );
      await openssl([
        'req',
        '-x509',
        '-newkey',
        'rsa:2048',
        '-sha256',
        '-nodes',
        '-days',
        '1',
        '-keyout',
        'root.key',
        '-out',
        'root.pem',
        '-config',
        'root.cnf',
      ]);
      await openssl([
        'req',
        '-new',
        '-newkey',
        'rsa:2048',
        '-sha256',
        '-nodes',
        '-subj',
        '/CN=localhost',
        '-keyout',
        'key.pem',
        '-out',
        'leaf.csr',
      ]);
      await File('${dir.path}/leaf.cnf').writeAsString(
        'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:localhost,IP:127.0.0.1\n',
      );
      await openssl([
        'x509',
        '-req',
        '-in',
        'leaf.csr',
        '-CA',
        'root.pem',
        '-CAkey',
        'root.key',
        '-CAcreateserial',
        '-out',
        'cert.pem',
        '-days',
        '1',
        '-sha256',
        '-extfile',
        'leaf.cnf',
      ]);
      final serverContext = SecurityContext()
        ..useCertificateChain('${dir.path}/cert.pem')
        ..usePrivateKey('${dir.path}/key.pem');
      final trusted = SecurityContext()
        ..setTrustedCertificates('${dir.path}/root.pem');
      final authority = LocalSceneAuthority(
        initial: initial(),
        canRead: (_, _) => true,
        canWrite: (_, _, _) => true,
      );
      final host = await SceneCollaborationServer.bind(
        sceneId: 'scene',
        epoch: 'one',
        authenticate: (_) => 'alice',
        connect: authority.connect,
        securityContext: serverContext,
      );
      final http = HttpSceneTransport(
        endpoint: host.endpoint,
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {},
        client: HttpClient(context: trusted),
      );
      final wsClient = HttpClient(context: trusted);
      final ws = WebSocketSceneTransport(
        endpoint: host.endpoint.replace(scheme: 'wss'),
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {},
        httpClient: wsClient,
      );
      final untrusted = HttpSceneTransport(
        endpoint: host.endpoint,
        sceneId: 'scene',
        epoch: 'one',
        headers: () => {},
      );
      addTearDown(() async {
        await http.close();
        await ws.close();
        wsClient.close(force: true);
        await untrusted.close();
        await host.close();
      });
      try {
        expect((await http.read()).revision, 0);
      } catch (e) {
        fail('Trusted HTTPS: $e');
      }
      try {
        expect((await ws.read()).revision, 0);
      } catch (e) {
        fail('Trusted WSS: $e');
      }
      await expectLater(untrusted.read(), throwsA(isA<HandshakeException>()));
    },
  );
}
