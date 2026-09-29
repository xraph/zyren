#import "ZyrenPlugin.h"
#import "zyren.h"
#import "ZyrenMetalViews.h"
#import "ZyrenSceneViews.h"
#import <CoreVideo/CoreVideo.h>
#include <dlfcn.h>
#include <mach-o/dyld.h>
#include <atomic>
#include <cstring>

using RuntimeToken = uint64_t (*)();
using CopyBuffer = void *(*)(Fg2SurfaceKey);
using Snapshot = uint32_t (*)(Fg2SurfaceKey, Fg2SurfaceSnapshot *, Fg2Error *);
using Counter = uint64_t (*)();
static std::atomic<uint64_t> rasterCopies{0};

@interface ZyrenFlutterTexture : NSObject <FlutterTexture>
@property(nonatomic, assign) Fg2SurfaceKey key;
@property(nonatomic, assign) CopyBuffer copyBuffer;
@end
@implementation ZyrenFlutterTexture
- (CVPixelBufferRef)copyPixelBuffer {
  CVPixelBufferRef buffer = static_cast<CVPixelBufferRef>(_copyBuffer(_key));
  if (buffer) rasterCopies.fetch_add(1);
  return buffer;
}
@end

@implementation ZyrenPlugin {
  __weak NSObject<FlutterTextureRegistry> *_textures;
  NSMutableDictionary<NSNumber *, ZyrenFlutterTexture *> *_views;
  void *_runtime;
  uint64_t _token;
  CopyBuffer _copyBuffer;
  Snapshot _snapshot;
  Snapshot _closeSurface;
  ZyrenMetalViews *_metalViews;
  ZyrenSceneViews *_sceneViews;
}
+ (void)registerWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  ZyrenPlugin *plugin = [ZyrenPlugin new];
  plugin->_textures = registrar.textures;
  plugin->_views = [NSMutableDictionary new];
  FlutterMethodChannel *channel = [FlutterMethodChannel methodChannelWithName:@"zyren/surfaces"
    binaryMessenger:registrar.messenger];
  [registrar addMethodCallDelegate:plugin channel:channel];
  __weak ZyrenPlugin *weak = plugin;
  plugin->_metalViews = [[ZyrenMetalViews alloc] initWithRegistrar:registrar connect:^void *(uint64_t token) {
    ZyrenPlugin *owner = weak;
    return owner && [owner connect:token] ? owner->_runtime : nullptr;
  }];
  plugin->_sceneViews = [[ZyrenSceneViews alloc] initWithRegistrar:registrar connect:^void *(uint64_t token) {
    ZyrenPlugin *owner = weak;
    return owner && [owner connect:token] ? owner->_runtime : nullptr;
  }];
  [registrar publish:plugin];
}
- (BOOL)connect:(uint64_t)token {
  if (_runtime) return _token == token;
  // Native assets load through Dart first. RTLD_NOLOAD can only find that exact
  // image; this adapter never opens a second copy of the Rust runtime.
  for (uint32_t index = 0; index < _dyld_image_count(); index++) {
    const char *path = _dyld_get_image_name(index);
    if (!path || !std::strstr(path, "zyren_runtime")) continue;
    void *library = dlopen(path, RTLD_NOW | RTLD_NOLOAD);
    if (!library) continue;
    auto identity = reinterpret_cast<RuntimeToken>(dlsym(library, "fg2_runtime_token"));
    if (!identity || identity() != token) { dlclose(library); continue; }
    _copyBuffer = reinterpret_cast<CopyBuffer>(dlsym(library, "fg2_apple_copy_pixel_buffer"));
    _snapshot = reinterpret_cast<Snapshot>(dlsym(library, "fg2_surface_snapshot"));
    _closeSurface = reinterpret_cast<Snapshot>(dlsym(library, "fg2_surface_close"));
    if (!_copyBuffer || !_snapshot || !_closeSurface) { dlclose(library); return NO; }
    _runtime = library;
    _token = token;
    return YES;
  }
  return NO;
}
- (void)closeViews {
  [_metalViews closeAll];
  [_sceneViews closeAll];
  for (NSNumber *identity in _views.allKeys) {
    ZyrenFlutterTexture *view = _views[identity];
    Fg2SurfaceSnapshot output = {sizeof(output), FG2_ABI_VERSION};
    Fg2Error error = {sizeof(error), FG2_ABI_VERSION};
    _closeSurface(view.key, &output, &error);
    [_textures unregisterTexture:identity.longLongValue];
  }
  [_views removeAllObjects];
}
- (void)detachFromEngineForRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar {
  [self closeViews];
}
- (void)dealloc {
  // Rust callbacks can outlive engine detachment through retained IOSurfaces.
  // Keep the runtime image loaded for the process lifetime.
  [self closeViews];
}
- (void)handleMethodCall:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"connect"]) {
    NSNumber *token = args[@"runtime"];
    if (![token isKindOfClass:NSNumber.class] || ![self connect:token.unsignedLongLongValue]) {
      result([FlutterError errorWithCode:@"runtimeMismatch" message:@"Flutter could not attach to the loaded GPU runtime." details:nil]);
    } else { result(@(_token)); }
    return;
  }
  if (!_runtime) {
    result([FlutterError errorWithCode:@"notConnected" message:@"Connect the native runtime first." details:nil]); return;
  }
  if ([call.method isEqualToString:@"diagnostics"]) {
    auto counter = [&](const char *symbol) -> uint64_t {
      auto fn = reinterpret_cast<Counter>(dlsym(_runtime, symbol));
      return fn ? fn() : 0;
    };
    result(@{@"textures": @(_views.count), @"rasterCopies": @(rasterCopies.load()),
      @"liveBuffers": @(counter("fg2_apple_live_buffers")),
      @"presentedFrames": @(counter("fg2_apple_presented_frames")),
      @"readbackBytes": @(counter("fg2_apple_readback_bytes"))}); return;
  }
  NSArray *fields = args[@"key"];
  if (![fields isKindOfClass:NSArray.class] || fields.count != 3 ||
      ![fields[0] isKindOfClass:NSNumber.class] || ![fields[1] isKindOfClass:NSNumber.class] || ![fields[2] isKindOfClass:NSNumber.class]) {
    result([FlutterError errorWithCode:@"invalidKey" message:@"A native surface identity is required." details:nil]); return;
  }
  Fg2SurfaceKey key = {sizeof(key), FG2_ABI_VERSION, [fields[0] unsignedLongLongValue],
    [fields[1] unsignedLongLongValue], [fields[2] unsignedLongLongValue]};
  if ([call.method isEqualToString:@"register"]) {
    Fg2SurfaceSnapshot snapshot = {sizeof(snapshot), FG2_ABI_VERSION};
    Fg2Error error = {sizeof(error), FG2_ABI_VERSION};
    if (_snapshot(key, &snapshot, &error) != FG2_OK || snapshot.state != FG2_SURFACE_READY) {
      result([FlutterError errorWithCode:@"surfaceUnavailable" message:@"Native surface is not ready." details:nil]); return;
    }
    ZyrenFlutterTexture *texture = [ZyrenFlutterTexture new];
    texture.key = key;
    texture.copyBuffer = _copyBuffer;
    NSObject<FlutterTextureRegistry> *registry = _textures;
    if (!registry) { result([FlutterError errorWithCode:@"registrationFailed" message:@"Flutter texture registry has detached." details:nil]); return; }
    int64_t identity = [registry registerTexture:texture];
#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
    const bool failed = identity <= 0;
#else
    // The pinned iOS engine starts its texture ID counter at zero.
    const bool failed = identity < 0;
#endif
    if (failed) { result([FlutterError errorWithCode:@"registrationFailed" message:@"Flutter texture registration failed." details:nil]); return; }
    _views[@(identity)] = texture;
    result(@(identity)); return;
  }
  NSNumber *identity = args[@"texture"];
  ZyrenFlutterTexture *texture = [identity isKindOfClass:NSNumber.class] ? _views[identity] : nil;
  if (!texture || texture.key.runtime_token != key.runtime_token || texture.key.slot != key.slot || texture.key.generation != key.generation) {
    if ([call.method isEqualToString:@"unregister"] && !texture) { result(nil); return; }
    result([FlutterError errorWithCode:@"staleSurface" message:@"Texture attachment has expired." details:nil]); return;
  }
  if ([call.method isEqualToString:@"unregister"]) {
    [_textures unregisterTexture:identity.longLongValue];
    [_views removeObjectForKey:identity];
    result(nil); return;
  }
  if ([call.method isEqualToString:@"frameAvailable"]) {
    Fg2SurfaceSnapshot snapshot = {sizeof(snapshot), FG2_ABI_VERSION};
    Fg2Error error = {sizeof(error), FG2_ABI_VERSION};
    if (_snapshot(key, &snapshot, &error) == FG2_OK && snapshot.state == FG2_SURFACE_READY &&
        snapshot.epoch == [args[@"epoch"] unsignedLongLongValue]) {
      [_textures textureFrameAvailable:identity.longLongValue]; result(@YES);
    } else { result(@NO); }
    return;
  }
  result(FlutterMethodNotImplemented);
}
@end
