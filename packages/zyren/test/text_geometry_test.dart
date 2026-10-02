import 'package:test/test.dart';
import 'package:zyren/zyren.dart';

Shape2D square(double a, double b) =>
    Shape2D([Vec2(a, a), Vec2(b, a), Vec2(b, b), Vec2(a, b)]);
OutlineFont font() => OutlineFont(
  unitsPerEm: 10,
  lineHeight: 12,
  glyphs: {
    65: GlyphOutline(advance: 12, shapes: [square(0, 10)]),
    86: GlyphOutline(advance: 11, shapes: [square(0, 10)]),
    32: GlyphOutline(advance: 4),
    63: GlyphOutline(advance: 10, shapes: [square(2, 8)]),
    0x1f600: GlyphOutline(advance: 10, shapes: [square(0, 10)]),
  },
  kerning: {(65, 86): -2},
  fallbackCodePoint: 63,
);

double volume(BufferGeometry g) {
  var result = 0.0;
  for (var i = 0; i < g.indices.length; i += 3) {
    final a = Vec3.array(g.positions, g.indices[i] * 3);
    final b = Vec3.array(g.positions, g.indices[i + 1] * 3);
    final c = Vec3.array(g.positions, g.indices[i + 2] * 3);
    result += a.dot(b.cross(c)) / 6;
  }
  return result;
}

void main() {
  test(
    'outline ownership is immutable and collinear caps use actual triangle counts',
    () {
      final shapes = [
        Shape2D(const [
          Vec2(0, 0),
          Vec2(1, 0),
          Vec2(2, 0),
          Vec2(2, 2),
          Vec2(0, 2),
        ]),
      ];
      final glyph = GlyphOutline(advance: 3, shapes: shapes);
      shapes.clear();
      final glyphs = {65: glyph};
      final f = OutlineFont(unitsPerEm: 2, lineHeight: 3, glyphs: glyphs);
      glyphs.clear();
      final result = TextGeometry('A', font: f, size: 2, depth: .5);
      expect(volume(result), closeTo(2, 1e-6));
      expect(() => f.glyphs.clear(), throwsUnsupportedError);
      expect(() => glyph.shapes.clear(), throwsUnsupportedError);
      final shifted = TextLayout.positioned(
        [GlyphPlacement(glyph, position: const Vec2(1e9, 1e9))],
        lineWidths: [3],
        lineHeight: 3,
      );
      expect(
        () => TextGeometry.fromLayout(shifted, depth: 0),
        throwsArgumentError,
      );
    },
  );

  test(
    'layout applies font scale, kerning, tracking, line breaks and alignment',
    () {
      final result = font().layout(
        'AV\r\nA',
        size: 2,
        letterSpacing: .2,
        alignment: TextAlignment.center,
      );
      expect(result.lineWidths, [closeTo(4.4, 1e-12), closeTo(2.4, 1e-12)]);
      expect(result.width, 4.4);
      expect(result.height, closeTo(4.8, 1e-12));
      expect(result.glyphs[0].position, const Vec2(-2.2, 0));
      expect(result.glyphs[1].position.x, closeTo(0, 1e-12));
      expect(result.glyphs[2].position.x, closeTo(-1.2, 1e-12));
      expect(result.glyphs[2].position.y, closeTo(-2.4, 1e-12));
      expect(result.glyphs[2].sourceIndex, 4);
    },
  );

  test(
    'Unicode scalars retain UTF16 cluster offsets and explicit fallback',
    () {
      final result = font().layout('😀A!');
      expect(result.glyphs.map((g) => g.sourceIndex), [0, 2, 3]);
      expect(result.lineWidths.single, closeTo(3.2, 1e-12));
      final strict = OutlineFont(
        unitsPerEm: 10,
        lineHeight: 12,
        glyphs: {65: GlyphOutline(advance: 12)},
      );
      expect(() => strict.layout('!'), throwsArgumentError);
      expect(() => font().layout('A\tV'), throwsArgumentError);
      expect(
        () => font().layout(String.fromCharCode(0xd800)),
        throwsArgumentError,
      );
    },
  );

  test(
    'flat text keeps counters empty and extrusion has the expected volume',
    () {
      final ring = Shape2D(
        square(0, 10).contour,
        holes: [square(3, 7).contour],
      );
      final outline = OutlineFont(
        unitsPerEm: 10,
        lineHeight: 12,
        glyphs: {
          79: GlyphOutline(advance: 12, shapes: [ring]),
        },
      );
      final flat = TextGeometry('OO', font: outline, size: 2, depth: 0);
      expect(flat.positions.every((v) => v.isFinite), isTrue);
      final scene = Scene()..add(Mesh(flat, UnlitMaterial()));
      expect(
        Raycaster()
            .capture(scene, Ray(const Vec3(1, 1, 2), const Vec3(0, 0, -1)))
            .intersectFirst(),
        isNull,
      );
      expect(
        Raycaster()
            .capture(scene, Ray(const Vec3(.2, .2, 2), const Vec3(0, 0, -1)))
            .intersectFirst(),
        isNotNull,
      );
      final solid = TextGeometry(
        'OO',
        font: outline,
        size: 2,
        depth: .5,
        steps: 2,
      );
      expect(volume(solid), closeTo(3.36, 1e-5));
      expect(solid.capture().bounds.maximum.x, closeTo(4.4, 1e-6));
      expect(solid.capture().bounds.maximum.z, .5);
    },
  );

  test(
    'positioned glyphs support shaped runs independently of a font parser',
    () {
      final shape = GlyphOutline(advance: 10, shapes: [square(0, 10)]);
      final glyphs = [
        GlyphPlacement(
          shape,
          position: const Vec2(3, 4),
          scale: .2,
          sourceIndex: 7,
        ),
      ];
      final layout = TextLayout.positioned(
        glyphs,
        lineWidths: [2],
        lineHeight: 2.4,
      );
      glyphs.clear();
      final text = TextGeometry.fromLayout(
        layout,
        depth: .25,
        bevelSize: .05,
        bevelThickness: .04,
        bevelSegments: 2,
      );
      expect(layout.glyphs.length, 1);
      expect(text.capture().bounds.minimum.x, 3);
      expect(text.capture().bounds.minimum.y, 4);
      expect(text.capture().bounds.maximum.x, 5);
      expect(text.capture().bounds.maximum.y, 6);
      expect(volume(text), inExclusiveRange(.5, 1));
    },
  );

  test('whitespace measures without inventing renderable geometry', () {
    final layout = font().layout(' \n');
    expect(layout.hasGeometry, isFalse);
    expect(layout.lineWidths, [.4, 0]);
    expect(() => TextGeometry.fromLayout(layout), throwsArgumentError);
    expect(font().layout('').glyphs, isEmpty);
  });

  test(
    'layout and geometry reject nonfinite data and allocation excess early',
    () {
      expect(() => GlyphOutline(advance: double.nan), throwsArgumentError);
      expect(
        () => OutlineFont(unitsPerEm: 0, lineHeight: 1, glyphs: {}),
        throwsArgumentError,
      );
      expect(
        () => font().layout('A', size: double.infinity),
        throwsArgumentError,
      );
      expect(() => font().layout('A' * 4097), throwsArgumentError);
      expect(() => font().layout('A', lineHeight: -1), throwsArgumentError);
      expect(
        () => TextGeometry(
          'A',
          font: font(),
          limits: const TextGeometryLimits(maxVertices: 3),
        ),
        throwsArgumentError,
      );
      expect(
        () => TextGeometry(
          'A',
          font: font(),
          limits: const TextGeometryLimits(maxBytes: 10),
        ),
        throwsArgumentError,
      );
      expect(
        () => TextGeometry('A', font: font(), steps: 1000000000),
        throwsArgumentError,
      );
      expect(
        () => TextGeometry('A', font: font(), depth: 0, bevelSize: .1),
        throwsArgumentError,
      );
      expect(
        () => TextLayout.positioned(
          [GlyphPlacement(GlyphOutline(advance: 1), scale: 0)],
          lineWidths: [1],
          lineHeight: 1,
        ),
        throwsArgumentError,
      );
    },
  );
}
