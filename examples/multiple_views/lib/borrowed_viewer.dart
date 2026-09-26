import 'package:flutter/widgets.dart';
import 'package:flutter_gpu3d/flutter_gpu3d.dart';

/// The caller owns this controller and may mount it again after this view closes.
class BorrowedViewer extends StatelessWidget {
  final SceneController controller;
  const BorrowedViewer({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => SceneView(controller: controller);
}
