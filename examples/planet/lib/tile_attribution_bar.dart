import 'package:flutter/material.dart';
import 'package:html/dom.dart' as dom;
import 'package:html/parser.dart' show parseFragment;
import 'package:url_launcher/url_launcher.dart';
import 'package:zyren_3d_tiles/zyren_3d_tiles.dart';

/// Native credits for the current viewport, with full text available on narrow views.
class TileAttributionBar extends StatelessWidget {
  final bool googleMaps;
  final List<String> tileCredits;
  final List<TileAttribution3D> providerCredits;
  final Future<bool> Function(Uri)? onOpenLink;
  const TileAttributionBar({
    super.key,
    this.googleMaps = false,
    this.tileCredits = const [],
    this.providerCredits = const [],
    this.onOpenLink,
  });

  Future<void> _open(BuildContext context, Uri uri) async {
    var opened = false;
    try {
      opened =
          await (onOpenLink?.call(uri) ??
              launchUrl(uri, mode: LaunchMode.externalApplication));
    } catch (_) {
      /* Keep platform launch failures in the current view. */
    }
    if (!opened && context.mounted) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        const SnackBar(content: Text('The source link could not open.')),
      );
    }
  }

  Uri? _link(String? value) {
    final uri = value == null ? null : Uri.tryParse(value);
    return uri?.scheme == 'https' &&
            uri!.host.isNotEmpty &&
            uri.userInfo.isEmpty
        ? uri
        : null;
  }

  List<Widget> _credit(BuildContext context, TileAttribution3D credit) {
    final result = <Widget>[];
    void nodes(List<dom.Node> values, int depth) {
      if (depth > 64) return;
      for (final node in values) {
        if (node is dom.Text) {
          final text = node.text.replaceAll(RegExp(r'\s+'), ' ').trim();
          if (text.isNotEmpty) result.add(Text(text));
        } else if (node is dom.Element) {
          if ([
            'script',
            'style',
            'iframe',
            'object',
          ].contains(node.localName)) {
            continue;
          }
          if (node.localName == 'img') {
            result.add(_image(node));
          } else if (node.localName == 'a') {
            final uri = _link(node.attributes['href']);
            final image = node.querySelector('img');
            final child = image != null
                ? _image(image)
                : Text(node.text.trim());
            result.add(
              uri == null
                  ? child
                  : TextButton(
                      style: TextButton.styleFrom(
                        minimumSize: const Size(32, 36),
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                      ),
                      onPressed: () => _open(context, uri),
                      child: child,
                    ),
            );
          } else {
            nodes(node.nodes, depth + 1);
          }
        }
      }
    }

    nodes(parseFragment(credit.html).nodes, 0);
    return result;
  }

  Widget _image(dom.Element node) {
    final uri = _link(node.attributes['src']);
    final label = node.attributes['alt'] ?? 'Source attribution';
    if (uri == null) return Text(label);
    return Image.network(
      uri.toString(),
      height: 18,
      fit: BoxFit.contain,
      semanticLabel: label,
      errorBuilder: (_, _, _) => Text(label),
    );
  }

  void _sources(BuildContext context) => showDialog<void>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: const Text('Data sources'),
      content: SingleChildScrollView(
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 13),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (googleMaps)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('Google Maps'),
                ),
              if (tileCredits.isNotEmpty)
                SelectableText(tileCredits.join('; ')),
              for (final credit in providerCredits)
                Wrap(
                  spacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: _credit(dialog, credit),
                ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(dialog),
          child: const Text('Close'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!googleMaps && tileCredits.isEmpty && providerCredits.isEmpty) {
      return const SizedBox.shrink();
    }
    return Material(
      color: const Color(0xff101820),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: DefaultTextStyle.merge(
          style: const TextStyle(fontSize: 12, color: Colors.white),
          child: LayoutBuilder(
            builder: (context, constraints) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (googleMaps)
                      const Text(
                        'Google Maps',
                        style: TextStyle(
                          fontWeight: FontWeight.w500,
                          fontSize: 14,
                        ),
                      ),
                    for (final credit in providerCredits.where(
                      (credit) => !credit.collapsible,
                    ))
                      ..._credit(context, credit),
                    if (constraints.maxWidth >= 680 && tileCredits.isNotEmpty)
                      ConstrainedBox(
                        constraints: BoxConstraints(
                          maxWidth: constraints.maxWidth * .5,
                        ),
                        child: Text(
                          tileCredits.join('; '),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    TextButton(
                      onPressed: () => _sources(context),
                      child: const Text('Data sources'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
