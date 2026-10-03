import 'dart:io';
import 'dart:typed_data';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';

class StudioModelDrop extends StatefulWidget {
  final Widget child;
  final bool enabled;
  final ValueChanged<String> onError;
  final Future<void> Function(List<String>) onFiles;
  const StudioModelDrop({
    super.key,
    required this.child,
    required this.enabled,
    required this.onError,
    required this.onFiles,
  });
  @override
  State<StudioModelDrop> createState() => _StudioModelDropState();
}

class _StudioModelDropState extends State<StudioModelDrop> {
  bool hovering = false;
  @override
  Widget build(BuildContext context) => Platform.isIOS
      ? widget.child
      : DropTarget(
          enable: widget.enabled,
          onDragEntered: (_) => setState(() => hovering = true),
          onDragExited: (_) => setState(() => hovering = false),
          onDragDone: (details) async {
            setState(() => hovering = false);
            final scopes = <Uint8List>[];
            try {
              for (final file in details.files) {
                final bookmark = file.extraAppleBookmark;
                if (bookmark != null &&
                    bookmark.isNotEmpty &&
                    await DesktopDrop.instance
                        .startAccessingSecurityScopedResource(
                          bookmark: bookmark,
                        )) {
                  scopes.add(bookmark);
                }
              }
              await widget.onFiles(
                details.files.map((file) => file.path).toList(),
              );
            } catch (error) {
              widget.onError('$error');
            } finally {
              for (final bookmark in scopes) {
                try {
                  await DesktopDrop.instance
                      .stopAccessingSecurityScopedResource(bookmark: bookmark);
                } catch (error) {
                  widget.onError('Could not release model file access: $error');
                }
              }
            }
          },
          child: Stack(
            fit: StackFit.expand,
            children: [
              widget.child,
              if (hovering && widget.enabled)
                Positioned.fill(
                  child: IgnorePointer(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        color: Theme.of(
                          context,
                        ).colorScheme.primary.withValues(alpha: .12),
                        border: Border.all(
                          color: Theme.of(context).colorScheme.primary,
                          width: 2,
                        ),
                      ),
                      child: Align(
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Chip(
                            label: const Text(
                              'Drop models · GLB, glTF, FBX, OBJ',
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
}
