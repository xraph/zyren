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
  final _providers = <AgentProvider>[];
  final _activeProviders = <AgentProvider, Registration>{};
  final bool deferRegistration;
  PluginContext? _attachment;
  bool _closed = false;
  StudioAgentExtensionContext({
    required this.scene,
    required this.agents,
    required this.isAvailable,
    required this.onChanged,
    required this.usePlugin,
    this.deferRegistration = false,
  });
  Registration register(AgentProvider provider) {
    if (_closed) throw StateError('Studio plugin scope is closed.');
    if (deferRegistration) {
      _providers.add(provider);
      if (_attachment case final attachment?) {
        try {
          _attachProvider(provider, attachment);
        } catch (_) {
          _providers.remove(provider);
          rethrow;
        }
      }
      final lease = Registration(() {
        _providers.remove(provider);
        _activeProviders.remove(provider)?.dispose();
      });
      _registrations.add(lease);
      return lease;
    }
    final registration = agents.register(provider);
    _registrations.add(registration);
    return registration;
  }

  void _attachProvider(AgentProvider provider, PluginContext context) {
    final registration = agents.register(provider);
    _activeProviders[provider] = registration;
    context.scope.keep(
      Registration(() {
        registration.dispose();
        if (identical(_activeProviders[provider], registration)) {
          _activeProviders.remove(provider);
        }
      }),
    );
  }

  /// Bind advertised tools to the same engine attachment as their runtime.
  /// Engine rollback, recovery and detach retire the provider registrations.
  ScenePlugin binding(String id, Iterable<String> runtimeIds) {
    if (!deferRegistration) {
      throw StateError(
        'Deferred registration is required for runtime binding.',
      );
    }
    return _StudioBindingPlugin(id, runtimeIds.toSet(), this);
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
    Object? failure;
    StackTrace? trace;
    for (final registration in _registrations.reversed) {
      try {
        registration.dispose();
      } catch (error, stack) {
        failure ??= error;
        trace ??= stack;
      }
    }
    _registrations.clear();
    _providers.clear();
    if (failure != null) Error.throwWithStackTrace(failure, trace!);
  }
}

final class _StudioBindingPlugin extends ScenePlugin {
  @override
  final String id;
  final Set<String> _runtimeIds;
  final StudioAgentExtensionContext owner;
  _StudioBindingPlugin(this.id, this._runtimeIds, this.owner);
  @override
  Set<String> get dependencies => {'zyren.agents', ..._runtimeIds};
  @override
  void attach(PluginContext context) {
    if (owner._closed) throw StateError('Studio plugin scope is closed.');
    final registry = context.service(sceneAgents);
    if (!identical(registry, owner.agents)) {
      throw StateError('Studio extension belongs to a different registry.');
    }
    owner._attachment = context;
    context.scope.keep(
      Registration(() {
        if (identical(owner._attachment, context)) owner._attachment = null;
      }),
    );
    for (final provider in owner._providers) {
      owner._attachProvider(provider, context);
    }
  }
}
