/// Native HTTP model adapters. No credential or transcript logging.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'workflow.dart';
import 'zyren_agents.dart';

enum AgentModelProtocol { openAI, anthropic, local }

class AgentModelConfiguration {
  final AgentModelProtocol protocol;
  final Uri baseUrl;
  final String model, apiKey;
  AgentModelConfiguration({
    required this.protocol,
    required this.baseUrl,
    required this.model,
    this.apiKey = '',
  }) {
    final local = {'localhost', '127.0.0.1', '::1'}.contains(baseUrl.host);
    if (!baseUrl.hasAuthority ||
        baseUrl.userInfo.isNotEmpty ||
        baseUrl.hasQuery ||
        baseUrl.hasFragment ||
        (baseUrl.scheme != 'https' && !(local && baseUrl.scheme == 'http')) ||
        model.trim().isEmpty ||
        model.length > 256 ||
        apiKey.contains('\n') ||
        apiKey.contains('\r')) {
      throw ArgumentError(
        'Use an HTTPS base URL (HTTP is allowed on loopback) and a model ID.',
      );
    }
  }

  /// Safe to persist. API keys never enter scene documents or profile files.
  Map<String, Object?> toJson() => {
    'protocol': protocol.name,
    'baseUrl': baseUrl.toString(),
    'model': model,
  };
  factory AgentModelConfiguration.fromJson(
    Map<String, Object?> value, {
    String apiKey = '',
  }) => AgentModelConfiguration(
    protocol: AgentModelProtocol.values.byName(value['protocol'] as String),
    baseUrl: Uri.parse(value['baseUrl'] as String),
    model: value['model'] as String,
    apiKey: apiKey,
  );
}

class HttpAgentModel implements AgentModel {
  final AgentModelConfiguration configuration;
  final Duration timeout;
  final _clients = <HttpClient>{};
  bool _closed = false;
  HttpAgentModel(
    this.configuration, {
    this.timeout = const Duration(seconds: 90),
  });
  @override
  void close() {
    _closed = true;
    for (final client in _clients.toList()) {
      client.close(force: true);
    }
    _clients.clear();
  }

  @override
  Future<AgentReply> complete({
    required List<Map<String, Object?>> messages,
    required List<Map<String, Object?>> tools,
    required AgentCancellation cancellation,
  }) async {
    if (_closed) throw StateError('Model adapter is closed.');
    cancellation.throwIfCancelled();
    final client = HttpClient()..connectionTimeout = timeout;
    _clients.add(client);
    var finished = false;
    unawaited(
      cancellation.whenCancelled.then((_) {
        if (!finished) client.close(force: true);
      }),
    );
    final anthropic = configuration.protocol == AgentModelProtocol.anthropic;
    final path =
        '${configuration.baseUrl.path.replaceFirst(RegExp(r'/+$'), '')}/${anthropic ? 'messages' : 'chat/completions'}';
    try {
      return await (() async {
        final request = await client.postUrl(
          configuration.baseUrl.replace(path: path),
        );
        request.followRedirects = false;
        request.headers.contentType = ContentType.json;
        if (anthropic) {
          request.headers.set('anthropic-version', '2023-06-01');
          if (configuration.apiKey.isNotEmpty) {
            request.headers.set('x-api-key', configuration.apiKey);
          }
        } else if (configuration.apiKey.isNotEmpty) {
          request.headers.set(
            HttpHeaders.authorizationHeader,
            'Bearer ${configuration.apiKey}',
          );
        }
        request.write(
          jsonEncode(
            anthropic
                ? _anthropicRequest(messages, tools)
                : {
                    'model': configuration.model,
                    'messages': messages,
                    'tools': tools,
                    'tool_choice': 'auto',
                    configuration.protocol == AgentModelProtocol.local
                            ? 'max_tokens'
                            : 'max_completion_tokens':
                        4096,
                    'stream': false,
                  },
          ),
        );
        final response = await request.close();
        if (response.statusCode != 200) {
          throw HttpException('Model HTTP ${response.statusCode}');
        }
        final bytes = <int>[];
        await for (final chunk in response) {
          cancellation.throwIfCancelled();
          if (bytes.length + chunk.length > 1048576) {
            throw const FormatException('Model response too large.');
          }
          bytes.addAll(chunk);
        }
        final body = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
        cancellation.throwIfCancelled();
        if (anthropic) {
          if (body['stop_reason'] == 'max_tokens') {
            throw const FormatException('Model response was truncated.');
          }
          final blocks = (body['content'] as List).cast<Map<String, dynamic>>();
          return AgentReply(
            text: blocks
                .where((b) => b['type'] == 'text')
                .map((b) => b['text'] as String)
                .join('\n'),
            calls: [
              for (final b in blocks.where((b) => b['type'] == 'tool_use'))
                AgentToolCall(
                  b['id'] as String,
                  b['name'] as String,
                  (b['input'] as Map).cast<String, Object?>(),
                ),
            ],
          );
        }
        final choice = (body['choices'] as List).first as Map;
        if (choice['finish_reason'] == 'length') {
          throw const FormatException('Model response was truncated.');
        }
        final message = choice['message'] as Map;
        return AgentReply(
          text: message['content'] as String? ?? '',
          calls: [
            for (final call in message['tool_calls'] as List? ?? [])
              AgentToolCall(
                call['id'] as String,
                call['function']['name'] as String,
                (jsonDecode(call['function']['arguments'] as String) as Map)
                    .cast<String, Object?>(),
              ),
          ],
        );
      })().timeout(timeout);
    } finally {
      finished = true;
      client.close(force: true);
      _clients.remove(client);
    }
  }

  Map<String, Object?> _anthropicRequest(
    List<Map<String, Object?>> messages,
    List<Map<String, Object?>> tools,
  ) {
    final result = <Map<String, Object?>>[];
    for (final message in messages.where((m) => m['role'] != 'system')) {
      final role = message['role'] == 'tool'
          ? 'user'
          : message['role'] as String;
      final blocks = <Map<String, Object?>>[];
      if (message['role'] == 'tool') {
        blocks.add({
          'type': 'tool_result',
          'tool_use_id': message['tool_call_id'],
          'content': message['content'],
        });
      } else {
        if ((message['content'] as String? ?? '').isNotEmpty) {
          blocks.add({'type': 'text', 'text': message['content']});
        }
        for (final raw in message['tool_calls'] as List? ?? []) {
          final f = raw['function'] as Map;
          blocks.add({
            'type': 'tool_use',
            'id': raw['id'],
            'name': f['name'],
            'input': jsonDecode(f['arguments'] as String),
          });
        }
      }
      if (blocks.isEmpty) continue;
      if (result.isNotEmpty && result.last['role'] == role) {
        (result.last['content'] as List).addAll(blocks);
      } else {
        result.add({'role': role, 'content': blocks});
      }
    }
    return {
      'model': configuration.model,
      'max_tokens': 4096,
      'system': messages
          .where((m) => m['role'] == 'system')
          .map((m) => m['content'])
          .join('\n'),
      'messages': result,
      'tools': [
        for (final tool in tools)
          {
            'name': (tool['function'] as Map)['name'],
            'description': (tool['function'] as Map)['description'],
            'input_schema': (tool['function'] as Map)['parameters'],
          },
      ],
    };
  }
}
