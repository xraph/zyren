# Native rendering limits and cloud quality

You can now select Auto, Low, Medium, High or Ultra in the Google cloud lab.
Auto selects Medium on phones and High on tablets and desktops. The normal app
shows when clouds are refining and when their 16-frame cycle has completed.

| Device | Scene edge / total pixels | Auto cloud edge | Ultra cloud edge | Tile payload budget |
| --- | --- | --- | --- | --- |
| Phone | 1600 / 1,572,864 | 512 | 640 | 48 MiB |
| Tablet | 1920 / 2,097,152 | 640 | 640 | 64 MiB |
| Desktop | 1920 / 2,097,152 | 640 | 768 | 64 MiB |

The previous demo limited the scene to 640 pixels and clouds to 192 pixels.
Waiting could never lift those caps. The new scene limits account for rounded
dimensions, and tile loading uses four requests with an eight-pixel screen-error
target. Cloud device profiles preserve Takram's sampling presets and bound the
shadow maps separately. You can supply other limits through `CloudQualitySettings`.

## Checked behavior

The geospatial suite passes 212 tests with 21 optional skips. Planet passes 16
widget tests, including quality selection before renderer attachment at desktop
and phone widths. Analysis and whitespace checks pass.

Native Metal and Pixel 9 Pro Vulkan runs use the pinned atmosphere/cloud assets,
all screen effects and a 64 MiB storage buffer for resource pressure. This buffer
tests capacity, not tile integration. Both runs pass landscape-to-portrait
replacement and every cloud sampling preset. Each setting reaches 16 history
frames, and native readback, renderer, session and retained-surface counters are
zero after disposal. The [structured records](render-quality.json) preserve the
actual resolutions and local log paths. Their elapsed times start at the first
frame-stat sample, so they exclude source loading and are not FPS benchmarks.

The live Tokyo Metal run also passes with real provider tiles at 1894 by 1106
pixels. It records 77 visible tiles, 66,357,698 tile bytes, 30 effects and zero
readback. Low, Ultra and Auto changes through the actual selector each complete
a refinement cycle. The harness verifies the loaded asset hashes and unchanged
source, then restores the normal interactive app. Its source snapshot is
`d24c55d`; the native settings API is `3ab4cc6`.

Physical macOS clicks in the restored app select Ultra, display the completed
refinement state and return to Auto/High. The Pixel normal-app launch succeeds
after testing. Both devices are left with interactive builds, rather than the
integration-test binding that discards physical taps.

## Shader changes and limits of the evidence

Commit `ceeead3` bounds distant cloud marching so a jittered step cannot skip an
entire thin layer. It also reconstructs ground transmission with temporal color
history instead of publishing a permanently coarse raw map. Native regression
tests reproduce both failures and pass with the changes.

Fine speckling remains in isolated orbital cloud captures. Disabling the cloud
pass removes it. The larger targets and completed history do not establish that
this visual issue is fully resolved, and no Takram reference-image comparison
was run. Live city detail can still reach the explicit tile memory limit.

iPhone quality transitions and physical tablet profiles were not rerun here.
The shared policy tests cover both Android and iOS classification, but those
tests do not substitute for device results. The separate input qualification
work retains its iPhone evidence.

## Repeat the checks

From `examples/planet`, use the pinned Flutter SDK and a local result path:

```sh
ZYREN_QUALIFICATION_OUTPUT=/tmp/cloud-quality.json fvm flutter drive \
  --driver=test_driver/qualification.dart \
  --target=integration_test/geospatial_quality_test.dart -d macos
```

Use the connected Pixel ID for Vulkan. The provider-free test disposes its scene;
restore a normal app before handing the device back. For the live city test and
automatic restoration, follow the [runner guide](../../tool/qualification/README.md).
