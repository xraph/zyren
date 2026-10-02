library;

import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_tools/zyren_tools.dart';

part 'src/document.dart';
part 'src/scene.dart';

/// The host chooses a storage location and keeps credentials outside the scene.
abstract interface class StudioStore {
  Future<StudioDocument?> read();
  Future<void> write(StudioDocument document);
}
