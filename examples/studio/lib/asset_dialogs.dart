import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'studio_assets.dart';

Future<Map<String, int>?> studioSourceMapDialog(
  BuildContext context,
  Map<int, String> nodes,
  Map<String, int> previous,
) async {
  final text = TextEditingController(
    text: previous.entries.map((e) => '${e.key} = ${e.value}').join('\n'),
  );
  String? error;
  try {
    return await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Map source parts'),
          content: SizedBox(
            width: 480,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Keep source keys stable to retain review notes. Check every index against this import. Removed mappings leave their notes unbound. Leave blank for instance-level review only.',
                  ),
                  ExpansionTile(
                    title: Text('${nodes.length} model nodes'),
                    children: [
                      SizedBox(
                        height: 180,
                        child: ListView.builder(
                          itemCount: nodes.length,
                          itemBuilder: (_, i) {
                            final e = nodes.entries.elementAt(i);
                            return ListTile(
                              dense: true,
                              title: Text(
                                '${e.key}: ${e.value.isEmpty ? "Unnamed node" : e.value}',
                              ),
                            );
                          },
                        ),
                      ),
                    ],
                  ),
                  TextField(
                    controller: text,
                    minLines: 3,
                    maxLines: 8,
                    maxLength: 65536,
                    decoration: const InputDecoration(
                      labelText: 'Source key = node index',
                      hintText: 'pump-body = 0\nimpeller = 3',
                    ),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel import'),
            ),
            TextButton(
              onPressed: () {
                try {
                  final values = <String, int>{};
                  for (final line
                      in text.text
                          .split('\n')
                          .where((s) => s.trim().isNotEmpty)) {
                    final divider = line.lastIndexOf('=');
                    if (divider < 1) {
                      throw const FormatException(
                        'Use source key = node index.',
                      );
                    }
                    final key = line.substring(0, divider).trim();
                    final index = int.parse(line.substring(divider + 1).trim());
                    if (!nodes.containsKey(index) ||
                        values.containsKey(key) ||
                        values.containsValue(index)) {
                      throw const FormatException(
                        'Use unique source keys and model node indices from this import.',
                      );
                    }
                    values[key] = index;
                  }
                  StudioAsset(
                    id: 'validate',
                    label: 'Mapping',
                    provider: 'zyren.pipeline',
                    reference: const {'validation': true},
                    sourceNodes: values,
                  );
                  Navigator.pop(context, values);
                } catch (failure) {
                  update(() => error = '$failure');
                }
              },
              child: const Text('Use source map'),
            ),
          ],
        ),
      ),
    );
  } finally {
    text.dispose();
  }
}

class StudioAssetsDialog extends StatefulWidget {
  final StudioDocument document;
  final StudioPipelineAssets resolver;
  const StudioAssetsDialog({
    super.key,
    required this.document,
    required this.resolver,
  });
  @override
  State<StudioAssetsDialog> createState() => _StudioAssetsDialogState();
}

class _StudioAssetsDialogState extends State<StudioAssetsDialog> {
  final _states = <String, String>{};
  StudioCancellation? _token;
  bool _busy = false;
  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _token?.cancel();
    super.dispose();
  }

  Future<void> _check() async {
    final token = _token = StudioCancellation();
    setState(() {
      _busy = true;
      _states.clear();
    });
    try {
      for (final asset in widget.document.assets) {
        var state = 'Checking';
        try {
          token.throwIfCancelled();
          final status = await widget.resolver.inspect(asset);
          state = status.name;
          if (state == 'available') {
            final template = await widget.resolver.load(asset, token);
            try {
              template.instantiate();
              state = 'Available, decoded and source map checked';
            } finally {
              await template.close();
            }
          }
        } on LoadCancelled {
          state = 'Cancelled';
        } catch (error) {
          state = 'Failed: $error';
        }
        if (!mounted) return;
        setState(() => _states[asset.id] = state);
        if (token.isCancelled) break;
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Asset diagnostics'),
    content: SizedBox(
      width: 440,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (widget.document.assets.isEmpty)
              const ZeroState(
                title: 'No imported assets',
                message: 'Choose Import from Authoring to add a pinned model.',
              ),
            for (final asset in widget.document.assets)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(asset.label),
                subtitle: Text(
                  '${_states[asset.id] ?? (_busy ? "Waiting" : "Not checked")}\n${asset.sourceNodes.length} source bindings',
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('Close'),
      ),
      TextButton(
        onPressed: _busy ? () => _token?.cancel() : _check,
        child: Text(_busy ? 'Cancel check' : 'Retry checks'),
      ),
    ],
  );
}
