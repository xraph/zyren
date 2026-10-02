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
  final CompiledGraph? _simulation, _sorting;
  final Mesh mesh;
  final Mesh? ribbon;
  final int _sortCapacity;
  bool _closed = false;
  int _tick = 0;
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
          size: settings.capacity * 48,
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
          size: 160,
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
          usage: {BufferUsage.storage, BufferUsage.copyDestination},
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
      CompiledGraph? simulation, sorting;
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
          for (var k = 2; k <= sortCapacity; k *= 2) {
            for (var j = k ~/ 2; j > 0; j ~/= 2) {
              passes.add(
                ComputePassDescriptor(
                  name: 'sort_${k}_$j',
                  program: program,
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
        sorting = await sortScope.graphs.compile(
          GraphDescription(inputs: [state, parameters, order], passes: passes),
        );
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

  /// Camera axes and origin refresh even while the emitter is paused.
  Future<void> update(
    List<ParticleTick> ticks, {
    required Mat4 emitter,
    required Mat4 camera,
  }) async {
    _check();
    final watch = Stopwatch()..start();
    var dispatches = 0, uploaded = 0;
    for (final tick in ticks) {
      if (tick.tick != _tick + 1) {
        throw StateError('Ticks must be consecutive. Reset before restarting.');
      }
      await _writeParameters(tick, emitter, camera);
      uploaded += 160;
      if (reference case final reference?) {
        reference.step(tick, emitterTransform: emitter);
      } else {
        dispatches += (await _simulation!.execute()).dispatches;
      }
      _tick = tick.tick;
    }
    // A zero-delta parameter refresh changes only rendering, never simulation.
    await _writeParameters(
      ParticleTick(_tick, 0, 0, settings.fixedStep),
      emitter,
      camera,
    );
    uploaded += 160;
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
          if (reference.state[i * 12 + 9] == 0) return double.negativeInfinity;
          var p = Vec3.array(reference.state, i * 12);
          if (settings.space == ParticleSpace.local) {
            p = transformParticlePoint(emitter, p);
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
      dispatches += (await _sorting!.execute()).dispatches;
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
    final bytes = ByteData(160);
    final commands = [tick.tick, tick.firstSerial, tick.count, settings.seed];
    for (var i = 0; i < 4; i++) {
      bytes.setUint32(i * 4, commands[i], Endian.little);
    }
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
    ];
    for (var i = 0; i < floats.length; i++) {
      bytes.setFloat32(16 + i * 4, floats[i], Endian.little);
    }
    await _scope.resources.writeBuffer(_parameters, bytes);
  }

  Future<void> reset() async {
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
    reference?.reset();
  }

  /// Explicit diagnostic readback. Never called from the render loop.
  Future<List<ParticleSnapshot>> inspect() async {
    _check();
    final bytes = await _scope.resources.readBuffer(_state);
    final data = ByteData.sublistView(bytes);
    final output = <ParticleSnapshot>[];
    for (var slot = 0; slot < settings.capacity; slot++) {
      final o = slot * 48;
      if (data.getFloat32(o + 36, Endian.little) > .5) {
        output.add(
          ParticleSnapshot(
            slot: slot,
            serial: data.getFloat32(o + 32, Endian.little).toInt(),
            position: Vec3(
              data.getFloat32(o, Endian.little),
              data.getFloat32(o + 4, Endian.little),
              data.getFloat32(o + 8, Endian.little),
            ),
            velocity: Vec3(
              data.getFloat32(o + 16, Endian.little),
              data.getFloat32(o + 20, Endian.little),
              data.getFloat32(o + 24, Endian.little),
            ),
            age: data.getFloat32(o + 12, Endian.little),
          ),
        );
      }
    }
    return output;
  }

  Future<void> close() {
    _closed = true;
    mesh.parent?.remove(mesh);
    ribbon?.parent?.remove(ribbon!);
    return _scope.close();
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
    }
    for (var i = 0; i < baseIndices.length; i++) {
      indices[slot * baseIndices.length + i] = slot * vertices + baseIndices[i];
    }
  }
  return BufferGeometry.fromAttributes(
    attributes: {
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
