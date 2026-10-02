import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_studio/zyren_studio.dart';

StudioDocument starterScene() => StudioDocument(
  id: 'studio-scene',
  title: 'Assembly study',
  nodes: [
    StudioNode(id: 'assembly', label: 'Assembly', kind: StudioNodeKind.group),
    StudioNode(
      id: 'base',
      label: 'Base',
      parentId: 'assembly',
      sourceId: 'part:base',
      size: const Vec3(3, .35, 2),
      position: const Vec3(0, -.8, 0),
      color: 0x617c91,
    ),
    StudioNode(
      id: 'block',
      label: 'Block',
      parentId: 'assembly',
      sourceId: 'part:block',
      size: const Vec3(1, 1.2, 1),
      position: const Vec3(0, 0, 0),
      color: 0x78dace,
    ),
  ],
  review: EngineeringDocument(
    id: 'studio-scene',
    objects: [
      EngineeringObject(
        id: 'part:base',
        label: 'Base',
        properties: {'origin': 'Studio fixture'},
      ),
      EngineeringObject(
        id: 'part:block',
        label: 'Block',
        properties: {'origin': 'Studio fixture'},
      ),
    ],
  ),
);
