# Engineering review plugin

You can attach engineering records to scene objects through a stable ID supplied
by your importer. The optional `gpu3d_engineering` package depends only on the
public Dart core. It does not add CAD import, asset governance or a second scene
format.

The first version stores a document ID, object records with labels and scalar
metadata, and text annotations anchored in object-local coordinates. Versioned
JSON keeps these values separate from geometry. Loading a document validates its
schema, duplicate IDs and annotation references before replacing any records.
Unbound records remain available after reload; your importer binds their IDs to
the new scene objects. A document ID mismatch rejects the load.

The plugin resolves annotation anchors through the current world transform. The
workbench draws their pins as native meshes and keeps labels in its inspector.
Pins follow transforms and visibility. They stay out of selection, measurements
and the assembly list.

Isolation temporarily hides branches outside the chosen objects while preserving
their ancestor paths and descendant visibility. Restore only writes values still
owned by isolation. A later visibility edit takes precedence. Helpers can be
excluded through a host predicate. Isolation is a view operation and is not saved
in the review document.

Storage belongs to the host. The package accepts an asynchronous text store and
offers an optional file adapter that writes through a temporary sibling file.
The workbench uses its application support directory, shows unsaved changes and
save/load errors, and supports explicit save and reload. Failed or stale loads
leave current records intact. Edits made while a save is in flight stay unsaved.

Tests cover ID rebinding, validation, annotation transforms, visibility ownership,
file round trips, stale reads and failed writes. The workbench checks edit, note,
isolate, save and reload at desktop and narrow widths, followed by a native run.
These checks qualify the review workflow, not CAD compatibility or collaboration.
