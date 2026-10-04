# Play controls

Click the viewport before you move. Keyboard and gamepad input share its focus and modal gates, so an inspector or apply-back dialog cannot leave a held movement command active. Controller disconnects release their actions. Play reports controller failures in the viewport.

Studio Play uses the same app lifecycle binding as GameLab. Backgrounding pauses the game and releases input; returning resumes a game that the lifecycle binding paused. A game you paused yourself stays paused. The session epoch changes on suspension, so queued model decisions cannot apply after you return.

The authored look axes are absolute normalized angles. `look.yaw` maps to radians in `[-pi, pi]`, while `look.pitch` maps to `[-pi/2, pi/2]` before the camera rig applies its pitch limit and native obstruction query. Holding an axis does not accumulate rotation.

If you embed `GamePlayInput`, pass its borrowed `GameSession` to enable lifecycle handling. Gamepads are enabled by default. You can inject an existing `GamepadAdapter` through `gamepadFactory` and report failures with `onGamepadError`; the widget closes its adapters when you remove it, and leaves the borrowed session open.
