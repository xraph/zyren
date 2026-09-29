import 'package:flutter/widgets.dart';
import 'package:flutter_zyren/flutter_zyren.dart';

/// The caller owns this controller and may mount it again after this view closes.
class BorrowedViewer extends StatelessWidget {
  final SceneController controller;
  const BorrowedViewer({super.key, required this.controller});
  @override
  Widget build(BuildContext context) => SceneView(controller: controller);
}
