import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

enum _Panel { controls, info, closed }

/// Keeps the scene mounted at the same size while its controls are opened.
class PhotorealisticLayout extends StatefulWidget {
  final String title;
  final Widget scene;
  final Widget controls;
  final Widget info;
  final Widget? attribution;
  final bool controlsNeedAttention;
  final bool infoNeedsAttention;

  const PhotorealisticLayout({
    super.key,
    this.title = 'Photorealistic 3D',
    required this.scene,
    required this.controls,
    required this.info,
    this.attribution,
    this.controlsNeedAttention = false,
    this.infoNeedsAttention = false,
  });

  @override
  State<PhotorealisticLayout> createState() => _PhotorealisticLayoutState();
}

class _PhotorealisticLayoutState extends State<PhotorealisticLayout> {
  _Panel? _selection;
  final _controlsScroll = ScrollController();
  final _infoScroll = ScrollController();
  final _controlsFocus = FocusNode();
  final _infoFocus = FocusNode();

  @override
  void dispose() {
    _controlsScroll.dispose();
    _infoScroll.dispose();
    _controlsFocus.dispose();
    _infoFocus.dispose();
    super.dispose();
  }

  void _close(_Panel panel) {
    setState(() => _selection = _Panel.closed);
    (panel == _Panel.controls ? _controlsFocus : _infoFocus).requestFocus();
  }

  void _toggle(_Panel target, _Panel active) {
    (target == _Panel.controls ? _controlsFocus : _infoFocus).requestFocus();
    setState(() => _selection = target == active ? _Panel.closed : target);
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, bounds) {
            final wide = bounds.maxWidth >= 1000;
            final sidePanel = bounds.maxWidth >= 600;
            final panel =
                _selection ?? (wide ? _Panel.controls : _Panel.closed);
            final open = panel != _Panel.closed;
            final controls = panel == _Panel.controls;
            final colors = Theme.of(context).colorScheme;
            final scroll = controls ? _controlsScroll : _infoScroll;
            final panelHeight = math.min(
              math.max(220.0, bounds.maxHeight * .55),
              math.max(0.0, bounds.maxHeight - 72),
            );
            return CallbackShortcuts(
              bindings: {
                if (open)
                  const SingleActivator(LogicalKeyboardKey.escape): () =>
                      _close(panel),
              },
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Positioned.fill(
                    child: KeyedSubtree(
                      key: const ValueKey('photorealistic-scene'),
                      child: widget.scene,
                    ),
                  ),
                  Positioned(
                    top: 0,
                    left: 0,
                    right: 0,
                    child: Material(
                      color: colors.surface,
                      child: SizedBox(
                        height: 56,
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Row(
                            children: [
                              if (Navigator.canPop(context))
                                IconButton(
                                  tooltip: 'All scenes',
                                  visualDensity: VisualDensity.standard,
                                  constraints: const BoxConstraints(
                                    minWidth: 48,
                                    minHeight: 48,
                                  ),
                                  onPressed: () => Navigator.pop(context),
                                  icon: const Icon(Icons.arrow_back),
                                ),
                              Expanded(
                                child: Text(
                                  widget.title,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    fontSize: 18,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.standard,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                key: const ValueKey('controls-toggle'),
                                focusNode: _controlsFocus,
                                tooltip: controls
                                    ? 'Hide controls'
                                    : 'Show controls',
                                isSelected: controls,
                                icon: Badge(
                                  isLabelVisible: widget.controlsNeedAttention,
                                  child: const Icon(Icons.tune),
                                ),
                                onPressed: () =>
                                    _toggle(_Panel.controls, panel),
                              ),
                              IconButton(
                                visualDensity: VisualDensity.standard,
                                constraints: const BoxConstraints(
                                  minWidth: 48,
                                  minHeight: 48,
                                ),
                                key: const ValueKey('info-toggle'),
                                focusNode: _infoFocus,
                                tooltip: panel == _Panel.info
                                    ? 'Hide info'
                                    : 'Show info',
                                isSelected: panel == _Panel.info,
                                icon: Badge(
                                  isLabelVisible: widget.infoNeedsAttention,
                                  child: const Icon(Icons.info_outline),
                                ),
                                onPressed: () => _toggle(_Panel.info, panel),
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
                  if (open)
                    Positioned(
                      top: sidePanel ? 68 : null,
                      bottom: sidePanel ? null : 12,
                      left: 12,
                      right: sidePanel ? null : 12,
                      width: sidePanel ? 320 : null,
                      child: ConstrainedBox(
                        constraints: BoxConstraints(
                          maxHeight: sidePanel
                              ? math.max(0, bounds.maxHeight - 80)
                              : panelHeight,
                        ),
                        child: Material(
                          key: ValueKey(
                            controls ? 'controls-panel' : 'info-panel',
                          ),
                          color: colors.surface,
                          elevation: 4,
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(12),
                            side: BorderSide(color: colors.outlineVariant),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: FocusTraversalGroup(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Padding(
                                  padding: const EdgeInsets.only(
                                    left: 16,
                                    right: 4,
                                  ),
                                  child: Row(
                                    children: [
                                      Expanded(
                                        child: Semantics(
                                          header: true,
                                          child: Text(
                                            controls
                                                ? 'Scene controls'
                                                : 'Scene info',
                                            style: Theme.of(
                                              context,
                                            ).textTheme.titleSmall,
                                          ),
                                        ),
                                      ),
                                      IconButton(
                                        visualDensity: VisualDensity.standard,
                                        constraints: const BoxConstraints(
                                          minWidth: 48,
                                          minHeight: 48,
                                        ),
                                        key: const ValueKey('panel-close'),
                                        tooltip: controls
                                            ? 'Close controls'
                                            : 'Close info',
                                        icon: const Icon(Icons.close, size: 20),
                                        onPressed: () => _close(panel),
                                      ),
                                    ],
                                  ),
                                ),
                                const Divider(height: 1),
                                Flexible(
                                  child: Scrollbar(
                                    controller: scroll,
                                    child: SingleChildScrollView(
                                      key: ValueKey(
                                        controls
                                            ? 'controls-scroll'
                                            : 'info-scroll',
                                      ),
                                      controller: scroll,
                                      padding: const EdgeInsets.all(12),
                                      child: controls
                                          ? widget.controls
                                          : widget.info,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            );
          },
        ),
      ),
      if (widget.attribution case final attribution?)
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 80),
          child: SingleChildScrollView(child: attribution),
        ),
    ],
  );
}
