# Selection outlines

Set `Scene.outline` to a `SceneOutline` containing the objects you want to mark.
The native renderer draws a constant-width edge inside their visible coverage.
Descendants inherit selection. You can exclude a helper subtree with
`outlineEnabled = false`, without changing its visibility or picking behavior.

The mask reuses each selected material's vertex and fragment shaders, texture
bindings, instance transforms and clipping planes. It reads the main pass depth
with an inclusive comparison and never writes depth. Standard and reversed depth
use matching comparisons. Alpha cutouts and fragment discards apply to the mask;
overlapping selected draws retain the largest coverage alpha. A fully occluded
object behind a depth-writing occluder has no mask and no outline. Materials that
disable depth testing keep that behavior. Occluders that do not write depth do
not hide the mask; coincident surfaces cannot be distinguished by depth alone.

The edge lies inside the selected coverage, including occlusion and section
boundaries. It stays behind depth-writing foreground objects. Custom shaders use
their output alpha as coverage and must be safe to execute for an extra draw.
Shader side effects and color-distorting postprocess warps are outside this
contract. The mask remains in scene screen coordinates after postprocessing.

The final overlay runs after tone mapping, bloom and output antialiasing. It
does not enter temporal history. Width is an integer from one to eight physical
pixels; color and opacity are explicit. Outlines alone allocate one RGBA8 mask,
without enabling HDR. Four-sample scenes also allocate a multisample mask and
resolve coverage before composition. Mask targets are per view, resize with it,
release when unused and share a bounded 64 MiB outline allocation budget.

Binary scene opcode 30 carries the outline style and each mesh's selection flag.
Removing an outline clears its flags even when the encoder returns to an older
opcode. The legacy JSON adapter rejects active outlines. Draw diagnostics include
selected mask draws and one composite draw; triangle counts describe scene
geometry, as before.

`SceneOutlinePlugin` in `zyren_tools` follows the tools selection. It owns a
reversible scene outline session and restores the earlier value only while it
still owns the current one. External outline edits take precedence until selection
changes. The workbench uses outlines and disables the older material color
highlight. Gizmos and review pins opt out of inherited outlines.

Tests cover immutable snapshots, packet deltas and removal, both depth modes,
occlusion, clipping, alpha cutouts, instances, primitives, custom materials, HDR,
MSAA, target resize/release and plugin ownership. The workbench also needs native
presentation and compact desktop/narrow layout checks. Platform qualification
must name the backend actually exercised.
