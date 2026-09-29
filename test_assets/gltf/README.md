# Authored glTF fixtures

`assembly.glb` and `assembly.gltf` describe the same three-box assembly with a
second scene containing one box. The JSON form references `assembly.bin` and
`corners.png`; the GLB embeds geometry and a PNG data URI. Names, hierarchy,
shared geometry, mipmapped sampling and scene selection are intentional.

`pbr.glb` uses the same geometry with brushed metal, painted dielectric and copper
materials. Its first scene has authored point and directional lights. The second
shares the meshes but omits lights, so you can check a viewer's explicit lighting
policy. The analytic texture/light fixtures in `zyren_gltf/test/support` use
repo-authored one-pixel PNGs and quads with known BRDF samples.

`normal-map.glb` adds a ribbed tangent-space normal texture to the painted
housing, without authored tangents. It exercises automatic MikkTSpace generation
in the viewer. The ribs affect lighting only; vertex positions are unchanged.

The geometry and four-corner image were authored for this repository. They use
no third-party model or image content and are maintained as repository test data.
Regenerate both this directory and the viewer bundle with:

```sh
dart tool/generate_model_fixtures.dart
```
