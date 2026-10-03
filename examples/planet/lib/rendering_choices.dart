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
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      Text('$label:', style: const TextStyle(fontSize: 14)),
      const SizedBox(width: 4),
      Flexible(
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final choice in choices)
                ChoiceChip(
                  key: ValueKey('${(key as ValueKey).value}-${choice.name}'),
                  label: Text(
                    choiceLabel(choice),
                    style: const TextStyle(fontSize: 12),
                  ),
                  selected: choice == selected,
                  onSelected: onChanged == null
                      ? null
                      : (_) => onChanged!(choice),
                  visualDensity: VisualDensity.compact,
                  showCheckmark: false,
                  padding: EdgeInsets.zero,
                  labelPadding: const EdgeInsets.symmetric(horizontal: 6),
                ),
            ],
          ),
        ),
      ),
    ],
  );
}
