import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'scalar_grid.dart';
import 'work.dart';

final class VolumeStop {
  final double position, opacity;
  final Color3 color;
  VolumeStop(this.position, this.color, this.opacity) {
    if (!position.isFinite ||
        position < 0 ||
        position > 1 ||
        !opacity.isFinite ||
        opacity < 0 ||
        opacity > 1 ||
        color.toList().any((v) => !v.isFinite || v < 0 || v > 1)) {
      throw ArgumentError(
        'Volume stops use normalized positions, linear RGB and opacity.',
      );
    }
  }
}

/// Piecewise linear color and opacity at a declared reference length.
final class VolumeTransferFunction {
  final ScientificUnit unit;
  final double minimum, maximum;
  final List<VolumeStop> stops;
  VolumeTransferFunction({
    required this.unit,
    required this.minimum,
    required this.maximum,
    required List<VolumeStop> stops,
  }) : stops = List.unmodifiable(stops) {
    if (!minimum.isFinite ||
        !maximum.isFinite ||
        maximum < minimum ||
        !(maximum - minimum).isFinite ||
        stops.length < 2 ||
        stops.length > 64 ||
        stops.first.position != 0 ||
        stops.last.position != 1) {
      throw ArgumentError('Invalid volume transfer range or stops.');
    }
    for (var i = 1; i < stops.length; i++) {
      if (stops[i].position <= stops[i - 1].position ||
          Float32List.fromList([stops[i].position]).single <=
              Float32List.fromList([stops[i - 1].position]).single) {
        throw ArgumentError('Volume transfer stops must increase.');
      }
    }
  }
}

final class ScientificVolumeSettings {
  final ScalarGrid3D grid;
  final VolumeTransferFunction transfer;
  final double sampleDistance,
      referenceDistance,
      coordinateTolerance,
      scalarTolerance;
  final int maxRaySteps, maxPixelSamples;
  late final int raySteps;
  ScientificVolumeSettings({
    required this.grid,
    required this.transfer,
    required this.sampleDistance,
    required this.referenceDistance,
    required this.coordinateTolerance,
    required this.scalarTolerance,
    this.maxRaySteps = 1024,
    this.maxPixelSamples = 256000000,
  }) {
    if (grid.valueUnit != transfer.unit ||
        [grid.sizeX, grid.sizeY, grid.sizeZ].any((v) => v < 2 || v > 256) ||
        [sampleDistance, referenceDistance].any((v) => !v.isFinite || v <= 0) ||
        [
          coordinateTolerance,
          scalarTolerance,
        ].any((v) => !v.isFinite || v < 0) ||
        maxRaySteps < 1 ||
        maxRaySteps > 4096 ||
        maxPixelSamples < 1 ||
        maxPixelSamples > 512000000) {
      throw ArgumentError('Invalid volume dimensions, units or work limits.');
    }
    final diagonal = extent.length;
    if (!diagonal.isFinite ||
        !(diagonal / sampleDistance).isFinite ||
        diagonal / sampleDistance > maxRaySteps - 1) {
      throw ArgumentError('Volume exceeds the ray-step budget.');
    }
    raySteps = (diagonal / sampleDistance).ceil() + 1;
    for (final value in [
      sampleDistance,
      referenceDistance,
      ...extent.storage,
    ]) {
      final f = Float32List.fromList([value]).single;
      if (!f.isFinite || f <= 0 || (f - value).abs() > coordinateTolerance) {
        throw ArgumentError(
          'Volume lengths exceed float32 coordinate tolerance.',
        );
      }
    }
    for (final value in [
      transfer.minimum,
      transfer.maximum,
      transfer.maximum - transfer.minimum,
    ]) {
      final f = Float32List.fromList([value]).single;
      if (!f.isFinite || (f - value).abs() > scalarTolerance) {
        throw ArgumentError('Transfer range exceeds scalar tolerance.');
      }
    }
    if (transfer.minimum != transfer.maximum &&
        Float32List.fromList([transfer.minimum]).single ==
            Float32List.fromList([transfer.maximum]).single) {
      throw ArgumentError('Float32 transfer range collapses.');
    }
  }
  Vec3 get extent => Vec3(
    (grid.sizeX - 1) * grid.spacing.x,
    (grid.sizeY - 1) * grid.spacing.y,
    (grid.sizeZ - 1) * grid.spacing.z,
  );
  void checkViewport(int width, int height) {
    if (width < 1 ||
        height < 1 ||
        width > maxPixelSamples ~/ raySteps ~/ height) {
      throw ArgumentError('Volume viewport exceeds the pixel-sample budget.');
    }
  }
}

/// Owns a native float volume and depth-aware HDR effect. Call update before
/// rendering each camera/viewport. Remove the scene registration before close.
final class ScientificVolumeEffect {
  final ScientificVolumeSettings settings;
  final GpuScope _scope;
  final GpuResource<Buffer> _uniform;
  final ScreenEffect effect;
  final double maxScalarError;
  ScientificVolumeEffect._(
    this.settings,
    this._scope,
    this._uniform,
    this.effect,
    this.maxScalarError,
  );
  bool get isClosed => _scope.isClosed;
  Future<void> close() => _scope.close();
  static Future<ScientificVolumeEffect> create(
    GpuScope owner, {
    required ScientificVolumeSettings settings,
    ScientificCancellation? cancellation,
  }) async {
    cancellation?.check();
    final g = settings.grid;
    final scope = owner.createChild(label: 'scientific volume');
    try {
      final data = Float32List(g.sampleCount * 4);
      var error = 0.0;
      for (var z = 0; z < g.sizeZ; z++) {
        for (var y = 0; y < g.sizeY; y++) {
          for (var x = 0; x < g.sizeX; x++) {
            final i = x + g.sizeX * (y + g.sizeY * z);
            if (i % 4096 == 0) await scientificYield(cancellation);
            final value = g.valueAt(x, y, z);
            if (value == null) continue;
            data[i * 4] = value;
            data[i * 4 + 1] = 1;
            final e = (data[i * 4] - value).abs();
            if (!data[i * 4].isFinite || e > settings.scalarTolerance) {
              throw ArgumentError(
                'Volume sample exceeds float32 scalar tolerance.',
              );
            }
            error = math.max(error, e);
          }
        }
      }
      final texture = await scope.resources.createTexture(
        TextureDescriptor(
          width: g.sizeX,
          height: g.sizeY,
          depth: g.sizeZ,
          dimension: TextureDimension.d3,
          format: TextureFormat.rgba32Float,
          usage: {TextureUsage.sampled, TextureUsage.copyDestination},
        ),
      );
      cancellation?.check();
      await scope.resources.writeTexture(texture, data.buffer.asUint8List());
      final uniform = await scope.resources.createBuffer(
        BufferDescriptor(
          size: 144,
          usage: {BufferUsage.uniform, BufferUsage.copyDestination},
        ),
      );
      final program = await scope.shaders.compile(
        ShaderSource.wgsl(
          '${PostProcessDescriptor.interfaceWgsl}\n${_shader(settings)}',
          label: 'scientific volume ray marcher',
        ),
      );
      cancellation?.check();
      final effect = await scope.materials.compileEffect(
        PostProcessDescriptor(
          program: program,
          stage: PostProcessStage.hdr,
          bindings: ShaderBindings([
            TextureBinding.sampled(0, texture, group: 1),
            BufferBinding.uniform(1, uniform, group: 1),
          ]),
        ),
      );
      cancellation?.check();
      return ScientificVolumeEffect._(settings, scope, uniform, effect, error);
    } catch (_) {
      await scope.close();
      rethrow;
    }
  }

  Future<void> update({
    required Camera camera,
    required Scene scene,
    required int width,
    required int height,
  }) async {
    settings.checkViewport(width, height);
    final minimum = settings.grid.origin - camera.position,
        maximum = minimum + settings.extent;
    final values = <double>[
      ...minimum.storage,
      settings.sampleDistance,
      ...maximum.storage,
      settings.referenceDistance,
      scene.clippingPlanes.length.toDouble(),
      0,
      0,
      0,
    ];
    for (var i = 0; i < 6; i++) {
      if (i < scene.clippingPlanes.length) {
        final plane = scene.clippingPlanes[i];
        values.addAll([
          ...plane.normal.storage,
          plane.offset - plane.normal.dot(camera.position),
        ]);
      } else {
        values.addAll([0, 0, 0, 0]);
      }
    }
    final floats = Float32List.fromList(values);
    for (var i = 0; i < floats.length; i++) {
      // Unit normals/counts are dimensionless; geometric offsets use length.
      final tolerance = i >= 12 && (i - 12) % 4 < 3
          ? 1e-6
          : settings.coordinateTolerance;
      if (!floats[i].isFinite || (floats[i] - values[i]).abs() > tolerance) {
        throw ArgumentError(
          'Camera-relative volume/clipping coordinates exceed tolerance.',
        );
      }
    }
    for (var i = 0; i < 3; i++) {
      if (floats[i] >= floats[i + 4]) {
        throw ArgumentError('Camera-relative volume bounds collapse.');
      }
    }
    await _scope.resources.writeBuffer(_uniform, floats);
  }
}

String _number(double value) => 'f32(${value.toString()})';
String _shader(ScientificVolumeSettings settings) {
  final transfer = settings.transfer;
  final mappings = StringBuffer();
  for (var i = 1; i < transfer.stops.length; i++) {
    final a = transfer.stops[i - 1], b = transfer.stops[i];
    String rgba(VolumeStop stop) =>
        'vec4<f32>(${[...stop.color.toList(), stop.opacity].map(_number).join(',')})';
    mappings.writeln(
      'if(t<=${_number(b.position)}) { return mix(${rgba(a)},${rgba(b)},clamp((t-${_number(a.position)})/${_number(b.position - a.position)},0.,1.)); }',
    );
  }
  return '''
@group(1) @binding(0) var field:texture_3d<f32>;
struct VolumeUniform { minimum:vec4<f32>, maximum:vec4<f32>, info:vec4<f32>, planes:array<vec4<f32>,6>, };
@group(1) @binding(1) var<uniform> volume:VolumeUniform;
fn transfer(value:f32)->vec4<f32> {
 let t=${transfer.minimum == transfer.maximum ? '0.5' : 'clamp((value-${_number(transfer.minimum)})/${_number(transfer.maximum - transfer.minimum)},0.,1.)'};
 $mappings
 return vec4<f32>(0.);
}
fn sampleField(p:vec3<f32>)->vec2<f32> {
 let q=clamp(p,vec3<f32>(0.),vec3<f32>(1.))*vec3<f32>(textureDimensions(field)-vec3<u32>(1u));
 let base=vec3<i32>(floor(q)); let f=fract(q); var value=0.;
 for(var z=0;z<2;z++) { for(var y=0;y<2;y++) { for(var x=0;x<2;x++) {
  let w=select(1.-f.x,f.x,x==1)*select(1.-f.y,f.y,y==1)*select(1.-f.z,f.z,z==1);
  if(w>0.) {
   let v=textureLoad(field,min(base+vec3<i32>(x,y,z),vec3<i32>(textureDimensions(field))-vec3<i32>(1)),0).rg;
   if(v.y<.5) { return vec2<f32>(0.); } value+=w*v.x;
  }
 } } }
 return vec2<f32>(value,1.);
}
@fragment fn fragment(v:ScreenVertex)->@location(0) vec4<f32> {
 let pixel=vec2<i32>(v.position.xy); let background=textureLoad(sceneColor,pixel,0);
 let start=scenePosition(v.uv,sceneNearDepth());
 let finish=scenePosition(v.uv,1.-sceneNearDepth());
 let direction=normalize(finish-start);
 var entry=0.;var exitDistance=length(finish-start);
 for(var axis=0;axis<3;axis++) {
  if(abs(direction[axis])<1e-10) {
   if(start[axis]<volume.minimum[axis]||start[axis]>volume.maximum[axis]) { return background; }
  } else {
   let a=(volume.minimum[axis]-start[axis])/direction[axis];let b=(volume.maximum[axis]-start[axis])/direction[axis];
   entry=max(entry,min(a,b));exitDistance=min(exitDistance,max(a,b));
  }
 }
 for(var i=0;i<i32(volume.info.x);i++) {
  let plane=volume.planes[i];let d=dot(plane.xyz,start)-plane.w;let slope=dot(plane.xyz,direction);
  if(abs(slope)<1e-10) { if(d<0.) { return background; } }
  else if(slope>0.) { entry=max(entry,-d/slope); } else { exitDistance=min(exitDistance,-d/slope); }
 }
 let depth=textureLoad(sceneDepth,pixel,0);
 if(!sceneDepthIsBackground(depth)) { exitDistance=min(exitDistance,dot(scenePosition(v.uv,depth)-start,direction)); }
 if(exitDistance<=entry) { return background; }
 let rayStart=start+direction*entry;
 let rayLength=exitDistance-entry;
 var t=0.;var opacity=0.;var rgb=vec3<f32>(0.);
 for(var i=0;i<${settings.raySteps};i++) {
  if(t>=rayLength||opacity>=.99998474) { break; }
  let step=min(volume.minimum.w,rayLength-t);
  let p=rayStart+direction*(t+step*.5);
  let sample=sampleField((p-volume.minimum.xyz)/(volume.maximum.xyz-volume.minimum.xyz));
  if(sample.y>.5) {
   let color=transfer(sample.x);
   let alpha=1.-pow(1.-color.a,step/volume.maximum.w);
   rgb+=(1.-opacity)*alpha*color.rgb;opacity+=(1.-opacity)*alpha;
  }
  t+=step;
 }
 return vec4<f32>(rgb+(1.-opacity)*background.rgb,opacity+(1.-opacity)*background.a);
}
''';
}

const scientificVolume = ServiceKey<ScientificVolumeController>(
  'scientific.volume',
);

final class ScientificVolumePlugin extends ScenePlugin {
  final ScientificVolumeSettings? settings;
  ScientificVolumeController? _controller;
  ScientificVolumePlugin({this.settings});
  ScientificVolumeController get controller =>
      _controller ?? (throw StateError('Volume plugin is not attached.'));
  @override
  String get id => 'zyren.scientific.volume';
  @override
  Set<RenderFeature> get requiredFeatures => {
    RenderFeature.scopedResources,
    RenderFeature.shaderCompilation,
    RenderFeature.shaderMaterials,
    RenderFeature.floatTextures,
    RenderFeature.volumeTextures,
    RenderFeature.postprocessing,
    RenderFeature.hdr,
  };
  @override
  void attach(PluginContext context) {
    final control = _controller = ScientificVolumeController._(
      context,
      context.createGpuScope(label: 'scientific volume plugin'),
      settings,
    );
    context.scope.onClose(control._close);
    context.provide(scientificVolume, control);
  }

  @override
  Future<void> beforeRender(PluginContext context, FrameInfo frame) =>
      controller._frame(frame);
}

final class ScientificVolumeController {
  final PluginContext _context;
  final GpuScope _owner;
  ScientificVolumeSettings? _settings;
  ScientificVolumeEffect? _active;
  EffectRegistration? _registration;
  Future<void> _queue = Future.value();
  final ScientificCancellation _lifetime = ScientificCancellation();
  bool _closed = false;
  int _width = 0, _height = 0;
  ScientificVolumeController._(this._context, this._owner, this._settings);
  ScientificVolumeSettings? get settings => _settings;
  bool get isClosed => _closed;
  double? get maxScalarError => _active?.maxScalarError;
  Future<T> _serial<T>(Future<T> Function() work) {
    final next = _queue.then((_) {
      if (_closed) throw StateError('Volume controller closed.');
      return work();
    });
    _queue = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> setVolume(
    ScientificVolumeSettings? next, {
    ScientificCancellation? cancellation,
  }) => _serial(() async {
    cancellation?.check();
    if (_width > 0) await _replace(next, cancellation: cancellation);
    _settings = next;
    _context.invalidate();
  });
  Future<void> _replace(
    ScientificVolumeSettings? settings, {
    ScientificCancellation? cancellation,
  }) async {
    final token = ScientificCancellation(
      isCancellationRequested: () =>
          _lifetime.isCancelled || (cancellation?.isCancelled ?? false),
    );
    ScientificVolumeEffect? candidate;
    try {
      if (settings != null) {
        settings.checkViewport(_width, _height);
        candidate = await ScientificVolumeEffect.create(
          _owner,
          settings: settings,
          cancellation: token,
        );
        await candidate.update(
          camera: _context.camera,
          scene: _context.scene,
          width: _width,
          height: _height,
        );
      }
      token.check();
      final previous = _active;
      if (candidate == null) {
        _registration?.dispose();
        _registration = null;
      } else if (_registration == null) {
        _registration = _context.scene.addEffect(candidate.effect, order: -100);
      } else {
        _registration!.replace(candidate.effect);
      }
      _active = candidate;
      await previous?.close();
    } catch (_) {
      if (!identical(_active, candidate)) await candidate?.close();
      rethrow;
    }
  }

  Future<void> _frame(FrameInfo frame) => _serial(() async {
    _width = frame.width;
    _height = frame.height;
    if (_active == null && _settings != null) await _replace(_settings);
    await _active?.update(
      camera: _context.camera,
      scene: _context.scene,
      width: _width,
      height: _height,
    );
  });
  Future<void> _close() async {
    _closed = true;
    _lifetime.cancel();
    await _queue;
    _registration?.dispose();
    _registration = null;
    await _active?.close();
    _active = null;
  }
}
