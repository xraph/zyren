import 'package:zyren/zyren.dart';
import 'package:zyren_studio/zyren_studio.dart';

void main() {
  var document = StudioDocument(
    id: 'assembly-study',
    title: 'Assembly study',
    nodes: [StudioNode(id: 'block', label: 'Block')],
  );
  document = StudioAuthoring.putKeyframe(
    document,
    clipId: 'move',
    nodeId: 'block',
    durationMicroseconds: 1000000,
    frame: StudioKeyframe(microseconds: 0, position: Vec3.zero),
  );
  document = StudioAuthoring.putKeyframe(
    document,
    clipId: 'move',
    nodeId: 'block',
    durationMicroseconds: 1000000,
    frame: StudioKeyframe(microseconds: 1000000, position: const Vec3(2, 0, 0)),
  );
  final restored = StudioDocument.decode(document.encode());
  print(
    '${restored.title}: ${restored.nodes.length} node, ${restored.clips.length} clip',
  );
}
