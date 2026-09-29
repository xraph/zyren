# Third-party notices

Native compressed-asset decoding uses meshopt 0.6.2, draco-core 2.2.1 and
basisu_c_sys 0.9.1. Their binding and bundled-code notices are retained in
[compression licenses](docs/licenses/compression). The Khronos Box fixture has
its own [source and attribution](test_assets/compression/khronos-box/SOURCE.md).

The geospatial maths and port inventory reference Takram's three-geospatial
project. Its MIT license is reproduced below.

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

PNG/JPEG decoding also uses the pinned Rust crates listed in
[image decoder dependency licenses](docs/image-decoder-licenses.md). That file
contains their license and copyright notices for redistribution.

## Three.js tone mapping, curve and sheen references

The ACES filmic fit in `packages/gpu3d_native/native/src/renderer/output.wgsl`
follows Three.js, including its viewing exposure adjustment. The Catmull-Rom
parameterization in `packages/gpu3d/lib/src/math/curve3.dart` follows the same
nonuniform cubic formulation and repeated-point handling. Its reference fixture
uses Three.js 0.184.0.

Source: https://github.com/mrdoob/three.js/blob/dev/src/renderers/shaders/ShaderChunk/tonemapping_pars_fragment.glsl.js

Curve source: https://github.com/mrdoob/three.js/blob/r184/src/extras/curves/CatmullRomCurve3.js

The Charlie directional-albedo fit in
`packages/gpu3d_native/native/src/renderer/physical.wgsl` follows Three.js r180.

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
Their [license](packages/gpu3d_native/native/src/renderer/ltc/LICENSE) and
[table provenance](packages/gpu3d_native/native/src/renderer/ltc/README.md) are
included with the data.

Reference: *Real-Time Polygonal-Light Shading with Linearly Transformed Cosines*,
Eric Heitz, Jonathan Dupuy, Stephen Hill and David Neubelt, ACM Transactions on
Graphics (Proceedings of ACM SIGGRAPH 2016) 35(4), 2016.
[Project page](https://eheitzresearch.wordpress.com/415-2/).
