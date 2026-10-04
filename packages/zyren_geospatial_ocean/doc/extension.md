# Geospatial host integration

Install `OceanExtension` in `GeospatialPlugin.extensions`, then pass the complete
`host.scenePlugins` list to your scene engine. The extension publishes versioned
`oceanSeaState`, `oceanSampler` and `oceanPresentation` services. Each scene admits
one ocean provider.

Supply the immutable sea state and two factories. `createSampler` returns an
owned CPU or GPU sampler using `context.worldFrame`, your coverage provider and
the shared simulation clock. `createPresentation` returns an owned
`OceanPresentation`. Its `prepare` callback receives the current simulation
instant, frame dimensions and layer visibility. It prepares visual resources
without advancing the clock. The extension closes both factory results after
accepted attachment work drains, including partial failures and cancellation.

The surface, foam and optional underwater layers belong to the ocean group.
Their IDs are available on the extension. Hiding the surface removes its shaded
foam too; hiding only foam leaves the surface visible. Underwater is independent.
The sampler remains available when you hide visuals, and surface queries are
allowed while hidden. Layer status reports presentation failures and recovers
only after a successful frame preparation. Coverage access still comes from the
sampler's provider; a ready visual layer does not establish real-Earth coverage.

For a custom native presentation, use `OceanViewResources.setVisibility` to apply
all three switches. `OceanWaterMaterial.setFoamEnabled` changes its shading
uniform while retaining the interaction field. `OceanUnderwaterPass.detach`
removes attenuation without closing its GPU resources; prepare and attach it
again to restore the effect. Apply these changes under the same frame owner.

Standalone water materials, queries and controllers remain available without a
geospatial host. The extension does not acquire a physics driver, install a layer
panel, invent terrain or supply external credentials.

## Built-in native presentation

Return `OceanNativePresentation` from your presentation factory. Supply the
context, sea state, quality and a `configureView(frame)` callback. The callback
returns an `OceanViewConfiguration` with the current scene camera, actual frame
size, scene sample count and host ellipsoid. Declare `hasUnderwater` up front so
the extension registers the layer only when the view installs that capability.
Its camera query still comes from your sampler and policy.

The presentation allocates on the scene device. It obtains scoped capture leases
through `PluginContext.createCaptureView`, so Flutter callers do not need access
to the backend. The boundary pass retains hidden water geometry: hiding the
surface visualization does not erase the volume boundary used by underwater.

`requestQuality` queues a change for the next frame. `requestLodUpdate` requests
new topology after camera movement. Both run under the frame owner and respect
an active quality fade. Read `effectiveQuality`, `controller`, `view` and
`lastFailure` for the applied state. A rejected request is reported and consumed;
the next frame can recover with the previous settings.

A new viewport, camera instance or sample count prepares a replacement before
publication. Admission counts both old and candidate payloads. Failed preparation
keeps the previous resources; successful publication retires them. Supply
`retainedBytes` for shared inputs and other ocean effects outside the view recipe.
Retirement errors remain observable and conservatively counted.

The globe recipe retains complete six-chart coverage. It currently expects ECEF
scene coordinates. Use the standalone material and capture APIs for a local-frame
presentation, or implement the `OceanPresentation` contract for another layout.
