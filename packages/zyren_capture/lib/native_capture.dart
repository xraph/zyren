import 'dart:io';
import 'package:zyren/zyren.dart';
import 'package:zyren_native/zyren_native.dart';
import 'zyren_capture.dart';
export 'zyren_capture.dart';

CaptureManager nativeCapture({
  required Scene scene,
  required String sceneId,
  required String documentId,
  required Directory outputParent,
}) => CaptureManager(
  scene: scene,
  sceneId: sceneId,
  documentId: documentId,
  outputParent: outputParent,
  openBackend: NativeBackend.create,
);
