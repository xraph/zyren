part of '../resources/resource_scope.dart';

(GraphDeviceDescription, List<String>, List<GraphResourceLifetime>)
_prepareGraph(GraphDescription graph, GraphDevice device) {
  final passes = graph.allPasses.toList();
  final boundary = graph.beforeScene.length;
  Never fail(
    GraphErrorCode code,
    String message, {
    PassDescriptor? pass,
    GpuResource<Object?>? resource,
  }) => throw GraphException(
    code,
    message,
    passName: pass?.name,
    resourceLabel: resource?.label,
  );
  bool validLabel(String value) =>
      value.isNotEmpty && utf8.encode(value).length <= 1024;
  if (utf8.encode(graph.label).length > 1024 ||
      passes.isEmpty ||
      passes.length > 128) {
    fail(
      GraphErrorCode.limitExceeded,
      'A graph needs 1 to 128 passes and a label within 1024 UTF-8 bytes.',
    );
  }
  final resources = <Object, GpuResource<Object?>>{};
  Object resourceKey(GpuResource<Object?> resource, [PassDescriptor? pass]) {
    if (resource.isClosed) {
      fail(
        GraphErrorCode.closedResource,
        'Resource owner has closed.',
        pass: pass,
        resource: resource,
      );
    }
    if (!identical(resource._scope._device, device)) {
      fail(
        GraphErrorCode.foreignResource,
        'Resource belongs to another device.',
        pass: pass,
        resource: resource,
      );
    }
    resources[resource._key] = resource;
    if (resources.length > 1024) {
      fail(
        GraphErrorCode.limitExceeded,
        'A graph supports at most 1024 resources.',
      );
    }
    return resource._key;
  }

  final inputs = {for (final input in graph.inputs) resourceKey(input)};
  if ((graph.sceneColor == null) != (graph.output == null)) {
    fail(
      GraphErrorCode.invalidDescriptor,
      'A frame graph requires both sceneColor and output.',
    );
  }
  if (boundary > 0 && graph.sceneColor == null) {
    fail(
      GraphErrorCode.invalidDescriptor,
      'Before-scene passes require a scene frame graph.',
    );
  }
  Object? sceneKey, outputKey;
  if (graph.sceneColor case final scene?) {
    sceneKey = resourceKey(scene);
    outputKey = resourceKey(graph.output!);
    final source = scene.descriptor as TextureDescriptor;
    final output = graph.output!.descriptor as TextureDescriptor;
    if (!source.usage.contains(TextureUsage.renderAttachment) ||
        !output.usage.contains(TextureUsage.sampled) ||
        source.mipLevels != 1 ||
        output.mipLevels != 1 ||
        source.width != output.width ||
        source.height != output.height) {
      fail(
        GraphErrorCode.invalidBinding,
        'Frame textures need matching dimensions, one mip, renderable scene color and sampled output.',
      );
    }
  }
  final names = <String, int>{};
  final reads = <Set<Object>>[],
      writes = <Set<Object>>[],
      discarded = <Set<Object>>[];
  final commands = <Map<String, Object?>>[];
  for (var index = 0; index < passes.length; index++) {
    final pass = passes[index];
    if (!validLabel(pass.name)) {
      fail(
        GraphErrorCode.invalidDescriptor,
        'Pass names need 1 to 1024 UTF-8 bytes.',
        pass: pass,
      );
    }
    if (names.containsKey(pass.name)) {
      fail(GraphErrorCode.duplicatePass, 'Duplicate pass name.', pass: pass);
    }
    names[pass.name] = index;
    if (pass.program.isClosed) {
      fail(
        GraphErrorCode.closedResource,
        'Shader owner has closed.',
        pass: pass,
      );
    }
    if (!identical(pass.program._compiler._device, device)) {
      fail(
        GraphErrorCode.foreignResource,
        'Shader belongs to another device.',
        pass: pass,
      );
    }
    final declaredReads = {
      for (final resource in pass.reads) resourceKey(resource, pass),
    };
    final declaredWrites = {
      for (final resource in pass.writes) resourceKey(resource, pass),
    };
    final actualReads = <Object>{},
        actualWrites = <Object>{},
        discard = <Object>{};
    final uses = <Object, (int, bool)>{};
    void use(GpuResource<Object?> resource, bool read, bool write) {
      final key = resourceKey(resource, pass);
      final previous = uses[key];
      if (previous != null && (previous.$2 || write)) {
        fail(
          GraphErrorCode.aliasConflict,
          'A writable allocation cannot occupy another binding or attachment in the same pass.',
          pass: pass,
          resource: resource,
        );
      }
      uses[key] = ((previous?.$1 ?? 0) + 1, (previous?.$2 ?? false) || write);
      if (read) actualReads.add(key);
      if (write) actualWrites.add(key);
    }

    final bindings = _encodeShaderBindings(
      pass.bindings,
      compute: pass is ComputePassDescriptor,
      label: pass.name,
      use: use,
    );
    void entryPoint(String name, ShaderStage stage) {
      if (!pass.program.entryPoints.any(
        (entry) => entry.name == name && entry.stage == stage,
      )) {
        fail(
          GraphErrorCode.invalidDescriptor,
          'Shader has no ${stage.name} entry point named $name.',
          pass: pass,
        );
      }
    }

    final command = <String, Object?>{
      'name': pass.name,
      'program': pass.program._key,
      'bindings': bindings,
      'reads': declaredReads.toList(),
      'writes': declaredWrites.toList(),
      'after': pass.after.toList(),
    };
    switch (pass) {
      case _MaterialPassDescriptor(:final descriptor):
        entryPoint(descriptor.vertexEntryPoint, ShaderStage.vertex);
        entryPoint(descriptor.fragmentEntryPoint, ShaderStage.fragment);
        if (descriptor case PostProcessDescriptor(target: final target?)) {
          use(target, false, true);
          final info = target.descriptor as TextureDescriptor;
          if (info.dimension != TextureDimension.d2 ||
              info.format != TextureFormat.rgba16Float ||
              !info.usage.contains(TextureUsage.renderAttachment)) {
            fail(
              GraphErrorCode.invalidBinding,
              'Screen targets require a 2D RGBA16F render attachment.',
              pass: pass,
              resource: target,
            );
          }
          command['screenTarget'] = target._key;
        }
        command.addAll({
          'kind': 'material',
          'vertexEntryPoint': descriptor.vertexEntryPoint,
          'fragmentEntryPoint': descriptor.fragmentEntryPoint,
          'requiresUv': descriptor.requiresUv,
          if (descriptor.blend != null) 'blend': descriptor.blend!.name,
          'screenSpace': descriptor is PostProcessDescriptor,
          if (descriptor is PostProcessDescriptor)
            'screenStage': descriptor.stage.index,
        });
      case ComputePassDescriptor():
        entryPoint(pass.entryPoint, ShaderStage.compute);
        final groups = [
          pass.workgroups.x,
          pass.workgroups.y,
          pass.workgroups.z,
        ];
        if (groups.any((n) => n < 1 || n > 65535)) {
          fail(
            GraphErrorCode.invalidDescriptor,
            'Each workgroup count must be in [1, 65535].',
            pass: pass,
          );
        }
        command.addAll({
          'kind': 'compute',
          'entryPoint': pass.entryPoint,
          'workgroups': groups,
        });
      case RenderPassDescriptor():
        entryPoint(pass.vertexEntryPoint, ShaderStage.vertex);
        entryPoint(pass.fragmentEntryPoint, ShaderStage.fragment);
        if (pass.sampleCount != 1) {
          fail(
            GraphErrorCode.unsupportedFeature,
            'Graph textures currently support one sample.',
            pass: pass,
          );
        }
        if (pass.vertexCount < 1 ||
            pass.vertexCount > 1048576 ||
            pass.instanceCount < 1 ||
            pass.instanceCount > 65535) {
          fail(
            GraphErrorCode.limitExceeded,
            'Procedural draw count exceeds the graph limit.',
            pass: pass,
          );
        }
        final color = pass.color, resource = pass.color.texture;
        use(resource, color.load == AttachmentLoad.load, true);
        final descriptor = resource.descriptor as TextureDescriptor;
        final clear = [
          color.clearColor.red,
          color.clearColor.green,
          color.clearColor.blue,
          color.clearColor.alpha,
        ];
        if (!descriptor.usage.contains(TextureUsage.renderAttachment) ||
            descriptor.dimension != TextureDimension.d2 ||
            color.mipLevel < 0 ||
            color.mipLevel >= descriptor.mipLevels ||
            clear.any(
              (value) => !value.isFinite || value.abs() > 3.4028234663852886e38,
            )) {
          fail(
            GraphErrorCode.invalidBinding,
            'Color attachment usage, mip or clear color is invalid.',
            pass: pass,
            resource: resource,
          );
        }
        if (color.store == AttachmentStore.discard) discard.add(resource._key);
        command.addAll({
          'kind': 'render',
          'vertexEntryPoint': pass.vertexEntryPoint,
          'fragmentEntryPoint': pass.fragmentEntryPoint,
          'vertexCount': pass.vertexCount,
          'instanceCount': pass.instanceCount,
          'sampleCount': pass.sampleCount,
          'blend': pass.blend.name,
          'color': {
            'key': resource._key,
            'mipLevel': color.mipLevel,
            'load': color.load.name,
            'store': color.store.name,
            'clear': clear,
          },
        });
    }
    if (actualReads.length != declaredReads.length ||
        !actualReads.containsAll(declaredReads) ||
        actualWrites.length != declaredWrites.length ||
        !actualWrites.containsAll(declaredWrites)) {
      fail(
        GraphErrorCode.accessMismatch,
        'Declared reads and writes must match all bindings and attachment load/store operations.',
        pass: pass,
      );
    }
    if (index < boundary &&
        (actualReads.contains(sceneKey) || actualWrites.contains(sceneKey))) {
      fail(
        GraphErrorCode.invalidDescriptor,
        'Before-scene passes cannot access the scene color attachment.',
        pass: pass,
        resource: graph.sceneColor,
      );
    }
    reads.add(declaredReads);
    writes.add(declaredWrites);
    discarded.add(discard);
    commands.add(command);
  }
  final edges = List.generate(passes.length, (_) => <int>{});
  void edge(int from, int to) {
    if (from >= boundary && to < boundary) {
      fail(
        GraphErrorCode.invalidDescriptor,
        'A before-scene pass cannot depend on work after the scene.',
        pass: passes[to],
      );
    }
    if (from != to) edges[from].add(to);
  }

  for (var before = 0; before < boundary; before++) {
    for (var after = boundary; after < passes.length; after++) {
      edge(before, after);
    }
  }
  for (var i = 0; i < passes.length; i++) {
    for (final dependency in passes[i].after) {
      final before = names[dependency];
      if (before == null) {
        fail(
          GraphErrorCode.missingDependency,
          'Unknown dependency $dependency.',
          pass: passes[i],
        );
      }
      if (before == i) {
        fail(
          GraphErrorCode.cycle,
          'A pass cannot depend on itself.',
          pass: passes[i],
        );
      }
      edge(before, i);
    }
  }
  for (final key in resources.keys) {
    final producers = [
      for (var i = 0; i < writes.length; i++)
        if (writes[i].contains(key)) i,
    ];
    for (var i = 1; i < producers.length; i++) {
      edge(producers[i - 1], producers[i]);
    }
    for (var reader = 0; reader < reads.length; reader++) {
      if (!reads[reader].contains(key)) continue;
      int? producer;
      for (final candidate in producers) {
        if (candidate < reader) producer = candidate;
      }
      if (producer == null &&
          !inputs.contains(key) &&
          !(key == sceneKey && reader >= boundary)) {
        if (producers.isEmpty || producers.first == reader) {
          fail(
            GraphErrorCode.uninitializedRead,
            'Resource is read before it is initialized.',
            pass: passes[reader],
            resource: resources[key],
          );
        }
        producer = producers.first;
      }
      if (producer != null) edge(producer, reader);
      final later = producers.where(
        (writer) => writer > (producer ?? reader) && writer != reader,
      );
      if (later.isNotEmpty) edge(reader, later.first);
    }
  }
  final incoming = List.filled(edges.length, 0);
  for (final successors in edges) {
    for (final target in successors) {
      incoming[target]++;
    }
  }
  final order = <int>[];
  final available = [
    for (var i = 0; i < incoming.length; i++)
      if (incoming[i] == 0) i,
  ];
  while (available.isNotEmpty) {
    available.sort();
    final current = available.removeAt(0);
    order.add(current);
    for (final next in edges[current]) {
      if (--incoming[next] == 0) available.add(next);
    }
  }
  if (order.length != passes.length) {
    final blocked = [
      for (var i = 0; i < incoming.length; i++)
        if (incoming[i] > 0) passes[i],
    ];
    fail(
      GraphErrorCode.cycle,
      'Pass dependencies and resource accesses form a cycle involving ${blocked.map((pass) => pass.name).join(', ')}.',
      pass: blocked.first,
    );
  }
  final initialized = {...inputs},
      intervals = <Object, (int, int)>{?sceneKey: (boundary - 1, boundary - 1)};
  for (var position = 0; position < order.length; position++) {
    if (position == boundary && sceneKey != null) initialized.add(sceneKey);
    final index = order[position];
    for (final key in reads[index]) {
      if (!initialized.contains(key)) {
        fail(
          GraphErrorCode.uninitializedRead,
          'Resource contents were discarded before this read.',
          pass: passes[index],
          resource: resources[key],
        );
      }
    }
    initialized.addAll(writes[index]);
    initialized.removeAll(discarded[index]);
    for (final key in {...reads[index], ...writes[index]}) {
      intervals[key] = (intervals[key]?.$1 ?? position, position);
    }
  }
  if (boundary == order.length && sceneKey != null) initialized.add(sceneKey);
  if (outputKey != null) {
    if (!initialized.contains(outputKey)) {
      fail(
        GraphErrorCode.uninitializedRead,
        'Frame output is uninitialized or discarded.',
        resource: graph.output,
      );
    }
    intervals[outputKey] = (intervals[outputKey]?.$1 ?? -1, order.length);
  }
  return (
    GraphDeviceDescription({
      'sceneColor': ?sceneKey,
      'scenePassIndex': boundary,
      'output': ?outputKey,
      'label': graph.label,
      'inputs': inputs.toList(),
      'resources': [
        for (final entry in resources.entries)
          {'key': entry.key, 'label': entry.value.label},
      ],
      'passes': [for (final index in order) commands[index]],
    }),
    [for (final index in order) passes[index].name],
    [
      for (final entry in intervals.entries)
        GraphResourceLifetime(
          resourceLabel: resources[entry.key]!.label,
          firstPass: entry.value.$1,
          lastPass: entry.value.$2,
        ),
    ],
  );
}

List<Map<String, Object?>> _encodeShaderBindings(
  ShaderBindings values, {
  required bool compute,
  required String label,
  required void Function(GpuResource<Object?>, bool, bool) use,
}) {
  Never fail(
    GraphErrorCode code,
    String message, {
    GpuResource<Object?>? resource,
  }) => throw GraphException(
    code,
    message,
    passName: label,
    resourceLabel: resource?.label,
  );
  if (values.entries.length > 64) {
    fail(GraphErrorCode.limitExceeded, 'A pass supports at most 64 bindings.');
  }
  final slots = <(int, int)>{};
  final bindings = <Map<String, Object?>>[];
  for (final binding in values.entries) {
    if (binding.group < 0 ||
        binding.group >= 4 ||
        binding.binding < 0 ||
        binding.binding >= 16 ||
        !slots.add((binding.group, binding.binding))) {
      fail(
        GraphErrorCode.invalidBinding,
        'Bindings need unique slots in groups 0 to 3, bindings 0 to 15.',
      );
    }
    final supportedStages = compute
        ? {ShaderStage.compute}
        : {ShaderStage.vertex, ShaderStage.fragment};
    final visibility =
        binding.visibility ??
        (compute
            ? {ShaderStage.compute}
            : binding._writes
            ? {ShaderStage.fragment}
            : {ShaderStage.vertex, ShaderStage.fragment});
    if (visibility.isEmpty || !supportedStages.containsAll(visibility)) {
      fail(
        GraphErrorCode.invalidBinding,
        'Binding visibility must match the pass stages.',
      );
    }
    final entry = <String, Object?>{
      'group': binding.group,
      'binding': binding.binding,
      'stages': visibility.map((stage) => stage.index).toList()..sort(),
      'kind': binding._kind,
    };
    final resource = binding.resource;
    if (resource != null) {
      use(resource, binding._reads, binding._writes);
      entry['key'] = resource._key;
    }
    switch (binding) {
      case BufferBinding():
        final descriptor = binding.resource.descriptor as BufferDescriptor;
        final size = binding.size ?? descriptor.size - binding.offset;
        final usage = binding.access == BufferBindingAccess.uniform
            ? BufferUsage.uniform
            : BufferUsage.storage;
        if (!descriptor.usage.contains(usage) ||
            binding.offset < 0 ||
            binding.offset % 256 != 0 ||
            size <= 0 ||
            size % 4 != 0 ||
            size > descriptor.size ||
            binding.offset > descriptor.size - size) {
          fail(
            GraphErrorCode.invalidBinding,
            'Buffer binding requires matching usage, a 256-byte aligned offset and a valid four-byte aligned range.',
            resource: resource,
          );
        }
        entry.addAll({'offset': binding.offset, 'size': size});
      case TextureBinding():
        final descriptor = binding.resource.descriptor as TextureDescriptor;
        final usage = binding.storage
            ? TextureUsage.storage
            : TextureUsage.sampled;
        if (!descriptor.usage.contains(usage) ||
            binding.mipLevel < 0 ||
            binding.mipLevels < 1 ||
            binding.mipLevels > descriptor.mipLevels ||
            binding.mipLevel > descriptor.mipLevels - binding.mipLevels ||
            (binding.storage &&
                (descriptor.format.isSrgb ||
                    descriptor.format.isCompressed ||
                    binding.mipLevels != 1))) {
          fail(
            GraphErrorCode.invalidBinding,
            'Texture binding usage, mip range or storage format is invalid.',
            resource: resource,
          );
        }
        entry.addAll({
          'mipLevel': binding.mipLevel,
          'mipLevels': binding.mipLevels,
        });
      case SamplerBinding():
        entry['sampler'] = binding.sampler.toPacket(volume: true);
    }
    bindings.add(entry);
  }
  return bindings;
}
