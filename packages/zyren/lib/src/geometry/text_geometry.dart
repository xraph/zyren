import 'dart:math' as math;
import 'dart:typed_data';
import '../math/vec2.dart';
import 'geometry.dart';
import 'shape.dart';
import 'vertex_attribute.dart';

/// A glyph's advance and already flattened, triangulated outlines in font units.
/// Empty outlines are useful for spaces. You can supply multiple disconnected
/// shapes, each with its own holes.
final class GlyphOutline {
  final double advance;
  final List<Shape2D> shapes;
  GlyphOutline({required this.advance, List<Shape2D> shapes = const []})
    : shapes = List.unmodifiable(shapes) {
    if (!advance.isFinite ||
        advance < 0 ||
        shapes.fold<int>(0, (n, s) => n + s.vertices.length) > 4096) {
      throw ArgumentError(
        'Glyphs need a finite nonnegative advance and at most 4096 outline vertices.',
      );
    }
  }
}

enum TextAlignment { start, center, end }

bool _scalar(int value) =>
    value >= 0 && value <= 0x10ffff && (value < 0xd800 || value > 0xdfff);

/// Format-independent outline font. File parsers and complex-script shaping
/// belong to optional asset/text plugins. [layout] provides scalar-order layout
/// with pair kerning; it does not perform bidi, ligature or script shaping.
final class OutlineFont {
  final double unitsPerEm, lineHeight;
  final Map<int, GlyphOutline> glyphs;
  final Map<(int, int), double> kerning;
  final int? fallbackCodePoint;
  OutlineFont({
    required this.unitsPerEm,
    required this.lineHeight,
    required Map<int, GlyphOutline> glyphs,
    Map<(int, int), double> kerning = const {},
    this.fallbackCodePoint,
  }) : glyphs = Map.unmodifiable(glyphs),
       kerning = Map.unmodifiable(kerning) {
    if (!unitsPerEm.isFinite ||
        unitsPerEm <= 0 ||
        !lineHeight.isFinite ||
        lineHeight <= 0 ||
        glyphs.length > 65536 ||
        glyphs.keys.any((key) => !_scalar(key)) ||
        kerning.length > 1000000 ||
        kerning.entries.any(
          (e) => !_scalar(e.key.$1) || !_scalar(e.key.$2) || !e.value.isFinite,
        ) ||
        (fallbackCodePoint != null && !glyphs.containsKey(fallbackCodePoint))) {
      throw ArgumentError(
        'Invalid outline font metrics, scalar keys or fallback glyph.',
      );
    }
    final total = glyphs.values.fold<int>(
      0,
      (n, g) => n + g.shapes.fold<int>(0, (m, s) => m + s.vertices.length),
    );
    if (total > 1000000) {
      throw ArgumentError('Font exceeds 1000000 outline vertices.');
    }
  }

  /// Size is world units per em; tracking and an optional line height are also
  /// world units. Each line is aligned around x=0; its first baseline is y=0.
  /// CRLF and CR normalize to LF. Other control characters are rejected.
  TextLayout layout(
    String text, {
    double size = 1,
    double letterSpacing = 0,
    double? lineHeight,
    TextAlignment alignment = TextAlignment.start,
  }) {
    if (text.length > 8192 ||
        !size.isFinite ||
        size <= 0 ||
        !letterSpacing.isFinite) {
      throw ArgumentError(
        'Text needs a positive finite size and at most 4096 Unicode scalars.',
      );
    }
    final scale = size / unitsPerEm;
    final height = lineHeight ?? this.lineHeight * scale;
    if (!scale.isFinite || scale <= 0 || !height.isFinite || height <= 0) {
      throw ArgumentError(
        'Text line height and scale must be positive and finite.',
      );
    }
    final lines = <List<GlyphPlacement>>[[]];
    final widths = <double>[];
    var x = 0.0, y = 0.0;
    int? previous;
    var offset = 0, count = 0;
    final scalars = text.runes.toList();
    if (scalars.length > 4096) {
      throw ArgumentError('Text exceeds 4096 Unicode scalars.');
    }
    for (var i = 0; i < scalars.length; i++) {
      final codePoint = scalars[i];
      final sourceIndex = offset;
      offset += codePoint > 0xffff ? 2 : 1;
      if (!_scalar(codePoint) ||
          codePoint == 0xfffd && text.codeUnitAt(sourceIndex) != 0xfffd) {
        throw ArgumentError('Text contains an unpaired UTF16 surrogate.');
      }
      if (codePoint == 10 || codePoint == 13) {
        if (codePoint == 13 && i + 1 < scalars.length && scalars[i + 1] == 10) {
          i++;
          offset++;
        }
        widths.add(x);
        lines.add([]);
        x = 0;
        y -= height;
        previous = null;
        count = 0;
        continue;
      }
      if (codePoint < 32 || codePoint >= 127 && codePoint < 160) {
        throw ArgumentError('Text contains an unsupported control character.');
      }
      final resolved = glyphs.containsKey(codePoint)
          ? codePoint
          : fallbackCodePoint;
      final glyph = glyphs[resolved];
      if (glyph == null) {
        throw ArgumentError(
          'Font has no glyph for U+${codePoint.toRadixString(16).toUpperCase()} and no fallback.',
        );
      }
      if (count > 0) x += letterSpacing;
      if (previous != null) x += (kerning[(previous, resolved!)] ?? 0) * scale;
      lines.last.add(
        GlyphPlacement(
          glyph,
          position: Vec2(x, y),
          scale: scale,
          sourceIndex: sourceIndex,
        ),
      );
      x += glyph.advance * scale;
      if (!x.isFinite || x < 0 || !y.isFinite) {
        throw ArgumentError(
          'Text advance exceeds finite nonnegative layout metrics.',
        );
      }
      previous = resolved;
      count++;
    }
    widths.add(x);
    return TextLayout.positioned(
      [
        for (var line = 0; line < lines.length; line++)
          for (final glyph in lines[line])
            GlyphPlacement(
              glyph.outline,
              position:
                  glyph.position -
                  Vec2(switch (alignment) {
                    TextAlignment.start => 0,
                    TextAlignment.center => widths[line] / 2,
                    TextAlignment.end => widths[line],
                  }, 0),
              scale: glyph.scale,
              sourceIndex: glyph.sourceIndex,
            ),
      ],
      lineWidths: widths,
      lineHeight: height,
    );
  }
}

/// A shaped glyph placement in world XY coordinates. Scale converts outline
/// units to world units. [sourceIndex] is its UTF16 cluster offset in source text.
final class GlyphPlacement {
  final GlyphOutline outline;
  final Vec2 position;
  final double scale;
  final int sourceIndex;
  GlyphPlacement(
    this.outline, {
    this.position = Vec2.zero,
    this.scale = 1,
    this.sourceIndex = 0,
  }) {
    if (!position.isFinite ||
        !scale.isFinite ||
        scale <= 0 ||
        sourceIndex < 0) {
      throw ArgumentError(
        'Glyph placement needs finite coordinates, positive scale and a nonnegative source index.',
      );
    }
  }
}

/// Immutable placements plus advance metrics. Ink can extend past the advance
/// width. A shaping plugin can supply these placements without using [OutlineFont].
final class TextLayout {
  final List<GlyphPlacement> glyphs;
  final List<double> lineWidths;
  final double lineHeight;
  TextLayout.positioned(
    List<GlyphPlacement> glyphs, {
    required List<double> lineWidths,
    required this.lineHeight,
  }) : glyphs = List.unmodifiable(glyphs),
       lineWidths = List.unmodifiable(lineWidths) {
    if (glyphs.length > 4096 ||
        lineWidths.isEmpty ||
        lineWidths.length > 4097 ||
        lineWidths.any((v) => !v.isFinite || v < 0) ||
        !lineHeight.isFinite ||
        lineHeight <= 0 ||
        !(lineHeight * lineWidths.length).isFinite) {
      throw ArgumentError('Invalid text metrics or too many glyphs/lines.');
    }
  }
  double get width => lineWidths.fold<double>(0, math.max);
  double get height => lineHeight * lineWidths.length;
  bool get hasGeometry => glyphs.any((g) => g.outline.shapes.isNotEmpty);
}

/// Bounds output payload; temporary shape and merge storage use additional heap.
final class TextGeometryLimits {
  final int maxVertices, maxBytes;
  const TextGeometryLimits({
    this.maxVertices = 250000,
    this.maxBytes = 64 * 1024 * 1024,
  });
}

/// One mesh for a glyph run, with local XY UVs on caps and perimeter UVs on walls.
/// Flat text faces +Z; extruded text extends from z=0 to [depth]. Whitespace-only
/// runs have no mesh: inspect [TextLayout.hasGeometry] before constructing one.
final class TextGeometry extends BufferGeometry {
  final TextLayout textLayout;
  factory TextGeometry(
    String text, {
    required OutlineFont font,
    double size = 1,
    double letterSpacing = 0,
    double? lineHeight,
    TextAlignment alignment = TextAlignment.start,
    double depth = .1,
    int steps = 1,
    double bevelSize = 0,
    double? bevelThickness,
    int bevelSegments = 1,
    IndexFormat indexFormat = IndexFormat.uint32,
    TextGeometryLimits limits = const TextGeometryLimits(),
  }) => TextGeometry.fromLayout(
    font.layout(
      text,
      size: size,
      letterSpacing: letterSpacing,
      lineHeight: lineHeight,
      alignment: alignment,
    ),
    depth: depth,
    steps: steps,
    bevelSize: bevelSize,
    bevelThickness: bevelThickness,
    bevelSegments: bevelSegments,
    indexFormat: indexFormat,
    limits: limits,
  );

  TextGeometry.fromLayout(
    this.textLayout, {
    double depth = .1,
    int steps = 1,
    double bevelSize = 0,
    double? bevelThickness,
    int bevelSegments = 1,
    IndexFormat indexFormat = IndexFormat.uint32,
    TextGeometryLimits limits = const TextGeometryLimits(),
  }) : super.fromData(
         _textGeometry(
           textLayout,
           depth,
           steps,
           bevelSize,
           bevelThickness ?? bevelSize,
           bevelSegments,
           indexFormat,
           limits,
         ),
       );
}

GeometryData _textGeometry(
  TextLayout layout,
  double depth,
  int steps,
  double bevelSize,
  double bevelThickness,
  int bevelSegments,
  IndexFormat format,
  TextGeometryLimits limits,
) {
  if (!depth.isFinite ||
      depth < 0 ||
      steps < 1 ||
      steps > 1000000 ||
      !bevelSize.isFinite ||
      bevelSize < 0 ||
      !bevelThickness.isFinite ||
      bevelThickness < 0 ||
      (bevelSize > 0) != (bevelThickness > 0) ||
      (depth == 0 ? bevelSize > 0 : bevelThickness * 2 >= depth) ||
      bevelSegments < 1 ||
      bevelSegments > 32 ||
      limits.maxVertices < 1 ||
      limits.maxVertices > 1000000 ||
      limits.maxBytes < 1 ||
      limits.maxBytes > 64 * 1024 * 1024) {
    throw ArgumentError('Invalid text extrusion options or output limits.');
  }
  var vertices = 0, indices = 0;
  final segments = steps + (bevelSize > 0 ? bevelSegments * 2 : 0);
  for (final glyph in layout.glyphs) {
    for (final shape in glyph.outline.shapes) {
      final n = shape.vertices.length;
      final capIndices = 3 * (n + 2 * shape.holes.length - 2);
      vertices += depth == 0 ? n : n * (4 * segments + 2);
      indices += depth == 0 ? capIndices : 6 * n * segments + capIndices * 2;
      if (vertices > limits.maxVertices ||
          vertices > (format == IndexFormat.uint16 ? 65536 : 1000000) ||
          indices > 3000000 ||
          vertices * 32 + indices * format.bytesPerIndex > limits.maxBytes) {
        throw ArgumentError(
          'Text exceeds the vertex, index or payload budget.',
        );
      }
    }
  }
  if (vertices == 0) {
    throw ArgumentError(
      'Text has no outlines. Check layout.hasGeometry before creating a mesh.',
    );
  }
  final positions = Float32List(vertices * 3),
      normals = Float32List(vertices * 3),
      uv = Float32List(vertices * 2);
  final triangles = Uint32List(indices);
  final cache = <(Shape2D, double), BufferGeometry>{};
  var vertexOffset = 0, indexOffset = 0;
  for (final glyph in layout.glyphs) {
    for (final shape in glyph.outline.shapes) {
      final piece = cache.putIfAbsent((shape, glyph.scale), () {
        final scaled = Shape2D(
          [for (final p in shape.contour) p * glyph.scale],
          holes: [
            for (final hole in shape.holes)
              [for (final p in hole) p * glyph.scale],
          ],
        );
        return depth == 0
            ? ShapeGeometry(scaled)
            : ExtrudeGeometry(
                scaled,
                depth: depth,
                steps: steps,
                bevelSize: bevelSize,
                bevelThickness: bevelThickness,
                bevelSegments: bevelSegments,
              );
      });
      for (var v = 0; v < piece.vertexCount; v++) {
        positions[(vertexOffset + v) * 3] =
            piece.positions[v * 3] + glyph.position.x;
        positions[(vertexOffset + v) * 3 + 1] =
            piece.positions[v * 3 + 1] + glyph.position.y;
        positions[(vertexOffset + v) * 3 + 2] = piece.positions[v * 3 + 2];
      }
      normals.setRange(
        vertexOffset * 3,
        (vertexOffset + piece.vertexCount) * 3,
        piece.normals,
      );
      uv.setRange(
        vertexOffset * 2,
        (vertexOffset + piece.vertexCount) * 2,
        piece.uv0!,
      );
      triangles.setRange(
        indexOffset,
        indexOffset + piece.indices.length,
        piece.indices.map((i) => vertexOffset + i),
      );
      vertexOffset += piece.vertexCount;
      indexOffset += piece.indices.length;
    }
  }
  // Translations can collapse small glyphs in float32 even when each outline
  // is valid in double precision. Reject unusable triangles before upload.
  for (var i = 0; i < indexOffset; i += 3) {
    final a = triangles[i] * 3,
        b = triangles[i + 1] * 3,
        c = triangles[i + 2] * 3;
    final x = positions[b] - positions[a],
        y = positions[b + 1] - positions[a + 1],
        z = positions[b + 2] - positions[a + 2];
    final u = positions[c] - positions[a],
        v = positions[c + 1] - positions[a + 1],
        w = positions[c + 2] - positions[a + 2];
    if (y * w - z * v == 0 && z * u - x * w == 0 && x * v - y * u == 0) {
      throw ArgumentError(
        'Text triangle collapsed in float32. Use local glyph coordinates and a scene transform.',
      );
    }
  }
  return GeometryData(
    attributes: {
      VertexSemantic.position: VertexAttribute(
        positions,
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        normals,
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.uv0: VertexAttribute(uv, format: VertexFormat.float32x2),
    },
    indices: Uint32List.sublistView(triangles, 0, indexOffset),
    indexFormat: format,
  );
}
