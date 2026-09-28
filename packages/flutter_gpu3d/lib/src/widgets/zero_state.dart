import 'package:flutter/material.dart';

/// Shared empty-state treatment for scene tools and viewers.
class ZeroState extends StatelessWidget {
  final String title, message;
  final Widget? action;
  const ZeroState({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topLeft,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.view_in_ar_outlined, size: 32),
            const SizedBox(height: 8),
            Text(title, style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(message),
            if (action != null) ...[const SizedBox(height: 8), action!],
          ],
        ),
      ),
    ),
  );
}
