import 'dart:io';

/// Run from the workspace root after changing the native surface ABI.
void main() {
  File(
    'packages/zyren_native/native/include/zyren.h',
  ).copySync('packages/flutter_zyren/darwin/Classes/zyren.h');
}
