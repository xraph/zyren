import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_zyren/flutter_zyren.dart';
import 'package:zyren_studio/io.dart';
import 'runtime_scene.dart';

void main() {
  const path = String.fromEnvironment('ZYREN_SCENE');
  runApp(
    MaterialApp(
      home: Scaffold(
        body: path.isEmpty
            ? const ZeroState(
                title: 'Choose an exported scene',
                message:
                    'Pass --dart-define=ZYREN_SCENE=/absolute/path/scene.runtime.zyren.',
              )
            : ZyrenRuntimeScene(
                uri: File(path).uri,
                read: ZyrenFileStore.readBytes,
                runtime: Platform.isAndroid
                    ? const SceneRuntime.nativeAndroid()
                    : const SceneRuntime.nativeMetal(),
              ),
      ),
    ),
  );
}
