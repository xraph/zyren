import 'package:file_selector/file_selector.dart';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_studio/io.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'fixture.dart';
import 'studio_editor.dart';
import 'studio_assets.dart';
import 'studio_theme.dart';

void main() => runApp(const StudioApp());

class StudioApp extends StatefulWidget {
  const StudioApp({super.key});
  @override
  State<StudioApp> createState() => _StudioAppState();
}

class _StudioAppState extends State<StudioApp> {
  ThemeMode mode = ThemeMode.system;
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: studioTheme(Brightness.light),
    darkTheme: studioTheme(Brightness.dark),
    themeMode: mode,
    home: _OpenStudio(
      themeMode: mode,
      onThemeChanged: (value) => setState(() => mode = value),
    ),
  );
}

class _OpenStudio extends StatefulWidget {
  final ThemeMode themeMode;
  final ValueChanged<ThemeMode> onThemeChanged;
  const _OpenStudio({required this.themeMode, required this.onThemeChanged});
  @override
  State<_OpenStudio> createState() => _OpenStudioState();
}

class _OpenStudioState extends State<_OpenStudio> {
  late Future<
    (
      StudioStore,
      StudioDocument,
      String,
      bool,
      StudioPipelineAssets,
      StudioAssetScope,
    )
  >
  _opening = _open();
  int _session = 0;
  final _sceneFolders = <String>{};
  Future<bool> _accessSceneFolder(String path) async {
    if (!Platform.isMacOS) return true;
    final parent = await File(path).parent.resolveSymbolicLinks();
    if (_sceneFolders.contains(parent)) return true;
    final selected = await getDirectoryPath(
      initialDirectory: parent,
      confirmButtonText: 'Use scene folder',
    );
    if (selected == null) return false;
    if (await Directory(selected).resolveSymbolicLinks() != parent) {
      throw StateError(
        'Select the folder containing the .zyren file and its chunks and assets.',
      );
    }
    _sceneFolders.add(parent);
    return true;
  }

  Future<
    (
      StudioStore,
      StudioDocument,
      String,
      bool,
      StudioPipelineAssets,
      StudioAssetScope,
    )
  >
  _open([String? path]) async {
    final directory = await getApplicationSupportDirectory();
    final file = File(path ?? '${directory.path}/studio-scene.zyren');
    final assets = StudioPipelineAssets(
      Directory('${directory.path}/studio-assets'),
    );
    final store = ZyrenFileStore(file, resources: assets.packageResources);
    final document = await store.read();
    if (document != null) {
      final root =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (root['format'] == 'zyren.scene') {
        final stream = await store.openStream();
        try {
          await assets.importPackage(stream);
        } finally {
          await stream.close();
        }
      }
    }
    final legacy = path == null && document == null
        ? await FileStudioStore(
            file: File('${directory.path}/studio-scene.json'),
            documentId: 'studio-scene',
          ).read()
        : null;
    if (path != null && document == null) {
      throw StateError('Scene file was not found.');
    }
    final value = document ?? legacy ?? starterScene();
    final scope = await StudioAssetScope.load(value, assets);
    return (store, value, file.path, document != null, assets, scope);
  }

  @override
  Widget build(BuildContext context) => FutureBuilder(
    future: _opening,
    builder: (context, snapshot) {
      if (snapshot.hasError) {
        return Scaffold(
          body: SafeArea(
            child: ZeroState(
              title: 'Saved scene unavailable',
              message: '${snapshot.error}',
              actionLabel: 'Retry opening',
              onAction: () => setState(() => _opening = _open()),
            ),
          ),
        );
      }
      if (!snapshot.hasData) {
        return const Scaffold(body: Center(child: CircularProgressIndicator()));
      }
      final (store, document, location, saved, assets, scope) = snapshot.data!;
      return StudioEditor(
        key: ValueKey((location, _session)),
        onFileAction: (action, current) async {
          String? path;
          if (action == 'open') {
            path = (await openFile(
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: 'Zyren scenes',
                  extensions: ['zyren', 'json'],
                  uniformTypeIdentifiers: ['public.data'],
                ),
              ],
            ))?.path;
          } else {
            path = (await getSaveLocation(
              suggestedName: action == 'export'
                  ? '${current.id}.runtime.zyren'
                  : action == 'new'
                  ? 'untitled.zyren'
                  : '${current.id}.zyren',
              acceptedTypeGroups: const [
                XTypeGroup(
                  label: 'Zyren scene',
                  extensions: ['zyren'],
                  uniformTypeIdentifiers: ['public.data'],
                ),
              ],
            ))?.path;
          }
          if (path == null) return false;
          if (action != 'open' && !path.toLowerCase().endsWith('.zyren')) {
            path += '.zyren';
          }
          if (action == 'export' && path == location) {
            throw StateError('Choose a different file for the runtime export.');
          }
          if (!await _accessSceneFolder(path)) return false;
          final target = ZyrenFileStore(
            File(path),
            resources: assets.packageResources,
          );
          if (action == 'export') {
            await target.export(current);
            return true;
          }
          if (action == 'new') {
            await target.write(
              StudioDocument(
                id: 'scene-${DateTime.now().microsecondsSinceEpoch}',
                title: File(
                  path,
                ).uri.pathSegments.last.replaceAll('.zyren', ''),
                nodes: const [],
              ),
            );
          } else if (action == 'saveAs') {
            await target.write(current);
          }
          final next = await _open(path);
          if (!mounted) {
            await next.$6.close();
            return false;
          }
          setState(() {
            _session++;
            _opening = Future.value(next);
          });
          return true;
        },
        showAgentInitially: true,
        themeMode: widget.themeMode,
        onThemeChanged: widget.onThemeChanged,
        document: document,
        store: store,
        assetResolver: assets,
        assetScope: scope,
        saveLocation: location,
        initiallySaved: saved,
        enableAgentTransport:
            const bool.fromEnvironment('ZYREN_AI_DX') &&
            const bool.fromEnvironment('ZYREN_AGENT_EDIT'),
        // The built-in chat reviews each mutation. Debug transport is separately opt-in.
        agentScopes: const {
          'studio.select',
          'studio.edit',
          'studio.save',
          'game.read',
          'game.build',
          'ai.inspect',
          'training.inspect',
          'training.start',
          'training.stop',
          'timeline.playback',
          'collaboration.read',
          'collaboration.write',
          'collaboration.camera',
        },
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
    },
  );
}
