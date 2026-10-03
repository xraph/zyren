import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'package:zyren_agents/workflow.dart';
import 'package:zyren_agents/io.dart';

class StudioAgentPanel extends StatefulWidget {
  final AgentRegistry registry;
  final Map<String, Object?> Function() sceneContext;
  final File? profileFile;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  final AgentModel Function(AgentModelConfiguration)? modelFactory;
  const StudioAgentPanel({
    super.key,
    required this.registry,
    required this.sceneContext,
    this.profileFile,
    this.themeMode = ThemeMode.system,
    this.onThemeChanged,
    this.modelFactory,
  });
  @override
  State<StudioAgentPanel> createState() => StudioAgentPanelState();
}

class StudioAgentPanelState extends State<StudioAgentPanel> {
  final prompt = TextEditingController();
  final events = <AgentWorkflowEvent>[];
  AgentModelConfiguration? configuration;
  AgentWorkflow? workflow;
  AgentApproval? pending;
  Completer<bool>? decision;
  String status = 'Choose your LLM in Settings';
  bool get running => workflow?.isRunning ?? false;
  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final file = widget.profileFile;
      if (file == null || !await file.exists()) return;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final config = AgentModelConfiguration.fromJson(json);
      if (mounted) {
        setState(() {
          configuration = config;
          status = 'Profile loaded. Add your API key in Settings if required.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => status =
              'Saved model settings could not be loaded. Open Settings to replace them.',
        );
      }
    }
  }

  @override
  void dispose() {
    decision?.complete(false);
    decision = null;
    workflow?.dispose();
    prompt.dispose();
    super.dispose();
  }

  void _decide(bool allow) {
    final current = decision;
    decision = null;
    if (mounted) setState(() => pending = null);
    current?.complete(allow);
  }

  void cancelForDetach() {
    workflow?.stop();
    decision?.complete(false);
    decision = null;
  }

  void _stop() {
    workflow?.stop();
    _decide(false);
    setState(() => status = 'Stopping...');
  }

  Future<void> _send() async {
    if (running || prompt.text.trim().isEmpty) return;
    if (configuration == null) {
      await _settings();
      return;
    }
    workflow ??= AgentWorkflow(
      registry: widget.registry,
      model:
          widget.modelFactory?.call(configuration!) ??
          HttpAgentModel(configuration!),
      context: widget.sceneContext,
      approve: (request) {
        if (!mounted) return Future.value(false);
        final answer = decision = Completer<bool>();
        setState(() {
          pending = request;
          status = 'Review ${request.tool}';
        });
        return answer.future;
      },
      onEvent: (event) {
        if (!mounted) return;
        setState(() {
          if (event.kind == 'status' || event.kind == 'progress') {
            status = event.text;
          } else {
            events.add(event);
            if (events.length > 400) events.removeAt(0);
            if (event.kind == 'error') status = event.text;
          }
        });
      },
    );
    final text = prompt.text.trim();
    prompt.clear();
    await workflow!.run(text);
    if (mounted) setState(() {});
  }

  Future<void> openSettings() => _settings();

  Future<void> _settings() async {
    if (running) return;
    final result = await showDialog<AgentModelConfiguration>(
      context: context,
      builder: (_) => _AgentSettings(
        configuration: configuration,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
      ),
    );
    if (!mounted || result == null) return;
    var saved = true;
    try {
      final file = widget.profileFile;
      if (file != null) {
        await file.parent.create(recursive: true);
        final temp = File('${file.path}.tmp');
        await temp.writeAsString(jsonEncode(result.toJson()), flush: true);
        await temp.rename(file.path);
      }
    } catch (_) {
      saved = false;
    }
    if (!mounted) return;
    workflow?.dispose();
    workflow = null;
    setState(() {
      configuration = result;
      events.clear();
      status = saved
          ? 'Configured. Send a request to start.'
          : 'Configured for this session. Profile could not be saved.';
    });
  }

  List<Map<String, Object?>> _providers() {
    final result = <Map<String, Object?>>[];
    var offset = 0;
    while (true) {
      final page = widget.registry.discover(offset: offset);
      result.addAll((page['providers'] as List).cast<Map<String, Object?>>());
      if (page['nextOffset'] == null) return result;
      offset = page['nextOffset'] as int;
    }
  }

  Future<void> _tools() => showDialog<void>(
    context: context,
    builder: (context) {
      final providers = _providers();
      return AlertDialog(
        title: const Text('Attached plugin tools'),
        content: SizedBox(
          width: 560,
          child: providers.isEmpty
              ? const ZeroState(
                  title: 'No attached tools',
                  message:
                      'Attach a plugin with an agent provider to this scene.',
                )
              : ListView(
                  shrinkWrap: true,
                  children: [
                    for (final p in providers)
                      ExpansionTile(
                        title: Text('${p['providerId']}'),
                        subtitle: Text(
                          '${p['instanceId']} · ${(p['tools'] as List).length} tools',
                        ),
                        children: [
                          for (final t in p['tools'] as List)
                            ListTile(
                              dense: true,
                              title: Text(t['name'] as String),
                              subtitle: Text(
                                '${t['description']}\n${t['readOnly'] == true ? 'Read only' : 'Review required'} · ${(t['requiredScopes'] as List).join(', ')}',
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Close'),
          ),
        ],
      );
    },
  );

  Widget _approval(AgentApproval request) => SingleChildScrollView(
    child: Container(
      padding: const EdgeInsets.all(8),
      color: Theme.of(context).colorScheme.secondaryContainer,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Review ${request.tool}',
            style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12),
          ),
          Text(
            '${request.providerId} / ${request.instanceId}',
            style: const TextStyle(fontSize: 10),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 110),
            child: SingleChildScrollView(
              child: SelectableText(
                const JsonEncoder.withIndent('  ').convert(request.arguments),
                style: const TextStyle(fontSize: 11),
              ),
            ),
          ),
          Wrap(
            spacing: 6,
            children: [
              FilledButton(
                onPressed: () => _decide(true),
                child: const Text('Apply change'),
              ),
              TextButton(
                onPressed: () => _decide(false),
                child: const Text('Decline'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  configuration?.model ?? 'Studio Agent',
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(fontSize: 12),
                ),
              ),
              IconButton(
                tooltip: 'Attached tools',
                onPressed: _tools,
                icon: const Icon(
                  Icons.extension_outlined,
                  size: 17,
                  semanticLabel: 'Attached tools',
                ),
              ),
              IconButton(
                tooltip: 'Agent settings',
                onPressed: running ? null : _settings,
                icon: const Icon(
                  Icons.settings_outlined,
                  size: 17,
                  semanticLabel: 'Agent settings',
                ),
              ),
              IconButton(
                tooltip: 'New conversation',
                onPressed: running
                    ? null
                    : () => setState(() {
                        workflow?.clear();
                        events.clear();
                        status = 'New conversation';
                      }),
                icon: const Icon(
                  Icons.add_comment_outlined,
                  size: 17,
                  semanticLabel: 'New conversation',
                ),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(
          child: pending != null
              ? _approval(pending!)
              : events.isEmpty
              ? ZeroState(
                  title: 'Build with your scene tools',
                  message:
                      'Create shapes, assemble characters, edit materials and animate poses. The agent discovers tools from every attached plugin.',
                  actionLabel: configuration == null
                      ? 'Configure LLM'
                      : 'Show attached tools',
                  onAction: configuration == null ? _settings : _tools,
                )
              : ListView(
                  padding: const EdgeInsets.all(10),
                  children: [
                    for (final event in events)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child:
                            event.kind == 'tool_start' ||
                                event.kind == 'tool_result'
                            ? ExpansionTile(
                                dense: true,
                                tilePadding: EdgeInsets.zero,
                                childrenPadding: EdgeInsets.zero,
                                title: Text(
                                  '${event.kind == 'tool_start' ? 'Calling' : event.data['status'] ?? 'Result'}: ${event.text}',
                                  style: const TextStyle(fontSize: 11),
                                ),
                                children: [
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: SelectableText(
                                      const JsonEncoder.withIndent(
                                        '  ',
                                      ).convert(event.data),
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              )
                            : Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    event.kind == 'user'
                                        ? 'You'
                                        : event.kind == 'error'
                                        ? 'Request failed'
                                        : 'Agent',
                                    style: TextStyle(
                                      fontSize: 10,
                                      color: scheme.primary,
                                    ),
                                  ),
                                  SelectableText(
                                    event.text,
                                    style: const TextStyle(
                                      fontSize: 12,
                                      height: 1.45,
                                    ),
                                  ),
                                ],
                              ),
                      ),
                  ],
                ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
          child: Text(
            status,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 10, color: scheme.onSurfaceVariant),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Expanded(
                child: TextField(
                  controller: prompt,
                  enabled: !running,
                  minLines: 1,
                  maxLines: 3,
                  maxLength: 16000,
                  style: const TextStyle(fontSize: 12),
                  decoration: const InputDecoration(
                    hintText: 'Build or change this scene...',
                    counterText: '',
                  ),
                  onSubmitted: (_) => _send(),
                ),
              ),
              IconButton(
                tooltip: running ? 'Stop agent' : 'Send request',
                onPressed: running ? _stop : _send,
                icon: Icon(
                  running ? Icons.stop_circle_outlined : Icons.arrow_upward,
                  semanticLabel: running ? 'Stop agent' : 'Send request',
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _AgentSettings extends StatefulWidget {
  final AgentModelConfiguration? configuration;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode>? onThemeChanged;
  const _AgentSettings({
    this.configuration,
    required this.themeMode,
    this.onThemeChanged,
  });
  @override
  State<_AgentSettings> createState() => _AgentSettingsState();
}

class _AgentSettingsState extends State<_AgentSettings> {
  final form = GlobalKey<FormState>();
  late final endpoint = TextEditingController(
    text: widget.configuration?.baseUrl.toString() ?? '',
  );
  late final model = TextEditingController(
    text: widget.configuration?.model ?? '',
  );
  late final keyInput = TextEditingController(
    text: widget.configuration?.apiKey ?? '',
  );
  late AgentModelProtocol protocol =
      widget.configuration?.protocol ?? AgentModelProtocol.openAI;
  late ThemeMode mode = widget.themeMode;
  String? error;
  @override
  void dispose() {
    endpoint.dispose();
    model.dispose();
    keyInput.clear();
    keyInput.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Studio settings'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.onThemeChanged != null) ...[
                DropdownButtonFormField<ThemeMode>(
                  isExpanded: true,
                  initialValue: mode,
                  decoration: const InputDecoration(labelText: 'Appearance'),
                  items: ThemeMode.values
                      .map(
                        (m) => DropdownMenuItem(value: m, child: Text(m.name)),
                      )
                      .toList(),
                  onChanged: (value) {
                    setState(() => mode = value!);
                    widget.onThemeChanged!(value!);
                  },
                ),
                const SizedBox(height: 14),
              ],
              DropdownButtonFormField<AgentModelProtocol>(
                isExpanded: true,
                initialValue: protocol,
                decoration: const InputDecoration(labelText: 'LLM protocol'),
                items: const [
                  DropdownMenuItem(
                    value: AgentModelProtocol.openAI,
                    child: Text('OpenAI-compatible'),
                  ),
                  DropdownMenuItem(
                    value: AgentModelProtocol.anthropic,
                    child: Text('Anthropic'),
                  ),
                  DropdownMenuItem(
                    value: AgentModelProtocol.local,
                    child: Text('Local / OpenAI-compatible'),
                  ),
                ],
                onChanged: (value) => setState(() => protocol = value!),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: endpoint,
                decoration: const InputDecoration(
                  labelText: 'Base URL',
                  hintText: 'https://your-provider.example/v1',
                ),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: model,
                decoration: const InputDecoration(labelText: 'Model ID'),
              ),
              const SizedBox(height: 14),
              TextFormField(
                controller: keyInput,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'API key (session only)',
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Requests send your prompts, current scene context and tool results to this endpoint. Scene edits pause for your review. API keys remain in memory; the model profile is saved without credentials.',
                style: TextStyle(fontSize: 12),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Cancel'),
      ),
      FilledButton(
        onPressed: () {
          try {
            final config = AgentModelConfiguration(
              protocol: protocol,
              baseUrl: Uri.parse(endpoint.text.trim()),
              model: model.text.trim(),
              apiKey: keyInput.text.trim(),
            );
            Navigator.pop(context, config);
          } catch (_) {
            setState(
              () => error =
                  'Enter a model ID and HTTPS base URL. Localhost may use HTTP.',
            );
          }
        },
        child: const Text('Save settings'),
      ),
    ],
  );
}
