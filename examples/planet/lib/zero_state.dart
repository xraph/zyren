import 'package:flutter/material.dart';
import 'package:flutter_zyren/widgets.dart' as zyren;

class RendererZeroState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const RendererZeroState({super.key, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) => zyren.ZeroState(
    title: 'The native renderer could not start',
    message: '$error',
    actionLabel: 'Retry renderer',
    onAction: onRetry,
  );
}
