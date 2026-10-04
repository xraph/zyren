import 'settings.dart';
import 'package:zyren/zyren.dart';

String sharedParticleWgsl(ParticleSettings s, {required bool compute}) =>
    '''
struct Particle { position: vec4<f32>, velocity: vec4<f32>, metadata: vec4<f32>, birthX: vec4<f32>, birthY: vec4<f32>, birthZ: vec4<f32> };
struct Parameters {
 commands: vec4<u32>, dynamics: vec4<f32>, emitter: mat4x4<f32>,
 camera: vec4<f32>, right: vec4<f32>, up: vec4<f32>, forward: vec4<f32>,
 origin: vec4<f32>, collisionOffsets: array<vec4<f32>,3>, emissionVelocity: vec4<f32>,
};
@group(${compute ? 0 : 1}) @binding(0) var<storage, ${compute ? 'read_write' : 'read'}> particles: array<Particle>;
@group(${compute ? 0 : 1}) @binding(1) var<uniform> params: Parameters;
@group(${compute ? 0 : 1}) @binding(2) var<storage, read> surface: array<vec4<f32>>;
@group(${compute ? 0 : 1}) @binding(3) var<storage, ${compute ? 'read_write' : 'read'}> history: array<vec4<f32>>;
@group(${compute ? 0 : 1}) @binding(4) var<storage, ${compute ? 'read_write' : 'read'}> order: array<vec2<u32>>;
fn hash(value: u32) -> u32 {
 var x = value; x = (x ^ (x >> 16u)) * 0x7feb352du;
 x = (x ^ (x >> 15u)) * 0x846ca68bu; return x ^ (x >> 16u);
}
fn random(serial: u32, channel: u32) -> f32 {
 return f32(hash(params.commands.w ^ (serial * 747796405u) ^ (channel * 2891336453u)) >> 8u) / 16777216.;
}
''';

String computeParticleWgsl(ParticleSettings s, int sortCapacity) {
  final samples = s.trails?.samples ?? 2;
  final collisions = StringBuffer();
  for (var i = 0; i < s.collisions.length; i++) {
    final c = s.collisions[i];
    final n = c.normal;
    collisions.writeln('''
{ let normal = vec3<f32>(${n.x},${n.y},${n.z});
 let distance = dot(p.position.xyz, normal) + params.collisionOffsets[${i ~/ 4}][${i % 4}];
 if distance < 0. {
  p.position = vec4<f32>(p.position.xyz - normal * distance, p.position.w);
  let speed = dot(p.velocity.xyz, normal);
  if speed < 0. { p.velocity = vec4<f32>(p.velocity.xyz - normal*speed*${1 + c.restitution},p.velocity.w); }
 }
}
''');
  }
  final forces = StringBuffer(), calls = StringBuffer();
  for (var i = 0; i < s.forces.length; i++) {
    forces.writeln(
      'fn force$i(p: vec3<f32>, v: vec3<f32>, time: f32, seed: u32) -> vec3<f32> { ${s.forces[i].wgslBody} }',
    );
    calls.writeln(
      'acceleration += force$i(p.position.xyz + params.origin.xyz, p.velocity.xyz, params.dynamics.y, u32(p.metadata.x));',
    );
  }
  return '''${sharedParticleWgsl(s, compute: true)}
fn shape(r: vec4<f32>) -> vec3<f32> { ${s.shape.wgslBody} }
$forces
@compute @workgroup_size(64) fn simulate(@builtin(global_invocation_id) id: vec3<u32>) {
 let slot = id.x; if slot >= ${s.capacity}u { return; }
 var p = particles[slot]; let dt = params.dynamics.x; let tick = params.commands.x;
 if p.metadata.y > .5 {
  p.position.w = f32(tick - u32(p.velocity.w)) * dt;
  if p.position.w >= ${s.lifetime} { p.metadata.y = 0.; } else {
   var acceleration = vec3<f32>(${s.gravity.x},${s.gravity.y},${s.gravity.z});
   $calls
   p.velocity = vec4<f32>((p.velocity.xyz + acceleration*dt) / (1. + ${s.drag}*dt), p.velocity.w);
   p.position = vec4<f32>(p.position.xyz + p.velocity.xyz*dt, p.position.w);
   $collisions
  }
 }
 if params.commands.z > 0u {
  let first = params.commands.y; let last = first + params.commands.z - 1u;
  let offset = (slot + ${s.capacity}u - (first % ${s.capacity}u)) % ${s.capacity}u;
  if offset < params.commands.z {
   let serial = ${s.overflow == ParticleOverflow.dropNew ? 'first + offset' : 'last - ((last-slot) % ${s.capacity}u)'};
   if serial >= first && (${s.overflow == ParticleOverflow.replaceOldest ? 'true' : 'p.metadata.y < .5'}) {
    var position = shape(vec4<f32>(random(serial,0u),random(serial,1u),random(serial,2u),random(serial,3u)));
    var velocity = vec3<f32>(${s.velocity.x},${s.velocity.y},${s.velocity.z}) +
      (vec3<f32>(random(serial,4u),random(serial,5u),random(serial,6u))*2.-vec3<f32>(1.)) *
      vec3<f32>(${s.velocitySpread.x},${s.velocitySpread.y},${s.velocitySpread.z});
    ${s.space == ParticleSpace.world ? 'position = (params.emitter*vec4<f32>(position,1.)).xyz; velocity = (params.emitter*vec4<f32>(velocity,0.)).xyz;' : ''}
    velocity += params.emissionVelocity.xyz;
    p.position = vec4<f32>(position,0.); p.velocity = vec4<f32>(velocity,f32(tick));
    p.metadata = vec4<f32>(f32(serial),1.,0.,0.);
    p.birthX=params.emitter[0]; p.birthY=params.emitter[1]; p.birthZ=params.emitter[2];
   }
  }
 }
 particles[slot] = p;
 history[(slot*${samples}u + tick%${samples}u)] = vec4<f32>(p.position.xyz, select(0.,p.velocity.w+1.,p.metadata.y>.5));
}
@compute @workgroup_size(64) fn initializeOrder(@builtin(global_invocation_id) id: vec3<u32>) {
 let slot = id.x; if slot >= ${sortCapacity}u { return; }
 var key = 0xffffffffu;
 if slot < ${s.capacity}u {
  let p = particles[slot];
  let world = ${s.space == ParticleSpace.local ? '(params.emitter*vec4<f32>(p.position.xyz,1.)).xyz' : 'p.position.xyz'};
  if p.metadata.y > .5 { key = 0xffffffffu - bitcast<u32>(max(0., dot(world-params.camera.xyz,params.forward.xyz))); }
 }
 order[slot] = vec2<u32>(slot,key);
}
''';
}

String curveWgsl(String name, ParticleCurve curve) {
  final code = StringBuffer('fn $name(t: f32) -> f32 {\n');
  for (var i = 1; i < curve.keys.length; i++) {
    final a = curve.keys[i - 1], b = curve.keys[i];
    code.writeln(
      'if t <= ${b.time} { return mix(${a.value},${b.value}, (t-${a.time})/${b.time - a.time}); }',
    );
  }
  code.writeln('return ${curve.keys.last.value}; }');
  return code.toString();
}

String renderParticleWgsl(ParticleSettings s, {bool trail = false}) {
  final samples = s.trails?.samples ?? 2;
  final meshVertices = s.mesh?.layout.vertexCount ?? 4;
  final texturedMesh =
      !trail && s.appearance == ParticleAppearance.mesh && s.texture != null;
  final curves = [
    curveWgsl('sizeCurve', s.size),
    curveWgsl('rotationCurve', s.rotation),
    curveWgsl('redCurve', s.color.red),
    curveWgsl('greenCurve', s.color.green),
    curveWgsl('blueCurve', s.color.blue),
    curveWgsl('alphaCurve', s.color.alpha),
  ].join('\n');
  return '''${ShaderMaterial.uniformsWgsl}
${sharedParticleWgsl(s, compute: false)}
$curves
${s.texture == null ? '' : '@group(1) @binding(5) var image: texture_2d<f32>; @group(1) @binding(6) var imageSampler: sampler;'}
struct Vertex {
 @builtin(position) position: vec4<f32>, @location(0) uv: vec2<f32>,
 @location(1) color: vec4<f32>, @location(2) relative: vec3<f32>,
};
fn worldPosition(position: vec3<f32>) -> vec3<f32> {
 return ${s.space == ParticleSpace.world ? 'position - params.camera.xyz' : '(mesh.model * vec4<f32>(position,1.)).xyz'};
}
@vertex fn vertex(@builtin(vertex_index) index: u32,
 @location(0) vertexPosition: vec3<f32>, @location(1) normal: vec3<f32>
 ${texturedMesh ? ', @location(2) inputUv: vec2<f32>, @location(3) secondaryUv: vec2<f32>' : ''}) -> Vertex {
 var output: Vertex;
 let ordinal = index / ${trail
      ? (samples - 1) * 4
      : s.appearance == ParticleAppearance.mesh
      ? meshVertices
      : 4}u;
 let slot = order[ordinal].x;
 var p: Particle;
 if slot < ${s.capacity}u { p = particles[slot]; }
 let t = clamp(p.position.w / ${s.lifetime},0.,1.);
 let angle = rotationCurve(t); let size = sizeCurve(t);
 var uv = vertexPosition.xy + vec2<f32>(.5);
 var relative = worldPosition(p.position.xyz);
 var alive = p.metadata.y > .5;
 ${trail
      ? '''
 let localIndex = index % ${(samples - 1) * 4}u; let segment = localIndex/4u;
 let corner = localIndex%4u; let lag = segment + select(0u,1u,corner>=2u);
 let tick = params.commands.x;
 let sampleIndex = (tick + ${samples}u - lag)%${samples}u;
 let previousIndex = (tick + ${samples}u - min(lag+1u,${samples - 1}u))%${samples}u;
 let h = history[slot*${samples}u+sampleIndex];
 let previous = history[slot*${samples}u+previousIndex];
 alive = alive && h.w == p.velocity.w+1. && previous.w == h.w && tick >= lag;
 let direction = worldPosition(h.xyz) - worldPosition(previous.xyz);
 var side = cross(direction,params.forward.xyz);
 if dot(side,side)<1e-12 { side = params.right.xyz; } else { side = normalize(side); }
 let scale = ${s.space == ParticleSpace.world ? 'max(length(p.birthX.xyz),max(length(p.birthY.xyz),length(p.birthZ.xyz)))' : 'max(length(mesh.model[0].xyz),max(length(mesh.model[1].xyz),length(mesh.model[2].xyz)))'};
 let width = ${s.trails!.width} * size * scale;
 relative = worldPosition(h.xyz) + side * select(-.5,.5,(corner&1u)==1u)*width;
 uv = vec2<f32>(select(0.,1.,(corner&1u)==1u),f32(lag)/${samples - 1}.);
'''
      : s.appearance == ParticleAppearance.mesh
      ? '''
 let rotated = vec3<f32>(vertexPosition.x*cos(angle)-vertexPosition.z*sin(angle),
 vertexPosition.y, vertexPosition.x*sin(angle)+vertexPosition.z*cos(angle));
 relative = worldPosition(p.position.xyz + ${s.space == ParticleSpace.world ? '(p.birthX.xyz*rotated.x+p.birthY.xyz*rotated.y+p.birthZ.xyz*rotated.z)' : 'rotated'}*size);
 uv = ${texturedMesh ? 'inputUv' : 'vertexPosition.xy'};
'''
      : '''
 let corner = index % 4u;
 let x = select(-.5,.5,(corner&1u)==1u); let y = select(-.5,.5,corner>=2u);
 var axesX = params.right.xyz; var axesY = params.up.xyz;
 ${s.appearance == ParticleAppearance.oriented
            ? s.space == ParticleSpace.local
                  ? 'axesX = normalize(mesh.model[0].xyz); axesY = normalize(mesh.model[1].xyz);'
                  : 'axesX = normalize(p.birthX.xyz); axesY = normalize(p.birthY.xyz);'
            : ''}
 ${s.appearance == ParticleAppearance.stretched ? '''
 var velocity = ${s.space == ParticleSpace.local ? '(mesh.model*vec4<f32>(p.velocity.xyz,0.)).xyz' : 'p.velocity.xyz'};
 velocity -= params.forward.xyz*dot(velocity,params.forward.xyz);
 if dot(velocity,velocity) > 1e-12 { axesY = normalize(velocity); axesX = normalize(cross(axesY,params.forward.xyz)); }
 axesY *= 1. + length(velocity)*${s.stretch};
''' : ''}
 ${s.space == ParticleSpace.local ? 'axesX *= length(mesh.model[0].xyz); axesY *= length(mesh.model[1].xyz);' : 'axesX *= length(p.birthX.xyz); axesY *= length(p.birthY.xyz);'}
 let rotated = vec2<f32>(x*cos(angle)-y*sin(angle),x*sin(angle)+y*cos(angle));
 relative += (axesX*rotated.x + axesY*rotated.y)*size;
 uv = vec2<f32>(x+.5,.5-y);
'''}
 ${s.texture == null || trail ? '' : '''
 let frame = u32(floor(p.position.w*${s.texture!.framesPerSecond})) % ${s.texture!.columns * s.texture!.rows}u;
 uv = clamp(uv,vec2<f32>(${.5 * s.texture!.columns / s.texture!.width},${.5 * s.texture!.rows / s.texture!.height}),
  vec2<f32>(${1 - .5 * s.texture!.columns / s.texture!.width},${1 - .5 * s.texture!.rows / s.texture!.height}));
 uv = (uv+vec2<f32>(f32(frame%${s.texture!.columns}u), f32(frame/${s.texture!.columns}u))) /
  vec2<f32>(${s.texture!.columns}.,${s.texture!.rows}.);
'''}
 output.position = mesh.view_projection * vec4<f32>(relative,1.);
 if !alive { output.position = vec4<f32>(2.,2.,2.,1.); }
 output.uv = uv; output.relative = relative;
 output.color = vec4<f32>(redCurve(t),greenCurve(t),blueCurve(t),alphaCurve(t));
 return output;
}
@fragment fn fragment(input: Vertex) -> @location(0) vec4<f32> {
 meshClip(input.relative);
 var color = input.color;
 ${s.texture == null ? (trail || s.appearance == ParticleAppearance.mesh ? '' : 'color.a *= 1. - smoothstep(.35,.5,length(input.uv-vec2<f32>(.5)));') : 'color *= textureSample(image,imageSampler,input.uv);'}
 ${s.blend == ParticleBlend.additive ? 'color = vec4<f32>(color.rgb*color.a,0.);' : ''}
 if color.a < .001 ${s.blend == ParticleBlend.additive ? '&& dot(color.rgb,color.rgb)<1e-8' : ''} { discard; }
 ${s.blend == ParticleBlend.opaque ? 'color.a = 1.;' : ''}
 return color;
}
''';
}

String sortParticleWgsl(int capacity, List<(int, int)> stages) {
  final source = StringBuffer(
    '@group(0) @binding(4) var<storage, read_write> order: array<vec2<u32>>;\n',
  );
  for (final stage in stages) {
    final (k, j) = stage;
    source.writeln('''
@compute @workgroup_size(64) fn sort_${k}_$j(@builtin(global_invocation_id) id: vec3<u32>) {
 let i = id.x; if i >= ${capacity}u { return; } let partner = i ^ ${j}u;
 if partner <= i { return; } let a = order[i]; let b = order[partner];
 let less = a.y < b.y || (a.y == b.y && a.x < b.x);
 if less == ((i & ${k}u) != 0u) { order[i] = b; order[partner] = a; }
}
''');
  }
  return source.toString();
}
