# Gizmo spaces and translation planes

You can switch movement and rotation between local and world axes. Scaling stays
local because the scene stores a rotation and three local scale components.
The space selector retains your choice when you leave Scale mode.

World translation converts a world displacement through the complete parent
inverse matrix. This includes rotated, reflected and nonuniformly scaled parents.
World handles use inverse transform groups to cancel their ancestors' transforms,
so they remain aligned with the world while using ordinary native mesh rendering.
Local handles keep their existing parent-relative size and orientation.

World rotation is available when the accumulated parent transform has uniform
scale and orthogonal axes. A nonuniform or sheared parent can require shear in
the object's local pose, which its position/rotation/scale representation cannot
store. In that case the workbench explains the restriction and you can choose
local rotation. Reflected uniform parents retain the correct rotation direction.

Translation adds XY, XZ and YZ pads. Ray-plane intersection constrains both
coordinates, and snapping rounds each displacement component in the chosen
space. An edge-on pad cannot start a gesture. Pads use opaque, depth-tested native
meshes, and ordinary selection ignores them along with the axis handles.

Each drag remains one undo entry. Changing spaces, modes, selection, the camera
or viewport cancels an owned preview. External edits and changed ancestors retain
priority. Existing axis-only hit testing remains available; a separate handle
query reports axes or planes.

Tests cover world alignment, transformed parents, plane constraints, snapping,
reflection, unsupported world rotation, cancellation, undo and redo. The
workbench adds a compact space selector and native desktop/mobile checks.
Screen-size scaling and always-visible rendering remain separate work.
