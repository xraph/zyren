# zyren_configurator

You can apply validated material and component choices to a Zyren scene, then
save the selection and restore it after reloading your model. Run
`dart run example/configure.dart` from this package for a complete example.

Bind your own source IDs to scene nodes and material instances. A catalog has a
stable ID, a revision and named slots containing options. Each option can assign
materials, set component visibility, require another choice or exclude one.
Required slots must have a selection. Conflicting writes fail validation.

`SceneConfigurator.apply` validates the full selection before it changes the
scene. When you choose an option that leaves a property unspecified, that
property returns to the value captured when you created the controller.
`reset` and `close` restore the same baseline. You still own the scene resources.

Reserve the catalog's material and visibility properties for the controller
while it is open. Use one stable ID per target object. Configuration documents
store choices, catalog identity and schema version, so you must provide matching
bindings when you load them into a new scene. Catalog migration is explicit.

Imported material variants, camera presets, hotspots and catalog-service
adapters remain planned. This first slice has no Flutter controls or device
qualification requirement; rendered appearance has not been checked here.
