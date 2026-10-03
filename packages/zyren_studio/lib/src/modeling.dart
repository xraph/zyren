part of '../zyren_studio.dart';

/// Unit primitives are baked to dimensions so node scale remains an editable pose.
BufferGeometry studioPrimitiveGeometry(StudioNodeKind kind, Vec3 size) {
  final base = switch (kind) {
    StudioNodeKind.box => BoxGeometry(),
    StudioNodeKind.sphere => SphereGeometry(radius: .5),
    StudioNodeKind.cylinder => CylinderGeometry(
      radiusTop: .5,
      radiusBottom: .5,
    ),
    StudioNodeKind.cone => ConeGeometry(radius: .5),
    StudioNodeKind.torus => TorusGeometry(radius: .35, tube: .15),
    StudioNodeKind.plane => PlaneGeometry(),
    _ => throw ArgumentError('Node is not a primitive.'),
  };
  final positions = <double>[], normals = <double>[];
  for (var i = 0; i < base.positions.length; i += 3) {
    positions.addAll([
      base.positions[i] * size.x,
      base.positions[i + 1] * size.y,
      base.positions[i + 2] * size.z,
    ]);
    final normal = Vec3(
      base.normals[i] / size.x,
      base.normals[i + 1] / size.y,
      base.normals[i + 2] / size.z,
    ).normalized();
    normals.addAll(normal.storage);
  }
  return BufferGeometry(
    positions: positions,
    normals: normals,
    indices: base.indices,
    uv0: base.uv0,
  );
}

/// Atomic modeling operations use the same validated document and undo history.
abstract final class StudioModeling {
  static StudioDocument addNodes(
    StudioDocument document,
    Iterable<StudioNode> nodes,
  ) {
    final additions = nodes.toList();
    if (additions.isEmpty ||
        additions.length > 64 ||
        additions.any(
          (n) => !n.kind.isPrimitive && n.kind != StudioNodeKind.group,
        )) {
      throw ArgumentError('Add 1 to 64 primitive or group nodes.');
    }
    return document.copyWith(nodes: [...document.nodes, ...additions]);
  }

  /// Articulated blockout with explicit pivots. Not a skin, rig or imported asset.
  static StudioDocument characterBlockout(
    StudioDocument document, {
    required String id,
    String label = 'Character',
    double height = 1.8,
    Vec3 position = Vec3.zero,
    int color = 0x7e9cb2,
  }) {
    if (!height.isFinite || height < .1 || height > 100) {
      throw ArgumentError('Height must be between .1 and 100 scene units.');
    }
    final nodes = <StudioNode>[
      StudioNode(
        id: id,
        label: label,
        kind: StudioNodeKind.group,
        position: position,
        scale: Vec3(height / 1.8, height / 1.8, height / 1.8),
      ),
    ];
    void joint(String name, String parent, Vec3 point) => nodes.add(
      StudioNode(
        id: '$id-$name',
        label: name,
        parentId: parent,
        kind: StudioNodeKind.group,
        position: point,
      ),
    );
    void part(
      String name,
      String parent,
      StudioNodeKind kind,
      Vec3 point,
      Vec3 size,
    ) => nodes.add(
      StudioNode(
        id: '$id-$name',
        label: name,
        parentId: parent,
        kind: kind,
        position: point,
        size: size,
        color: color,
      ),
    );
    part(
      'torso',
      id,
      StudioNodeKind.box,
      const Vec3(0, 1.22, 0),
      const Vec3(.42, .52, .24),
    );
    joint('neck', id, const Vec3(0, 1.52, 0));
    part(
      'head',
      '$id-neck',
      StudioNodeKind.sphere,
      const Vec3(0, .15, 0),
      const Vec3(.28, .32, .28),
    );
    for (final side in [('left', -1.0), ('right', 1.0)]) {
      final name = side.$1, sign = side.$2;
      joint('$name-shoulder', id, Vec3(sign * .29, 1.44, 0));
      part(
        '$name-upper-arm',
        '$id-$name-shoulder',
        StudioNodeKind.cylinder,
        const Vec3(0, -.14, 0),
        const Vec3(.13, .28, .13),
      );
      joint('$name-elbow', '$id-$name-shoulder', const Vec3(0, -.3, 0));
      part(
        '$name-forearm',
        '$id-$name-elbow',
        StudioNodeKind.cylinder,
        const Vec3(0, -.13, 0),
        const Vec3(.11, .26, .11),
      );
      joint('$name-hip', id, Vec3(sign * .12, .92, 0));
      part(
        '$name-thigh',
        '$id-$name-hip',
        StudioNodeKind.cylinder,
        const Vec3(0, -.2, 0),
        const Vec3(.17, .4, .17),
      );
      joint('$name-knee', '$id-$name-hip', const Vec3(0, -.42, 0));
      part(
        '$name-shin',
        '$id-$name-knee',
        StudioNodeKind.cylinder,
        const Vec3(0, -.19, 0),
        const Vec3(.14, .38, .14),
      );
      part(
        '$name-foot',
        '$id-$name-knee',
        StudioNodeKind.box,
        const Vec3(0, -.44, .06),
        const Vec3(.16, .12, .3),
      );
    }
    return addNodes(document, nodes);
  }
}
