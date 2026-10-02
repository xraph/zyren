# Native engineering review

Run this macOS example to convert CAD, inspect source objects, keep notes through
model reloads and reconcile edits with a shared review service.

```sh
flutter pub get
flutter run -d macos
```

The demo is a real IFC housing converted by `../../tool/cad/convert.py`. Load it
with **Demo**, select the housing and add a note. Tap a surface to set the next
note's local anchor. Drag to orbit, scroll to zoom, or use Fit. Orange markers
show note anchors. Reload keeps the source bindings and review notes.

Open bundle expects a folder containing `model.glb` and `review.json`. The digest
must match before geometry is loaded. A failed import keeps the previous model.
Objects missing from a new version remain in the review as unbound records.
Save local writes review JSON atomically; Load review asks before replacing your
current local records. Local files contain review data, not geometry.

## Convert source CAD

First prepare the Python environment described in the [converter guide](../../tool/cad/README.md).
You can enter or pick its Python executable and converter script in the app, or
provide their absolute paths when launching:

```sh
flutter run -d macos \
  --dart-define=ZYREN_CAD_PYTHON=/absolute/path/to/.venv/bin/python \
  --dart-define=ZYREN_CAD_CONVERTER=/absolute/path/to/tool/cad/convert.py
```

Choose Convert CAD, the source file and an output parent folder. Each conversion
creates a new bundle directory and opens it after verification. IFC uses GlobalId
and metre units. STEP/IGES also require a source identity map and a scale for the
transferred coordinates. A fresh process isolates the two parser runtimes. The
app drains parser logs, bounds displayed errors and stops a conversion after five
minutes. Parser errors keep your model and notes available for retry.

This is a local developer application. Its macOS App Sandbox is disabled so the
chosen Python environment can load native parser libraries and read the selected
source files. Convert trusted files here. A distributable host should move
untrusted parsing into a separately constrained worker. The renderer uses Metal
with native presentation required; there is no browser rendering fallback.

## Share a review

Start the [self-hosted HTTPS service](../../deploy/README.md), then choose Connect.
Enter the `/review` endpoint and a reader or writer token. Tokens stay in memory
and are neither saved to disk nor included in local review JSON. Use the same
document ID on both ends (the default is `review`); set `ZYREN_REVIEW_ID` with
`--dart-define` for another review.

Connecting reads the service without replacing local data. Sync merges edits
against the last acknowledged shared revision. A first connection uses an empty
common baseline, so unequal records require an explicit decision. Choose base,
local or remote for each conflicting record, then apply the choices. The app
shows the full record values, including deletion. Choices apply only while those
exact values still match; newer remote edits require another decision.

A reader can connect but receives a visible denial on Sync, which writes a merged
revision. Local edits survive denial, connection failure and stale writes. Retry
reads the current revision again. Disconnect also keeps local edits. Reconnecting
to the same endpoint during the app session retains its acknowledged baseline.
Restarting the app requires loading a saved local review and reconnecting.

The service synchronizes review records, not model files. Share the matching CAD
bundle through your existing file delivery process. This example does not include
user provisioning, live push updates or a hosted model library. Sync is explicit.

## Checks

```sh
flutter analyze lib test integration_test
flutter test test/widget_test.dart
flutter test integration_test/native_review_test.dart -d macos
```

Widget tests cover 1100- and 390-pixel layouts, note editing, reload, denied writes,
retry and conflict choices. The native integration test uses Metal and a real
local HTTP service, checks local persistence and shared conflict recovery, and
requires zero presentation readback bytes. TLS and container restart checks live
in the engineering package's service tests and deployment smoke script.
