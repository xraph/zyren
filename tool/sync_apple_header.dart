import 'dart:io';

/// Run from the workspace root after changing the native surface ABI.
void main() {
  File(
    'packages/gpu3d_native/native/include/gpu3d.h',
  ).copySync('packages/flutter_gpu3d/darwin/Classes/gpu3d.h');
}
