# Geospatial offline data checks

Run the offline coast lab with `fvm flutter run -d macos -t
lib/layers/offline_main.dart` from `examples/planet`. You can download, cancel,
resume, inject a source denial, retry and reopen the saved region.

The data, terrain and streaming suite passed 111 tests on macOS. This includes
fresh-process terrain loading with transport forbidden, native imagery decoding,
region publication and cancellation, file corruption, concurrent writers,
process termination at publication stages, bounded scalar fields and scoped data
services. The refresh regression now preserves a fresh denial even when older
cached bytes remain readable.

The native Flutter integration test passed with `flutter test --no-pub -d macos
integration_test/offline_test.dart`. It downloads the finite synthetic dataset,
cancels after one verified resource, resumes, observes a denied refresh, retries,
switches to offline-only access and closes/reopens the scene and file store. The
cold view reports zero transport attempts, pinned payload bytes and the expected
105 m depth sample. The renderer reports ready terrain at 1000 x 700 and 390 x 700;
the canvas remains taller than 400 logical pixels and the controls are reachable.

Two application tests passed for the repository and model-cache adapter. The
model test reopens a pinned archive and loads its glTF, external vertex/UV buffer
and PNG texture through the native decoder with transport forbidden. The model
cache keeps its own archive pins. It does not join the geographic
region commit, so a complete geographic manifest cannot certify model coverage.

Manual inspection of the native window is pending because the Mac was locked.
The automated native checks do not establish visual acceptance. Global coast
masks, bathymetry providers, licensed live data and mobile/Windows/Linux results
remain unqualified. The lab's field colours are not an ocean material.

Storage qualification covers macOS process crashes. Portable Dart does not expose
a directory fsync here, so sudden power-loss durability is not established.
Keep the directory private to cooperating store instances. See the package README
for stale PID gates, byte admission and corrupt-index recovery limits.
