part of '../flutter_zyren_studio.dart';

/// Adapt these panes into the existing workspace's pane type.
final class StudioEditorPane {
  final String id, title;
  final IconData icon;
  final Widget child;
  final StudioEditorDock defaultDock;
  final bool initiallyOpen;
  final int order;
  const StudioEditorPane(
    this.id,
    this.title,
    this.icon,
    this.child, {
    this.defaultDock = StudioEditorDock.right,
    this.initiallyOpen = false,
    this.order = 0,
  });
}

typedef StudioEditorWorkspaceBuilder =
    Widget Function(BuildContext, List<StudioEditorPane>, Widget viewport);

/// Adds scoped UI and shortcuts around the host's existing docking workspace.
class StudioEditorHost extends StatefulWidget {
  final StudioEditorHostController controller;
  final Widget viewport;
  final FocusNode? viewportFocusNode;
  final StudioEditorWorkspaceBuilder workspaceBuilder;
  const StudioEditorHost({
    super.key,
    required this.controller,
    required this.viewport,
    required this.workspaceBuilder,
    this.viewportFocusNode,
  });
  @override
  State<StudioEditorHost> createState() => _StudioEditorHostState();
}

class _StudioEditorHostState extends State<StudioEditorHost> {
  final _ownedViewportFocus = FocusNode(debugLabel: 'Studio viewport');
  FocusNode get _viewportFocus =>
      widget.viewportFocusNode ?? _ownedViewportFocus;
  @override
  void dispose() {
    _ownedViewportFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) {
      final host = widget.controller;
      final shortcuts = <ShortcutActivator, Intent>{
        for (final entry in host._commands.values)
          if (entry.value.shortcut case final shortcut?)
            _EditorShortcut(
              shortcut,
              () =>
                  entry.context.isAvailable &&
                  entry.value.enabled(entry.context),
            ): _EditorCommandIntent(
              entry.value.id,
            ),
      };
      final viewport = Focus(
        focusNode: _viewportFocus,
        child: Stack(
          key: const ValueKey('studio.editor.viewport'),
          fit: StackFit.expand,
          children: [
            widget.viewport,
            for (final entry in host._overlays.values)
              Positioned.fill(
                key: ValueKey('studio.overlay.${entry.value.id}'),
                child: IgnorePointer(
                  ignoring:
                      !entry.value.interactive || !entry.context.isAvailable,
                  child: entry.value.builder(context, entry.context),
                ),
              ),
          ],
        ),
      );
      final panes = <StudioEditorPane>[
        for (final entry in host._panels.values)
          StudioEditorPane(
            entry.value.id,
            entry.value.title,
            entry.value.icon,
            _StudioContributedPanel(
              key: ValueKey('studio.panel.${entry.value.id}'),
              entry: entry,
              fallbackFocus: _viewportFocus,
            ),
            defaultDock: entry.value.defaultDock,
            initiallyOpen: entry.value.initiallyOpen,
            order: entry.value.order,
          ),
      ];
      return Shortcuts(
        shortcuts: shortcuts,
        child: Actions(
          actions: {
            _EditorCommandIntent: CallbackAction<_EditorCommandIntent>(
              onInvoke: (intent) {
                final entry = host._commands[intent.id];
                final shortcut = entry?.value.shortcut;
                if (entry == null ||
                    !entry.context.isAvailable ||
                    !entry.value.enabled(entry.context)) {
                  return null;
                }
                if (shortcut != null &&
                    !shortcut.control &&
                    !shortcut.meta &&
                    !shortcut.alt &&
                    _isTextEntry()) {
                  return null;
                }
                unawaited(
                  host.executeCommand(intent.id).catchError(_reportEditorError),
                );
                return null;
              },
            ),
          },
          child: FocusTraversalGroup(
            child: widget.workspaceBuilder(
              context,
              List.unmodifiable(panes),
              viewport,
            ),
          ),
        ),
      );
    },
  );
}

class _StudioContributedPanel extends StatefulWidget {
  final _Owned<StudioEditorPanel> entry;
  final FocusNode fallbackFocus;
  const _StudioContributedPanel({
    super.key,
    required this.entry,
    required this.fallbackFocus,
  });
  @override
  State<_StudioContributedPanel> createState() =>
      _StudioContributedPanelState();
}

class _StudioContributedPanelState extends State<_StudioContributedPanel> {
  final _focus = FocusScopeNode(debugLabel: 'Studio contributed panel');
  bool _restoreFocus = false;
  @override
  void initState() {
    super.initState();
    widget.entry.context._host.addListener(_registrationChanged);
  }

  void _registrationChanged() {
    if (!widget.entry.context.isActive && _focus.hasFocus) _restoreFocus = true;
  }

  @override
  void dispose() {
    widget.entry.context._host.removeListener(_registrationChanged);
    final restore = _restoreFocus || _focus.hasFocus;
    final fallback = widget.fallbackFocus;
    _focus.dispose();
    if (restore) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (fallback.context != null && fallback.canRequestFocus) {
          fallback.requestFocus();
        }
      });
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FocusScope(
    node: _focus,
    child: Semantics(
      container: true,
      label: widget.entry.value.title,
      child: widget.entry.value.builder(context, widget.entry.context),
    ),
  );
}
