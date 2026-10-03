import 'package:zyren/zyren.dart';
import '../geospatial_plugin.dart';
import 'extension.dart';

/// Validate identity as well as IDs before the engine owns any new resources.
void validateGeospatialHost(GeospatialPlugin host, List<ScenePlugin> plugins) {
  final hosts = plugins.whereType<GeospatialPlugin>().toList();
  if (hosts.length != 1 ||
      !identical(hosts.single, host) ||
      host.id != GeospatialPlugin.pluginId) {
    throw StateError('Install exactly one geospatial host per scene.');
  }
  for (final expected in host.scenePlugins) {
    if (!plugins.any((plugin) => identical(plugin, expected))) {
      throw StateError(
        'Install the complete GeospatialPlugin.scenePlugins list. Missing ${expected.id}.',
      );
    }
  }
}

void validateGeospatialExtension(
  GeospatialExtension extension,
  List<ScenePlugin> plugins,
) {
  if (!RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(extension.localId) ||
      extension.id != 'geospatial.ext.${extension.localId}') {
    throw ArgumentError(
      'Use a nonempty extension local ID with letters, digits, hyphens or underscores.',
    );
  }
  if (extension.contractVersion != 1) {
    throw ArgumentError(
      'Unsupported geospatial contract version ${extension.contractVersion}.',
    );
  }
  if (!extension.dependencies.contains(GeospatialPlugin.pluginId) ||
      plugins.whereType<GeospatialPlugin>().length != 1) {
    throw StateError(
      'Geospatial extensions require the geospatial host dependency.',
    );
  }
  for (final plugin in plugins) {
    if (plugin is GeospatialExtension &&
        !identical(plugin, extension) &&
        extension.exclusiveCapabilities
            .intersection(plugin.exclusiveCapabilities)
            .isNotEmpty) {
      throw StateError(
        '${extension.id} and ${plugin.id} provide the same exclusive capability.',
      );
    }
    if (extension.incompatiblePluginIds.contains(plugin.id)) {
      throw StateError('${extension.id} cannot coexist with ${plugin.id}.');
    }
  }
  for (final adapter in extension.adapters) {
    if (!adapter.id.startsWith('${extension.id}.') ||
        !adapter.dependencies.contains(extension.id)) {
      throw ArgumentError(
        'Adapters must use extension-prefixed IDs and depend on ${extension.id}.',
      );
    }
    if (!plugins.any((plugin) => identical(plugin, adapter))) {
      throw StateError('Missing adapter ${adapter.id} for ${extension.id}.');
    }
  }
}
