# Moonlight for globe tiles

You can choose Off, Natural or Visible moonlight in Planet's Google atmosphere
and cloud labs. Visible is the default. It raises lunar surface lighting and adds
2% night fill so tile detail can remain visible when the Moon is new or below the
horizon. Natural uses the lunar irradiance scale without fill. Night view sets
the selected location to 23:00 local solar time; turn it off to restore the
preset time.

Commit `77d1949` adds `moonLight`, `moonLightIntensity` and
`nightLightIntensity` to `AtmosphereAppearance`. Surface lighting follows the
current lunar direction, a Lambert-sphere phase approximation, atmospheric
attenuation, normals and lighting masks. The Moon disk retains its own intensity
control. Solar cloud shadows are not applied to lunar rays. Lunar table lookups
run only on night-side pixels. Commit `4d37137` completes their fade before
sunrise, preserving daylight even just above the horizon.

[Recorded checks](moonlight.json) include seven passing native Metal tests on
Mac and four passing Planet widget tests. The native pixel regression covers a
dark albedo surface, lunar phase, independent disk brightness, zero lunar gain,
lighting masks, the Moon below the horizon, night fill and unchanged daylight.
It uses an unlit plane, generated vacuum tables and CPU pixel readback. GPU
resident bytes return to zero after disposal.

Widget checks at 1000x700 and 390x700 cover both lighting choices and Night view,
preset persistence and restoring the original time. The existing cloud controls
still fit. Analysis passed for the changed files. The workspace boundary check
failed on concurrent `zyren_devtools` imports of `zyren_agents`, outside this
commit; those files were preserved.

The normal Mac and iOS profile apps built successfully. Both bundles passed
signature verification after the Mac app's outer ad hoc seal was refreshed,
preserving its existing metadata. The signed iOS app was installed on iPhone and
iPad. After unlocking, both apps launched successfully and their processes
remained alive. This confirms normal app startup, without a physical touch or
moonlight image check on either device.

The Mac app restarted after unlocking. Its bundle digest still matched the
recorded build. Live Tokyo tiles rendered in daylight, then Night view rendered
with Visible moonlight selected. Terrain and building detail remained visible;
the interface reported 75 tiles, none loading and detail limited by the memory
budget. Keyboard navigation activated Night view because coordinate automation
could not target the window.

The subsequent dropdown comparison was interrupted by a Mac process crash.
`planet-2026-10-02-201028.ips` records `EXC_BAD_ACCESS` at address `0x48` in
`flutter::AccessibilityBridge::CreateRemoveReparentedNodesUpdate()`, followed by
`CommitUpdates()` and `FlutterViewController updateSemantics:`. It occurred while
interacting with the cloud quality dropdown after Night view. Off and Natural
were not visually compared. The normal app was restarted afterward; this run
does not establish reliable Mac control operation or identify a GPU driver loss.

The JSON records the compiled bundle digests and unchanged feature-file hashes.
Other concurrent workspace changes are included in these builds. This check
does not establish physical-device moonlight rendering on iOS, iPadOS or Android,
or matched Takram photometry. Surface moonlight does not light cloud volumes.
