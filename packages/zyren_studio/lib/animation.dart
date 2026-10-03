import 'package:zyren_timeline/zyren_timeline.dart';
import 'zyren_studio.dart';

/// Attach this timeline to a reconstructed preview, leaving the editor untouched.
SceneTimelinePlugin studioTimeline(StudioScene scene, String clipId) {
  final clip = scene.document.clips.singleWhere((c) => c.id == clipId);
  return SceneTimelinePlugin(
    duration: Duration(microseconds: clip.durationMicroseconds),
    tracks: [
      for (final entry in clip.tracks.entries)
        TransformTrack(scene.objects[entry.key]!, [
          for (final key in entry.value)
            TransformKeyframe(
              Duration(microseconds: key.microseconds),
              position: key.position,
              rotation: key.rotation,
              scale: key.scale,
              visible: key.visible,
            ),
        ]),
    ],
  );
}
