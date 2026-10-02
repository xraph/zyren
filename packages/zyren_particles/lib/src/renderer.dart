import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'settings.dart';
import 'simulation.dart';
import 'shaders.dart';

final class ParticleMeasurements {
  final int simulationTicks, dispatches, uploadedBytes;
  final int? liveParticles;
  final Duration hostTime;
  const ParticleMeasurements({
    required this.simulationTicks,
    required this.dispatches,
    required this.uploadedBytes,
    required this.hostTime,
    this.liveParticles,
  });
}

/// Scoped native emitter. State never leaves the GPU unless you call inspect.
/// You can use it without Flutter, including in headless native qualification.
final class ParticleRenderer {
  final ParticleSettings settings;
  final GpuScope _scope;
  final ParticleReference? reference;
  final GpuResource<Buffer> _state, _parameters, _history, _order;
  final CompiledGraph? _simulation;
  final List<CompiledGraph> _sorting;
  final Mesh mesh;
  final Mesh? ribbon;
  final int _sortCapacity;
  bool _closed = false;
  Future<void>? _pending, _closing;
  int _tick = 0;
  Mat4 _emitter = Mat4.identity();
  Vec3? _origin;
  ParticleMeasurements measurements = const ParticleMeasurements(
    simulationTicks: 0,
    dispatches: 0,
    uploadedBytes: 0,
    hostTime: Duration.zero,
  );
  ParticleRenderer._(
    this.settings,
    this._scope,
    this.reference,
    this._state,
    this._parameters,
    this._history,
    this._order,
    this._simulation,
    this._sorting,
    this.mesh,
    this.ribbon,
    this._sortCapacity,
  );
  bool get isClosed => _closed || _scope.isClosed;

  static Future<ParticleRenderer> create(
    GpuScope owner,
    ParticleSettings settings,
  ) async {
    if (settings.softIntersections) {
      throw UnsupportedError(
        'Soft particles require a sampled scene depth binding. '
        'The current native mesh material interface does not expose one.',
      );
    }
    final scope = owner.createChild(label: 'particle emitter');
    final sortScope = scope.createChild(label: 'particle sorting');
    try {
      var sortCapacity = 1;
      while (sortCapacity < settings.capacity) {
        sortCapacity *= 2;
      }
      final state = await scope.resources.createBuffer(
        BufferDescriptor(
          label: 'particle state',
          size: settings.capacity * particleStateBytes,
          usage: {
            BufferUsage.storage,
            BufferUsage.copySource,
            BufferUsage.copyDestination,
          },
        ),
      );
      final parameters = await scope.resources.createBuffer(
        BufferDescriptor(
          label: 'particle parameters',
          size: 224,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final shapeData = settings.shape.gpuData;
      final surface = await scope.resources.createBuffer(
        BufferDescriptor(
          label: 'emission shape',
          size: shapeData.lengthInBytes,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      await scope.resources.writeBuffer(surface, shapeData);
      final history = await scope.resources.createBuffer(
        BufferDescriptor(
          label: 'particle ribbon history',
          size: settings.capacity * (settings.trails?.samples ?? 2) * 16,
          usage: {
            BufferUsage.storage,
            BufferUsage.copyDestination,
            BufferUsage.copySource,
          },
        ),
      );
      final order = await scope.resources.createBuffer(
        BufferDescriptor(
          label: 'particle depth order',
          size: sortCapacity * 8,
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
        ),
      );
      await scope.resources.writeBuffer(
        state,
        Uint8List(state.descriptor.byteLength),
      );
      await scope.resources.writeBuffer(
        history,
        Uint8List(history.descriptor.byteLength),
      );
      final initialOrder = Uint32List(sortCapacity * 2);
      for (var i = 0; i < sortCapacity; i++) {
        initialOrder[i * 2] = i;
      }
      await scope.resources.writeBuffer(order, initialOrder);
      List<ShaderBinding> bindings({required bool compute}) => [
        compute
            ? BufferBinding.storageReadWrite(0, state)
            : BufferBinding.storageRead(0, state, group: 1),
        BufferBinding.uniform(1, parameters, group: compute ? 0 : 1),
        BufferBinding.storageRead(2, surface, group: compute ? 0 : 1),
        compute
            ? BufferBinding.storageReadWrite(3, history)
            : BufferBinding.storageRead(3, history, group: 1),
        compute
            ? BufferBinding.storageReadWrite(4, order)
            : BufferBinding.storageRead(4, order, group: 1),
      ];
      CompiledGraph? simulation;
      final sorting = <CompiledGraph>[];
      if (settings.path == ParticlePath.gpu) {
        final program = await scope.shaders.compile(
          ShaderSource.wgsl(
            computeParticleWgsl(settings, sortCapacity),
            label: 'particle compute',
          ),
        );
        simulation = await scope.graphs.compile(
          GraphDescription(
            inputs: [state, parameters, surface, history, order],
            passes: [
              ComputePassDescriptor(
                name: 'simulate',
                program: program,
                entryPoint: 'simulate',
                workgroups: Workgroups((settings.capacity + 63) ~/ 64),
                bindings: ShaderBindings(bindings(compute: true)),
                reads: [state, parameters, surface, history, order],
                writes: [state, history, order],
              ),
            ],
          ),
        );
        final sortedBindings = <ShaderBinding>[
          BufferBinding.storageReadWrite(0, state),
          BufferBinding.uniform(1, parameters),
          BufferBinding.storageReadWrite(4, order),
        ];
        final passes = <ComputePassDescriptor>[
          ComputePassDescriptor(
            name: 'initialize order',
            program: program,
            entryPoint: 'initializeOrder',
            workgroups: Workgroups((sortCapacity + 63) ~/ 64),
            bindings: ShaderBindings(sortedBindings),
            reads: [state, parameters, order],
            writes: [state, order],
          ),
        ];
        if (settings.blend == ParticleBlend.alpha) {
          final stages = <(int, int)>[
            for (var k = 2; k <= sortCapacity; k *= 2)
              for (var j = k ~/ 2; j > 0; j ~/= 2) (k, j),
          ];
          for (var start = 0; start < stages.length; start += 60) {
            final chunk = stages.sublist(
              start,
              math.min(start + 60, stages.length),
            );
            final sortProgram = await sortScope.shaders.compile(
              ShaderSource.wgsl(
                sortParticleWgsl(sortCapacity, chunk),
                label: 'particle sorting',
              ),
            );
            for (final (k, j) in chunk) {
              passes.add(
                ComputePassDescriptor(
                  name: 'sort_${k}_$j',
                  program: sortProgram,
                  entryPoint: 'sort_${k}_$j',
                  workgroups: Workgroups((sortCapacity + 63) ~/ 64),
                  bindings: ShaderBindings([
                    BufferBinding.storageReadWrite(4, order),
                  ]),
                  reads: [order],
                  writes: [order],
                  after: {passes.last.name},
                ),
              );
            }
          }
        }
        // A native graph supports 128 passes. Large bitonic sorts span bounded
        // graphs on the same ordered queue, with explicit imports between them.
        for (var start = 0; start < passes.length; start += 120) {
          final chunk = passes.sublist(
            start,
            math.min(start + 120, passes.length),
          );
          final first = chunk.first;
          chunk[0] = ComputePassDescriptor(
            name: first.name,
            program: first.program,
            entryPoint: first.entryPoint,
            workgroups: first.workgroups,
            bindings: first.bindings,
            reads: first.reads,
            writes: first.writes,
          );
          final compiler = sortScope
              .createChild(label: 'particle sort ${start ~/ 120}')
              .graphs;
          sorting.add(
            await compiler.compile(
              GraphDescription(
                inputs: [state, parameters, order],
                passes: chunk,
              ),
            ),
          );
        }
      }
      final renderBindings = bindings(compute: false);
      if (settings.texture case final texture?) {
        final image = await scope.resources.createTexture(
          TextureDescriptor(
            label: 'particle sprite atlas',
            width: texture.width,
            height: texture.height,
            format: TextureFormat.rgba8UnormSrgb,
            usage: {TextureUsage.sampled, TextureUsage.copyDestination},
          ),
        );
        await scope.resources.writeTexture(image, texture.rgba);
        renderBindings.addAll([
          TextureBinding.sampled(5, image, group: 1),
          SamplerBinding(6, group: 1),
        ]);
      }
      Future<Mesh> createMesh(bool trail) async {
        final program = await scope.shaders.compile(
          ShaderSource.wgsl(
            renderParticleWgsl(settings, trail: trail),
            label: trail ? 'particle ribbons' : 'particle rendering',
          ),
        );
        final shader = await scope.materials.compile(
          MeshShaderDescriptor(
            program: program,
            bindings: ShaderBindings(renderBindings),
            supportsClipping: true,
            requiresUv:
                !trail &&
                settings.appearance == ParticleAppearance.mesh &&
                settings.texture != null,
            blend: settings.blend == ParticleBlend.additive
                ? RenderBlend.additive
                : null,
          ),
        );
        return Mesh(
          _particleGeometry(settings, trail: trail),
          ShaderMaterial(
            shader,
            side: MaterialSide.doubleSided,
            alphaMode: settings.blend == ParticleBlend.opaque
                ? MaterialAlphaMode.opaque
                : MaterialAlphaMode.blend,
            depthTest: settings.depthTest,
            depthWrite: settings.depthWrite
                ? DepthWrite.enabled
                : DepthWrite.disabled,
          ),
          name: trail ? 'particle ribbons' : 'particles',
        )..outlineEnabled = false;
      }

      final mesh = await createMesh(false);
      final ribbon = settings.trails == null ? null : await createMesh(true);
      return ParticleRenderer._(
        settings,
        scope,
        settings.path == ParticlePath.reference
            ? ParticleReference(settings)
            : null,
        state,
        parameters,
        history,
        order,
        simulation,
        sorting,
        mesh,
        ribbon,
        sortCapacity,
      );
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<T> _exclusive<T>(Future<T> Function() action) {
    if (isClosed) {
      return Future.error(StateError('Particle renderer has closed.'));
    }
    if (_pending != null) {
      return Future.error(
        StateError('Await the preceding particle operation.'),
      );
    }
    final future = Future.sync(action);
    final settled = future.then<void>(
      (_) {},
      onError: (Object _, StackTrace _) {},
    );
    _pending = settled;
    return future.whenComplete(() {
      if (identical(_pending, settled)) _pending = null;
    });
  }

  Future<void> update(
    List<ParticleTick> ticks, {
    required Mat4 emitter,
    required Mat4 camera,
  }) => _exclusive(() => _update(ticks, emitter: emitter, camera: camera));
  Future<void> reset() => _exclusive(_reset);
  Future<List<ParticleSnapshot>> inspect() => _exclusive(_inspect);
  Future<ParticleBounds?> inspectBounds() => _exclusive(_inspectBounds);

  /// Camera axes and origin refresh even while the emitter is paused.
  Future<void> _update(
    List<ParticleTick> ticks, {
    required Mat4 emitter,
    required Mat4 camera,
  }) async {
    _check();
    if (ticks.length > 4096) {
      throw ArgumentError('A batch supports at most 4096 ticks.');
    }
    for (var i = 0; i < ticks.length; i++) {
      final tick = ticks[i];
      if (tick.tick != _tick + i + 1 ||
          tick.tick > 0xffffff ||
          tick.step != settings.fixedStep ||
          tick.firstSerial < 0 ||
          tick.count < 0 ||
          tick.firstSerial + tick.count > 0xffffff) {
        throw ArgumentError(
          'Ticks must be consecutive, use the configured step and fit the exact GPU counter range.',
        );
      }
    }
    _validateMatrix(emitter);
    _validateMatrix(camera);
    _emitter = emitter;
    final origin = _origin ??= Vec3(
      emitter.storage[12],
      emitter.storage[13],
      emitter.storage[14],
    );
    final relativeEmitter = _relativeMatrix(emitter, origin);
    final relativeCamera = _relativeMatrix(camera, origin);
    final watch = Stopwatch()..start();
    var dispatches = 0, uploaded = 0;
    for (final tick in ticks) {
      if (tick.tick != _tick + 1) {
        throw StateError('Ticks must be consecutive. Reset before restarting.');
      }
      await _writeParameters(tick, relativeEmitter, relativeCamera);
      uploaded += 224;
      if (reference case final reference?) {
        reference.step(
          tick,
          emitterTransform: relativeEmitter,
          origin: settings.space == ParticleSpace.world ? origin : Vec3.zero,
        );
      } else {
        dispatches += (await _simulation!.execute()).dispatches;
      }
      _tick = tick.tick;
    }
    // A zero-delta parameter refresh changes only rendering, never simulation.
    await _writeParameters(
      ParticleTick(_tick, 0, 0, settings.fixedStep),
      relativeEmitter,
      relativeCamera,
    );
    uploaded += 224;
    if (reference case final reference?) {
      if (ticks.isNotEmpty) {
        await _scope.resources.writeBuffer(_state, reference.state);
        await _scope.resources.writeBuffer(_history, reference.history);
        uploaded +=
            reference.state.lengthInBytes + reference.history.lengthInBytes;
      }
      final indices = List<int>.generate(settings.capacity, (i) => i);
      if (settings.blend == ParticleBlend.alpha) {
        final cameraPosition = transformParticlePoint(camera, Vec3.zero);
        final forward = -transformParticlePoint(
          camera,
          const Vec3(0, 0, 1),
          direction: true,
        ).normalized();
        double depth(int i) {
          if (reference.state[i * particleStateFloats + 9] == 0) {
            return double.negativeInfinity;
          }
          var p = Vec3.array(reference.state, i * particleStateFloats);
          if (settings.space == ParticleSpace.local) {
            p = transformParticlePoint(emitter, p);
          } else {
            p = p + origin;
          }
          return (p - cameraPosition).dot(forward);
        }

        indices.sort((a, b) {
          final comparison = depth(b).compareTo(depth(a));
          return comparison == 0 ? a.compareTo(b) : comparison;
        });
      }
      final order = Uint32List(_sortCapacity * 2);
      for (var i = 0; i < _sortCapacity; i++) {
        order[i * 2] = i < indices.length ? indices[i] : i;
      }
      await _scope.resources.writeBuffer(_order, order);
      uploaded += order.lengthInBytes;
    } else {
      for (final graph in _sorting) {
        dispatches += (await graph.execute()).dispatches;
      }
    }
    watch.stop();
    measurements = ParticleMeasurements(
      simulationTicks: ticks.length,
      dispatches: dispatches,
      uploadedBytes: uploaded,
      hostTime: watch.elapsed,
      liveParticles: reference?.liveCount,
    );
  }

  Future<void> _writeParameters(
    ParticleTick tick,
    Mat4 emitter,
    Mat4 camera,
  ) async {
    final bytes = ByteData(224);
    final commands = [tick.tick, tick.firstSerial, tick.count, settings.seed];
    for (var i = 0; i < 4; i++) {
      bytes.setUint32(i * 4, commands[i], Endian.little);
    }
    final simulationOrigin = settings.space == ParticleSpace.world
        ? (_origin ?? Vec3.zero)
        : Vec3.zero;
    final floats = <double>[
      tick.step,
      tick.time,
      0,
      0,
      ...emitter.storage,
      camera.storage[12],
      camera.storage[13],
      camera.storage[14],
      0,
      ...transformParticlePoint(
        camera,
        const Vec3(1, 0, 0),
        direction: true,
      ).normalized().storage,
      0,
      ...transformParticlePoint(
        camera,
        const Vec3(0, 1, 0),
        direction: true,
      ).normalized().storage,
      0,
      ...(-transformParticlePoint(
        camera,
        const Vec3(0, 0, 1),
        direction: true,
      ).normalized()).storage,
      0,
      ...simulationOrigin.storage,
      0,
      for (var i = 0; i < 12; i++)
        i < settings.collisions.length
            ? settings.collisions[i].offset +
                  simulationOrigin.dot(settings.collisions[i].normal)
            : 0,
    ];
    for (var i = 0; i < floats.length; i++) {
      bytes.setFloat32(16 + i * 4, floats[i], Endian.little);
    }
    await _scope.resources.writeBuffer(_parameters, bytes);
  }

  Future<void> _reset() async {
    _check();
    await _scope.resources.writeBuffer(
      _state,
      Uint8List(_state.descriptor.byteLength),
    );
    await _scope.resources.writeBuffer(
      _history,
      Uint8List(_history.descriptor.byteLength),
    );
    _tick = 0;
    _origin = null;
    reference?.reset();
  }

  /// Explicit diagnostic readback. Never called from the render loop.
  Future<List<ParticleSnapshot>> _inspect() async {
    _check();
    final bytes = await _scope.resources.readBuffer(_state);
    final data = ByteData.sublistView(bytes);
    final output = <ParticleSnapshot>[];
    for (var slot = 0; slot < settings.capacity; slot++) {
      final o = slot * particleStateBytes;
      if (data.getFloat32(o + 36, Endian.little) > .5) {
        output.add(
          ParticleSnapshot(
            slot: slot,
            serial: data.getFloat32(o + 32, Endian.little).toInt(),
            position:
                Vec3(
                  data.getFloat32(o, Endian.little),
                  data.getFloat32(o + 4, Endian.little),
                  data.getFloat32(o + 8, Endian.little),
                ) +
                (settings.space == ParticleSpace.world
                    ? (_origin ?? Vec3.zero)
                    : Vec3.zero),
            velocity: Vec3(
              data.getFloat32(o + 16, Endian.little),
              data.getFloat32(o + 20, Endian.little),
              data.getFloat32(o + 24, Endian.little),
            ),
            age: data.getFloat32(o + 12, Endian.little),
            birthScale: Vec3(
              _columnLength(data, o + 48),
              _columnLength(data, o + 64),
              _columnLength(data, o + 80),
            ),
          ),
        );
      }
    }
    return output;
  }

  /// Conservative world bounds measured through explicit diagnostic readback.
  /// Native clipping uses shader positions, never the carrier quad's CPU bounds.
  Future<ParticleBounds?> _inspectBounds() async {
    final particles = await _inspect();
    if (particles.isEmpty) return null;
    final matrix = _emitter;
    final localScale = math.sqrt(
      transformParticlePoint(
            matrix,
            const Vec3(1, 0, 0),
            direction: true,
          ).length2 +
          transformParticlePoint(
            matrix,
            const Vec3(0, 1, 0),
            direction: true,
          ).length2 +
          transformParticlePoint(
            matrix,
            const Vec3(0, 0, 1),
            direction: true,
          ).length2,
    );
    var meshRadius = 1.0;
    if (settings.mesh case final geometry?) {
      final points = BufferGeometry.fromData(geometry).positions;
      for (var i = 0; i < points.length; i += 3) {
        meshRadius = math.max(meshRadius, Vec3.array(points, i).length);
      }
    }
    var low = const Vec3(double.infinity, double.infinity, double.infinity);
    var high = const Vec3(
      double.negativeInfinity,
      double.negativeInfinity,
      double.negativeInfinity,
    );
    void include(Vec3 position, double radius) {
      final p = settings.space == ParticleSpace.local
          ? transformParticlePoint(matrix, position)
          : position;
      low = Vec3(
        math.min(low.x, p.x - radius),
        math.min(low.y, p.y - radius),
        math.min(low.z, p.z - radius),
      );
      high = Vec3(
        math.max(high.x, p.x + radius),
        math.max(high.y, p.y + radius),
        math.max(high.z, p.z + radius),
      );
    }

    ByteData? history;
    if (settings.trails != null) {
      history = ByteData.sublistView(
        await _scope.resources.readBuffer(_history),
      );
    }
    for (final p in particles) {
      final scale = settings.space == ParticleSpace.local
          ? localScale
          : p.birthScale.length;
      final size = settings.size.sample(
        (p.age / settings.lifetime).clamp(0, 1),
      );
      final radius =
          size *
          scale *
          (settings.appearance == ParticleAppearance.mesh
              ? meshRadius
              : math.max(1, 1 + p.velocity.length * settings.stretch * scale));
      include(p.position, radius);
      if (history != null) {
        for (var sample = 0; sample < settings.trails!.samples; sample++) {
          final offset = (p.slot * settings.trails!.samples + sample) * 16;
          if (history.getFloat32(offset + 12, Endian.little) ==
              (_tick - (p.age / settings.fixedStep).round() + 1).toDouble()) {
            include(
              Vec3(
                    history.getFloat32(offset, Endian.little),
                    history.getFloat32(offset + 4, Endian.little),
                    history.getFloat32(offset + 8, Endian.little),
                  ) +
                  (settings.space == ParticleSpace.world
                      ? (_origin ?? Vec3.zero)
                      : Vec3.zero),
              size * scale * settings.trails!.width,
            );
          }
        }
      }
    }
    return ParticleBounds(low, high);
  }

  Future<void> close() {
    _closed = true;
    mesh.parent?.remove(mesh);
    ribbon?.parent?.remove(ribbon!);
    return _closing ??= _retire();
  }

  Future<void> _retire() async {
    await _pending;
    await _scope.close();
  }

  void _check() {
    if (isClosed) throw StateError('Particle renderer has closed.');
  }
}

BufferGeometry _particleGeometry(ParticleSettings s, {required bool trail}) {
  final base = s.appearance == ParticleAppearance.mesh && !trail
      ? BufferGeometry.fromData(s.mesh!)
      : null;
  final vertices =
      base?.vertexCount ?? (trail ? (s.trails!.samples - 1) * 4 : 4);
  final uv = base?.uv0 == null ? null : Float32List(s.capacity * vertices * 2);
  final positions = Float32List(s.capacity * vertices * 3),
      normals = Float32List(positions.length);
  final baseIndices =
      base?.indices ??
      [
        for (
          var segment = 0;
          segment < (trail ? s.trails!.samples - 1 : 1);
          segment++
        ) ...[
          segment * 4,
          segment * 4 + 1,
          segment * 4 + 2,
          segment * 4 + 2,
          segment * 4 + 1,
          segment * 4 + 3,
        ],
      ];
  final indices = Uint32List(s.capacity * baseIndices.length);
  for (var slot = 0; slot < s.capacity; slot++) {
    for (var v = 0; v < vertices; v++) {
      final o = (slot * vertices + v) * 3;
      positions[o] = base?.positions[v * 3] ?? ((v % 2) - .5);
      positions[o + 1] = base?.positions[v * 3 + 1] ?? ((v % 4 ~/ 2) - .5);
      positions[o + 2] = base?.positions[v * 3 + 2] ?? 0;
      normals[o + 2] = 1;
      if (uv != null) {
        uv[(slot * vertices + v) * 2] = base!.uv0![v * 2];
        uv[(slot * vertices + v) * 2 + 1] = base.uv0![v * 2 + 1];
      }
    }
    for (var i = 0; i < baseIndices.length; i++) {
      indices[slot * baseIndices.length + i] = slot * vertices + baseIndices[i];
    }
  }
  return BufferGeometry.fromAttributes(
    attributes: {
      if (uv != null)
        VertexSemantic.uv0: VertexAttribute(uv, format: VertexFormat.float32x2),
      VertexSemantic.position: VertexAttribute(
        positions,
        format: VertexFormat.float32x3,
      ),
      VertexSemantic.normal: VertexAttribute(
        normals,
        format: VertexFormat.float32x3,
      ),
    },
    indices: indices,
  );
}

final class ParticleBounds {
  final Vec3 min, max;
  const ParticleBounds(this.min, this.max);
  bool contains(Vec3 point) =>
      point.x >= min.x &&
      point.x <= max.x &&
      point.y >= min.y &&
      point.y <= max.y &&
      point.z >= min.z &&
      point.z <= max.z;
}

double _columnLength(ByteData data, int offset) {
  final x = data.getFloat32(offset, Endian.little),
      y = data.getFloat32(offset + 4, Endian.little),
      z = data.getFloat32(offset + 8, Endian.little);
  return math.sqrt(x * x + y * y + z * z);
}

/// Camera pose for billboards and sorting. Zyren cameras use target/up,
/// independently of Object3D.quaternion, just like the native scene projection.
Mat4 particleCameraTransform(Camera camera) {
  camera.viewProjection(1);
  final back = (camera.position - camera.target).normalized();
  final right = camera.up.cross(back).normalized();
  final up = back.cross(right);
  return Mat4([
    ...right.storage,
    0,
    ...up.storage,
    0,
    ...back.storage,
    0,
    ...camera.position.storage,
    1,
  ]);
}

Mat4 _relativeMatrix(Mat4 matrix, Vec3 origin) {
  final values = matrix.storage.toList();
  values[12] -= origin.x;
  values[13] -= origin.y;
  values[14] -= origin.z;
  return Mat4(values);
}

void _validateMatrix(Mat4 matrix) {
  final values = matrix.storage;
  if (values[3] != 0 ||
      values[7] != 0 ||
      values[11] != 0 ||
      values[15] != 1 ||
      values.any((value) => value.abs() > 1e15) ||
      matrix.toVectorMath().determinant().abs() < 1e-20) {
    throw ArgumentError(
      'Particle transforms require an invertible affine matrix within 1e15 scene units.',
    );
  }
}
