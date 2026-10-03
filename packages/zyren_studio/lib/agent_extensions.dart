import 'package:zyren/zyren.dart';
import 'package:zyren_agents/zyren_agents.dart';
import 'zyren_studio.dart';

/// A plugin owns its runtime binding and providers. Studio owns their lifetime.
/// Future modeling, rigging and morphing plugins use this same public contract.
class StudioAgentExtension {
  final String id;
  final Set<String> scopes;
  final void Function(StudioAgentExtensionContext) attach;
  StudioAgentExtension({
    required this.id,
    required Set<String> scopes,
    required this.attach,
  }) : scopes = Set.unmodifiable(scopes);
}

class StudioAgentExtensionContext {
  final StudioScene scene;
  final AgentRegistry agents;
  final bool Function() isAvailable;
  final void Function() onChanged;
  final void Function(ScenePlugin) usePlugin;
  final _registrations = <Registration>[];
  bool _closed = false;
  StudioAgentExtensionContext({
    required this.scene,
    required this.agents,
    required this.isAvailable,
    required this.onChanged,
    required this.usePlugin,
  });
  Registration register(AgentProvider provider) {
    if (_closed) throw StateError('Studio plugin scope is closed.');
    final registration = agents.register(provider);
    _registrations.add(registration);
    return registration;
  }

  /// Register any resource cleanup alongside provider registrations.
  void keep(Registration registration) {
    if (_closed) {
      registration.dispose();
      return;
    }
    _registrations.add(registration);
  }

  void dispose() {
    if (_closed) return;
    _closed = true;
    for (final registration in _registrations.reversed) {
      registration.dispose();
    }
    _registrations.clear();
  }
}
