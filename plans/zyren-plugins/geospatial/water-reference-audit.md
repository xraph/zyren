# Water reference audit

Inspected 2026-10-03. This is source reconnaissance, not visual qualification.

## TwinOS Terra

The reference checkout is `../twinos-app`, at commit `9611c957a` when inspected.
The inspected water directory and preset file had no working-tree changes.
Paths below are relative to that repository. Its web renderer supplies useful
behaviour and design references; Zyren keeps native rendering throughout.

| Reference | Observed behaviour | Use in Zyren |
| --- | --- | --- |
| `packages/terra-engine/src/components/scene/water/README.md` | Describes a shared analytical renderer for saved simple, Gerstner and FFT modes. Some legacy controls no longer allocate work. | Preserve its honest description of approximations. Every exposed Zyren quality control must affect a declared workload or reject unsupported settings. |
| `water-runtime.ts`, under the same directory | Up to 16 wave bands, matching CPU height/slopes, bounded geometry, logarithmic rings and local globe anchoring. | Reference tests for shared phase/time, stable anchors, filtering and camera coverage. This is not an inverse FFT implementation. |
| `FFTWater.tsx` | Delegates to WaterSurface with the legacy FFT configuration key. | Keep the distinction between a serialized name and its actual algorithm. |
| `WaterSurface.tsx` | Stable materials, frame invalidation and camera-following geometry. Local globe detail fades between 6 and 12 km altitude. | Lifecycle and local/global transition ideas, with measured native thresholds. |
| `water-material.ts`, `advanced-water-capture.ts` | Environment lighting, reflected scene capture, scene-colour/depth refraction, absorption and foam. | Optical acceptance cases, especially foreground rejection, target sizing, exposure and cleanup. Reimplement through native scene inputs. |
| `UnderwaterPass.tsx`, `UnderwaterEffect.tsx`, `water-volume.ts` | Underwater treatment, bounded volumes and depth reconstruction. | Tests for waterline transitions, bounded rays and avoiding duplicate depth decoding. |
| `water-caustics.ts`, `underwater-particles.ts`, `underwater-frame.ts` | Caustic, suspended-particle and frame helpers, with budget tests. | Behavioural reference. Reuse Zyren particles and rendering APIs where applicable. |
| `OceanGlobe.tsx` | Cheap planetary sphere and nearby detail. The distant sphere uses an intentional 500 m radius offset for a stylized water planet. | Global/local composition reference only. Physical sea level must not inherit this offset. |
| `packages/terra-engine/src/components/scene/Models.tsx` | Single or four-point height following, damped tilt, and a globe-mode early return. It writes rendered transforms. | Wave-query fixtures only. Native buoyancy must apply forces and torque through physics and work in a local frame on the globe. |

The source confirms useful mechanics, not the appearance or performance of the
current app. No TwinOS water demo was run for this audit. Its nearby reflection
capture is a planar approximation; wakes, wave self-reflection and volumetric
breaking water cannot be inferred from the presence of an advanced setting.

## Primary rendering references

These establish techniques to evaluate. They are not dependencies or permission
to copy engine source, shipped assets or commercial shader code.

| Reference | Applicable observation | Design consequence |
| --- | --- | --- |
| [Tessendorf, Simulating Ocean Water](https://jtessen.people.clemson.edu/reports/papers_files/coursenotes2002.pdf) | Frequency-domain wave synthesis, time evolution and inverse transforms generate a periodic ocean surface. | Implement spectral waves with an independent numerical reference. A heightfield model has limits, especially at breaking waves. |
| [Rare, The Technical Art of Sea of Thieves](https://history.siggraph.org/wp-content/uploads/2022/09/2018-Talks-Ang_The-Technical-Art-of-Sea-of-Thieves.pdf) | Describes FFT ocean waves, crest/intersection foam with temporal dispersion and underwater Snell's-window treatment. | Evaluate persistent foam and underwater optics together with the wave field. Keep art direction separate from solver coefficients. |
| [Epic, Water meshing and surface rendering](https://dev.epicgames.com/documentation/unreal-engine/water-meshing-system-and-surface-rendering-in-unreal-engine?lang=en-US) | Camera-dependent mesh selection and morphing between levels. | Continuous LOD transitions and visible budgets, independently of physical sampling. |
| [Epic, Single Layer Water](https://dev.epicgames.com/documentation/en-us/unreal-engine/single-layer-water-shading-model-in-unreal-engine) | Uses scene colour/depth for composition, with scattering, absorption, reflection and refraction. | Qualify native scene-input access and composition ordering before writing the complete material. |
| [Epic, Water buoyancy](https://dev.epicgames.com/documentation/en-us/unreal-engine/water-buoyancy-component-in-unreal-engine) | Uses spherical pontoons as a low-cost volume approximation, with drag controls. | Provide an explicit pontoon approximation and a more detailed hull-volume option; report each model's limits. |
| [Guerrilla, Rendering Water in Horizon Forbidden West](https://advances.realtimerendering.com/s2022/index.html) | The course abstract describes processed Houdini simulations assembled into localized breaking-wave deformations. | Treat authored breaking geometry as its own future adapter. An FFT surface does not provide that geometry automatically. |

The Horizon course abstract was read. Its linked slide PDF could not be opened
through the browser tool, so no slide-specific implementation claims are used.

## Zyren integration findings

- Core plugin scopes and shared graphs already own native resources and ordered
  compute work. `packages/zyren_native/test/support/graph_phase_checks.dart`
  contains a compute-to-custom-material example to retain as a regression.
- Public render graphs expose before-scene and after-scene phases. Public
  postprocess shaders expose HDR scene colour and depth. Those APIs alone do not
  establish scene-colour/depth access for a custom mesh at the required phase.
- The native renderer already has transmission capture in
  `packages/zyren_native/native/src/renderer/transmission.rs`. Extend that generic
  facility if custom mesh sampling needs an API. Do not build a water-owned copy
  of the scene renderer or assume fullscreen postprocessing solves mesh ordering.
- Physics bodies expose point impulses, point forces and torque in
  `packages/zyren_physics/lib/src/physics.dart`. Use the native simulation owner
  and its fixed tick. Additive per-tick impulses can avoid clearing forces owned
  by other systems; their integration error still needs convergence tests.
- Custom shaders, material packet transport and native presentation are being
  edited concurrently. Re-read them immediately before implementation and make
  focused changes. This audit is not permission to overwrite those edits.

## Reuse decisions

Carry forward shared CPU/GPU wave conventions, stable world anchoring, local/global
water coverage, bounded capture targets and underwater regression cases.

Build spectral simulation, physical buoyancy, globe LOD and the quality controller
against Zyren's public Dart and native APIs. Require captures and timing evidence
before using a professional-fidelity label in release notes. The requested quality
bar is accepted; meeting it remains implementation and qualification work.
