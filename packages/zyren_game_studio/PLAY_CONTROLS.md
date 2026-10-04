# Play controls

Click the viewport before you move. Keyboard and gamepad input share its focus and modal gates, so an inspector or apply-back dialog cannot leave a held movement command active. Controller disconnects release their actions. Play reports controller failures in the viewport.

Studio Play uses the same app lifecycle binding as GameLab. Backgrounding pauses the game and releases input; returning resumes a game that the lifecycle binding paused. A game you paused yourself stays paused. The session epoch changes on suspension, so queued model decisions cannot apply after you return.

The authored look axes are absolute normalized angles. `look.yaw` maps to radians in `[-pi, pi]`, while `look.pitch` maps to `[-pi/2, pi/2]` before the camera rig applies its pitch limit and native obstruction query. Holding an axis does not accumulate rotation.

If you embed `GamePlayInput`, pass its borrowed `GameSession` to enable lifecycle handling. Gamepads are enabled by default. You can inject an existing `GamepadAdapter` through `gamepadFactory` and report failures with `onGamepadError`; the widget closes its adapters when you remove it, and leaves the borrowed session open.

## Checkpoints and explicit respawn

`GamePlayGameplay` consumes each `game.checkpoint` radius in world units, using the actor's physical center. Reaching it selects that checkpoint and its authored `game.spawn` marker for the actor. If regions overlap, the closest checkpoint wins, with entity ID breaking a tie. The selection remains active after you leave the region and survives `GameSave` with regenerated handles. The exploration template credits its checkpoint objective through `game.checkpoint-active`, using that selection.

Call `gameplay.respawnActor(actor)` or add the registered `game.respawn` rule action when your game decides to respawn. There is no inferred death or fall condition. `selectedCheckpoint(actor)` and `selectedSpawn(actor)` expose the current live selection.

Place spawn markers at the character capsule's center, clear of solid geometry. Respawn uses the marker's current position and rotation and checks the actual native capsule before changing anything. A blocked marker, inactive or missing entity, paused session, or player still possessing a vehicle returns `false`. Exit the vehicle first. Sensors do not block placement.

Successful respawn clears motion, held input, queued commands and in-flight work for that actor, including its old native control lease. Inventory, objectives, completed interaction history and remembered state-machine state remain intact. Imported characters retain their animation clocks and root-motion phase; their falling speed resets. Other actors continue normally. Deactivating or removing the checkpoint or its spawn invalidates the selection.
