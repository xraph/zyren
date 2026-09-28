# Compile WGSL modules

Use `NativeBackend.createShaderCompiler()` to validate WGSL on the backend's
native wgpu device. This runs on its worker isolate, so you can await diagnostics
without doing parser work on Flutter's UI isolate.

```dart
final backend = await NativeBackend.create();
try {
  final shaders = backend.createShaderCompiler(label: 'effects');
  final program = await shaders.compile(ShaderSource.wgsl('''
    @compute @workgroup_size(8, 8, 1)
    fn main() {}
  ''', label: 'cloud-density.wgsl'));
  print(program.entryPoints.single.workgroupSize); // (8, 8, 1)
} finally {
  await backend.close();
}
```

This API creates validated shader modules. Use a [render graph](render-graphs.md)
to compile their pipelines, bind resources and execute compute or procedural
render passes into scoped textures. `NativeBackend` advertises
`RenderFeature.shaderCompilation`, `renderGraphs`, `compute` and `storageTextures`.
Custom mesh materials and Flutter platform-view graph integration remain in
plan 03, task 4.

## Plugin ownership

Inside `ScenePlugin.attach`, use `context.shaders.compile(source)`. The context
creates one compiler when you first access it. Add
`RenderFeature.shaderCompilation` to your plugin's `requiredFeatures` if it needs
this API; an unsupported backend rejects attachment with the plugin ID.

Closing the attachment scope stops new compilation immediately, waits for
accepted requests and releases their programs. A result that arrives after
close is released without being published. Cleanup also runs when attachment
fails. `AttachmentScope.onClose` lets you register other asynchronous cleanup;
await `scope.whenClosed` to observe all collected failures.

If you need a program to outlive its original compiler, retain it in another
compiler on the same device:

```dart
final retained = await otherShaders.retain(program);
await originalShaders.close();
// retained is still open. program is closed.
```

Views created with `backend.createView()` share the device and can retain each
other's programs. Independent backends cannot. A `ShaderProgram` exposes source,
entry points and diagnostics, with no constructor or native handle. Its entry
point workgroup size is null for non-compute stages and for compute workgroup
sizes that depend on override constants.

## Errors and source locations

Catch `ShaderCompilationException` for compiler failures. You get the exact
`ShaderSource`, a typed code and immutable diagnostics. `ShaderLocation` uses
one-based lines and columns plus zero-based offsets and lengths in UTF-16 units,
so you can index the original Dart string even when its comments contain emoji.

Syntax and type errors leave the device usable. Out-of-memory and internal GPU
errors mark it failed and require recreation. Native token checks reject closed,
reused or foreign program handles. Buffer and shader registries use distinct
identities, including when they belong to the same device.

The native parser and wgpu both validate source before a program is published.
The error text is bounded to eight diagnostics of at most 4096 UTF-8 bytes each.
Diagnostic locations remain available separately from that text.

## Limits and cache

You can submit up to 1 MiB of UTF-8 source per compilation and use labels up to
1024 bytes. A module may have up to 64 entry points, each with a name of at most
512 bytes. Per device, admission limits are 256 live program allocations and
16 MiB of source accounting. Retaining a program shares its allocation; compiling
the same source again creates a new scoped allocation and charges its source
size again.

Identical source shares a cached module within one device, regardless of its
diagnostic label. The cache holds only weak references, so releasing the last
program removes the cached source and module. `backend.shaderStats()` reports
live programs, cached modules, admitted source bytes, compilation attempts and
cache hits. Those bytes are source accounting, not measured driver memory.

Shader control messages use versioned JSON with request IDs, an 8 MiB input cap
and a fixed 256 KiB response buffer. Native admission checks the complete response
capacity before mutating ownership. Buffer and image data keep the existing
binary resource protocol.

Run `fvm dart run example/shader_compiler.dart` from `packages/gpu3d_native` to
validate a storage-texture shader, print a source error and check cleanup on your
native device. See [verification](../verification.md) for the tested platforms.
