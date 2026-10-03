part of '../flutter_zyren_studio.dart';

final class StudioEditorCommand {
  final String id, label;
  final SingleActivator? shortcut;
  final bool Function(StudioEditorContext) enabled;
  final FutureOr<void> Function(StudioEditorContext) handler;
  StudioEditorCommand({
    required String id,
    required this.label,
    this.shortcut,
    required this.enabled,
    required this.handler,
  }) : id = _editorId(id);
}

String _shortcutSignature(SingleActivator shortcut) =>
    '${shortcut.trigger.keyId}:${shortcut.control}:${shortcut.shift}:${shortcut.alt}:${shortcut.meta}';

class _EditorCommandIntent extends Intent {
  final String id;
  const _EditorCommandIntent(this.id);
}

bool _isTextEntry() =>
    FocusManager.instance.primaryFocus?.context
        ?.findAncestorStateOfType<EditableTextState>() !=
    null;

class _EditorShortcut extends ShortcutActivator {
  final SingleActivator shortcut;
  final bool Function() enabled;
  _EditorShortcut(this.shortcut, this.enabled);
  @override
  Iterable<LogicalKeyboardKey> get triggers => shortcut.triggers;
  @override
  String debugDescribeKeys() => shortcut.debugDescribeKeys();
  @override
  bool accepts(KeyEvent event, HardwareKeyboard state) {
    if (!enabled()) return false;
    if (!shortcut.control &&
        !shortcut.meta &&
        !shortcut.alt &&
        _isTextEntry()) {
      return false;
    }
    return shortcut.accepts(event, state);
  }
}

void _reportEditorError(Object error, StackTrace stack) =>
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stack,
        library: 'flutter_zyren_studio',
      ),
    );
