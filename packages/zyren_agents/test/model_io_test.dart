import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:test/test.dart';
import 'package:zyren_agents/io.dart';
import 'package:zyren_agents/workflow.dart';
import 'package:zyren_agents/zyren_agents.dart';

void main() {
  for (final protocol in AgentModelProtocol.values) {
    test(
      '${protocol.name} sends tool schemas and decodes calls over HTTP',
      () async {
        final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        final done = Completer<void>();
        server.listen((request) async {
          try {
            final data =
                jsonDecode(await utf8.decoder.bind(request).join()) as Map;
            expect(data['model'], 'test-model');
            expect(data['tools'], isNotEmpty);
            if (protocol == AgentModelProtocol.anthropic) {
              expect(request.uri.path, '/v1/messages');
              expect(request.headers.value('x-api-key'), 'test-credential');
              request.response.write(
                jsonEncode({
                  'content': [
                    {
                      'type': 'tool_use',
                      'id': 'a',
                      'name': 'list_plugins',
                      'input': <String, Object?>{},
                    },
                  ],
                  'stop_reason': 'tool_use',
                }),
              );
            } else {
              expect(request.uri.path, '/v1/chat/completions');
              expect(
                request.headers.value('authorization'),
                'Bearer test-credential',
              );
              request.response.write(
                jsonEncode({
                  'choices': [
                    {
                      'finish_reason': 'tool_calls',
                      'message': {
                        'content': null,
                        'tool_calls': [
                          {
                            'id': 'a',
                            'function': {
                              'name': 'list_plugins',
                              'arguments': '{}',
                            },
                          },
                        ],
                      },
                    },
                  ],
                }),
              );
            }
            await request.response.close();
            done.complete();
          } catch (error, stack) {
            done.completeError(error, stack);
            await request.response.close();
          }
        });
        final configuration = AgentModelConfiguration(
          protocol: protocol,
          baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1/'),
          model: 'test-model',
          apiKey: 'test-credential',
        );
        expect(
          jsonEncode(configuration.toJson()),
          isNot(contains('test-credential')),
        );
        final model = HttpAgentModel(configuration);
        final reply = await model.complete(
          messages: [
            {'role': 'system', 'content': 'Test'},
            {'role': 'user', 'content': 'Inspect'},
          ],
          tools: AgentWorkflow.toolDefinitions,
          cancellation: AgentCancellation(),
        );
        expect(reply.calls.single.name, 'list_plugins');
        await done.future;
        model.close();
        await server.close(force: true);
      },
    );
  }
  test('non-loopback plaintext endpoints and URL credentials are rejected', () {
    for (final url in [
      'http://example.com/v1',
      'https://user:password@example.com/v1',
      'https://example.com/v1?key=secret',
    ]) {
      expect(
        () => AgentModelConfiguration(
          protocol: AgentModelProtocol.openAI,
          baseUrl: Uri.parse(url),
          model: 'model',
        ),
        throwsArgumentError,
      );
    }
  });
  test('stop interrupts an outstanding model request', () async {
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final arrived = Completer<void>();
    server.listen((_) => arrived.complete());
    final token = AgentCancellation();
    final model = HttpAgentModel(
      AgentModelConfiguration(
        protocol: AgentModelProtocol.local,
        baseUrl: Uri.parse('http://127.0.0.1:${server.port}/v1'),
        model: 'model',
      ),
    );
    final request = model.complete(
      messages: [],
      tools: [],
      cancellation: token,
    );
    final expectation = expectLater(request, throwsA(anything));
    await arrived.future;
    token.cancel();
    await expectation.timeout(const Duration(seconds: 2));
    model.close();
    await server.close(force: true);
  });
}
