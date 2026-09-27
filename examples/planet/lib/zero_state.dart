import 'package:flutter/material.dart';
import 'package:flutter_gpu3d/widgets.dart' as gpu3d;

class ZeroState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ZeroState({super.key, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) => gpu3d.ZeroState(
    title: 'The native renderer could not start',
    message: '$error',
    actionLabel: 'Retry renderer',
    onAction: onRetry,
  );
}
