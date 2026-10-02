part of '../zyren_interaction.dart';

const sceneInteraction = ServiceKey<SceneInteractionRouter>(
  'zyren.interaction',
);

/// Connects a borrowed router for this plugin attachment. Dispose the router
/// yourself when its scene owner ends. Detach preserves handlers for reattach.
final class SceneInteractionPlugin extends ScenePlugin {
  final SceneInteractionRouter router;
  final Set<SceneGesture> gestures;
  SceneInteractionPlugin(
    this.router, {
    Set<SceneGesture> gestures = const {SceneGesture.tap},
  }) : gestures = Set.unmodifiable(gestures);

  @override
  String get id => 'zyren.interaction';

  @override
  void attach(PluginContext context) {
    if (!identical(context.scene, router.scene)) {
      throw ArgumentError('The router must belong to this plugin scene.');
    }
    final input = context.input;
    if (input == null) {
      throw StateError('Object interaction requires viewport input.');
    }
    context.provide(sceneInteraction, router);
    context.scope.keep(router.connect(input, gestures: gestures));
  }
}
