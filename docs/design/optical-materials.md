# Iridescence and dispersion

Use iridescence for thin-film reflection. Set film thickness in nanometres:

```dart
final film = PhysicalMaterial(
  iridescence: 1,
  iridescenceIor: 1.3,
  iridescenceThicknessMinimum: 100,
  iridescenceThicknessMaximum: 400,
);
final glass = PhysicalMaterial(
  transmission: 1,
  thickness: .5,
  ior: 1.5,
  dispersion: .4,
  roughness: .05,
);
```

`iridescenceMap` multiplies the strength by its linear red channel.
`iridescenceThicknessMap` interpolates minimum to maximum thickness with its
linear green channel. You can reverse the endpoints. Without a thickness map,
the maximum sets a uniform thickness. Both maps support UV0/UV1, samplers,
scoped ownership and immutable `copyWith` edits.

The thin-film model evaluates two Fourier orders of the Belcour/Barla spectral
integration used by Khronos. It modifies dielectric and metal Fresnel response
and reduces underlying diffuse/transmitted energy. Clearcoat remains a separate
outer layer. Direct lights evaluate the angular response; area lights use the
existing bounded quadrature. Environment lighting uses an angular split-sum
approximation with the existing GGX prefilter. Zero strength or zero film
thickness retains the base reflection model.

Dispersion traces the opaque scene capture at three indices of refraction. The
red and blue paths use half the spread `(ior - 1) * .025 * dispersion` around the
green path, with a lower IOR bound of one. Each path keeps rough filtering, depth
rejection and distance-dependent absorption. Coverage uses the maximum of their
alpha values so a partly covered channel retains enough associated coverage.
The zero-dispersion path performs one trace. Dispersion has no effect without
transmission and nonzero thickness.

Strength accepts [0, 1], film IOR [1, 1e6], thickness endpoints [0, 1e6] nm and
dispersion [0, 1000]. All values must be finite. The native profile permits
exaggerated dispersion above the usual [0, 1] range. The glTF loader supports
required `KHR_materials_iridescence` and `KHR_materials_dispersion`, including
linear texture interpretation and the dispersion extension's volume dependency.
Scene opcode 34 adds eight optical floats and extends physical map slots to 12;
older opcodes keep their original layout.

Transmission still uses visible opaque scene content and its environment fallback.
Dispersion does not add internal bounces, caustics or nested refractive volumes.
See [transmission](transmission.md) for capture limits and [temporal AA](temporal-antialiasing.md)
for reactive glass handling.

References: [Khronos iridescence](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_iridescence),
[Khronos dispersion](https://github.com/KhronosGroup/glTF/tree/main/extensions/2.0/Khronos/KHR_materials_dispersion),
and [Three.js r180 thin-film implementation](https://github.com/mrdoob/three.js/blob/r180/src/renderers/shaders/ShaderChunk/iridescence_fragment.glsl.js).
The Three.js MIT notice is retained in `THIRD_PARTY_NOTICES.md`.
