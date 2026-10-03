import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:path_provider/path_provider.dart';
import 'package:zyren_studio/io.dart';
import 'package:zyren_studio/zyren_studio.dart';
import 'fixture.dart';
import 'studio_editor.dart';
import 'studio_assets.dart';

void main() => runApp(const StudioApp());

class StudioApp extends StatelessWidget {
  const StudioApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      useMaterial3: true,
      visualDensity: VisualDensity.compact,
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xff78dace),
        brightness: Brightness.dark,
      ),
    ),
    home: const _OpenStudio(),
  );
}

class _OpenStudio extends StatefulWidget {
  const _OpenStudio();
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
  _open() async {
    final directory = await getApplicationSupportDirectory();
    final file = File('${directory.path}/studio-scene.json');
    final store = FileStudioStore(file: file, documentId: 'studio-scene');
    final document = await store.read();
    final assets = StudioPipelineAssets(
      Directory('${directory.path}/studio-assets'),
    );
    final value = document ?? starterScene();
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
        document: document,
        store: store,
        assetResolver: assets,
        assetScope: scope,
        saveLocation: location,
        initiallySaved: saved,
        enableAgentTransport: const bool.fromEnvironment('ZYREN_AI_DX'),
        agentScopes: const bool.fromEnvironment('ZYREN_AGENT_EDIT')
            ? const {
                'studio.select',
                'studio.edit',
                'timeline.playback',
                'collaboration.read',
                'collaboration.write',
                'collaboration.camera',
              }
            : const {},
        runtime: Platform.isAndroid
            ? const SceneRuntime.nativeAndroid()
            : const SceneRuntime.nativeMetal(),
      );
    },
  );
}
