#include <jni.h>
#include <android/native_window_jni.h>
#include <dlfcn.h>
#include <link.h>
#include <cstdint>
#include <string>
#include <vector>
#include "gpu3d.h"

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
Java_dev_twinos_gpu3d_Native_connect(JNIEnv *env, jobject, jlong token) {
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
#undef LOAD
  api = candidate;
  // Keep the exact asset loaded while platform callbacks can use its functions.
  runtime = search.library;
}

extern "C" JNIEXPORT jlong JNICALL
Java_dev_twinos_gpu3d_Native_create(JNIEnv *env, jobject) {
  if (!ready(env)) return 0;
  auto handle = api.create();
  if (!handle) nativeError(env);
  return static_cast<jlong>(handle);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_gpu3d_Native_destroy(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.destroy(handle)) nativeError(env);
}
extern "C" JNIEXPORT void JNICALL
Java_dev_twinos_gpu3d_Native_detach(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.detach(handle)) nativeError(env);
}
extern "C" JNIEXPORT jboolean JNICALL
Java_dev_twinos_gpu3d_Native_render(JNIEnv *env, jobject, jlong handle, jobject surface,
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
Java_dev_twinos_gpu3d_Native_present(JNIEnv *env, jobject, jlong handle) {
  if (ready(env) && !api.present(handle)) nativeError(env);
}
extern "C" JNIEXPORT jstring JNICALL
Java_dev_twinos_gpu3d_Native_info(JNIEnv *env, jobject, jlong handle) {
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
Java_dev_twinos_gpu3d_Native_counters(JNIEnv *env, jobject) {
  if (!ready(env)) return nullptr;
  jlong values[] = {static_cast<jlong>(api.live()), static_cast<jlong>(api.retiring())};
  auto result = env->NewLongArray(2);
  env->SetLongArrayRegion(result, 0, 2, values);
  return result;
}
