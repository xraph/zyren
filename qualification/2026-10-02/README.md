# Phone qualification rerun, 2026-10-02

Both the Pixel 9 Pro over USB and the iPhone 16 Pro over wireless are reachable.
No device tests were running when qualification started. The iPad and Watch are
still unavailable. The user requested keeping the iPhone on wireless.

Android reaches native startup on the real 426.7 by 952 logical-pixel viewport
with shared-texture presentation. This advances the earlier startup blocker
after `be474e6` fixed Android codec C++ linkage. It does not establish the full
interaction, timeline or disposal qualification.

The first APK packaging attempt fails deleting a generated Vulkan validation
library. The next build and installation pass. The native layout test reaches
its selection check, but the test taps before its inspector scroll is laid out.
The tap lands on the timeline. The test now pumps after centering the row and
asserts that the row is hit-testable before selection. Formatting and Dart
analysis pass.

The corrected device run was interrupted when other chats started section and
physics tests on the same phones. Only this chat's launcher was interrupted.
The test correction still needs a completed physical-device run.

The signed iPhone profile build passes in 42.3 seconds. Its packaged artifact is
frozen locally and contains the expected qualification test label. It predates
the scroll correction and has not been launched in this rerun. GPU diagnostics
and physics tests are using the iPhone. Wireless qualification needs an
exclusive device window; permission to coordinate those chats is pending.

`results.json` records four commands, before/after source digests, dirty source
hashes and outcomes. Shared source changed during three commands, so these
results do not qualify a clean commit. Full logs and the profile artifact remain
under `/tmp/zyren-qualification-20261002`.

The earlier [qualification report](../2026-10-01/README.md) and
[connected-device evidence](../2026-10-01/connected-devices.md) retain their
historical snapshots. Windows/Linux presentation and the native macOS narrow
visual check remain unverified.
