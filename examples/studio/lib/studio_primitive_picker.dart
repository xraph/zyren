import 'package:flutter/material.dart';
import 'package:zyren_studio/zyren_studio.dart';

Future<StudioNodeKind?> showStudioPrimitivePicker(BuildContext context) =>
    showDialog<StudioNodeKind>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add primitive'),
        content: SizedBox(
          width: 320,
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final item in const [
                (StudioNodeKind.box, 'Box', Icons.crop_square),
                (StudioNodeKind.sphere, 'Sphere', Icons.circle_outlined),
                (
                  StudioNodeKind.cylinder,
                  'Cylinder',
                  Icons.view_in_ar_outlined,
                ),
                (StudioNodeKind.cone, 'Cone', Icons.change_history),
                (StudioNodeKind.torus, 'Torus', Icons.donut_large),
                (StudioNodeKind.plane, 'Plane', Icons.layers_outlined),
              ])
                SizedBox(
                  width: 100,
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(context, item.$1),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(item.$3, size: 22),
                          const SizedBox(height: 6),
                          Text(item.$2),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
