import 'dart:typed_data';
import 'fixtures.dart';

// Authored one-pixel images: base RGBA, packed occlusion/roughness/metallic,
// tangent-space +Z normal, emission, and tangent-space +Y normal.
const pbrImages = [
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNocFBoAAADhQFhC+q+qAAAAABJRU5ErkJggg==',
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNg+M/wHwAEAQH/cetH5QAAAABJRU5ErkJggg==',
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNoaPj/HwAGggL/s75RMwAAAABJRU5ErkJggg==',
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNwaGD4DwADhAHAE8vxAAAAAABJRU5ErkJggg==',
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNo+N/wHwAHAQL/Jx/KFwAAAABJRU5ErkJggg==',
];

Uint8List pbrModel({
  Map<String, Object?> material = const {
    'pbrMetallicRoughness': {
      'baseColorFactor': [.5, .5, .5, 1],
      'metallicFactor': 0,
    },
  },
  Map<String, Object?> light = const {'type': 'directional'},
  Map<String, Object?> lightNode = const {},
  double handedness = 1,
  bool unlit = false,
  List<double>? colors,
  int colorComponentType = 5126,
}) => primitiveModel(
  indices: [0, 1, 2, 0, 2, 3],
  normals: [
    for (var i = 0; i < 4; i++) ...[0, 0, 1],
  ],
  tangents: [
    for (var i = 0; i < 4; i++) ...[1, 0, 0, handedness],
  ],
  byteUvs: true,
  colors: colors,
  colorComponentType: colorComponentType,
  changes: {
    'extensionsUsed': ['KHR_lights_punctual', if (unlit) 'KHR_materials_unlit'],
    'extensionsRequired': [
      'KHR_lights_punctual',
      if (unlit) 'KHR_materials_unlit',
    ],
    'extensions': {
      'KHR_lights_punctual': {
        'lights': [light],
      },
    },
    'materials': [
      {
        ...material,
        if (unlit) 'extensions': {'KHR_materials_unlit': <String, Object?>{}},
      },
    ],
    'images': [
      for (final image in pbrImages) {'uri': 'data:image/png;base64,$image'},
    ],
    'textures': [
      for (var i = 0; i < pbrImages.length; i++) {'source': i, 'sampler': 0},
    ],
    'samplers': [
      {'minFilter': 9728, 'magFilter': 9728, 'wrapS': 33071, 'wrapT': 33071},
    ],
    'nodes': [
      {'mesh': 0},
      {
        ...lightNode,
        'extensions': {
          'KHR_lights_punctual': {'light': 0},
        },
      },
    ],
    'scenes': [
      {
        'nodes': [0, 1],
      },
    ],
  },
);
