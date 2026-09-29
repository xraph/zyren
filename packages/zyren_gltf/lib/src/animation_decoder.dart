import 'dart:math' as math;
import 'dart:typed_data';
import 'package:zyren/zyren.dart';
import 'accessor.dart';
import 'checked.dart';
import 'limits.dart';

String animationNodeTarget(int index) => 'node:$index';

final class _Sampler {
  final List<double> times;
  final DecodedAccessor output;
  final KeyframeInterpolation interpolation;
  final String path;
  const _Sampler(this.times, this.output, this.interpolation, this.path);
}

List<AnimationClip> decodeAnimations(
  Map<String, Object?> root,
  AccessorReader reader,
  GltfLimits limits,
  List<List<double>> meshWeights,
) {
  final animations = array(field(root, 'animations', const []), 'animations');
  if (root.containsKey('animations') && animations.isEmpty) {
    fail('animations', 'Animation arrays must be nonempty when present.');
  }
  void bound(int count, int maximum, String path) {
    if (count > maximum) {
      fail(
        path,
        'Animation data exceeds its configured limit.',
        AssetLoadError.limitExceeded,
      );
    }
  }

  bound(animations.length, limits.maxAnimations, 'animations');
  final accessors = array(field(root, 'accessors', const []), 'accessors');
  final nodes = array(field(root, 'nodes', const []), 'nodes');
  final clips = <AnimationClip>[];
  var samplerCount = 0, channelCount = 0, samplerKeys = 0, channelKeys = 0;
  for (var a = 0; a < animations.length; a++) {
    final path = 'animations[$a]', animation = object(animations[a], path);
    final rawSamplers = array(animation['samplers'], '$path.samplers');
    final channels = array(animation['channels'], '$path.channels');
    if (rawSamplers.isEmpty || channels.isEmpty) {
      fail(path, 'Animations need nonempty samplers and channels.');
    }
    bound(
      samplerCount += rawSamplers.length,
      limits.maxAnimationChannels,
      '$path.samplers',
    );
    bound(
      channelCount += channels.length,
      limits.maxAnimationChannels,
      '$path.channels',
    );
    final samplers = <_Sampler>[];
    for (var s = 0; s < rawSamplers.length; s++) {
      final sp = '$path.samplers[$s]', sampler = object(rawSamplers[s], sp);
      final inputIndex = index(sampler['input'], accessors.length, '$sp.input');
      final outputIndex = index(
        sampler['output'],
        accessors.length,
        '$sp.output',
      );
      final interpolation = switch (field(sampler, 'interpolation', 'LINEAR')) {
        'STEP' => KeyframeInterpolation.step,
        'LINEAR' => KeyframeInterpolation.linear,
        'CUBICSPLINE' => KeyframeInterpolation.cubicSpline,
        _ => fail('$sp.interpolation', 'Unknown animation interpolation mode.'),
      };
      final inputMeta = object(accessors[inputIndex], 'accessors[$inputIndex]');
      final count = integer(
        inputMeta['count'],
        'accessors[$inputIndex].count',
        min: 1,
      );
      bound(samplerKeys += count, limits.maxAnimationKeyframes, '$sp.input');
      if (interpolation == KeyframeInterpolation.cubicSpline && count < 2) {
        fail('$sp.input', 'Cubic interpolation requires at least two keys.');
      }
      final input = reader.read(inputIndex, usage: AccessorUsage.animation);
      if (input.type != 'SCALAR' ||
          input.componentType != 5126 ||
          input.normalized) {
        fail('$sp.input', 'Animation times require float scalar accessors.');
      }
      reader.budget.reserve(count * 8, '$sp.input');
      final times = <double>[];
      var previous = -1.0;
      for (final value in input.values) {
        final t = value.toDouble();
        if (t < 0 || t <= previous) {
          fail(
            '$sp.input',
            'Animation times must be nonnegative and strictly increasing.',
          );
        }
        if (t > 1e9) {
          fail(
            '$sp.input',
            'Animation time exceeds 1e9 seconds.',
            AssetLoadError.limitExceeded,
          );
        }
        times.add(t);
        previous = t;
      }
      for (final (key, expected) in [
        ('min', times.first),
        ('max', times.last),
      ]) {
        final declared = numbers(
          inputMeta[key],
          1,
          'accessors[$inputIndex].$key',
        );
        if (Float32List.fromList(declared).single != expected) {
          fail(
            'accessors[$inputIndex].$key',
            'Time bounds do not match the decoded keys.',
          );
        }
      }
      final output = reader.read(outputIndex, usage: AccessorUsage.animation);
      samplers.add(_Sampler(times, output, interpolation, sp));
    }
    final tracks = <KeyframeTrack>[];
    final targets = <(int, String)>{};
    var duration = 0.0;
    for (var c = 0; c < channels.length; c++) {
      final cp = '$path.channels[$c]', channel = object(channels[c], cp);
      final sampler =
          samplers[index(channel['sampler'], samplers.length, '$cp.sampler')];
      final target = object(channel['target'], '$cp.target');
      final property = string(target['path'], '$cp.target.path');
      final weights = property == 'weights';
      if (!['translation', 'rotation', 'scale', 'weights'].contains(property)) {
        fail('$cp.target.path', 'Unknown animation target path.');
      }
      final node = target.containsKey('node')
          ? index(target['node'], nodes.length, '$cp.target.node')
          : null;
      if (node != null) {
        if (!targets.add((node, property))) {
          fail(
            '$cp.target',
            'An animation cannot target the same node property twice.',
          );
        }
        if (!weights &&
            object(nodes[node], 'nodes[$node]').containsKey('matrix')) {
          fail(
            '$cp.target.node',
            'Animated nodes must use TRS instead of a matrix.',
          );
        }
      }
      final output = sampler.output, op = '${sampler.path}.output';
      final rotation = property == 'rotation';
      final float = output.componentType == 5126 && !output.normalized;
      final normalizedInteger =
          [5120, 5121, 5122, 5123].contains(output.componentType) &&
          output.normalized;
      if (output.type !=
              (weights
                  ? 'SCALAR'
                  : rotation
                  ? 'VEC4'
                  : 'VEC3') ||
          !(float || ((rotation || weights) && normalizedInteger))) {
        fail(
          op,
          weights
              ? 'Morph weights require float or normalized integer SCALAR accessors.'
              : rotation
              ? 'Rotations require float or normalized integer VEC4 accessors.'
              : 'Translation and scale require float VEC3 accessors.',
        );
      }
      bound(
        channelKeys += sampler.times.length,
        limits.maxAnimationKeyframes,
        cp,
      );
      final cubic = sampler.interpolation == KeyframeInterpolation.cubicSpline;
      final stride = cubic ? 3 : 1;
      var components = output.components;
      if (weights) {
        if (node == null) continue;
        final metadata = object(nodes[node], 'nodes[$node]');
        if (!metadata.containsKey('mesh')) {
          fail(
            '$cp.target.node',
            'Weight animation requires a mesh with morph targets.',
          );
        }
        final mesh = index(
          metadata['mesh'],
          meshWeights.length,
          'nodes[$node].mesh',
        );
        components = meshWeights[mesh].length;
        if (components == 0) {
          fail('$cp.target.node', 'Weight animation requires morph targets.');
        }
      }
      if (output.count !=
          sampler.times.length * stride * (weights ? components : 1)) {
        fail(
          op,
          'Output count does not match keyframes and target components.',
        );
      }
      if (weights && sampler.times.length * components > 1000000) {
        fail(
          op,
          'Morph animation exceeds one million key components.',
          AssetLoadError.limitExceeded,
        );
      }
      final data = output.values;
      for (var k = 0; k < sampler.times.length; k++) {
        final at = (k * stride + (cubic ? 1 : 0)) * components;
        if (rotation) {
          var norm = 0.0;
          for (var j = 0; j < 4; j++) {
            norm += data[at + j] * data[at + j];
          }
          final tolerance = [5120, 5121].contains(output.componentType)
              ? .02
              : normalizedInteger
              ? .0002
              : .0001;
          if ((norm - 1).abs() > tolerance) {
            fail(op, 'Rotation keys must be unit quaternions.');
          }
        } else if (property == 'scale' &&
            (data[at] == 0 || data[at + 1] == 0 || data[at + 2] == 0)) {
          fail(
            op,
            'Singular scale keys are not yet supported.',
            AssetLoadError.unsupportedFeature,
          );
        }
      }
      // A missing node is legal for extension channels. It has no core target.
      if (node == null) continue;
      duration = math.max(duration, sampler.times.last);
      // Bound expanded immutable key objects and lists, including copied times.
      reader.budget.reserve(
        sampler.times.length *
            (16 +
                stride *
                    (components * (weights ? 16 : 8) + (weights ? 64 : 40))),
        cp,
      );
      final id = animationNodeTarget(node);
      final keyOffset = cubic ? 1 : 0;
      List<Vec3> vectors(int offset) => [
        for (var k = 0; k < sampler.times.length; k++)
          Vec3(
            data[(k * stride + offset) * 3].toDouble(),
            data[(k * stride + offset) * 3 + 1].toDouble(),
            data[(k * stride + offset) * 3 + 2].toDouble(),
          ),
      ];
      List<Quat> quaternions(int offset) => [
        for (var k = 0; k < sampler.times.length; k++)
          Quat(
            data[(k * stride + offset) * 4].toDouble(),
            data[(k * stride + offset) * 4 + 1].toDouble(),
            data[(k * stride + offset) * 4 + 2].toDouble(),
            data[(k * stride + offset) * 4 + 3].toDouble(),
          ),
      ];
      if (weights) {
        List<List<double>> vectors(int offset) => [
          for (var k = 0; k < sampler.times.length; k++)
            [
              for (var j = 0; j < components; j++)
                data[(k * stride + offset) * components + j].toDouble(),
            ],
        ];
        final values = vectors(keyOffset);
        if (values.any((v) => v.any((w) => w.abs() > 1e6))) {
          fail(
            op,
            'Morph weight magnitude exceeds 1e6.',
            AssetLoadError.limitExceeded,
          );
        }
        tracks.add(
          MorphWeightKeyframeTrack(
            target: id,
            times: sampler.times,
            values: values,
            interpolation: sampler.interpolation,
            inTangents: cubic ? vectors(0) : null,
            outTangents: cubic ? vectors(2) : null,
          ),
        );
      } else if (rotation) {
        tracks.add(
          QuaternionKeyframeTrack(
            target: id,
            times: sampler.times,
            values: quaternions(keyOffset),
            interpolation: sampler.interpolation,
            inTangents: cubic ? quaternions(0) : null,
            outTangents: cubic ? quaternions(2) : null,
          ),
        );
      } else {
        final create = property == 'translation'
            ? VectorKeyframeTrack.position
            : VectorKeyframeTrack.scale;
        tracks.add(
          create(
            target: id,
            times: sampler.times,
            values: vectors(keyOffset),
            interpolation: sampler.interpolation,
            inTangents: cubic ? vectors(0) : null,
            outTangents: cubic ? vectors(2) : null,
          ),
        );
      }
    }
    clips.add(
      AnimationClip(
        name: animation.containsKey('name')
            ? string(animation['name'], '$path.name')
            : null,
        tracks: tracks,
        durationSeconds: duration,
      ),
    );
  }
  return List.unmodifiable(clips);
}
