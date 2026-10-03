# Flutter Zyren Audio

Use `AudioFocusSession` to connect your playback engine to mobile audio focus.
Pass your engine's suspend and resume callbacks, then call `play()`, `pause()`
and `setForeground()` from your host.

```dart
final focus = AudioFocusSession(
  suspend: audio.suspend,
  resume: audio.resume,
  onError: reportError,
);
final cancel = focus.addStateListener(() {
  // Update your host from focus.allowed, focus.foreground and focus.wantsPlayback.
});
await focus.play();
await focus.setForeground(false);
cancel();
focus.dispose();
await focus.released;
```

You can own one mobile session per binary messenger and channel. A second
constructor throws `StateError` until you dispose the current owner and await
`released`. The native plugin also rejects acquisition from another Flutter
engine while an engine holds focus. Listener registrations are limited to 32
per session; cancel them when your host detaches.

Focus loss and ducking suspend playback. A transient gain reacquires focus only
when your host is foregrounded and still wants playback. Permanent loss or a
removed audio route requires another Play. Background Play keeps that intent
without acquiring focus, so returning to the foreground can resume it.

The plugin uses `zyren/audio-session`. Android uses `AudioFocusRequest` with
`USAGE_GAME`, music content and pause-on-ducking, starting at API 26. iOS uses
`AVAudioSession` playback with `mixWithOthers`, starting at iOS 14. Desktop hosts
keep the same foreground policy without acquiring a native audio session. This
package does not create an audio engine or change its mixing policy.

Flutter mock tests cover policy, ownership, listener cancellation and delayed
native replies. Device interruption, headphone removal and multiple-engine
acquisition still need native qualification on Android and iOS.
