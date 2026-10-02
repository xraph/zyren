part of '../resources/resource_scope.dart';

/// Internal shared-graph adapter. Matches allocation identity, including aliases.
GraphDescription swapHistoryTextures(
  GraphDescription graph,
  Iterable<(GpuResource<Texture>, GpuResource<Texture>)> pairs,
) {
  Object identity(GpuResource<Object?> r) => (r._scope._device, r._key);
  final swaps = <Object, GpuResource<Texture>>{};
  for (final (previous, current) in pairs) {
    final before = identity(previous), after = identity(current);
    if (before == after ||
        swaps.containsKey(before) ||
        swaps.containsKey(after)) {
      throw GraphException(
        GraphErrorCode.aliasConflict,
        'History texture roles must not alias.',
      );
    }
    var written = false;
    for (final pass in graph.allPasses) {
      for (final resource in pass.writes) {
        if (identity(resource) == before) {
          throw GraphException(
            GraphErrorCode.accessMismatch,
            'Previous history is read-only.',
            passName: pass.name,
          );
        }
        if (identity(resource) == after) {
          written = true;
          if (pass is RenderPassDescriptor &&
              pass.color.store == AttachmentStore.discard) {
            throw GraphException(
              GraphErrorCode.uninitializedRead,
              'History writes must be stored.',
              passName: pass.name,
            );
          }
        }
      }
    }
    if (!written || graph.inputs.any((r) => identity(r) == after)) {
      throw GraphException(
        GraphErrorCode.uninitializedRead,
        'Current history must be produced by this graph, not imported.',
      );
    }
    swaps[before] = current;
    swaps[after] = previous;
  }
  GpuResource<T> swap<T>(GpuResource<T> r) =>
      (swaps[identity(r)] ?? r) as GpuResource<T>;
  ShaderBindings bindings(ShaderBindings source) => ShaderBindings([
    for (final entry in source.entries)
      if (entry is TextureBinding)
        if (entry.storage)
          TextureBinding.storage(
            entry.binding,
            swap(entry.resource),
            group: entry.group,
            mipLevel: entry.mipLevel,
            visibility: entry.visibility,
          )
        else
          TextureBinding.sampled(
            entry.binding,
            swap(entry.resource),
            group: entry.group,
            mipLevel: entry.mipLevel,
            mipLevels: entry.mipLevels,
            visibility: entry.visibility,
          )
      else
        entry,
  ]);
  PassDescriptor pass(PassDescriptor p) => switch (p) {
    _MaterialPassDescriptor() => throw UnsupportedError(
      'Material passes cannot be used in history graphs.',
    ),
    ComputePassDescriptor() => ComputePassDescriptor(
      name: p.name,
      program: p.program,
      entryPoint: p.entryPoint,
      workgroups: p.workgroups,
      bindings: bindings(p.bindings),
      reads: p.reads.map(swap),
      writes: p.writes.map(swap),
      after: p.after,
    ),
    RenderPassDescriptor() => RenderPassDescriptor(
      name: p.name,
      program: p.program,
      vertexEntryPoint: p.vertexEntryPoint,
      fragmentEntryPoint: p.fragmentEntryPoint,
      vertexCount: p.vertexCount,
      instanceCount: p.instanceCount,
      sampleCount: p.sampleCount,
      color: ColorAttachment(
        swap(p.color.texture),
        mipLevel: p.color.mipLevel,
        load: p.color.load,
        store: p.color.store,
        clearColor: p.color.clearColor,
      ),
      bindings: bindings(p.bindings),
      reads: p.reads.map(swap),
      writes: p.writes.map(swap),
      after: p.after,
    ),
  };
  return GraphDescription(
    label: graph.label,
    sceneColor: graph.sceneColor == null ? null : swap(graph.sceneColor!),
    output: graph.output == null ? null : swap(graph.output!),
    beforeScene: graph.beforeScene.map(pass),
    passes: graph.passes.map(pass),
    inputs: graph.inputs.map(swap),
  );
}
