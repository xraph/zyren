part of 'frame_submission.dart';

/// Immutable transfer plus the proposed view baseline. Accept only after the
/// native renderer reports that it applied the frame, including hidden frames.
final class EncodedScenePacket {
  final Uint8List bytes;
  late final FrameSubmission submission;

  /// Opaque native binding prefix. A resource-capable adapter records this on
  /// publication and reuses it for the native-owned cover during staging.
  Uint8List? bindingHeader;
  Map<Object, Object> _tokens = {};
  bool get ready => _stage == null;
  int get uploadBacklogBytes => _backlogBytes;
  int get stagedBytes => _stagedBytes;
  int _backlogBytes = 0, _stagedBytes = 0;
  SceneAdmission get admission => SceneAdmission(
    candidateReady: ready,
    publishedRevision: ready ? _revision : _owner.publishedRevision,
    uploadBacklogBytes: uploadBacklogBytes,
    stagedBytes: stagedBytes,
    presentedIdentities: presentedIdentities,
  );
  SceneSnapshot? _stage;
  EncodedScenePacket? _display;

  /// Object and resource identities of the cover this packet actually presents.
  List<(int, int)> get presentedIdentities =>
      List.unmodifiable(_scene._identities);
  final int uploadedBytes, changedMeshes;
  final ScenePacketEncoder _owner;
  final int _revision;
  final SceneSnapshot _scene;
  final Map<int, GeometrySnapshot> _uploaded;
  final Set<int> _uploadedTextures;
  final Map<int, InstanceSnapshot> _uploadedInstances;
  final Map<int, DeformationSnapshot> _uploadedPoses;
  EncodedScenePacket._(
    this.bytes,
    this.uploadedBytes,
    this.changedMeshes,
    this._owner,
    this._revision,
    this._scene,
    this._uploaded,
    this._uploadedTextures,
    this._uploadedInstances,
    this._uploadedPoses,
  );
}

/// One serial view's binary encoder. Resources survive visibility changes.
/// Independent views need independent encoders, even when sharing a device.
///
/// Accept only a successful native receipt. Camera-only updates preserve staged
/// immutable resources. A replacement candidate keeps resources it still needs
/// and abandons the rest; returning to the published cover cancels the backlog.
/// Call [reject] after failed preparation so a retry resends uncertain uploads.
/// Native publication keeps resource references until replacement or view close,
/// independently of the Dart owners. Closing an owner invalidates new use.
final class ScenePacketEncoder {
  final int viewId;
  final MaterialDevice? materialDevice;
  int _uploadBudgetBytes = 64 * 1024 * 1024;

  /// Upload target per frame, separate from the hard protocol limits.
  /// An indivisible asset above this target is admitted alone to make progress.
  int get uploadBudgetBytes => _uploadBudgetBytes;
  set uploadBudgetBytes(int value) {
    RangeError.checkValueInInterval(
      value,
      1,
      64 * 1024 * 1024,
      'uploadBudgetBytes',
    );
    _uploadBudgetBytes = value;
  }

  int _next = 0, _accepted = 0;
  SceneSnapshot? _previous;
  Map<Object, Object> _tokens = {};
  Uint8List? _bindingHeader;
  FrameSubmission? _published;
  FrameSubmission? presentedSubmission;
  SceneAdmission? admission;
  SceneSnapshot? _staged;

  /// The last complete cover accepted by the native presenter.
  FrameSubmission? get publishedSubmission => _published;
  int get publishedRevision => _publishedRevision;
  int _publishedRevision = 0;
  int uploadBacklogBytes = 0;
  int stagedBytes = 0;
  Map<int, GeometrySnapshot> _uploaded = {};
  Set<int> _uploadedTextures = {};
  Map<int, InstanceSnapshot> _uploadedInstances = {};
  Map<int, DeformationSnapshot> _uploadedPoses = {};
  ScenePacketEncoder({
    required this.viewId,
    this.materialDevice,
    int uploadBudgetBytes = 64 * 1024 * 1024,
  }) {
    if (viewId <= 0) throw ArgumentError.value(viewId, 'viewId');
    this.uploadBudgetBytes = uploadBudgetBytes;
  }
  EncodedScenePacket encode(FrameSubmission submission) => _encode(submission);
  EncodedScenePacket _encode(
    FrameSubmission submission, {
    bool resourceOnly = false,
    bool allowStage = true,
  }) {
    final scene = submission.scene;
    final tokens = <Object, Object>{};
    Uint8List materialToken(Object owner, Uint8List Function() encode) {
      final token = !allowStage && _tokens[owner] is Uint8List
          ? _tokens[owner] as Uint8List
          : encode();
      tokens[owner] = token;
      return token;
    }

    for (final mesh in scene._meshes) {
      if (mesh['shader'] case final MeshShader shader) {
        final device = materialDevice;
        if (device == null) {
          throw UnsupportedError(
            'Custom materials require a material-capable backend.',
          );
        }
        materialToken(shader, () => shader.encodeForDevice(device));
      }
    }
    final effects = [
      for (final effect in scene._settings.effects)
        materialToken(
          effect,
          () => effect.encodeForDevice(
            materialDevice ??
                (throw UnsupportedError(
                  'Effects require a material-capable backend.',
                )),
          ),
        ),
    ];
    final environment = scene._settings.environment;
    final environmentKeys =
        environment != null && !allowStage && _tokens[environment] != null
        ? _tokens[environment] as List<Uint8List>
        : environment?.encodeForDevice(
            materialDevice is EnvironmentDevice
                ? materialDevice as EnvironmentDevice
                : throw UnsupportedError(
                    'Environment lighting requires a resource-capable backend.',
                  ),
          );
    if (environment != null && environmentKeys != null) {
      tokens[environment] = environmentKeys;
    }
    final locals = <Environment, List<Uint8List>>{};
    for (final local in scene.localEnvironments.values.toSet()) {
      final keys = !allowStage && _tokens[local] != null
          ? _tokens[local] as List<Uint8List>
          : local.encodeForDevice(materialDevice as EnvironmentDevice);
      locals[local] = keys;
      tokens[local] = keys;
    }
    final previous = _previous;
    final topology =
        previous == null ||
        previous._meshes.length != scene._meshes.length ||
        List.generate(scene._meshes.length, (i) => i).any(
          (i) =>
              previous._meshes[i]['geometry'] != scene._meshes[i]['geometry'],
        );
    final logicalIds = {
      for (final geometry in scene._geometries.values) geometry.logicalId,
    };
    final uploaded = Map<int, GeometrySnapshot>.of(_uploaded)
      ..removeWhere((id, _) => !logicalIds.contains(id));
    final visible = resourceOnly
        ? scene._geometries.keys.toSet()
        : {for (final mesh in scene._meshes) mesh['geometry'] as int};
    final uploads = <GeometrySnapshot>[];
    final patches = <_GeometryPatch>[];
    for (final geometry in scene._geometries.values) {
      if (!visible.contains(geometry.id)) continue;
      if (geometry.topology != GeometryTopology.triangles &&
          (geometry.uv0 != null ||
              geometry.uv1 != null ||
              geometry.tangents != null)) {
        throw UnsupportedError(
          'Expanded primitives do not support UV or tangent attributes.',
        );
      }
      if (_staged?._geometries.containsKey(geometry.id) ?? false) {
        uploaded[geometry.logicalId] = geometry;
        continue;
      }
      final base = uploaded[geometry.logicalId];
      if (base?.id == geometry.id) continue;
      final ranges =
          base == null ||
              geometry.topology != GeometryTopology.triangles ||
              geometry.joints != null ||
              geometry.morphTargets.isNotEmpty
          ? null
          : geometry.changesSince(base);
      if (base == null || ranges == null) {
        uploads.add(geometry);
      } else {
        patches.add(_GeometryPatch(base.id, geometry, ranges));
      }
      uploaded[geometry.logicalId] = geometry;
    }
    // Hidden edits keep the last uploaded version until this view needs pixels.
    final owned = {
      for (final geometry in scene._geometries.values)
        uploaded[geometry.logicalId]?.id ?? geometry.id,
    };
    final uploadedTextures = _uploadedTextures.intersection(
      scene._textures.keys.toSet(),
    );
    final visibleTextures = resourceOnly
        ? scene._textures.keys.toSet()
        : {
            for (final mesh in scene._meshes)
              if ((mesh['colorMap'] as List).isNotEmpty)
                (mesh['colorMap'] as List).first as int,
            for (final mesh in scene._meshes)
              for (final field in [
                ..._standardMapFields,
                ..._physicalMapFields,
              ])
                if ((mesh['pbr'] as Map?)?[field] case final List binding)
                  binding.first as int,
          };
    final textures = [
      for (final id in visibleTextures)
        if (!uploadedTextures.contains(id) &&
            !(_staged?._textures.containsKey(id) ?? false))
          scene._textures[id]!,
    ];
    final instanceLogicalIds = scene._instances.values
        .map((v) => v.logicalId)
        .toSet();
    final uploadedInstances = Map<int, InstanceSnapshot>.of(_uploadedInstances)
      ..removeWhere((id, _) => !instanceLogicalIds.contains(id));
    final visibleInstances = resourceOnly
        ? scene._instances.keys.toSet()
        : scene._meshes.map((m) => m['instances']).toSet();
    final instanceUploads = <InstanceSnapshot>[];
    final instancePatches = <(int, InstanceSnapshot, List<InstanceRange>)>[];
    for (final instance in scene._instances.values) {
      if (!visibleInstances.contains(instance.id)) continue;
      if (_staged?._instances.containsKey(instance.id) ?? false) {
        uploadedInstances[instance.logicalId] = instance;
        continue;
      }
      final base = uploadedInstances[instance.logicalId];
      if (base?.id == instance.id) continue;
      final ranges = base == null ? null : instance.changesSince(base);
      if (base == null || ranges == null) {
        instanceUploads.add(instance);
      } else {
        instancePatches.add((base.id, instance, ranges));
      }
      uploadedInstances[instance.logicalId] = instance;
    }
    final ownedInstances = {
      for (final instance in scene._instances.values)
        if (uploadedInstances[instance.logicalId] case final uploaded?)
          uploaded.id,
    };
    final poseLogicalIds = scene._poses.values.map((v) => v.logicalId).toSet();
    final uploadedPoses = Map<int, DeformationSnapshot>.of(_uploadedPoses)
      ..removeWhere((id, _) => !poseLogicalIds.contains(id));
    final visiblePoses = resourceOnly
        ? scene._poses.keys.toSet()
        : scene._meshes.map((m) => m['pose']).toSet();
    final poseUploads = <DeformationSnapshot>[];
    for (final pose in scene._poses.values) {
      if (!visiblePoses.contains(pose.id)) continue;
      if (_staged?._poses.containsKey(pose.id) ?? false) {
        uploadedPoses[pose.logicalId] = pose;
        continue;
      }
      if (uploadedPoses[pose.logicalId]?.id == pose.id) continue;
      poseUploads.add(pose);
      uploadedPoses[pose.logicalId] = pose;
    }
    final ownedPoses = {
      for (final pose in scene._poses.values)
        if (uploadedPoses[pose.logicalId] case final uploaded?) uploaded.id,
    };
    final updates = <int>[];
    // Choose full replacement before accessing the nullable baseline. Keep this
    // guard explicit for AOT compilation as well as first-frame ownership.
    if (previous == null || topology) {
      updates.addAll(List.generate(scene._meshes.length, (i) => i));
    } else {
      for (var i = 0; i < scene._meshes.length; i++) {
        if (!_sameMesh(scene._meshes[i], previous._meshes[i])) {
          updates.add(i);
        }
      }
    }
    if (scene._geometries.length > 4096 ||
        scene._meshes.length > 4096 ||
        scene._textures.length > 4096) {
      throw ArgumentError(
        'A scene view supports at most 4096 meshes, geometries and images each.',
      );
    }
    var uploadBytes = 0, vertices = 0, indices = 0;
    for (final geometry in uploads) {
      vertices += geometry.positions.length ~/ 3;
      indices += geometry.indices.length;
      uploadBytes += geometry.gpuByteLength;
    }
    for (final patch in patches) {
      uploadBytes += patch.uploadedBytes;
    }
    for (final texture in textures) {
      uploadBytes += texture.levels.fold<int>(
        0,
        (sum, level) => sum + level.length,
      );
    }
    uploadBytes += instanceUploads.fold<int>(
      0,
      (n, instance) => n + instance.gpuByteLength,
    );
    for (final (_, _, ranges) in instancePatches) {
      uploadBytes += ranges.fold<int>(0, (n, range) => n + range.count * 128);
    }
    uploadBytes += poseUploads.fold<int>(
      0,
      (n, pose) => n + pose.gpuByteLength,
    );
    final uploadCostBytes =
        uploadBytes +
        textures.fold<int>(0, (sum, texture) {
          final sourceBytes = texture.levels.fold<int>(
            0,
            (n, level) => n + level.length,
          );
          return sum + math.max(0, texture.descriptor.byteLength - sourceBytes);
        });
    if (vertices > 1000000 ||
        indices > 3000000 ||
        uploadBytes > 64 * 1024 * 1024 ||
        textures.fold<int>(0, (n, t) => n + t.descriptor.byteLength) >
            64 * 1024 * 1024 ||
        (allowStage && uploadCostBytes > uploadBudgetBytes)) {
      if (!allowStage) {
        throw ArgumentError(
          'A single scene asset exceeds the admitted upload limit.',
        );
      }
      return _stagePacket(
        submission,
        [...uploads, ...patches.map((p) => p.geometry)],
        textures,
        [...instanceUploads, ...instancePatches.map((p) => p.$2)],
        poseUploads,
      );
    }
    final settings = scene._settings;
    final screenEnabled =
        (settings.screenSpaceLighting?.enabled ?? false) ||
        settings.hdr ||
        settings.effects.isNotEmpty ||
        settings.bloom != null ||
        settings.toneMapping != ToneMapping.linear ||
        settings.exposure != 1 ||
        settings.sampleCount != 1 ||
        settings.spatialAntialiasing != SpatialAntialiasing.none ||
        settings.environment != null ||
        settings.historyEpoch != 0;
    final extension =
        settings.opaqueCaptureScale != 1 ||
        locals.isNotEmpty ||
        scene._shadowLights.any(
          (light) => light.settings is! DirectionalShadow,
        ) ||
        screenEnabled ||
        submission.camera.depthStrategy == DepthStrategy.reversed ||
        scene._outline != null ||
        scene._meshes.any(
          (m) =>
              m['shader'] != null ||
              (m['clippingPlanes'] as List).isNotEmpty ||
              (m['coverage'] as List)[0] != 0.0 ||
              (m['coverage'] as List)[1] != 1.0 ||
              (m['pbr'] != null &&
                  ((m['pbr'] as Map)['normal_scale_y'] !=
                          (m['pbr'] as Map)['normal_scale'] ||
                      ((m['pbr'] as Map)['specular_aa'] as List)[0] != .15 ||
                      ((m['pbr'] as Map)['specular_aa'] as List)[1] != .2)),
        );
    final opcode = extension
        ? 36
        : scene._shadowLights.any((light) => light.settings is AreaShadow)
        ? 35
        : scene._meshes.any((m) => (m['pbr'] as Map?)?['physical'] != null)
        ? 34
        : submission.temporalAA != null
        ? 31
        : scene.areaLightCount > 0
        ? 30
        : scene._meshes.any((m) => (m['pbr'] as Map?)?['physical'] != null)
        ? 29
        : (submission.colorPipeline?.sampleCount ?? 1) > 1
        ? 28
        : scene._meshes.any((m) => m['color_visible'] == false)
        ? 27
        : scene.hasInstances
        ? 26
        : scene.hasDeformation ||
              scene._geometries.values.any(
                (g) => g.joints != null || g.morphTargets.isNotEmpty,
              )
        ? 25
        : scene._geometries.values.any((g) => g.colors != null) ||
              scene._meshes.any((m) => m['vertex_colors'] == true)
        ? 23
        : scene.hasShadows
        ? 22
        : submission.colorPipeline != null
        ? 21
        : scene.hasStandardMaterials ||
              scene.hemisphereLightCount > 0 ||
              scene._geometries.values.any((g) => g.tangents != null)
        ? 20
        : scene.punctualLightCount > 0
        ? 19
        : scene.backgroundOpacity < 1
        ? 18
        : scene._meshes.any((m) => m['side'] != 0)
        ? 17
        : scene._meshes.any((m) => m['primitive_kind'] != 0)
        ? 16
        : scene._meshes.any(
            (m) =>
                m['alpha_mode'] != 0 ||
                m['opacity'] != 1.0 ||
                m['alpha_cutoff'] != .5 ||
                m['depth_test'] != true ||
                m['depth_write'] != true ||
                m['render_order'] != 0,
          )
        ? 15
        : textures.any((image) => image.generatesMipmaps)
        ? 14
        : uploads.any((g) => g.indexFormat == IndexFormat.uint16)
        ? 13
        : patches.isNotEmpty
        ? 12
        : 11;
    final body = _SceneWriter();
    body.u64(viewId);
    body.u64(topology ? 0 : _accepted);
    body.u32(owned.length);
    body.u32(uploads.length);
    body.u32(scene._meshes.length);
    body.u32(updates.length);
    body.floats(submission.camera.viewProjection);
    body.floats(scene._background);
    body.floats(scene._light);
    body.floats([scene._ambient]);
    if (opcode >= 18) body.floats([scene.backgroundOpacity]);
    if (opcode >= 19) {
      body.u32(scene._lights.length);
      for (final light in scene._lights) {
        body.u32(light['kind'] as int);
        body.floats((light['color'] as List).cast<double>());
        body.floats([light['intensity'] as double]);
        body.floats((light['position'] as List).cast<double>());
        body.floats((light['direction'] as List).cast<double>());
        body.floats([
          light['range'] as double,
          light['inner_cos'] as double,
          light['outer_cos'] as double,
        ]);
      }
    }
    if (opcode >= 20) {
      body.u32(scene._hemispheres.length);
      for (final light in scene._hemispheres) {
        body.floats((light['sky_color'] as List).cast<double>());
        body.floats((light['ground_color'] as List).cast<double>());
        body.floats((light['direction'] as List).cast<double>());
        body.floats([light['intensity'] as double]);
      }
    }
    if (opcode >= 30) {
      body.u32(scene._areas.length);
      for (final light in scene._areas) {
        for (final field in [
          'position',
          'half_width',
          'half_height',
          'color',
        ]) {
          body.floats((light[field] as List).cast<double>());
        }
        body.floats([light['intensity'] as double]);
      }
    }
    if (opcode >= 32) body.u32(submission.temporalAA == null ? 0 : 1);
    if (opcode >= 31 && submission.temporalAA != null) {
      final options = submission.temporalAA!;
      body.floats([options.historyWeight, options.depthTolerance]);
      body.u64(options.maxBytes);
      body.u64(submission.temporalReset);
      body.u64(submission.camera.identity);
      // Float64 origins preserve cut detection at large world coordinates.
      for (final value in submission.camera.origin) {
        final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
        body.add(bytes.buffer.asUint8List());
      }
      body.floats(submission.camera.forward);
      body.floats([submission.camera.targetDistance]);
      body.floats(submission.camera.projection);
      body.u32(scene._identities.length);
      for (final pair in scene._identities) {
        body.u64(pair.$1);
        body.u64(pair.$2);
      }
    }
    if (opcode >= 22) body.u32(submission.colorPipeline == null ? 0 : 1);
    if (opcode >= 21 && submission.colorPipeline != null) {
      body.u32(submission.colorPipeline!.toneMapping.index);
      body.floats([submission.colorPipeline!.exposure]);
      if (opcode >= 28) body.u32(submission.colorPipeline!.sampleCount);
    }
    if (opcode >= 22) {
      body.u32(submission.shadows.views.length);
      body.floats(submission.shadows.forward);
      for (final view in submission.shadows.views) {
        body.integers([
          view.lightIndex,
          view.kind,
          view.resolution,
          view.revision,
        ]);
        body.floats(view.viewProjection);
        body.floats([
          view.near,
          view.far,
          view.blend,
          view.settings.strength,
          view.settings.bias,
          view.settings.normalBias,
          view.settings.slopeBias,
          view.settings.filterRadius,
        ]);
      }
    }
    body.u32(scene._textures.length);
    body.u32(textures.length);
    if (opcode >= 12) body.u32(patches.length);
    if (opcode >= 24) {
      body.u32(ownedInstances.length);
      body.u32(instanceUploads.length);
      body.u32(instancePatches.length);
    }
    if (opcode >= 25) {
      body.u32(ownedPoses.length);
      body.u32(poseUploads.length);
    }
    for (final id in owned) {
      body.u32(id);
    }
    for (final id in scene._textures.keys) {
      body.u32(id);
    }
    if (opcode >= 24) {
      for (final id in ownedInstances) {
        body.u32(id);
      }
    }
    if (opcode >= 25) {
      for (final id in ownedPoses) {
        body.u32(id);
      }
    }
    for (final image in textures) {
      body.u32(image.id);
      body.u32(image.descriptor.width);
      body.u32(image.descriptor.height);
      body.u32(image.descriptor.format.index);
      body.u32(image.levels.length);
      if (opcode >= 14) {
        body.u32(
          image.generatesMipmaps ? image.mipmapAlphaFilter.index + 1 : 0,
        );
      }
      for (final level in image.levels) {
        body.u32(level.length);
        body.add(level);
      }
      uploadedTextures.add(image.id);
    }
    for (final geometry in uploads) {
      body.u32(geometry.id);
      body.u32(geometry.positions.length ~/ 3);
      body.u32(geometry.indices.length);
      body.u32(
        (geometry.uv0 == null ? 0 : 1) |
            (geometry.uv1 == null ? 0 : 2) |
            (geometry.indexFormat == IndexFormat.uint16 ? 4 : 0) |
            (geometry.tangents == null ? 0 : 8) |
            (geometry.colors == null ? 0 : 16) |
            (geometry.joints == null ? 0 : 32) |
            (geometry.morphTargets.isEmpty ? 0 : 64),
      );
      if (opcode >= 16) body.u32(geometry.topology.index);
      body.floats(geometry.positions);
      body.floats(geometry.normals);
      body.indices(geometry.indices, geometry.indexFormat);
      if (geometry.uv0 != null) body.floats(geometry.uv0!);
      if (geometry.uv1 != null) body.floats(geometry.uv1!);
      if (geometry.tangents != null) body.floats(geometry.tangents!);
      if (geometry.colors != null) body.floats(geometry.colors!);
      if (geometry.joints != null) {
        body.integers(geometry.joints!);
        body.floats(geometry.weights!);
      }
      if (geometry.morphTargets.isNotEmpty) {
        body.u32(geometry.morphTargets.length);
        for (final target in geometry.morphTargets) {
          body.u32(
            (target.positions == null ? 0 : 1) |
                (target.normals == null ? 0 : 2) |
                (target.tangents == null ? 0 : 4),
          );
          if (target.positions != null) body.floats(target.positions!);
          if (target.normals != null) body.floats(target.normals!);
          if (target.tangents != null) body.floats(target.tangents!);
        }
      }
    }
    for (final patch in patches) {
      body.u32(patch.geometry.id);
      body.u32(patch.baseId);
      body.u32(patch.ranges.length);
      for (final range in patch.ranges) {
        body.u32(range.semantic.index);
        body.u32(range.firstVertex);
        body.u32(range.vertexCount);
        final attribute = patch.geometry.attributes[range.semantic]!;
        final values = range.semantic == VertexSemantic.color
            ? patch.geometry.colors!
            : attribute.data as Float32List;
        final components = range.semantic == VertexSemantic.color
            ? 4
            : attribute.format.components;
        body.floats(
          values.sublist(
            range.firstVertex * components,
            (range.firstVertex + range.vertexCount) * components,
          ),
        );
      }
    }
    for (final instance in instanceUploads) {
      body.u32(instance.id);
      body.u32(instance.capacity);
      for (var i = 0; i < instance.capacity; i++) {
        body.floats(instance.transforms[i].storage);
        body.floats(instance.colors[i].toList());
      }
    }
    for (final (baseId, instance, ranges) in instancePatches) {
      body.u32(instance.id);
      body.u32(baseId);
      body.u32(ranges.length);
      for (final range in ranges) {
        body.u32(range.first);
        body.u32(range.count);
        for (var i = range.first; i < range.first + range.count; i++) {
          body.floats(instance.transforms[i].storage);
          body.floats(instance.colors[i].toList());
        }
      }
    }
    for (final pose in poseUploads) {
      body.integers([
        pose.id,
        pose.geometry.id,
        pose.weights.length,
        pose.matrices.length,
      ]);
      body.floats(pose.weights);
      for (final matrix in pose.matrices) {
        body.floats(matrix.storage);
      }
    }
    for (final i in updates) {
      final mesh = scene._meshes[i];
      body.u32(i);
      body.u32(mesh['geometry'] as int);
      body.floats((mesh['model'] as List).cast<double>());
      body.floats((mesh['color'] as List).cast<double>());
      body.u32(mesh['unlit'] == true ? 1 : 0);
      final map = (mesh['colorMap'] as List).cast<int>();
      body.u32(map.isEmpty ? 0 : 1);
      body.integers(map);
      if (opcode >= 15) {
        body.u32(mesh['alpha_mode'] as int);
        body.floats([
          mesh['opacity'] as double,
          mesh['alpha_cutoff'] as double,
        ]);
        body.u32(mesh['depth_test'] == true ? 1 : 0);
        body.u32(mesh['depth_write'] == true ? 1 : 0);
        body.i32(mesh['render_order'] as int);
        if (opcode >= 16) {
          body.u32(mesh['primitive_kind'] as int);
          body.floats([mesh['primitive_size'] as double]);
          body.u32(mesh['size_units'] as int);
          body.u32(mesh['point_shape'] as int);
          if (opcode >= 17) body.u32(mesh['side'] as int);
          if (opcode >= 19) {
            final material = mesh['pbr'] as Map?;
            body.u32(material == null ? 0 : 1);
            if (material != null) {
              body.floats([
                material['metallic'] as double,
                material['roughness'] as double,
              ]);
              body.floats((material['emissive'] as List).cast<double>());
              if (opcode >= 20) {
                body.floats([
                  material['normal_scale'] as double,
                  material['occlusion_strength'] as double,
                ]);
                for (final field in _standardMapFields) {
                  final binding = (material[field] as List?)?.cast<int>();
                  body.u32(binding == null ? 0 : 1);
                  if (binding != null) body.integers(binding);
                }
              }
            }
            if (opcode >= 29) {
              final physical = (material?['physical'] as List?)?.cast<double>();
              body.u32(physical == null ? 0 : 1);
              if (physical != null) {
                body.floats(physical);
                if (opcode >= 33) {
                  body.floats(
                    (material!['transmission'] as List).cast<double>(),
                  );
                }
                if (opcode >= 34) {
                  body.floats((material!['optical'] as List).cast<double>());
                }
                if (opcode >= 32) {
                  for (final field in _physicalMapFields) {
                    final binding = (material![field] as List?)?.cast<int>();
                    body.u32(binding == null ? 0 : 1);
                    if (binding != null) body.integers(binding);
                  }
                }
              }
            }
          }
        }
      }
      if (opcode >= 22) {
        body.u32(mesh['cast_shadow'] == true ? 1 : 0);
        body.u32(mesh['receive_shadow'] == true ? 1 : 0);
      }
      if (opcode >= 23) body.u32(mesh['vertex_colors'] == true ? 1 : 0);
      if (opcode >= 24) {
        body.u32(mesh['instances'] as int);
        body.u32(mesh['instance_count'] as int);
      }
      if (opcode >= 25) body.u32(mesh['pose'] as int);
      if (opcode >= 27) body.u32(mesh['color_visible'] == false ? 0 : 1);
      if (opcode >= 36) {
        List<int> key(Uint8List bytes) {
          final d = ByteData.sublistView(bytes);
          return [
            for (var i = 0; i < 4; i++) d.getUint64(i * 8, Endian.little),
          ];
        }

        final shader = mesh['shader'] as MeshShader?;
        final planes = mesh['clippingPlanes'] as List;
        body.json({
          'material_shader': shader == null
              ? null
              : key(
                  materialToken(
                    shader,
                    () => shader.encodeForDevice(materialDevice!),
                  ),
                ),
          'clipping_planes': [
            for (var i = 0; i < planes.length; i += 4) planes.sublist(i, i + 4),
          ],
          'coverage': mesh['coverage'],
          'outlined': mesh['outlined'],
          'normal_scale_y': (mesh['pbr'] as Map?)?['normal_scale_y'],
          'specular_aa': (mesh['pbr'] as Map?)?['specular_aa'],
          'shadow_world_model': (mesh['shadow_world_model'] as List).isEmpty
              ? null
              : mesh['shadow_world_model'],
        });
      }
    }
    if (opcode >= 36) {
      List<int> key(Uint8List bytes) {
        final d = ByteData.sublistView(bytes);
        return [for (var i = 0; i < 4; i++) d.getUint64(i * 8, Endian.little)];
      }

      final bloom = settings.bloom, outline = scene._outline;
      body.json({
        'local_environments': [
          for (final local in locals.entries)
            {
              'meshes': [
                for (final entry in scene.localEnvironments.entries)
                  if (identical(entry.value, local.key)) entry.key,
              ],
              'keys': local.value.map(key).toList(),
              'intensity': local.key.intensity,
              'rotation': [
                local.key.rotation.x,
                local.key.rotation.y,
                local.key.rotation.z,
                local.key.rotation.w,
              ],
            },
        ],
        'screen_lighting': settings.screenSpaceLighting?.toPacket(),
        'enabled': screenEnabled,
        'sample_count': screenEnabled
            ? submission.colorPipeline?.sampleCount ?? settings.sampleCount
            : 1,
        'depth_strategy': submission.camera.depthStrategy.index,
        'opaque_capture_scale': settings.opaqueCaptureScale,
        'spatial_antialiasing': settings.spatialAntialiasing.index,
        'effects': effects.map(key).toList(),
        'tone_mapping':
            (submission.colorPipeline?.toneMapping ?? settings.toneMapping)
                .index,
        'exposure': submission.colorPipeline?.exposure ?? settings.exposure,
        'background_alpha': scene.backgroundOpacity,
        'camera_origin': submission.camera.origin,
        'shadow_world_lights': [
          for (final light in scene._shadowLights)
            [light.index, ...light.worldPosition],
        ],
        'shadow_world_areas': [
          for (final light in scene._shadowLights)
            if (light.areaAxes.isNotEmpty) [light.index, ...light.areaAxes],
        ],
        'history_epoch': settings.historyEpoch,
        if (bloom != null)
          'bloom': {
            'intensity': bloom.intensity,
            'threshold': bloom.threshold,
            'soft_knee': bloom.softKnee,
            'scatter': bloom.scatter,
            'levels': bloom.levels,
          },
        if (outline != null)
          'outline': {
            'color': [...outline.color.toList(), outline.opacity],
            'width': outline.width,
          },
        if (environment != null)
          'environment': {
            'keys': environmentKeys!.map(key).toList(),
            'intensity': environment.intensity,
            'rotation': environment.rotation,
          },
      });
    }
    final payload = body.finish();
    if (payload.length > 66 * 1024 * 1024 - 24) {
      throw ArgumentError('Scene packet exceeds the byte budget.');
    }
    final revision = ++_next;
    final header = _SceneWriter()
      ..u32(2)
      ..u32(opcode | (resourceOnly ? 0x10000 : 0))
      ..u64(revision)
      ..u64(payload.length);
    header.add(payload);
    final packet =
        EncodedScenePacket._(
            header.finish().asUnmodifiableView(),
            uploadBytes,
            updates.length,
            this,
            revision,
            scene,
            uploaded,
            {
              ...uploadedTextures,
              ...?_staged?._textures.keys.where(scene._textures.containsKey),
            },
            uploadedInstances,
            uploadedPoses,
          )
          ..submission = submission
          .._tokens = tokens;
    return !resourceOnly && _staged != null
        ? _wrapAdmission(packet, null, const [], 0, 0)
        : packet;
  }

  /// Discards upload assumptions after a rejected native preparation. The
  /// published scene remains valid and the next candidate retries its resources.
  void reject(EncodedScenePacket packet) {
    if (identical(packet._owner, this) &&
        packet._revision == _next &&
        packet._revision > _accepted) {
      _staged = null;
      uploadBacklogBytes = stagedBytes = 0;
    }
  }

  void accept(EncodedScenePacket packet) {
    if (!identical(packet._owner, this) ||
        packet._revision != _next ||
        packet._revision <= _accepted) {
      throw StateError('Only the latest pending packet can advance this view.');
    }
    if (packet.ready) {
      _tokens = packet._tokens;
      _bindingHeader = packet.bindingHeader;
    }
    presentedSubmission = packet.submission;
    admission = packet.admission;
    if (packet._display case final display?) {
      _previous = display._scene;
      _uploaded = display._uploaded;
      _uploadedTextures = display._uploadedTextures;
      _uploadedInstances = display._uploadedInstances;
      _uploadedPoses = display._uploadedPoses;
      _accepted = packet._revision;
      _staged = packet._stage;
      uploadBacklogBytes = packet.uploadBacklogBytes;
      stagedBytes = packet.stagedBytes;
      if (packet.ready) {
        _published = packet.submission;
        _publishedRevision = packet._revision;
      }
      return;
    }
    _published = packet.submission;
    _publishedRevision = packet._revision;
    _staged = null;
    uploadBacklogBytes = stagedBytes = 0;
    _previous = packet._scene;
    _uploaded = packet._uploaded;
    _uploadedTextures = packet._uploadedTextures;
    _uploadedInstances = packet._uploadedInstances;
    _uploadedPoses = packet._uploadedPoses;
    _accepted = packet._revision;
  }
}

final class _GeometryPatch {
  final int baseId;
  final GeometrySnapshot geometry;
  final List<GeometryRange> ranges;
  _GeometryPatch(this.baseId, this.geometry, this.ranges);
  int get uploadedBytes {
    var bytes = 0;
    for (var buffer = 0; buffer < 4; buffer++) {
      final selected = [
        for (final range in ranges)
          if ((range.semantic.index < 2
                  ? 0
                  : range.semantic.index < 4
                  ? 1
                  : range.semantic.index - 2) ==
              buffer)
            range,
      ]..sort((a, b) => a.firstVertex.compareTo(b.firstVertex));
      var end = 0;
      for (final range in selected) {
        final first = range.firstVertex < end ? end : range.firstVertex;
        final next = range.firstVertex + range.vertexCount;
        if (next > first) bytes += (next - first) * (buffer == 0 ? 24 : 16);
        if (next > end) end = next;
      }
    }
    return bytes;
  }
}

const _standardMapFields = [
  'normal_map',
  'metallic_roughness_map',
  'occlusion_map',
  'emissive_map',
];

bool _sameMesh(Map<String, Object> a, Map<String, Object> b) {
  final leftPbr = a['pbr'] as Map?, rightPbr = b['pbr'] as Map?;
  if (leftPbr == null || rightPbr == null) {
    if (leftPbr != rightPbr) return false;
  } else {
    if (leftPbr['metallic'] != rightPbr['metallic'] ||
        leftPbr['roughness'] != rightPbr['roughness'] ||
        leftPbr['normal_scale'] != rightPbr['normal_scale'] ||
        leftPbr['normal_scale_y'] != rightPbr['normal_scale_y'] ||
        leftPbr['occlusion_strength'] != rightPbr['occlusion_strength']) {
      return false;
    }
    for (final field in [
      ..._standardMapFields,
      ..._physicalMapFields,
      'physical',
      'transmission',
      'optical',
      'specular_aa',
    ]) {
      final left = (leftPbr[field] as List?) ?? const [],
          right = (rightPbr[field] as List?) ?? const [];
      if (left.length != right.length) return false;
      for (var i = 0; i < left.length; i++) {
        if (left[i] != right[i]) return false;
      }
    }
    for (var i = 0; i < 3; i++) {
      if ((leftPbr['emissive'] as List)[i] !=
          (rightPbr['emissive'] as List)[i]) {
        return false;
      }
    }
  }
  for (final field in [
    'geometry',
    'shader',
    'outlined',
    'instances',
    'pose',
    'instance_count',
    'unlit',
    'vertex_colors',
    'side',
    'alpha_mode',
    'opacity',
    'alpha_cutoff',
    'depth_test',
    'depth_write',
    'render_order',
    'primitive_kind',
    'primitive_size',
    'size_units',
    'point_shape',
    'cast_shadow',
    'receive_shadow',
    'color_visible',
  ]) {
    if (a[field] != b[field]) return false;
  }
  for (final field in [
    'model',
    'shadow_world_model',
    'color',
    'colorMap',
    'clippingPlanes',
    'coverage',
  ]) {
    final left = a[field] as List, right = b[field] as List;
    if (left.length != right.length) return false;
    for (var i = 0; i < left.length; i++) {
      if (left[i] != right[i]) return false;
    }
  }
  return true;
}

final class _SceneWriter {
  final _bytes = BytesBuilder(copy: false);
  void json(Map<String, Object?> value) {
    final bytes = Uint8List.fromList(utf8.encode(jsonEncode(value)));
    u32(bytes.length);
    add(bytes);
  }

  void add(Uint8List bytes) => _bytes.add(bytes);
  void u32(int value) {
    if (value < 0 || value > 0xffffffff) {
      throw ArgumentError('Scene identifier exceeds uint32.');
    }
    add((ByteData(4)..setUint32(0, value, Endian.little)).buffer.asUint8List());
  }

  void i32(int value) => add(
    (ByteData(4)..setInt32(0, value, Endian.little)).buffer.asUint8List(),
  );

  void u64(int value) => add(
    (ByteData(8)..setUint64(0, value, Endian.little)).buffer.asUint8List(),
  );
  void indices(List<int> values, IndexFormat format) {
    if (format == IndexFormat.uint32) {
      integers(values);
      return;
    }
    final buffer = ByteData(values.length * 2);
    for (var i = 0; i < values.length; i++) {
      buffer.setUint16(i * 2, values[i], Endian.little);
    }
    add(buffer.buffer.asUint8List());
  }

  void integers(List<int> values) {
    final buffer = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      buffer.setUint32(i * 4, values[i], Endian.little);
    }
    add(buffer.buffer.asUint8List());
  }

  void f64(double value) {
    final bytes = ByteData(8)..setFloat64(0, value, Endian.little);
    add(bytes.buffer.asUint8List());
  }

  void floats(List<double> values) {
    final buffer = ByteData(values.length * 4);
    for (var i = 0; i < values.length; i++) {
      buffer.setFloat32(i * 4, values[i], Endian.little);
      if (!buffer.getFloat32(i * 4, Endian.little).isFinite) {
        throw ArgumentError('Scene values must fit finite float32 storage.');
      }
    }
    add(buffer.buffer.asUint8List());
  }

  Uint8List finish() => _bytes.takeBytes();
}

const _physicalMapFields = [
  'clearcoat_map',
  'clearcoat_roughness_map',
  'clearcoat_normal_map',
  'sheen_color_map',
  'sheen_roughness_map',
  'specular_intensity_map',
  'specular_color_map',
  'anisotropy_map',
  'transmission_map',
  'thickness_map',
  'iridescence_map',
  'iridescence_thickness_map',
];
