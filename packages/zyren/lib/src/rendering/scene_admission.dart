part of 'frame_submission.dart';

extension _SceneAdmission on ScenePacketEncoder {
  EncodedScenePacket _stagePacket(
    FrameSubmission candidate,
    List<GeometrySnapshot> geometries,
    List<TextureImage> textures,
    List<InstanceSnapshot> instances,
    List<DeformationSnapshot> poses,
  ) {
    var bytes = 0, vertices = 0, indices = 0;
    bool admit(int size, [int vertexCount = 0, int indexCount = 0]) {
      if (size > 64 * 1024 * 1024 ||
          vertexCount > 1000000 ||
          indexCount > 3000000) {
        throw ArgumentError(
          'A single scene asset exceeds the admitted upload limit.',
        );
      }
      if (bytes + size > 64 * 1024 * 1024 ||
          vertices + vertexCount > 1000000 ||
          indices + indexCount > 3000000) {
        return false;
      }
      if (bytes > 0 && bytes + size > uploadBudgetBytes) return false;
      bytes += size;
      vertices += vertexCount;
      indices += indexCount;
      return true;
    }

    final source = candidate.scene;
    final selectedGeometry = <int, GeometrySnapshot>{};
    final selectedTextures = <int, TextureImage>{};
    final selectedInstances = <int, InstanceSnapshot>{};
    final selectedPoses = <int, DeformationSnapshot>{};
    var remaining = 0;
    for (final geometry in geometries) {
      if (admit(
        geometry.gpuByteLength,
        geometry.positions.length ~/ 3,
        geometry.indices.length,
      )) {
        selectedGeometry[geometry.id] = geometry;
      } else {
        remaining += geometry.gpuByteLength;
      }
    }
    for (final texture in textures) {
      final size = texture.levels.fold<int>(0, (n, level) => n + level.length);
      if (admit(math.max(size, texture.descriptor.byteLength))) {
        selectedTextures[texture.id] = texture;
      } else {
        remaining += size;
      }
    }
    for (final instance in instances) {
      if (admit(instance.gpuByteLength)) {
        selectedInstances[instance.id] = instance;
      } else {
        remaining += instance.gpuByteLength;
      }
    }
    // Pose source geometry is uploaded first, possibly in an earlier frame.
    for (final pose in poses) {
      if ((selectedGeometry.containsKey(pose.geometry.id) ||
              (_staged?._geometries.containsKey(pose.geometry.id) ?? false) ||
              _uploaded[pose.geometry.logicalId]?.id == pose.geometry.id) &&
          admit(pose.gpuByteLength)) {
        selectedPoses[pose.id] = pose;
      } else {
        remaining += pose.gpuByteLength;
      }
    }
    final selected = _resourceSnapshot(
      source,
      selectedGeometry,
      selectedTextures,
      selectedInstances,
      selectedPoses,
    );
    return _finishStage(candidate, selected, remaining);
  }

  EncodedScenePacket _finishStage(
    FrameSubmission candidate,
    SceneSnapshot selected,
    int remaining,
  ) {
    final source = _neededResources(candidate.scene);
    Map<int, T> retained<T>(
      Map<int, T>? old,
      Map<int, T> next,
      Map<int, T> wanted,
    ) => {
      for (final entry in (old ?? <int, T>{}).entries)
        if (wanted.containsKey(entry.key)) entry.key: entry.value,
      ...next,
    };
    final staged = _resourceSnapshot(
      source,
      retained(_staged?._geometries, selected._geometries, source._geometries),
      retained(_staged?._textures, selected._textures, source._textures),
      retained(_staged?._instances, selected._instances, source._instances),
      retained(_staged?._poses, selected._poses, source._poses),
    );
    final manifest = _manifestFor(source);
    final stageSubmission = _withScene(candidate, selected);
    final stageEncoder = ScenePacketEncoder(
      viewId: viewId,
      materialDevice: materialDevice,
    );
    final stage = stageEncoder._encode(
      stageSubmission,
      resourceOnly: true,
      allowStage: false,
    );
    final display = _published == null
        ? FrameSubmission._(
            _resourceSnapshot(source, {}, {}, {}, {}),
            candidate.camera,
            candidate.target,
            candidate.size,
            candidate.time,
            candidate.cpuBuildTime,
            null,
            candidate.colorPipeline,
            null,
            candidate.temporalReset,
            null,
            ShadowSnapshot._([], candidate.camera.forward),
          )
        : _reproject(_published!, candidate);
    final packet = _encode(display, allowStage: false);
    return _wrapAdmission(
      packet._display ?? packet,
      stage,
      manifest,
      remaining,
      _manifestFor(staged).fold<int>(0, (n, item) => n + item[2]),
      staged: staged,
    );
  }

  EncodedScenePacket _wrapAdmission(
    EncodedScenePacket display,
    EncodedScenePacket? upload,
    List<List<int>> manifest,
    int backlog,
    int stagedBytes, {
    SceneSnapshot? staged,
  }) {
    final metadata = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'view': viewId,
          'resources': manifest,
          'backlogBytes': backlog,
          'stagedBytes': stagedBytes,
          'publish': staged == null,
        }),
      ),
    );
    final writer = _SceneWriter()
      ..u32(4)
      ..u32(metadata.length)
      ..u32(upload?.bytes.length ?? 0)
      ..u32(display.bytes.length)
      ..add(metadata);
    if (upload != null) writer.add(upload.bytes);
    writer.add(display.bytes);
    return EncodedScenePacket._(
        writer.finish().asUnmodifiableView(),
        display.uploadedBytes + (upload?.uploadedBytes ?? 0),
        display.changedMeshes,
        this,
        display._revision,
        display._scene,
        display._uploaded,
        display._uploadedTextures,
        display._uploadedInstances,
        display._uploadedPoses,
      )
      ..submission = display.submission
      .._tokens = display._tokens
      ..bindingHeader = staged == null ? display.bindingHeader : _bindingHeader
      .._display = display
      .._stage = staged
      .._backlogBytes = backlog
      .._stagedBytes = stagedBytes;
  }
}

SceneSnapshot _neededResources(SceneSnapshot source) {
  final geometries = source._meshes.map((m) => m['geometry']).toSet();
  final instances = source._meshes.map((m) => m['instances']).toSet();
  final poses = source._meshes.map((m) => m['pose']).toSet();
  final textures = {
    for (final mesh in source._meshes)
      if ((mesh['colorMap'] as List).isNotEmpty)
        (mesh['colorMap'] as List).first,
    for (final mesh in source._meshes)
      for (final field in [..._standardMapFields, ..._physicalMapFields])
        if ((mesh['pbr'] as Map?)?[field] case final List binding)
          binding.first,
  };
  return _resourceSnapshot(
    source,
    Map.of(source._geometries)
      ..removeWhere((id, _) => !geometries.contains(id)),
    Map.of(source._textures)..removeWhere((id, _) => !textures.contains(id)),
    Map.of(source._instances)..removeWhere((id, _) => !instances.contains(id)),
    Map.of(source._poses)..removeWhere((id, _) => !poses.contains(id)),
  );
}

List<List<int>> _manifestFor(SceneSnapshot scene) => [
  for (final g in scene._geometries.values) [0, g.id, g.gpuByteLength],
  for (final t in scene._textures.values) [1, t.id, t.descriptor.byteLength],
  for (final i in scene._instances.values) [2, i.id, i.gpuByteLength],
  for (final p in scene._poses.values) [3, p.id, p.gpuByteLength],
];

SceneSnapshot _resourceSnapshot(
  SceneSnapshot source,
  Map<int, GeometrySnapshot> geometries,
  Map<int, TextureImage> textures,
  Map<int, InstanceSnapshot> instances,
  Map<int, DeformationSnapshot> poses,
) => SceneSnapshot._(
  [],
  [],
  [],
  [],
  [],
  geometries,
  instances,
  poses,
  textures,
  source._background,
  source.backgroundOpacity,
  source._light,
  source._ambient,
  {},
  [],
  RenderSettings(),
  null,
  const {},
);

FrameSubmission _withScene(FrameSubmission frame, SceneSnapshot scene) =>
    FrameSubmission._(
      scene,
      frame.camera,
      frame.target,
      frame.size,
      frame.time,
      frame.cpuBuildTime,
      frame.graph,
      frame.colorPipeline,
      frame.temporalAA,
      frame.temporalReset,
      frame.environment,
      frame.shadows,
    );

FrameSubmission _reproject(FrameSubmission published, FrameSubmission current) {
  final shift = List.generate(
    3,
    (i) => published.camera.origin[i] - current.camera.origin[i],
  );
  final source = published.scene;
  List<Map<String, Object>> lights(List<Map<String, Object>> values) => [
    for (final light in values)
      {
        ...light,
        if (light['position'] case final List position)
          'position': List.generate(
            3,
            (i) => (position[i] as double) + shift[i],
          ),
      },
  ];
  final meshes = <Map<String, Object>>[];
  for (final mesh in source._meshes) {
    final model = List<double>.of((mesh['model'] as List).cast<double>());
    for (var i = 0; i < 3; i++) {
      model[12 + i] += shift[i];
    }
    final clipping = (mesh['clippingPlanes'] as List).cast<double>().toList();
    for (var i = 0; i < clipping.length; i += 4) {
      clipping[i + 3] -=
          clipping[i] * shift[0] +
          clipping[i + 1] * shift[1] +
          clipping[i + 2] * shift[2];
    }
    // The published frustum belongs to an older camera. Retain every authored
    // visible/layer-matched mesh during staging and let GPU clipping reject it
    // in this view. Ordinary conservative CPU culling resumes on publication.
    meshes.add({
      ...mesh,
      'color_visible': true,
      'model': model,
      'clippingPlanes': clipping,
    });
  }
  final scene = SceneSnapshot._(
    meshes,
    source._identities,
    lights(source._lights),
    source._hemispheres,
    lights(source._areas),
    source._geometries,
    source._instances,
    source._poses,
    source._textures,
    source._background,
    source.backgroundOpacity,
    source._light,
    source._ambient,
    source.meshShaders,
    source._shadowLights,
    source._settings,
    source._outline,
    source.localEnvironments,
  );
  final translation = vm.Matrix4.translationValues(
    -shift[0],
    -shift[1],
    -shift[2],
  );
  final shadows = ShadowSnapshot._([
    for (final view in published.shadows.views)
      ShadowView._(
        view.lightIndex,
        view.kind,
        view.resolution,
        view.revision,
        (vm.Matrix4.fromList(view.viewProjection) * translation).storage,
        view.near,
        view.far,
        view.blend,
        view.settings,
      ),
  ], current.camera.forward);
  return FrameSubmission._(
    scene,
    current.camera,
    current.target,
    current.size,
    current.time,
    current.cpuBuildTime,
    published.graph,
    published.colorPipeline,
    current.temporalAA,
    current.temporalReset,
    published.environment,
    shadows,
  );
}
