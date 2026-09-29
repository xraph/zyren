#include <jni.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <link.h>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>
#include "zyren.h"

namespace {
struct Api {
  uint64_t (*token)() = nullptr;
  uint64_t (*create)() = nullptr;
  uint32_t (*destroy)(uint64_t) = nullptr;
  size_t (*error)(uint8_t *, size_t) = nullptr;
  decltype(&fg_android_attach) attach = nullptr;
  decltype(&fg_android_render) render = nullptr;
  decltype(&fg_android_present) present = nullptr;
  decltype(&fg_android_detach) detach = nullptr;
  decltype(&fg_android_info) info = nullptr;
  size_t (*live)() = nullptr;
  size_t (*retiring)() = nullptr;
  decltype(&fg2_resource_command) resource = nullptr;
  decltype(&fg2_shader_command) shader = nullptr;
  decltype(&fg2_graph_command) graph = nullptr;
} api;
void *runtime = nullptr;
void fail(JNIEnv *env, const std::string &message) {
  env->ThrowNew(env->FindClass("java/lang/IllegalStateException"), message.c_str());
}
void nativeError(JNIEnv *env) {
  auto size = api.error(nullptr, 0);
  std::string message(size, '\0');
  api.error(reinterpret_cast<uint8_t *>(message.data()), size);
  fail(env, message);
}
bool ready(JNIEnv *env) {
  if (runtime) return true;
  fail(env, "Connect Dart's loaded Rust runtime first.");
  return false;
}
struct Search { uint64_t token; void *library = nullptr; };
int findRuntime(dl_phdr_info *info, size_t, void *data) {
  auto search = static_cast<Search *>(data);
  if (!info->dlpi_name || !*info->dlpi_name) return 0;
  void *library = dlopen(info->dlpi_name, RTLD_NOW | RTLD_NOLOAD);
  if (!library) return 0;
  auto token = reinterpret_cast<uint64_t (*)()>(dlsym(library, "fg2_runtime_token"));
  if (token && token() == search->token) { search->library = library; return 1; }
  dlclose(library);
  return 0;
}
}

extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_zyren_Native_connect(JNIEnv *env, jobject, jlong token) {
  if (runtime) {
    if (api.token() != static_cast<uint64_t>(token)) fail(env, "Rust runtime identity mismatch.");
    return;
  }
  Search search{static_cast<uint64_t>(token)};
  dl_iterate_phdr(findRuntime, &search);
  if (!search.library) { fail(env, "Dart's loaded Rust runtime was not found."); return; }
  Api candidate;
#define LOAD(field, symbol) candidate.field = reinterpret_cast<decltype(candidate.field)>(dlsym(search.library, symbol)); \
  if (!candidate.field) { dlclose(search.library); fail(env, "Missing Rust symbol: " symbol); return; }
  LOAD(token, "fg2_runtime_token")
  LOAD(create, "fg_create")
  LOAD(destroy, "fg_destroy")
  LOAD(error, "fg_last_error")
  LOAD(attach, "fg_android_attach")
  LOAD(render, "fg_android_render")
  LOAD(present, "fg_android_present")
  LOAD(detach, "fg_android_detach")
  LOAD(info, "fg_android_info")
  LOAD(live, "fg_live_renderer_count")
  LOAD(retiring, "fg_retiring_renderer_count")
  LOAD(resource, "fg2_resource_command")
  LOAD(shader, "fg2_shader_command")
  LOAD(graph, "fg2_graph_command")
#undef LOAD
  api = candidate;
  // Keep the exact asset loaded while platform callbacks can use its functions.
  runtime = search.library;
}

extern "C" JNIEXPORT jbyteArray JNICALL
Java_dev_twinos_zyren_Native_gpuCommand(JNIEnv *env, jobject, jlong handle, jint kind,
                                       jbyteArray input, jint capacity) {
  if (!ready(env)) return nullptr;
  if (!input || kind < 0 || kind > 2) { fail(env, "Invalid native command kind or bytes."); return nullptr; }
  const auto length = env->GetArrayLength(input);
  if (length == 0 || (kind == 0
      ? (length > 64 * 1024 * 1024 + 2048 || capacity < 24 || capacity > 64 * 1024 * 1024 + 24)
      : (length > 8 * 1024 * 1024 || capacity != 256 * 1024))) {
    fail(env, "Native command exceeds its transfer limits."); return nullptr;
  }
  std::vector<uint8_t> bytes(length), output(static_cast<size_t>(capacity) + 4);
  env->GetByteArrayRegion(input, 0, length, reinterpret_cast<jbyte *>(bytes.data()));
  if (env->ExceptionCheck()) return nullptr;
  const auto command = kind == 0 ? api.resource : kind == 1 ? api.shader : api.graph;
  size_t written = 0;
  const uint32_t status = command(handle, bytes.data(), bytes.size(), output.data() + 4, capacity, &written);
  if (written > static_cast<size_t>(capacity)) { fail(env, "Native response exceeded capacity."); return nullptr; }
  if (status) {
    written = std::min(api.error(nullptr, 0), static_cast<size_t>(4096));
    output.resize(4 + written);
    api.error(output.data() + 4, written);
  } else {
    output.resize(4 + written);
  }
  for (int i = 0; i < 4; ++i) output[i] = static_cast<uint8_t>(status >> (8 * i));
  auto result = env->NewByteArray(static_cast<jsize>(output.size()));
  if (!result) return nullptr;
  env->SetByteArrayRegion(result, 0, static_cast<jsize>(output.size()), reinterpret_cast<const jbyte *>(output.data()));
  return result;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_twinos_zyren_Native_create(JNIEnv *env, jobject) {
  if (!ready(env)) return 0;
  auto handle = api.create();
  if (!handle) nativeError(env);
  return static_cast<jlong>(handle);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_zyren_Native_destroy(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.destroy(handle)) nativeError(env);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_zyren_Native_detach(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.detach(handle)) nativeError(env);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_twinos_zyren_Native_render(JNIEnv *env, jobject, jlong handle, jobject surface,
                                  jbyteArray packet, jint width, jint height) {
  if (!ready(env)) return false;
  auto window = ANativeWindow_fromSurface(env, surface);
  if (!window) { fail(env, "Android Surface has no native window."); return false; }
  const auto attached = api.attach(handle, window, width, height);
  ANativeWindow_release(window);
  if (!attached) { nativeError(env); return false; }
  std::vector<uint8_t> bytes(env->GetArrayLength(packet));
  env->GetByteArrayRegion(packet, 0, bytes.size(), reinterpret_cast<jbyte *>(bytes.data()));
  if (env->ExceptionCheck()) return false;
  auto status = api.render(handle, bytes.data(), bytes.size());
  if (!status) nativeError(env);
  return status == 1;
}
extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_zyren_Native_present(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.present(handle)) nativeError(env);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_twinos_zyren_Native_info(JNIEnv *env, jobject, jlong handle) {
  if (!ready(env)) return nullptr;
  const auto size = api.info(handle, nullptr, 0);
  if (!size || size > 65536) { nativeError(env); return nullptr; }
  std::string json(size, '\0');
  if (api.info(handle, reinterpret_cast<uint8_t *>(json.data()), size) != size) {
    fail(env, "Vulkan diagnostics changed unexpectedly."); return nullptr;
  }
  return env->NewStringUTF(json.c_str());
}
extern "C" JNIEXPORT jlongArray JNICALL
Java_dev_twinos_zyren_Native_counters(JNIEnv *env, jobject) {
  if (!ready(env)) return nullptr;
  jlong values[] = {static_cast<jlong>(api.live()), static_cast<jlong>(api.retiring())};
  auto result = env->NewLongArray(2);
  env->SetLongArrayRegion(result, 0, 2, values);
  return result;
}
