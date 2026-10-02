# Cloud density and animation controls

You can reduce cloud density from 100% to 0% and turn animation off in Planet's
Google cloud lab. Both choices survive preset and quality changes. Auto quality
uses the device profile; the recorded runs selected Medium on iPhone and High on
iPad and Mac.

Density multiplies each active layer's extinction and its shadows while keeping
the layer ratios and weather coverage. Zero removes cloud-layer extinction.
Atmosphere and haze have their own settings.

Pausing freezes the cloud motion clock, preserves the configured velocities and
allows temporal refinement to finish. Resuming advances from that frozen clock.
The core API exposes `CloudParameters.densityMultiplier`,
`CloudPlugin(animationEnabled: false)` and `CloudController.animationEnabled`.

## Native checks

The controls landed in `8969bff`. Native checks exposed two remaining issues:
temporal effect-slot updates kept requesting frames, and wall-time gaps cleared
paused history. Commit `2ba98e9` updates those slots without scheduling another
frame and uses the active animation clock for history. Normal effect replacement
still invalidates the scene. The idle check in `a771806` drains an already
submitted final presentation before observing whether drawing has stopped.

[Recorded runs](cloud-controls.json) cover the native Metal profile fixture on
all three Apple device types:

| Device | Presented frames | Samples | Result |
| --- | ---: | ---: | --- |
| Mac | 201 | 14 | Passed |
| iPhone 16 Pro | 200 | 14 | Passed |
| iPad Pro 13-inch M4 | 200 | 14 | Passed |

At logical sizes 1000x700 and 390x700, the fixture pauses animation, finishes
16-frame refinement and verifies that further presentations stop after draining
in-flight work. Density changes to 25%, 0% and 100% and quality changes refine
again while the motion clock stays frozen. Resuming advances that clock.
All runs ended with zero sessions, renderers, retiring resources, held drawables
and CPU readback bytes.

Eight core effect and postprocess tests, four native geospatial control and
temporal tests, and four Planet widget tests passed. Widget checks cover the
controls at desktop and narrow widths and preserve their choices across preset
and quality changes. Analysis, package boundaries and the Apple ABI check passed.

The same frozen signed iOS fixture ran on iPhone and iPad over wireless. Its
source and bundle digests are recorded in the JSON, including the concurrent
local declarative Flutter overlay. Included source files stayed unchanged during
that compilation. The Mac fixture used `2ba98e9` plus the final-presentation drain
later committed in `a771806`.

## Normal apps and limits

The normal Mac Google cloud lab was rebuilt and left running. With live Tokyo
tiles, the density slider accepted 50%, animation stayed off and the interface
showed "Clouds refined." Normal profile apps were reinstalled on iPhone and iPad.
The iPad launched and remained alive. The iPhone locked before its final launch.

The native fixture loads cloud assets and adds a 64 MiB GPU buffer. It has no
Google tiles or network load and does not measure interactive FPS or Takram
visual parity. The Mac live check covers those controls with provider tiles;
physical touch operation on iPhone and iPad remains unverified. Normal app builds
included concurrent workspace changes and have no whole-source digest recorded.
