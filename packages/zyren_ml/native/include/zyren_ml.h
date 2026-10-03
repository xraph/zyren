#ifndef ZYREN_ML_H
#define ZYREN_ML_H
#include <stddef.h>
#include <stdint.h>
#ifdef _WIN32
#define ZML_EXPORT __declspec(dllexport)
#else
#define ZML_EXPORT __attribute__((visibility("default")))
#endif
#ifdef __cplusplus
extern "C" {
#endif

enum ZyrenMlStatus { ZYREN_ML_OK = 0, ZYREN_ML_INVALID = 1,
  ZYREN_ML_UNSUPPORTED = 2, ZYREN_ML_FAILED = 3 };
/* dtype uses ONNX values: float32=1, int64=7, bool=9. */
typedef struct ZyrenMlTensor {
  int32_t dtype;
  int32_t rank;
  const int64_t* dimensions;
  size_t byte_length;
  void* data;
} ZyrenMlTensor;

typedef struct ZyrenMlSession ZyrenMlSession;
typedef struct ZyrenMlResult ZyrenMlResult;
ZML_EXPORT int32_t zyren_ml_open(const void* api_base, const void* model,
  size_t model_length, ZyrenMlSession** session, char* error, size_t error_length);
ZML_EXPORT void zyren_ml_close(ZyrenMlSession* session);
ZML_EXPORT int32_t zyren_ml_run(ZyrenMlSession* session,
  const char* const* input_names, const ZyrenMlTensor* inputs, size_t input_count,
  const char* const* output_names, size_t output_count, ZyrenMlResult** result,
  char* error, size_t error_length);
/* Returned tensor storage remains owned by result until zyren_ml_result_close. */
ZML_EXPORT int32_t zyren_ml_result_tensor(ZyrenMlResult* result, size_t index,
  ZyrenMlTensor* tensor, char* error, size_t error_length);
ZML_EXPORT void zyren_ml_result_close(ZyrenMlResult* result);
ZML_EXPORT int64_t zyren_ml_live_sessions(void);
ZML_EXPORT int64_t zyren_ml_live_results(void);
#ifdef __cplusplus
}
#endif
#endif
