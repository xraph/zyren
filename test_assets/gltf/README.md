# Authored glTF fixtures

`assembly.glb` and `assembly.gltf` describe the same three-box assembly with a
second scene containing one box. The JSON form references `assembly.bin` and
`corners.png`; the GLB embeds geometry and a PNG data URI. Names, hierarchy,
shared geometry, mipmapped sampling and scene selection are intentional.

The geometry and four-corner image were authored for this repository. They use
no third-party model or image content and are maintained as repository test data.
Regenerate both this directory and the viewer bundle with:

```sh
dart tool/generate_model_fixtures.dart
```
