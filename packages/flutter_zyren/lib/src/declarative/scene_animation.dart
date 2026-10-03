import 'package:flutter/widgets.dart';
import 'package:zyren/zyren.dart';
import 'package:zyren_gltf/zyren_gltf.dart';
import 'scene_canvas.dart';

final _animationOwners = Expando<Object>('declarative model animation owner');

/// Owns one instance mixer and action. Use in ModelNode.builder. Skinned and
/// morph models require native deformation. Playback runs outside Flutter build.
class ModelAnimationNode extends StatefulWidget {
  final ModelInstance instance;
  final String? clipName;
  final int? clipIndex;
  final AnimationLoop loop;
  final double speed;
  final int? repetitions;
  final bool playing, paused;
  final Widget child;
  final void Function(AnimationAction)? onAction;
  const ModelAnimationNode({
    super.key,
    required this.instance,
    this.clipName,
    this.clipIndex,
    this.loop = AnimationLoop.repeat,
    this.speed = 1,
    this.repetitions,
    this.playing = true,
    this.paused = false,
    this.child = const SizedBox.shrink(),
    this.onAction,
  });
  @override
  State<ModelAnimationNode> createState() => _ModelAnimationNodeState();
}

class _ModelAnimationNodeState extends State<ModelAnimationNode> {
  AnimationMixer? _mixer;
  AnimationAction? _action;
  ModelInstance? _owned;
  Object? _error;
  void _trySync({bool restart = false}) {
    try {
      _sync(restart: restart);
      _error = null;
    } catch (error) {
      _release();
      _error = error;
    }
  }

  void _release() {
    _action?.stop();
    _action = null;
    if (_owned != null && identical(_animationOwners[_owned!], this)) {
      _animationOwners[_owned!] = null;
    }
    _owned = null;
    _mixer = null;
  }

  ModelAnimation _clip() {
    if (widget.clipName != null && widget.clipIndex != null) {
      throw ArgumentError('Choose clipName or clipIndex.');
    }
    final clips = widget.instance.animations;
    if (widget.clipName case final name?) {
      final matches = clips.where((clip) => clip.name == name).toList();
      if (matches.length != 1) {
        throw ArgumentError(
          'Clip name must identify exactly one animation: $name',
        );
      }
      return matches.single;
    }
    final index = widget.clipIndex ?? 0;
    RangeError.checkValidIndex(index, clips, 'clipIndex');
    return clips[index];
  }

  void _sync({bool restart = false}) {
    final clip = _clip();
    if (_owned != widget.instance) {
      _release();
      final mixer = widget.instance.mixer;
      if (_animationOwners[widget.instance] != null ||
          mixer.actions.isNotEmpty) {
        throw StateError('Model mixer already has a playback owner.');
      }
      _animationOwners[widget.instance] = this;
      _owned = widget.instance;
      _mixer = mixer;
    }
    if (!widget.playing || restart) {
      _action?.stop();
      _action = null;
    }
    if (!widget.playing) {
      return;
    }
    if (_action == null) {
      _action = _mixer!.play(
        clip,
        loop: widget.loop,
        speed: widget.speed,
        repetitions: widget.repetitions,
      );
      widget.onAction?.call(_action!);
    } else {
      if (_action!.loop != widget.loop) {
        _action!.loop = widget.loop;
      }
      if (_action!.speed != widget.speed) {
        _action!.speed = widget.speed;
      }
      if (_action!.repetitions != widget.repetitions) {
        _action!.repetitions = widget.repetitions;
      }
    }
    if (widget.paused) {
      if (!_action!.isPaused) {
        _action!.pause();
      }
    } else if (_action!.isPaused && !_action!.isFinished) {
      _action!.resume();
    }
  }

  @override
  void initState() {
    super.initState();
    _trySync();
  }

  @override
  void didUpdateWidget(ModelAnimationNode oldWidget) {
    super.didUpdateWidget(oldWidget);
    _trySync(
      restart:
          widget.clipName != oldWidget.clipName ||
          widget.clipIndex != oldWidget.clipIndex,
    );
  }

  @override
  void deactivate() {
    _release();
    super.deactivate();
  }

  @override
  void activate() {
    super.activate();
    _trySync();
  }

  @override
  void dispose() {
    _release();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      throw _error!;
    }
    return ScenePluginNode(plugin: _mixer!, child: widget.child);
  }
}
