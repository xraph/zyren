import 'package:zyren/zyren.dart';
import 'zyren_agents.dart';

/// Publishes the host registry through the engine's shared service key.
class AgentRegistryPlugin extends ScenePlugin {
  final AgentRegistry registry;
  AgentRegistryPlugin(this.registry);
  @override
  String get id => 'zyren.agents';
  @override
  void attach(PluginContext context) => context.provide(sceneAgents, registry);
}

/// Attach this alongside any runtime plugin's existing AgentProvider adapter.
/// Recovery and detachment retire old providers and pending commands automatically.
class AgentProviderPlugin extends ScenePlugin {
  @override
  final String id;
  final Set<String> runtimeDependencies;
  final Iterable<AgentProvider> Function(PluginContext context) createProviders;
  AgentProviderPlugin({
    required this.id,
    required Set<String> runtimeDependencies,
    required this.createProviders,
  }) : runtimeDependencies = Set.unmodifiable(runtimeDependencies);
  @override
  Set<String> get dependencies => {'zyren.agents', ...runtimeDependencies};
  @override
  void attach(PluginContext context) {
    final registry = context.service(sceneAgents);
    for (final provider in createProviders(context)) {
      context.scope.keep(registry.register(provider));
    }
  }
}
