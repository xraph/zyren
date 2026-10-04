#include "onnxruntime_c_api.h"

// Pull the official static Apple runtime into a separately bundled dynamic asset.
// Dart still calls its original OrtGetApiBase export through the same asset ID.
extern "C" __attribute__((visibility("default"), used))
const OrtApiBase* zyren_ml_ort_anchor() { return OrtGetApiBase(); }
