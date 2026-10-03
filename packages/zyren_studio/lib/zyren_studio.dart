library;

import 'dart:convert';
import 'package:zyren/zyren.dart';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_tools/zyren_tools.dart';

part 'src/document.dart';
part 'src/authoring_data.dart';
part 'src/scene.dart';
part 'src/assets.dart';
part 'src/history.dart';
part 'src/authoring.dart';
part 'src/modeling.dart';

/// The host chooses a storage location and keeps credentials outside the scene.
abstract interface class StudioStore {
  Future<StudioDocument?> read();
  Future<void> write(StudioDocument document);
}
