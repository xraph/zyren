# Policy execution

A5 provides native learned-policy execution. The A1 LSTM weights remain a
locally generated execution probe. They are not an accepted trained game policy.
T3/T5 supply trained artifacts, T4 evaluates behavior and Q1 qualifies the
exported game. No quality claim follows from matching this trace.

Create one `PolicyBrain` per actor and share one bounded `MlScheduler` and
`MlModelCache` across compatible actors. The native worker owns the model session.
An actor owns its recurrent input tensors, memory and pending proposal. Only one
unresolved request or staged proposal is allowed per actor, so two requests
cannot fork the same recurrent state. Cancellation preserves A2's native row
mapping when actors disappear from a batch.

## Contracts and timing

`PolicyContract` pins the full ML manifest, ordered observation/action schemas,
encoder ID, tensor bindings, cadence, latency, hold limit and hidden-state budget.
Record `toJson()` and `hash` with the training/export receipt. Observation schema
cadence and latency must match the contract. The default encoder uses the complete
frame tensor, including validity masks. A custom `PolicyObservationEncoder`
receives only the filtered frame and needs a versioned ID. Its host Dart code is
trusted. Never pass a scene snapshot or hidden-world lookup to the encoder.

```dart
final brain = PolicyBrain(
  identity: BrainIdentity(episodeId: episode, entity: actor, modelHash: model.sha256),
  contract: PolicyContract(model: model, observation: assembler.spec,
    decoder: ActionDecoder.character(), latencyTicks: 2, maxHoldTicks: 1),
  ml: sharedScheduler, entities: session.entities,
);
brain.synchronize(gameEpoch: session.epoch, controlEpoch: controlRevision, paused: false);
brain.observe(frame);
final pending = brain.request(contextAtObservationTick,
  legality: capturedLegality, target: permittedGoalTarget);
await sharedScheduler.flush();
await pending;
// Advance the shared game to frame.tick + contract.latencyTicks.
final decision = brain.decide(contextAtDueTick);
final intent = brain.decisions.currentAction.character!;
if (decision.isApplicable(session.entities, brain.identity)) {
  characterController.apply(intent, lease: actorControlLease);
}
```

The host advances the same authoritative game ticks in deployment and training.
`request` requires the ML scheduler's current tick to match the context tick.
Its deadline is the declared apply tick, and an optional wall deadline can bound
queue waiting. Waiting for inference does not advance game time. `decide` consumes
an already staged result at its exact due tick and can submit the next current
observation without blocking the game thread. A missed tick uses fallback and
commits neither the action nor its hidden output.

`BrainDecision` carries identity, observation/completion/apply ticks, schema hash,
normalized action, next hidden state, base state version, state epoch, game epoch,
control epoch and optional target generation. `DecisionScheduler.accept` validates
these together. It also requires current `validTargets` for a targeted decision
and current legality masks for discrete branches. Revoking eligibility while the
entity remains alive rejects both the action and state. `PolicyReceipt` records
bounded observation, completion, due and application ticks with the accepted flag.
It does not retain every historical hidden tensor. Inspect `lastFailure` for a
typed ML outcome and a bounded error message.

## Controllers and fallback

`ActionDecoder.character` maps move axes directly to `CharacterIntent`. Optional
look axes map normalized yaw to radians in ±pi and pitch to ±pi/2. Optional jump
uses a legal discrete stay/jump branch. Out-of-range, NaN, infinity, invalid
indices and illegal choices reject the whole proposal. Nothing silently clamps
an invalid network output.

`ActionDecoder.vehicle` uses steering in [-1,1] and signed drive in [-1,1].
Positive drive becomes throttle, negative drive becomes brake. `VehicleIntent`
remains normalized; the native vehicle owns its authored steering angle and
force limits. The default character fallback stops. The default vehicle
fallback brakes. `maxHoldTicks` bounds retaining a previously accepted action,
with fresh target/legality checks. It never commits a hidden state twice.

Float discrete logits select the highest legal choice for each branch. Integer
outputs encode exact choice indices. An unknown or all-false mask rejects the
proposal. A captured mask can guide inference selection, but it cannot replace
an execution-time mask after the world's legality changes.

Apply typed intents through the G4/G5 control lease and validate current
ownership at that point. Increment `controlEpoch` whenever ownership changes,
even if the entity handle stays the same. The epoch is an explicit host revision,
not an inferred lease ID. A receipt alone does not grant control.

## Pause, restore and replacement

Call `synchronize` before the next capture when pause, game epoch or control
ownership changes. It cancels pending work, drops staged/held actions and resets
recurrent state. `invalidatePending` also drops the cached observation and last
decision tick. Use it after restoring a snapshot even when the saved game epoch
repeats. A monotonic state epoch rejects an old zero-version candidate after
reset. The next earlier restored tick can capture and request normally.

Episode/entity reset clears memory and observations. Construct a new brain for
a model swap, then close the old brain. The immutable model contract cannot be
changed in place. `PolicyBrain.close` cancels only its actor's request. The host
owns the shared scheduler and must close it to wait for real native completion
and release the shared cache/worker.

`HybridBrain` routes explicit goals through a `GoalSelector` to registered
scripted or learned `GameBrain` skills and their declared action schemas. Skills
in one hybrid actor use the same episode/entity/model identity. A transition
resets the previous child, cancelling learned work or scripted G6 execution.
Different model pins need separate brain instances and a host-managed swap.

Historical A4 beliefs still retain their captured observer frame and tick.
Training/navigation adapters must use a saved observer pose to transform them.
They must never treat that vector as a current moving frame or query the hidden
target's current pose.

## Evidence

The native tests compare the exported A1 1,000-step sequence through both
character and vehicle decoders and apply their intents to the real G4/G5 fixture
controllers. Two actors share one native model session and perform 1,000 native
calls. Tests check action, hidden and cell outputs at float32 tolerance 1e-5,
sequence reset points and bounded receipts. A deliberate divide-by-zero recurrent
model proves nonfinite actions brake without accepting hidden state. Dispatched
middle cancellation preserves native output rows 0/2. Jitter tests reject missed
apply ticks without updating recurrence. The presentation fixture uses its test
renderer; this qualifies native ML/motor execution on macOS arm64, not GPU camera
sensing, mobile/provider parity or learned task performance.
