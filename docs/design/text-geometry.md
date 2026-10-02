# Text geometry

You can turn outline glyphs into a flat or extruded mesh:

```dart
final layout = font.layout(
  'TwinOS\nPlant 04',
  size: .5,
  alignment: TextAlignment.center,
  letterSpacing: .02,
);
if (layout.hasGeometry) {
  final geometry = TextGeometry.fromLayout(layout, depth: .04);
  scene.add(Mesh(geometry, StandardMaterial()));
}
```

`font` is an `OutlineFont`. It contains Unicode scalar keys, `GlyphOutline`
objects, font-unit metrics and optional pair kerning. Each glyph has an advance
and a list of `Shape2D` outlines, so letters can have counters, disconnected dots
or several components. The core accepts prepared outlines. File parsing belongs
to an optional assets package; there is no system-font or browser dependency.

`TextGeometry('Hello', font: font, size: 1, depth: .1)` is the convenience API.
Use `depth: 0` for flat text facing +Z. Extrusion extends toward +Z and supports
wall steps and the same bevel options as `ExtrudeGeometry`. Caps use local XY
UVs; walls use perimeter distance and depth. Repeated outlines share preparation
within one build, and the result is one ordinary `BufferGeometry`.

Size is world units per em. Letter spacing and an optional line-height override
are also in world units. The first baseline is y=0 and later lines move toward
negative Y. Start alignment anchors each line at x=0; center and end alignment
shift it by half or all of its advance width. Tracking appears between glyphs,
including spaces. CRLF and CR normalize to line breaks, while other control
characters, including tabs, fail explicitly.

`TextLayout.lineWidths`, `width` and `height` describe advance metrics, not ink
bounds. Whitespace has metrics but no triangles, so check `hasGeometry` before
building a mesh. Missing glyphs throw unless you set `fallbackCodePoint` on the
font. Placements retain UTF16 source offsets, including after surrogate pairs.
Malformed surrogate sequences fail.

The built-in layout follows scalar order with pair kerning. It does not shape
Arabic, apply bidi ordering or substitute ligatures. A shaping plugin can supply
`GlyphPlacement` values through `TextLayout.positioned`, including positioned
marks and shared cluster offsets, then use the same tessellation path.

## Bounds and checks

Runs accept at most 4096 Unicode scalars or positioned glyphs. A glyph accepts
4096 outline vertices, and a font accepts 65536 glyph entries with at most one
million outline vertices in total. Each `Shape2D` retains its own ring validation.
Input maps and lists are copied into immutable storage.

`TextGeometryLimits` defaults to 250000 output vertices and 64 MiB of vertex/index
payload. You can lower either bound or raise the vertex cap to one million;
indices must also fit the selected index format and the core's three-million
index limit. Conservative cap/wall counts are checked before tessellation.
Temporary shape preparation and merge buffers consume additional heap memory.

Use local coordinates. Translation that collapses a text triangle in float32
fails with an error; place distant labels with the scene transform. Overlapping
glyphs remain overlapping geometry, and bevels that collapse an outline fail.

Core tests check kerning, alignment, Unicode offsets, explicit missing-glyph
behavior, whitespace, counter picking, collinear caps, known extrusion volume,
immutability and allocation limits. The native Metal fixture checks flat and
extruded counters, detached dots, placement and residency cleanup.
