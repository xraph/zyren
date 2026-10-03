import 'package:flutter/material.dart';

/// Semantic colors shared by the mock workspace and settings.
class StudioPalette {
  final bool dark;
  const StudioPalette(this.dark);
  factory StudioPalette.of(BuildContext context) =>
      StudioPalette(Theme.of(context).brightness == Brightness.dark);
  Color get chrome => Color(dark ? 0xff1e1f22 : 0xffedf0f3);
  Color get panel => Color(dark ? 0xff25262a : 0xffffffff);
  Color get raised => Color(dark ? 0xff2b2d30 : 0xfff3f5f7);
  Color get text => Color(dark ? 0xffdfe1e5 : 0xff242832);
  Color get muted => Color(dark ? 0xff9299a5 : 0xff626a78);
  Color get border => Color(dark ? 0xff34363b : 0xffd7dce3);
  Color get accent => Color(dark ? 0xff8aa8ff : 0xff315fbd);
  Color get selection => Color(dark ? 0xff334261 : 0xffe3ebfc);
  Color get positive => Color(dark ? 0xff9fc3ac : 0xff326745);
}

ThemeData studioTheme(Brightness brightness) {
  final p = StudioPalette(brightness == Brightness.dark);
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    visualDensity: VisualDensity.compact,
    scaffoldBackgroundColor: p.panel,
    colorScheme: ColorScheme.fromSeed(
      seedColor: p.accent,
      brightness: brightness,
      surface: p.panel,
    ),
    textTheme: TextTheme(
      bodyMedium: TextStyle(fontSize: 13, color: p.text),
      bodySmall: TextStyle(fontSize: 11, color: p.muted),
      titleMedium: TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
      titleSmall: TextStyle(
        fontSize: 13,
        fontWeight: FontWeight.w600,
        color: p.text,
      ),
    ),
    dividerTheme: DividerThemeData(color: p.border, space: 1, thickness: 1),
    inputDecorationTheme: InputDecorationTheme(
      isDense: true,
      filled: true,
      fillColor: p.raised,
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(5),
        borderSide: BorderSide(color: p.border),
      ),
    ),
    iconTheme: IconThemeData(size: 17, color: p.muted),
    tooltipTheme: const TooltipThemeData(
      waitDuration: Duration(milliseconds: 450),
    ),
  );
}

/// Session-only mock metadata. Credentials are never retained here.
class AgentProfile {
  final String provider, model, endpoint;
  const AgentProfile({
    required this.provider,
    required this.model,
    required this.endpoint,
  });
}

class StudioSettings extends StatefulWidget {
  final AgentProfile? profile;
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  final bool narrowPreview;
  const StudioSettings({
    super.key,
    this.profile,
    required this.themeMode,
    required this.onThemeChanged,
    this.narrowPreview = false,
  });
  @override
  State<StudioSettings> createState() => _StudioSettingsState();
}

class _StudioSettingsState extends State<StudioSettings> {
  final form = GlobalKey<FormState>();
  late final model = TextEditingController(text: widget.profile?.model ?? '');
  late final endpoint = TextEditingController(
    text: widget.profile?.endpoint ?? '',
  );
  final credential = TextEditingController();
  late String provider = widget.profile?.provider ?? 'OpenAI-compatible';
  late ThemeMode mode = widget.themeMode;
  bool showKey = false;
  @override
  void dispose() {
    model.dispose();
    endpoint.dispose();
    credential.clear();
    credential.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = StudioPalette.of(context);
    return Dialog(
      insetPadding: const EdgeInsets.all(16),
      backgroundColor: p.panel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      child: SizedBox(
        width: widget.narrowPreview ? 364 : 580,
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(context).height - 64,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 6, 8),
                child: Row(
                  children: [
                    const Icon(Icons.settings_outlined, size: 17),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        'Settings',
                        style: TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    IconButton(
                      tooltip: 'Close settings',
                      onPressed: () => Navigator.pop(context),
                      icon: const Icon(Icons.close, size: 18),
                    ),
                  ],
                ),
              ),
              const Divider(),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: Form(
                    key: form,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          'Appearance',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 8),
                        SegmentedButton<ThemeMode>(
                          showSelectedIcon: false,
                          segments: const [
                            ButtonSegment(
                              value: ThemeMode.system,
                              label: Text('System'),
                              icon: Icon(
                                Icons.desktop_windows_outlined,
                                size: 15,
                              ),
                            ),
                            ButtonSegment(
                              value: ThemeMode.light,
                              label: Text('Light'),
                              icon: Icon(Icons.light_mode_outlined, size: 15),
                            ),
                            ButtonSegment(
                              value: ThemeMode.dark,
                              label: Text('Dark'),
                              icon: Icon(Icons.dark_mode_outlined, size: 15),
                            ),
                          ],
                          selected: {mode},
                          onSelectionChanged: (values) {
                            setState(() => mode = values.single);
                            widget.onThemeChanged(mode);
                          },
                        ),
                        const SizedBox(height: 18),
                        const Divider(),
                        const SizedBox(height: 16),
                        Text(
                          'Agent LLM',
                          style: Theme.of(context).textTheme.titleSmall,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Studio provides chat, scene context and tools. You choose the model that powers it.',
                          style: TextStyle(fontSize: 12, color: p.muted),
                        ),
                        const SizedBox(height: 14),
                        DropdownButtonFormField<String>(
                          initialValue: provider,
                          isExpanded: true,
                          decoration: const InputDecoration(
                            labelText: 'Provider',
                          ),
                          items:
                              ['OpenAI-compatible', 'Anthropic', 'Local model']
                                  .map(
                                    (name) => DropdownMenuItem(
                                      value: name,
                                      child: Text(
                                        name,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ),
                                  )
                                  .toList(),
                          onChanged: (value) =>
                              setState(() => provider = value!),
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: model,
                          style: const TextStyle(fontSize: 12),
                          decoration: const InputDecoration(
                            labelText: 'Model ID',
                            hintText: 'Enter the model ID from your provider',
                          ),
                          validator: (value) =>
                              value == null || value.trim().isEmpty
                              ? 'Enter a model ID.'
                              : null,
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: endpoint,
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            labelText: provider == 'Local model'
                                ? 'Local endpoint'
                                : 'Base URL',
                            hintText: 'https://your-provider.example/v1',
                          ),
                          validator: (value) {
                            final uri = Uri.tryParse(value?.trim() ?? '');
                            if (uri == null ||
                                !uri.hasAuthority ||
                                !['http', 'https'].contains(uri.scheme)) {
                              return 'Enter a valid HTTP or HTTPS URL.';
                            }
                            if (uri.userInfo.isNotEmpty ||
                                uri.hasQuery ||
                                uri.hasFragment) {
                              return 'Use a base URL without credentials or query parameters.';
                            }
                            return null;
                          },
                        ),
                        const SizedBox(height: 14),
                        TextFormField(
                          controller: credential,
                          obscureText: !showKey,
                          autocorrect: false,
                          enableSuggestions: false,
                          style: const TextStyle(fontSize: 12),
                          decoration: InputDecoration(
                            labelText: provider == 'Local model'
                                ? 'API key (if required)'
                                : 'API key',
                            hintText: 'Credential field preview',
                            suffixIcon: IconButton(
                              tooltip: showKey
                                  ? 'Hide API key'
                                  : 'Show API key',
                              onPressed: () =>
                                  setState(() => showKey = !showKey),
                              icon: Icon(
                                showKey
                                    ? Icons.visibility_off_outlined
                                    : Icons.visibility_outlined,
                                size: 16,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 10),
                        Text(
                          'UI mock: keys are discarded when Settings closes. Profiles last for this session. No connection is tested.',
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: p.muted,
                          ),
                        ),
                        const SizedBox(height: 14),
                        Row(
                          children: [
                            Icon(
                              Icons.fact_check_outlined,
                              size: 16,
                              color: p.accent,
                            ),
                            const SizedBox(width: 8),
                            const Expanded(
                              child: Text(
                                'Review scene changes before applying',
                                style: TextStyle(fontSize: 12),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              const Divider(),
              Padding(
                padding: const EdgeInsets.all(10),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(context),
                      child: const Text('Close'),
                    ),
                    const SizedBox(width: 8),
                    FilledButton(
                      onPressed: () {
                        if (!form.currentState!.validate()) return;
                        Navigator.pop(
                          context,
                          AgentProfile(
                            provider: provider,
                            model: model.text.trim(),
                            endpoint: endpoint.text.trim(),
                          ),
                        );
                      },
                      child: const Text('Save preview profile'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
