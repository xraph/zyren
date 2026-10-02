# Scene inspector

Add inspection to your Flutter app with the optional `zyren_inspector` package:

```dart
import 'package:zyren_inspector/zyren_inspector.dart';

SizedBox(
  width: 360,
  height: 600,
  child: SceneInspector(controller: controller),
)
```

You can search object names, expand the hierarchy and select an object to see
its transform, layers, local visibility and mesh settings. Search includes the
ancestors of matching objects, even inside collapsed groups. Removed objects
leave the selection automatically. The tree refreshes at most every 200 ms
after scene changes and builds visible rows lazily.

To connect inspection to your app's selection, supply `selectedObject` and
`onSelectionChanged`. The callback runs when you select a row. Inspection does
not edit objects, move cameras, create native sessions or acquire frame demand.
You keep ownership of the controller. Both widgets cancel their subscriptions
and pending timers when unmounted or given another controller.

For statistics alone, place this widget over your view:

```dart
SceneStatsOverlay(
  controller: controller,
  refreshInterval: const Duration(milliseconds: 500),
)
```

The overlay lets pointer input pass through. Give it a positive refresh interval.
It reads `SceneController.latestFrameStats` when mounted, so you can inspect an
idle view without rendering another frame. Subsequent stream samples are
coalesced, including the final sample after rendering stops. "Last frame" refers
to a presented frame, not a current FPS measurement.

CPU build and encode timings cover Dart work. GPU timing and residency remain
"unavailable" unless the backend supplies them. Local visibility and scene bounds
cannot establish pixel visibility or occlusion. Failure, suspension and an empty
scene are separate states; the inspector shows the latest operational issue it
observed, or the current failure when attached after an error.

The package uses public Flutter facade contracts. It contains no renderer,
native bridge or geospatial dependency. See the
[culling lab](../../examples/shader_lab/README.md#culling-lab) for selection,
framing and inspection in a native view.
