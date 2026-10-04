#include "zyren_ml.h"
#include "onnxruntime_c_api.h"
#include <atomic>
#include <cstring>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kMaxTensorBytes = 64 * 1024 * 1024;
constexpr size_t kMaxModelBytes = 64 * 1024 * 1024;
constexpr size_t kMaxTensors = 64;
std::atomic<int64_t> sessions{0}, results{0};
std::atomic<int64_t> completed_runs{0};
std::atomic<int64_t> active_runs{0};
struct ActiveRun {
  ActiveRun() { ++active_runs; }
  ~ActiveRun() { --active_runs; }
};

void message(char* dest, size_t size, const char* text) noexcept {
  if (dest && size) {
    std::strncpy(dest, text, size - 1);
    dest[size - 1] = '\0';
  }
}
void check(const OrtApi* api, OrtStatus* status) {
  if (!status) return;
  // Release status even if copying the error string fails to allocate.
  const auto release = [api](OrtStatus* value) { api->ReleaseStatus(value); };
  std::unique_ptr<OrtStatus, decltype(release)> owned(status, release);
  const std::string error(api->GetErrorMessage(status));
  throw std::runtime_error(error);
}
size_t elementSize(int dtype) {
  switch (dtype) {
    case 1: return 4;
    case 7: return 8;
    case 9: return 1;
    default: throw std::invalid_argument("Unsupported tensor dtype.");
  }
}
size_t tensorBytes(const int64_t* dims, size_t rank, int dtype) {
  if (rank > 8 || (rank && !dims)) throw std::invalid_argument("Invalid tensor rank.");
  size_t bytes = elementSize(dtype);
  for (size_t i = 0; i < rank; ++i) {
    if (dims[i] <= 0 || static_cast<uint64_t>(dims[i]) > kMaxTensorBytes / bytes)
      throw std::invalid_argument("Tensor shape exceeds byte budget.");
    bytes *= static_cast<size_t>(dims[i]);
  }
  return bytes;
}
}

struct ZyrenMlSession {
  const OrtApi* api = nullptr;
  OrtEnv* env = nullptr;
  OrtSessionOptions* options = nullptr;
  OrtSession* session = nullptr;
  OrtMemoryInfo* memory = nullptr;
  bool counted = false;
  bool profiling = false;
  ~ZyrenMlSession() {
    if (!api) return;
    if (session) api->ReleaseSession(session);
    if (memory) api->ReleaseMemoryInfo(memory);
    if (options) api->ReleaseSessionOptions(options);
    if (env) api->ReleaseEnv(env);
    if (counted) --sessions;
  }
};
struct ZyrenMlResult {
  const OrtApi* api;
  std::vector<OrtValue*> values;
  std::vector<std::vector<int64_t>> dimensions;
  bool counted = false;
  explicit ZyrenMlResult(const OrtApi* api, size_t count)
      : api(api), values(count, nullptr), dimensions(count) {}
  ~ZyrenMlResult() {
    for (auto value : values) if (value) api->ReleaseValue(value);
    if (counted) --results;
  }
};
namespace {
struct InputValues {
  const OrtApi* api;
  std::vector<OrtValue*> values;
  InputValues(const OrtApi* api, size_t count) : api(api), values(count, nullptr) {}
  ~InputValues() { for (auto value : values) if (value) api->ReleaseValue(value); }
};
struct TensorInfo {
  const OrtApi* api;
  OrtTensorTypeAndShapeInfo* value = nullptr;
  ~TensorInfo() { if (value) api->ReleaseTensorTypeAndShapeInfo(value); }
};
}

extern "C" {
int32_t zyren_ml_open(const void* api_base, const void* model, size_t length,
                     ZyrenMlSession** out, char* error, size_t error_length) {
  return zyren_ml_open_provider(api_base, model, length, 0, nullptr, out,
                                error, error_length);
}

int32_t zyren_ml_open_provider(const void* api_base, const void* model, size_t length,
                     int32_t provider, const char* profile_prefix,
                     ZyrenMlSession** out, char* error, size_t error_length) {
  if (out) *out = nullptr;
  if (provider != 0 && provider != 1) {
    message(error, error_length, "Unsupported execution provider.");
    return ZYREN_ML_UNSUPPORTED;
  }
#if !defined(__APPLE__)
  if (provider == 1 || profile_prefix) {
    message(error, error_length, "CoreML probes require an Apple target.");
    return ZYREN_ML_UNSUPPORTED;
  }
#endif
  if (!api_base || !model || !out || !length || length > kMaxModelBytes) {
    message(error, error_length, "Invalid model or runtime pointer.");
    return ZYREN_ML_INVALID;
  }
  try {
    const auto base = static_cast<const OrtApiBase*>(api_base);
    const auto api = base->GetApi(ORT_API_VERSION);
    if (!api) {
      message(error, error_length, "ONNX Runtime C API version is unsupported.");
      return ZYREN_ML_UNSUPPORTED;
    }
    auto state = std::make_unique<ZyrenMlSession>();
    state->api = api;
    check(api, api->CreateEnv(ORT_LOGGING_LEVEL_ERROR, "zyren_ml", &state->env));
    check(api, api->DisableTelemetryEvents(state->env));
    check(api, api->CreateSessionOptions(&state->options));
    check(api, api->SetIntraOpNumThreads(state->options, 1));
    check(api, api->SetInterOpNumThreads(state->options, 1));
    check(api, api->SetSessionGraphOptimizationLevel(state->options, ORT_ENABLE_BASIC));
    if (provider == 1) {
      char** available = nullptr;
      int count = 0;
      check(api, api->GetAvailableProviders(&available, &count));
      const auto release = [api, count](char** value) {
        if (auto status = api->ReleaseAvailableProviders(value, count)) api->ReleaseStatus(status);
      };
      std::unique_ptr<char*, decltype(release)> inventory(available, release);
      bool found = false;
      for (int i = 0; i < count; ++i)
        found |= std::strcmp(available[i], "CoreMLExecutionProvider") == 0;
      if (!found) {
        message(error, error_length, "Pinned runtime has no CoreML execution provider.");
        return ZYREN_ML_UNSUPPORTED;
      }
      const char* keys[] = {"ModelFormat", "MLComputeUnits", "RequireStaticInputShapes",
                            "EnableOnSubgraphs"};
      const char* values[] = {"MLProgram", "ALL", "0", "0"};
      check(api, api->SessionOptionsAppendExecutionProvider(state->options,
                                                           "CoreML", keys, values, 4));
      check(api, api->AddSessionConfigEntry(state->options,
                                            "session.disable_cpu_ep_fallback", "1"));
    }
#if defined(__APPLE__)
    if (profile_prefix) {
      const size_t size = std::strlen(profile_prefix);
      if (!size || size > 2048) throw std::invalid_argument("Invalid profiling prefix.");
      check(api, api->EnableProfiling(state->options, profile_prefix));
      state->profiling = true;
    }
#endif
    check(api, api->CreateSessionFromArray(state->env, model, length,
                                         state->options, &state->session));
    check(api, api->CreateCpuMemoryInfo(OrtArenaAllocator, OrtMemTypeDefault, &state->memory));
    state->counted = true;
    ++sessions;
    *out = state.release();
    return ZYREN_ML_OK;
  } catch (const std::exception& e) {
    message(error, error_length, e.what());
  } catch (...) {
    message(error, error_length, "Unknown native model load failure.");
  }
  return ZYREN_ML_FAILED;
}

int32_t zyren_ml_provider_inventory(const void* api_base, char* output,
                                    size_t capacity, char* error, size_t error_length) {
  if (!api_base || !output || !capacity) return ZYREN_ML_INVALID;
  output[0] = '\0';
  try {
    const auto api = static_cast<const OrtApiBase*>(api_base)->GetApi(ORT_API_VERSION);
    if (!api) return ZYREN_ML_UNSUPPORTED;
    char** names = nullptr;
    int count = 0;
    check(api, api->GetAvailableProviders(&names, &count));
    const auto release = [api, count](char** value) {
      if (auto status = api->ReleaseAvailableProviders(value, count)) api->ReleaseStatus(status);
    };
    std::unique_ptr<char*, decltype(release)> owned(names, release);
    std::string text;
    for (int i = 0; i < count; ++i) { text += names[i]; text += '\n'; }
    if (text.size() >= capacity) return ZYREN_ML_INVALID;
    message(output, capacity, text.c_str());
    return ZYREN_ML_OK;
  } catch (const std::exception& e) { message(error, error_length, e.what()); }
  catch (...) { message(error, error_length, "Provider inventory failed."); }
  return ZYREN_ML_FAILED;
}

int32_t zyren_ml_profile_end(ZyrenMlSession* state, char* output,
                            size_t capacity, char* error, size_t error_length) {
  if (!state || !state->profiling || !output || !capacity) return ZYREN_ML_INVALID;
  try {
    OrtAllocator* allocator = nullptr;
    check(state->api, state->api->GetAllocatorWithDefaultOptions(&allocator));
    char* path = nullptr;
    check(state->api, state->api->SessionEndProfiling(state->session, allocator, &path));
    const auto release = [allocator](char* value) { allocator->Free(allocator, value); };
    std::unique_ptr<char, decltype(release)> owned(path, release);
    state->profiling = false;
    if (!path || std::strlen(path) >= capacity) return ZYREN_ML_INVALID;
    message(output, capacity, path);
    return ZYREN_ML_OK;
  } catch (const std::exception& e) { message(error, error_length, e.what()); }
  catch (...) { message(error, error_length, "Provider profiling failed."); }
  return ZYREN_ML_FAILED;
}

void zyren_ml_close(ZyrenMlSession* session) { delete session; }

int32_t zyren_ml_run(ZyrenMlSession* state, const char* const* names,
                    const ZyrenMlTensor* tensors, size_t count,
                    const char* const* output_names, size_t output_count,
                    ZyrenMlResult** out, char* error, size_t error_length) {
  if (out) *out = nullptr;
  if (!state || !out || !names || !tensors || !output_names || !count ||
      count > kMaxTensors || !output_count || output_count > kMaxTensors) {
    message(error, error_length, "Invalid inference arguments.");
    return ZYREN_ML_INVALID;
  }
  try {
    const auto api = state->api;
    InputValues inputs(api, count);
    size_t total_bytes = 0;
    for (size_t i = 0; i < count; ++i) {
      const auto& tensor = tensors[i];
      if (!names[i] || !tensor.data || tensor.rank < 0)
        throw std::invalid_argument("Invalid tensor input.");
      const auto bytes = tensorBytes(tensor.dimensions, tensor.rank, tensor.dtype);
      if (bytes != tensor.byte_length || bytes > kMaxTensorBytes - total_bytes)
        throw std::invalid_argument("Tensor input byte length exceeds budget or differs from shape.");
      total_bytes += bytes;
      check(api, api->CreateTensorWithDataAsOrtValue(
          state->memory, tensor.data, bytes, tensor.dimensions, tensor.rank,
          static_cast<ONNXTensorElementDataType>(tensor.dtype), &inputs.values[i]));
    }
    for (size_t i = 0; i < output_count; ++i)
      if (!output_names[i]) throw std::invalid_argument("Missing output name.");
    auto result = std::make_unique<ZyrenMlResult>(api, output_count);
    {
      ActiveRun active;
      check(api, api->Run(state->session, nullptr, names, inputs.values.data(), count,
                         output_names, output_count, result->values.data()));
      ++completed_runs;
    }
    // Inspect all outputs before returning any storage to Dart.
    total_bytes = 0;
    for (size_t i = 0; i < output_count; ++i) {
      TensorInfo info{api};
      check(api, api->GetTensorTypeAndShape(result->values[i], &info.value));
      size_t rank = 0;
      check(api, api->GetDimensionsCount(info.value, &rank));
      if (rank > 8) throw std::invalid_argument("Output rank exceeds budget.");
      result->dimensions[i].resize(rank);
      check(api, api->GetDimensions(info.value, result->dimensions[i].data(), rank));
      ONNXTensorElementDataType dtype;
      check(api, api->GetTensorElementType(info.value, &dtype));
      const auto bytes = tensorBytes(result->dimensions[i].data(), rank, dtype);
      if (bytes > kMaxTensorBytes - total_bytes)
        throw std::invalid_argument("Output bytes exceed budget.");
      total_bytes += bytes;
    }
    result->counted = true;
    ++results;
    *out = result.release();
    return ZYREN_ML_OK;
  } catch (const std::invalid_argument& e) {
    message(error, error_length, e.what());
    return ZYREN_ML_INVALID;
  } catch (const std::exception& e) {
    message(error, error_length, e.what());
  } catch (...) {
    message(error, error_length, "Unknown native inference failure.");
  }
  return ZYREN_ML_FAILED;
}

int32_t zyren_ml_result_tensor(ZyrenMlResult* result, size_t index,
                              ZyrenMlTensor* tensor, char* error, size_t error_length) {
  if (!result || !tensor || index >= result->values.size()) {
    message(error, error_length, "Invalid result index.");
    return ZYREN_ML_INVALID;
  }
  try {
    const auto api = result->api;
    TensorInfo info{api};
    check(api, api->GetTensorTypeAndShape(result->values[index], &info.value));
    ONNXTensorElementDataType dtype;
    check(api, api->GetTensorElementType(info.value, &dtype));
    tensor->dtype = dtype;
    tensor->rank = static_cast<int32_t>(result->dimensions[index].size());
    tensor->dimensions = result->dimensions[index].data();
    tensor->byte_length = tensorBytes(tensor->dimensions, tensor->rank, dtype);
    check(api, api->GetTensorMutableData(result->values[index], &tensor->data));
    return ZYREN_ML_OK;
  } catch (const std::exception& e) { message(error, error_length, e.what()); }
  catch (...) { message(error, error_length, "Unknown native result failure."); }
  return ZYREN_ML_FAILED;
}

void zyren_ml_result_close(ZyrenMlResult* result) { delete result; }
int64_t zyren_ml_live_sessions() { return sessions.load(); }
int64_t zyren_ml_live_results() { return results.load(); }
int64_t zyren_ml_completed_runs() { return completed_runs.load(); }
int64_t zyren_ml_active_runs() { return active_runs.load(); }
}
