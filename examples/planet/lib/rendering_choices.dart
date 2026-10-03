import 'package:flutter/material.dart';

/// Persistent controls avoid popup-route reparenting in native semantics trees.
class RenderingChoices<T extends Enum> extends StatelessWidget {
  final String label;
  final T selected;
  final List<T> choices;
  final String Function(T) choiceLabel;
  final ValueChanged<T>? onChanged;
  const RenderingChoices({
    required ValueKey<String> key,
    required this.label,
    required this.selected,
    required this.choices,
    required this.choiceLabel,
    required this.onChanged,
  }) : super(key: key);

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: const TextStyle(fontSize: 14)),
      Wrap(
        spacing: 4,
        children: [
          for (final choice in choices)
            ChoiceChip(
              key: ValueKey('${(key as ValueKey).value}-${choice.name}'),
              label: Text(
                choiceLabel(choice),
                style: const TextStyle(fontSize: 13),
              ),
              selected: choice == selected,
              onSelected: onChanged == null ? null : (_) => onChanged!(choice),
              visualDensity: VisualDensity.standard,
              materialTapTargetSize: MaterialTapTargetSize.padded,
              showCheckmark: false,
              padding: EdgeInsets.zero,
              labelPadding: const EdgeInsets.symmetric(horizontal: 8),
            ),
        ],
      ),
    ],
  );
}
