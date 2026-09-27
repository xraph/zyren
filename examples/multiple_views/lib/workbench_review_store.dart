import 'dart:io';
import 'package:zyren_engineering/zyren_engineering.dart';
import 'package:zyren_engineering/file_store.dart';
import 'package:path_provider/path_provider.dart';

/// The demo's private review file. Tests inject their own store.
class WorkbenchReviewStore implements EngineeringStore {
  Future<FileEngineeringStore> _file() async {
    final directory = await getApplicationSupportDirectory();
    // Keep the original directory so existing review files remain available.
    return FileEngineeringStore(
      File('${directory.path}/gpu3d-workbench/pump-review-v1.json'),
    );
  }

  @override
  Future<String?> read() async => (await _file()).read();
  @override
  Future<void> write(String document) async => (await _file()).write(document);
}
