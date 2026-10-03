import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'cascades.dart';

/// Per-frame camera-relative inputs shared by cloud and shadow passes.
final class CloudFrameState {
  final Float32List data;
  final CloudShadowCascades cascades;
  final Camera camera;
  final Vec3 correctedCamera, sun;
  final int width, height;
  CloudFrameState._(
    this.data,
    this.cascades,
    this.camera,
    this.correctedCamera,
    this.sun,
    this.width,
    this.height,
  );
  factory CloudFrameState({
    required Camera camera,
    required Mat4 worldToEcef,
    required Vec3 correctedCamera,
    required Vec3 sun,
    Vec3 moon = const Vec3(0, 0, 1),
    double moonIrradiance = 0,
    double nightIrradiance = 0,
    double bottomRadius = 6360000,
    required double aspect,
    required int width,
    required int height,
    required int shadowSize,
    required int cascadeCount,
    bool shadowsEnabled = true,
    double shadowFarScale = 1,
    int frame = 0,
    Mat4? previousViewProjection,
    Vec3? previousCamera,
  }) {
    if (!moon.isFinite ||
        (moon.length - 1).abs() > 1e-5 ||
        !moonIrradiance.isFinite ||
        moonIrradiance < 0 ||
        !nightIrradiance.isFinite ||
        nightIrradiance < 0 ||
        nightIrradiance > 1) {
      throw ArgumentError('Invalid lunar cloud lighting.');
    }
    final near = camera is PerspectiveCamera
        ? camera.near
        : (camera as OrthographicCamera).near;
    final far = camera is PerspectiveCamera
        ? camera.far
        : (camera as OrthographicCamera).far;
    if (!shadowFarScale.isFinite || shadowFarScale <= 0 || shadowFarScale > 1) {
      throw ArgumentError('Invalid cloud shadow far scale.');
    }
    // Scale the visible depth interval, since globe controls move near into
    // orbit. Grow the span budget with near to avoid one-metre shadow slabs.
    final shadowFar =
        near + math.min((far - near) * shadowFarScale, math.max(200000, near));
    final rotation = Mat4([...worldToEcef.storage.take(12), 0, 0, 0, 1]);
    final inverse = rotation.inverted();
    final worldSun = cloudVector(inverse, sun).normalized();
    final distance = 1e6 + (1e3 - 1e6) * sun.dot(correctedCamera.normalized());
    final maps = shadowsEnabled
        ? CloudShadowCascades.build(
            camera: camera,
            aspect: aspect,
            sunDirection: worldSun,
            count: cascadeCount,
            mapWidth: shadowSize,
            mapHeight: shadowSize,
            maxFar: shadowFar,
            distance: distance,
            splitLambda: .6,
            farScale: 1,
          )
        : CloudShadowCascades.disabled(near: near, far: far);
    final forward = (camera.target - camera.position).normalized();
    Mat4 relative(Mat4 matrix, bool isInverse) {
      final m = matrix.storage.toList();
      if (isInverse) {
        m[12] -= camera.position.x;
        m[13] -= camera.position.y;
        m[14] -= camera.position.z;
      } else {
        for (var row = 0; row < 4; row++) {
          m[12 + row] +=
              m[row] * camera.position.x +
              m[4 + row] * camera.position.y +
              m[8 + row] * camera.position.z;
        }
      }
      return Mat4(m);
    }

    final values = Float32List.fromList([
      ...correctedCamera.storage,
      bottomRadius,
      ...sun.storage,
      near,
      ...forward.storage,
      camera is OrthographicCamera ? 1 : 0,
      width.toDouble(),
      height.toDouble(),
      far,
      (frame % 16777216).toDouble(),
      ...rotation.storage,
      for (var i = 0; i < 4; i++)
        ...(i < maps.cascades.length
                ? relative(maps.cascades[i].inverseMatrix, true)
                : Mat4.identity())
            .storage,
      for (var i = 0; i < 4; i++)
        ...(i < maps.cascades.length
                ? relative(maps.cascades[i].matrix, false)
                : Mat4.identity())
            .storage,
      for (var i = 0; i < 4; i++) ...[
        i < maps.cascades.length ? maps.cascades[i].interval.$1 : 0,
        i < maps.cascades.length ? maps.cascades[i].interval.$2 : 0,
        0,
        0,
      ],
      maps.near,
      maps.far,
      shadowSize.toDouble(),
      shadowSize.toDouble(),
      ...(previousViewProjection ?? camera.viewProjection(aspect)).storage,
      ...(camera.position - (previousCamera ?? camera.position)).storage,
      previousViewProjection == null ? 0 : 1,
      ...moon.storage,
      moonIrradiance,
      nightIrradiance,
      0,
      0,
      0,
    ]);
    if (values.length != 208 || values.any((v) => !v.isFinite)) {
      throw ArgumentError('Invalid cloud frame.');
    }
    return CloudFrameState._(
      values,
      maps,
      camera,
      correctedCamera,
      sun,
      width,
      height,
    );
  }
}

Vec3 cloudVector(Mat4 m, Vec3 p) => Vec3(
  m.storage[0] * p.x + m.storage[4] * p.y + m.storage[8] * p.z,
  m.storage[1] * p.x + m.storage[5] * p.y + m.storage[9] * p.z,
  m.storage[2] * p.x + m.storage[6] * p.y + m.storage[10] * p.z,
);
Vec3 cloudPoint(Mat4 m, Vec3 p) =>
    cloudVector(m, p) + Vec3(m.storage[12], m.storage[13], m.storage[14]);

const cloudFrameWgsl = r'''
struct CloudFrame {
 camera:vec4<f32>,sun:vec4<f32>,forward:vec4<f32>,extent:vec4<f32>,worldToEcef:mat4x4<f32>,
 inverseShadows:array<mat4x4<f32>,4>,shadowMatrices:array<mat4x4<f32>,4>,intervals:array<vec4<f32>,4>,shadowNearFar:vec4<f32>,
 previousViewProjection:mat4x4<f32>,previousCamera:vec4<f32>,
 moon:vec4<f32>,lunar:vec4<f32>,
};
@group(2) @binding(5) var<uniform> cf:CloudFrame;
fn cloudEcef(relative:vec3<f32>)->vec3<f32>{return cf.camera.xyz+(cf.worldToEcef*vec4<f32>(relative,0.)).xyz;}
fn cloudWorld(position:vec3<f32>)->vec3<f32>{return (transpose(cf.worldToEcef)*vec4<f32>(position-cf.camera.xyz,0.)).xyz;}
fn cloudSphere(origin:vec3<f32>,direction:vec3<f32>,radius:f32)->vec2<f32>{
 let b=dot(origin,direction);let c=dot(origin,origin)-radius*radius;let disc=b*b-c;
 if(disc<0.){return vec2<f32>(-1.);}let q=sqrt(disc);return vec2<f32>(-b-q,-b+q);
}
fn cloudJitter(pixel:vec2<f32>)->f32{return fract(52.9829189*fract(dot(pixel,vec2<f32>(.06711056,.00583715))));}
''';
