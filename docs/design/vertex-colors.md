# Vertex colors

You can build a colored triangle without an image or a lighting setup:

```dart
final geometry = BufferGeometry.fromAttributes(
  attributes: {
    VertexSemantic.position: VertexAttribute(
      Float32List.fromList([-1, -1, 0, 1, -1, 0, 0, 1, 0]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.normal: VertexAttribute(
      Float32List.fromList([0, 0, 1, 0, 0, 1, 0, 0, 1]),
      format: VertexFormat.float32x3,
    ),
    VertexSemantic.color: VertexAttribute(
      Uint8List.fromList([255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255]),
      format: VertexFormat.unorm8x4,
    ),
  },
  indices: [0, 1, 2],
  dynamic: true,
);
scene.add(Mesh(geometry, UnlitMaterial(vertexColors: true)));
geometry.updateAttribute(
  VertexSemantic.color,
  Uint8List.fromList([255, 255, 0, 255]),
  firstVertex: 2,
);
```

Import `dart:typed_data` and `package:gpu3d/gpu3d.dart` for this example.
You get the same flag on `DiffuseMaterial`, `StandardMaterial`, `LineMaterial`
and `PointsMaterial`. It defaults to false. Enabling it requires a color
attribute, and a material created with vertex colors defaults to a white tint.

Core attributes accept `float32x3`, `float32x4` and `unorm8x4`. RGB gets alpha 1.
Float inputs must be finite and within [0, 1]. glTF import also accepts normalized
unsigned-short RGB/RGBA and clamps imported channels as required by the format.

## Rendering and updates

Colors are linear-light multipliers. The GPU interpolates them with perspective
correction before multiplying the base color, base-color texture and alpha.
Emission is independent. Opaque materials ignore alpha, masks discard below the
cutoff, and blended materials use source-over with the existing depth policy.
Masked shadow casters use the same combined alpha as their visible surface.

Expanded line vertices carry both endpoint colors so camera-plane clipping can
interpolate them at the new endpoints. Points keep their source vertex color.
These primitives retain their existing unlit, untextured material profile.

Each immutable geometry revision caches normalized RGBA data. Native triangles
store it in a separate 16-byte-per-vertex buffer. A one-vertex update uploads
16 bytes, even when your CPU attribute uses normalized bytes. Shared views retain
their captured revision through the existing copy-on-write resource path.
Expanded lines and points use 32 extra bytes per quad vertex and require full
recipe uploads after edits.

Scene packet opcode 23 adds the optional color stream and material flag.
Uncolored scenes retain their prior packet versions. The native decoder checks
finite channel values, bounds, flags and truncation before publishing geometry.

## Current limits

Built-in materials consume colors. Custom `ShaderMaterial` layouts do not yet
expose this attribute. Joint/weight attributes and deformation are separate work,
and this addition does not change the sorted-transparency limitations.

The model viewer's Colors sample contains a PBR assembly with normalized RGB
vertex colors and authored lights. Decoder tests cover all six glTF color formats,
flat-normal expansion, clamping and per-primitive material selection. Native
probes cover interpolation, emission, texture products, alpha, clipped lines,
points, shared-view updates, HDR output and shadow invalidation.
