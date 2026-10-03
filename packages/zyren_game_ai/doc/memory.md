# Memory and scripted brains

Create one `ScriptedBrain` per actor. Its `BrainIdentity` pins the episode,
entity generation and model hash. Pass filtered `ObservationFrame` instances to
`observe`, then call `decide` with a strictly increasing game tick. The brain
uses its own memory and observation. Your `BrainContext` supplies authored goals,
explicitly permitted target handles, an action schema and bounded utility inputs.
It cannot hold a scene, body, sensor snapshot or physics query service.

```dart
final identity = BrainIdentity(
  episodeId: 'trial-1', entity: actor, modelHash: 'script-v1',
);
final brain = ScriptedBrain(
  identity: identity,
  entities: session.entities,
  memoryProfile: MemoryProfile(maxBeliefs: 64, maxSerializedBytes: 65536,
    ttlTicks: 60, confidenceDecayPerTick: .005),
  onCancel: (receipt) => clearActorIntent(receipt.identity.entity),
);
brain.observe(frame);
final decision = brain.decide(BrainContext(
  identity: identity, tick: session.tick, beliefs: [], goals: [],
  validTargets: permittedTargets, actionSpec: ScriptedBrain.characterActions,
));
if (decision.isApplicable(session.entities, identity)) {
  // Validate the game tick, ownership and command schema before applying.
  applyCharacterCommands(decision.actions);
}
```

`applyCharacterCommands` and `clearActorIntent` are host adapters. Movement goes
through the existing `GameCharacterController` or `VehicleController` control
lease. `ai.move` carries normalized `moveX` and `moveZ`. `ai.drive` carries
`throttle`, `brake` and `steering`, which maps to `VehicleIntent.steer`. The default
action schemas are pinned. You can configure an explicit schema for custom
skills. Drivers require `driver: true` and `ScriptedBrain.driverActions`.

Check `isApplicable` again at application. It rejects an old episode/model,
a dead actor and a despawned target generation. It does not grant possession,
reachability or a fresh application tick. Those checks belong to the host motor
and gameplay command path. `ai.interact` carries `targetId` and
`targetGeneration`; the host must submit it through the shared G6 gameplay
command validation and its per-actor sequence receipts.

## Bounded knowledge

`BeliefStore` retains source, original position, capture frame, confidence and
observation tick. TTL is inclusive: a belief observed at tick10 with TTL10 is
active through tick20 and expires at tick21. Older and duplicate captures cannot
rewrite a record. Eviction removes expired entries first, then the oldest tick,
with a stable key tie break. Both entry count and portable JSON byte reservations
are bounded. Reservations include the identity envelope, optional unknown
timestamps and tick growth when restoring. They are not a measurement of Dart
heap allocation. A profile too small for its identity envelope is rejected.

`observed` means a capture at the requested tick. `unobserved` means a retained
capture from an earlier tick or no record. `unknown` means a later incomplete
sensor reading prevented an update. `expired` means the retained record exceeded
TTL. `atTick` omits expired records and exposes decayed confidence. Known target
handles remain versioned, so reusing an entity ID cannot transfer its memory or
goal to the replacement.

Vision stores only visible positions from the filtered frame. An occluded target
keeps its original local coordinates in the original observer capture frame.
The store never reads its current pose. The guard baseline investigates that
historical bearing until expiry. It is a reactive comparison baseline, not a
world-space path planner. For navigation, your adapter must transform historical
coordinates using saved observer poses and the explicitly authored map. A hidden
target's live pose must not enter that transform.

Hearing retains the reported bearing sector, distance band, category, event tick
and obstruction uncertainty. It does not retain exact source coordinates or
source identity. The guard can investigate this uncertain bearing. A fresh sound
capture does not extend the original event's TTL.

Team communication is explicit. `receive` requires an authored permission,
matching team and recipient identity, an allowed host-measured sender distance,
delivery delay and a live TTL. A message preserves its sender capture frame and
original observation tick. The default investigate skill declines a position
from another actor's local frame. Adapt it using saved sender poses when your
game allows shared location knowledge. Never read the hidden target's pose.

## Goals and skills

`UtilityGoalSelector` orders explicit priority, utility and stable goal ID. Its
minimum commitment period holds a still-permitted goal to avoid oscillation.
Removing a goal or invalidating its target interrupts commitment immediately.
A custom typed score callback receives only `BrainContext`.

The default skill registry includes `investigate`, `follow-route`, `interact`
and `idle`. Each compiles and executes through the existing G6 graph runner.
Authored routes are finite bounded local points; `routeIndex` is an explicit
utility input. `canInteract == 1` admits an interaction proposal, with final
reach and cost checks in G6. A driver brakes if its configured forward ray is
stale, invalid, unknown or within the stopping threshold.

Custom `GameSkill` implementations register typed G6 actions and predicates.
An action declares `game.ai.context` and accesses
`context.service<BrainSkillService>('game.ai.context').context`. The runner's
step and command queue budgets apply to custom skills too. A failing action
clears queued commands through G6. Host Dart extensions are trusted code.

Goal changes, invalid targets, reset and close cancel the running skill and emit
`SkillCancellation` to `onCancel`. The host clears the motor intent there. G6
cancellation cannot enqueue a new gameplay command. Reset clears memory,
observations and goal commitment and changes identity. Close is idempotent.

## Saved ages

Persist `memory.snapshot(tick: savedGameTick).encode()`. Decode with
`MemorySnapshot.decode`, then restore only into the same identity and profile.
Restore shifts observation and sound timestamps by the difference between the
new game tick and saved tick. A five-tick-old sighting remains five ticks old.
Invalid or over-budget restores leave the existing store intact. Use reset for
an episode or model change; cross-identity restoration is rejected.

The native tests exercise real Rapier occlusion, a moving character motor and a
raycast vehicle. Scene presentation uses the shared test fixture renderer. These
tests establish the structured CPU baseline on macOS arm64; they do not qualify
rendered camera sensing, learned policies, training workers or Studio inspection.
