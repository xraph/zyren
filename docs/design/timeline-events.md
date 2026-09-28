# Timeline events

You can mark moments in a clip and subscribe to playback notifications through
`zyren_timeline`. Markers belong to the timeline, so you can use them with object
tracks, camera tracks or a clip that only carries events.

## Playback contract

`TimelineMarker` contains a unique, nonempty `id`, a nonnegative `time` and an
optional label. Pass markers in time order to `SceneTimelinePlugin`. Equal times
keep their declaration order. The plugin copies the list and rejects markers
past the clip's duration.

Listen to `events` for immutable `TimelineEvent` records. Each record contains
its marker, a zero-based `loopIndex` and the sampled `position` after the advance.
Delivery uses an asynchronous broadcast stream, after all track samples validate
and their edits apply. A listener sees a notification about a completed advance;
the scene may have advanced again before it handles that notification. Sampled
position and marker time are therefore separate fields.

Forward playback emits markers in `(previous, next]`. Starting at zero emits
zero-time markers once. Pausing and resuming at zero does not repeat them.
Calling `seek` emits nothing and resets the loop index; seeking to zero arms the
start markers for the next playback advance. Playing a finished clip restarts it
at zero.

At a loop boundary, markers at the duration fire for the ending loop before
zero-time markers fire for the next loop. One advance may cross several loops.
Equal timestamps remain ordered, including exact boundary landings. A failed
pose sample emits no events for that advance, retains the previous position and
releases playback's frame demand.

The default limit is 1,024 events per advance, including start markers. You can
change it with `maxEventsPerAdvance`. The plugin counts crossings before applying
a pose or building event records. If an advance would exceed the limit, playback
pauses and reports a `StateError` without skipping markers or changing position.
This bounds work for very short looping clips, even when the engine supplies an
explicit delta. Consumer-owned paused stream subscriptions can still buffer
notifications; cancel them when their consumer closes.

Seeking, attachment and detachment are silent. Detaching preserves position and
stops playback. Plugin reuse after renderer recovery preserves the consumed start
marker state. Events describe local playback only; imported animation events,
reverse playback, clip mixing, skinning and morph targets remain separate work.

## Workbench and checks

The exploded assembly marks its start, midpoint and end. A compact status beside
the playback controls shows the last delivered marker. Scrubbing clears that
status because it does not dispatch events. Playback markers do not add scene
meshes or alter renderer packets.

Tests cover ordering, endpoints, repeated frames, loop overshoot, multiple loops,
pause/resume, seek/replay, detached reuse, invalid markers, failed track samples
and the event limit. Workbench checks cover playback, silent scrubbing and compact
desktop/narrow layouts. Run the native Metal workbench to confirm event delivery
through the real engine and presentation path.
