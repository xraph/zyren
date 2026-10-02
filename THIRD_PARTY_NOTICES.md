# Third-party notices

Native compressed-asset decoding uses meshopt 0.6.2, draco-core 2.2.1 and
basisu_c_sys 0.9.1. Their binding and bundled-code notices are retained in
[compression licenses](docs/licenses/compression). The Khronos Box fixture has
its own [source and attribution](test_assets/compression/khronos-box/SOURCE.md).

PNG/JPEG decoding also uses the pinned Rust crates listed in
[image decoder dependency licenses](docs/image-decoder-licenses.md). That file
contains their license and copyright notices for redistribution.

## 3d-tiles-renderer

CameraTransitionManager, EnvironmentControls and GlobeControls are adapted from
3d-tiles-renderer 0.4.24, copyright
2020 California Institute of Technology, licensed under Apache 2.0. The port
uses Dart camera values, typed events, native input, surface queries and explicit
elapsed time. Interrupted input clears pending motion, and wheel input refreshes
its target without requiring a preceding pointer move.

Source: https://github.com/NASA-AMMOS/3DTilesRendererJS

The full license is in [licenses/3d-tiles-renderer.txt](licenses/3d-tiles-renderer.txt).

## three-geospatial

The geospatial maths, atmosphere and celestial shader equations, star catalogue
and port inventory reference Takram's three-geospatial project. The Gaussian,
Kawase, mipmap and surface blur kernels adapt its WebGPU filter nodes. Their
reference fixtures execute the original TSL expressions. Its MIT license
is reproduced below. The catalogue object and regeneration command are pinned
in [Atmosphere parity](https://xraph.com/docs/zyren/reference/parity/atmosphere).

Source: https://github.com/takram-design-engineering/three-geospatial

The MIT License (MIT)

Copyright (c) 2024 Shota Matsuda

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## Three.js

Camera reference fixtures execute Three.js 0.184.0, and the three184 orbit mode
ports its OrbitControls implementation. The standard material shader adapts its
scalar GGX, correlated Smith and Schlick functions, with numerical fixtures
extracted from the same pinned release. The native FXAA pass adapts its
FXAAShader, which credits NVIDIA, Jasper Flick and Dave Hoskins. FXAA reference
fixtures evaluate that release's display-space equations. Native Cineon, ACES
Filmic, AgX and Neutral tone mapping also port its GLSL, with fixtures executing
the original shader functions. Its MIT license follows.

Source: https://github.com/mrdoob/three.js

The MIT License

Copyright © 2010-2026 three.js authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## three-stdlib

OrbitControls ports the behavior of three-stdlib 2.36.1.

Source: https://github.com/pmndrs/three-stdlib

MIT License

Copyright (c) 2021-2023 Poimandres

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.

PNG/JPEG decoding also uses the pinned Rust crates listed in
[image decoder dependency licenses](licenses/image-decoder-notices.md). That file
contains their license and copyright notices for redistribution.


## Astronomy Engine

The optional geospatial plugin ports the Earth VSOP series, lunar series,
Espenak-Meeus Delta T, precession, nutation, sidereal time and Moon rotation from
Astronomy Engine 2.1.19. Only the sun and moon APIs needed by the atmosphere are
included. The port runs in Dart; JavaScript is used to generate reference fixtures.

Source: https://github.com/cosinekitty/astronomy

Copyright (c) 2019-2023 Don Cross. The complete MIT license is in
[licenses/astronomy-engine.txt](licenses/astronomy-engine.txt).

## Precomputed Atmospheric Scattering

The geospatial atmosphere ports the Bruneton transmittance, single and multiple
scattering, irradiance and runtime equations carried by the supplied
three-geospatial snapshot. Copyright (c) 2017 Eric Bruneton and Copyright (c)
2008 INRIA. The complete redistribution conditions and disclaimer are retained
in [licenses/bruneton.txt](licenses/bruneton.txt).

## Cloud noise

The optional cloud generators adapt the Perlin, Worley and curl-noise equations
carried by three-geospatial. These include TileableVolumeNoise, copyright (c)
2017 Sébastien Hillaire, and GLM noise, copyright (c) 2005 G-Truc Creation.
Their notices and redistribution terms are in
[licenses/cloud-noise.txt](licenses/cloud-noise.txt).

Cloud shadow cascade construction follows the supplied CascadedShadowMaps and
FrustumCorners implementations, derived from three-csm and three.js. The vtHawk
MIT notice is retained in `licenses/cloud-cascades.txt`.

## postprocessing

The Hald interpolation, lens blur and SMAA shaders are WGSL adaptations of
postprocessing 6.39.1. SMAA includes its original area and search lookup images.
The reference fixtures execute the original GLSL. These ports are altered
versions, not the original software.

The original SMAA authors' notice is retained in `licenses/smaa.txt`.
Source: https://github.com/iryoku/smaa

Source: https://github.com/pmndrs/postprocessing

Copyright © 2015 Raoul van Rüschen

This software is provided 'as-is', without any express or implied warranty. In
no event will the authors be held liable for any damages arising from the use of
this software.

Permission is granted to anyone to use this software for any purpose, including
commercial applications, and to alter it and redistribute it freely, subject to
the following restrictions:

1. The origin of this software must not be misrepresented; you must not claim
   that you wrote the original software. If you use this software in a product,
   an acknowledgment in the product documentation would be appreciated but is
   not required.

2. Altered source versions must be plainly marked as such, and must not be
   misrepresented as being the original software.

3. This notice may not be removed or altered from any source distribution.

## Three.js tone mapping, curve and sheen references

The ACES filmic fit in `packages/zyren_native/native/src/renderer/output.wgsl`
follows Three.js, including its viewing exposure adjustment. The Catmull-Rom
parameterization in `packages/zyren/lib/src/math/curve3.dart` follows the same
nonuniform cubic formulation and repeated-point handling. Its reference fixture
uses Three.js 0.184.0.

Source: https://github.com/mrdoob/three.js/blob/dev/src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js

Curve source: https://github.com/mrdoob/three.js/blob/r184/src/extras/curves/CatmullRomCurve3.js

The Charlie directional-albedo fit in
`packages/zyren_native/native/src/renderer/physical.wgsl` follows Three.js r180.

Sheen source: https://github.com/mrdoob/three.js/blob/r180/src/renderers/shaders/ShaderChunk/lights_physical_pars_fragment.glsl.js

The MIT License

Copyright © 2010-2026 three.js authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
THE SOFTWARE.

## LTC area-light tables

The native rectangular-light matrix and amplitude tables are adapted from
Three.js r180, under the Three.js MIT terms above, and from the fitted LTC data
by Eric Heitz, Jonathan Dupuy, Stephen Hill and David Neubelt (2017).
Their [license](packages/zyren_native/native/src/renderer/ltc/LICENSE) and
[table provenance](packages/zyren_native/native/src/renderer/ltc/README.md) are
included with the data.

Reference: *Real-Time Polygonal-Light Shading with Linearly Transformed Cosines*,
Eric Heitz, Jonathan Dupuy, Stephen Hill and David Neubelt, ACM Transactions on
Graphics (Proceedings of ACM SIGGRAPH 2016) 35(4), 2016.
[Project page](https://eheitzresearch.wordpress.com/415-2/).

## Dart Earcut

Shape triangulation uses `dart_earcut` 1.2.0, a Dart port of Earcut. The package's
[MIT and ISC notices](docs/licenses/geometry/dart-earcut.txt) are retained for
redistribution. See the [upstream repository](https://github.com/JaffaKetchup/dart_earcut).
