import 'package:flutter/material.dart';

class ZeroState extends StatelessWidget {
  final Object error;
  final VoidCallback onRetry;
  const ZeroState({super.key, required this.error, required this.onRetry});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.all(24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(
              Icons.view_in_ar_outlined,
              size: 56,
              color: Color(0xff78dace),
            ),
            const SizedBox(height: 12),
            const Text(
              'The native renderer could not start',
              style: TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 8),
            Text('$error'),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('Retry renderer'),
            ),
          ],
        ),
      ),
    ),
  );
}
