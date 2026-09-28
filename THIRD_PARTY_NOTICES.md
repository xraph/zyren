# Third-party notices

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

## Three.js

Camera reference fixtures execute Three.js 0.184.0, and the three184 orbit mode
ports its OrbitControls implementation. The standard material shader adapts its
scalar GGX, correlated Smith and Schlick functions, with numerical fixtures
extracted from the same pinned release. The native FXAA pass adapts its
FXAAShader, which credits NVIDIA, Jasper Flick and Dave Hoskins. FXAA reference
fixtures evaluate that release's display-space equations. Its MIT license follows.

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
[image decoder dependency licenses](docs/image-decoder-licenses.md). That file
contains their license and copyright notices for redistribution.
