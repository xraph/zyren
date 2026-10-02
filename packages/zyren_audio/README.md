# zyren_audio

You can attach a native audio listener and mono PCM emitters to your scene.
Run `dart run example/native_audio.dart` for an offline native mixer example.
Pass `--play` to hear the one-second tone, or `--device-check` to open and close
your output device without playing a sound.

Create `SpatialAudio` with your scene root and `AudioListener(node)`. Add an
emitter with a stable ID, its scene node and mono float32 samples at the engine's
sample rate. Call `play`, `pause` and `configure` through the returned emitter.
Call `sync` after changing transforms. Parent transforms affect sound positions;
generic listeners face local +Z, while cameras use their target/up pose.

The backend compiles miniaudio 0.11.23 as a Dart native asset. Its spatial mixer
supports inverse, linear and exponential distance attenuation. Distances use your
scene's units. The default engine owns at most 64 emitters and 64 MiB of PCM.
It copies samples, so you may release or change the input buffer after `add`.

Close the engine with your scene attachment. It releases all voices and PCM.
`sync` closes detached emitters and pauses playback if the listener was removed.
Device initialization failures throw `AudioException` with the native result
code. Explicit `offline: true` uses the same mixer without an output device;
normal playback never falls back to a null device.

Five tests exercise the actual native mixer on macOS: distance energy, stereo
orientation, PCM ownership, playback/removal, listener removal and validation.
A silent native device probe initialized and closed Core Audio on macOS.
Audible playback, mobile audio interruptions and other platforms remain
unverified. Streaming, decoding, occlusion and timeline synchronization are
later milestones. You supply decoded PCM in this first slice.

See [the upstream manual](https://miniaud.io/docs/manual/index.html) for the
engine API and [the retained license](native/vendor/LICENSE) for redistribution.
The vendored header comes from tag `0.11.23`, SHA-256
`7e4f3f13c8fe66df2080ac3dd12a89193e3c2463cb7f067c798abd7331cd8ee6`.
