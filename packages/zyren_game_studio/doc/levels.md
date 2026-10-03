# Levels and behavior authoring

You can create an exploration scene or a vehicle playground from Level tools.
Each template includes primitive geometry, collider definitions, a player input
map, a camera, inventory, interactions, objectives and registered behavior rules.
Replacing the scene is one undoable edit. No asset download is required.

Create one `GameRuleLibrary`, pass it to
`createGameDevelopmentAuthoring(rules: rules)`, then register both
`GameStudioContribution(authoring).contribution` and
`GameLevelStudioContribution(authoring, rules).contribution` with the existing
Studio host. Custom operations must be registered before creating the authoring
registry, compiler or runtime.

The component inspector edits collider dimensions, spawn groups, checkpoints,
level links and semantic input bindings. Level tools persist a build profile and
request a bake from the shared navigation plugin. The saved bake includes source
geometry and settings. Scene, asset or collider changes mark that bake stale.
`GameLevelAuthoring.validateLinks` checks destination levels and spawn groups
across the documents you plan to compile.

The rule panel uses compact lists at every width. You can add a sequence,
selector, registered action or predicate, reorder children, invert a result and
remove a subtree. Typed ports and the runtime graph compiler reject cycles,
missing operations and invalid connections before an edit reaches history.
The state panel adds named states, chooses an initial state, edits each state's
graph and connects states with registered predicates. Removing a state removes
its transitions in the same undo entry. You choose whether each graph repeats.

The templates' actions describe the key, gate, checkpoint and possession flow.
The optional `gameplay.dart` adapter binds those definitions to isolated native
play. It uses the existing interaction query, gameplay rules, physics bodies and
possession leases. Compilation and offline bundle loading have separate checks
from native controller execution and rendered device qualification.

Save a document through the shared Studio store. Read it back before compiling
with `GameProjectCompiler`; the compiler consumes the same component registry
and pinned Pipeline assets. `GameExportManifest` contains the runtime recipe and
offline resolver. Missing required assets must be imported through the host's
existing asset workflow before retrying play or export.
