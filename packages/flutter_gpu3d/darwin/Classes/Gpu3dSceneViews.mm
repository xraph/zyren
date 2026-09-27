#import "Gpu3dSceneViews.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <atomic>
#include <dlfcn.h>
#include <map>
#include <memory>

namespace {
struct Api {
  uint64_t (*create)();
  uint32_t (*destroy)(uint64_t);
  void *(*device)(uint64_t);
  uint32_t (*render)(uint64_t, const uint8_t *, size_t, void *, void *);
  uint32_t (*capture)(uint64_t, const uint8_t *, size_t, uint32_t, uint32_t, uint8_t *, size_t);
  size_t (*lastError)(uint8_t *, size_t);
  uint64_t (*readback)(uint64_t);
  size_t (*live)();
  size_t (*retiring)();
  bool load(void *runtime) {
    if (!runtime) return false;
#define LOAD(member, symbol) member = reinterpret_cast<decltype(member)>(dlsym(runtime, symbol))
    LOAD(create, "fg_create"); LOAD(destroy, "fg_destroy"); LOAD(device, "fg_metal_copy_device");
    LOAD(render, "fg_metal_render_texture"); LOAD(capture, "fg_render");
    LOAD(lastError, "fg_last_error"); LOAD(readback, "fg_metal_readback_bytes");
    LOAD(live, "fg_live_renderer_count"); LOAD(retiring, "fg_retiring_renderer_count");
#undef LOAD
    return create && destroy && device && render && capture && lastError && readback && live && retiring;
  }
  NSString *error() const {
    uint8_t bytes[1024]; size_t length = lastError(bytes, sizeof(bytes));
    return [[NSString alloc] initWithBytes:bytes length:std::min(length, sizeof(bytes)) encoding:NSUTF8StringEncoding] ?: @"Native renderer failed.";
  }
};
FlutterError *error(NSString *code, NSString *message) { return [FlutterError errorWithCode:code message:message details:nil]; }
FlutterError *deferred() { return error(@"frameDeferred", @"The native view changed or its drawable is unavailable."); }
bool number(id value) { return [value isKindOfClass:NSNumber.class]; }
std::atomic<uint64_t> sessions{0}, held{0}, submitted{0}, presented{0}, readbackBytes{0};

struct Session {
  const Api api;
  const dispatch_queue_t queue;
  uint64_t renderer = 0; // Queue only, including create and destroy.
  std::atomic<bool> closed{false};
  std::atomic<uint64_t> epoch{1};
  // All remaining fields belong to the platform thread.
  id<MTLDevice> device;
  CAMetalLayer *layer;
  id<CAMetalDrawable> pending;
  uint64_t generation = 0, revokedThrough = 0, pendingFrame = 0;
  int64_t view = -1;
  CGSize logical = CGSizeZero;
  bool visible = false, suspended = false, busy = false;
  Session(Api api) : api(api), queue(dispatch_queue_create("gpu3d.scene", DISPATCH_QUEUE_SERIAL)) { sessions.fetch_add(1); }
  ~Session() { sessions.fetch_sub(1); }
  void discard() { if (pending) { pending = nil; held.fetch_sub(1); } pendingFrame = 0; }
  void revoke() { epoch.fetch_add(1); discard(); }
  void detach(uint64_t attachment) {
    revokedThrough = std::max(revokedThrough, attachment);
    if (generation != attachment) return;
    revoke(); layer = nil; view = -1; visible = false;
  }
  void layout(CGSize size, bool attached) {
    const bool nextVisible = attached && size.width > 0 && size.height > 0;
    if (!CGSizeEqualToSize(logical, size) || visible != nextVisible) { logical = size; visible = nextVisible; revoke(); }
  }
};
// Blocks capture C++ reference parameters by reference. Keep an owning value
// alive until asynchronous renderer destruction finishes.
void close(std::shared_ptr<Session> session, FlutterResult result) {
  if (session->closed.exchange(true)) { if (result) result(nil); return; }
  session->revoke(); session->layer = nil; session->device = nil;
  dispatch_async(session->queue, ^{
    @autoreleasepool {
      if (session->renderer) { session->api.destroy(session->renderer); session->renderer = 0; }
      dispatch_async(dispatch_get_main_queue(), ^{ if (result) result(nil); });
    }
  });
}
bool matches(const std::shared_ptr<Session> &s, NSDictionary *args) {
  return number(args[@"attachment"]) && number(args[@"view"]) && !s->closed.load() && s->layer &&
    s->generation == [args[@"attachment"] unsignedLongLongValue] && s->view == [args[@"view"] longLongValue];
}
}

#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
@interface Gpu3dSceneHost : NSView {
@public std::weak_ptr<Session> session; uint64_t generation;
}
@end
@implementation Gpu3dSceneHost
- (NSView *)hitTest:(NSPoint)point { return nil; }
- (void)layout { [super layout]; if (auto s = session.lock()) if (s->generation == generation) s->layout(self.bounds.size, self.window != nil); }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self setNeedsLayout:YES]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; if (auto s = session.lock()) if (s->generation == generation) s->revoke(); [self setNeedsLayout:YES]; }
- (void)dealloc { if (auto s = session.lock()) s->detach(generation); }
@end
#else
@interface Gpu3dSceneHost : UIView <FlutterPlatformView> {
@public std::weak_ptr<Session> session; uint64_t generation;
}
@end
@implementation Gpu3dSceneHost
+ (Class)layerClass { return CAMetalLayer.class; }
- (UIView *)view { return self; }
- (void)layoutSubviews { [super layoutSubviews]; if (auto s = session.lock()) if (s->generation == generation) s->layout(self.bounds.size, self.window != nil); }
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }
- (void)dealloc { if (auto s = session.lock()) s->detach(generation); }
@end
#endif

@implementation Gpu3dSceneViews {
  Api _api;
  bool _connected;
  uint64_t _nextSession;
  void *(^_connect)(uint64_t);
  FlutterMethodChannel *_channel;
  std::map<uint64_t, std::shared_ptr<Session>> _sessions;
}
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar connect:(void *(^)(uint64_t))connect {
  self = [super init];
  if (self) {
    _connect = [connect copy]; _nextSession = 1;
    _channel = [FlutterMethodChannel methodChannelWithName:@"gpu3d/scene-views" binaryMessenger:registrar.messenger];
    __weak Gpu3dSceneViews *weak = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
      Gpu3dSceneViews *owner = weak;
      if (owner) [owner handle:call result:result]; else result(error(@"disposed", @"Native scene plugin detached."));
    }];
    [registrar registerViewFactory:self withId:@"gpu3d/scene"];
  }
  return self;
}
- (NSObject<FlutterMessageCodec> *)createArgsCodec { return [FlutterStandardMessageCodec sharedInstance]; }
#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
- (NSView *)createWithViewIdentifier:(int64_t)viewId arguments:(id)args {
  Gpu3dSceneHost *host = [[Gpu3dSceneHost alloc] initWithFrame:NSZeroRect];
  host.wantsLayer = YES; host.layer = [CAMetalLayer layer];
#else
- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame viewIdentifier:(int64_t)viewId arguments:(id)args {
  Gpu3dSceneHost *host = [[Gpu3dSceneHost alloc] initWithFrame:frame];
  host.userInteractionEnabled = NO;
#endif
  if (![args isKindOfClass:NSDictionary.class] || !number(args[@"session"]) || !number(args[@"attachment"])) return host;
  auto found = _sessions.find([args[@"session"] unsignedLongLongValue]);
  if (found == _sessions.end()) return host;
  auto s = found->second; uint64_t generation = [args[@"attachment"] unsignedLongLongValue];
  if (s->closed.load() || !s->device || generation <= s->revokedThrough || generation <= s->generation || s->layer) return host;
  CAMetalLayer *layer = (CAMetalLayer *)host.layer;
  layer.device = s->device; layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
  layer.framebufferOnly = YES; layer.maximumDrawableCount = 3; layer.allowsNextDrawableTimeout = YES; layer.opaque = YES;
  CGColorSpaceRef color = CGColorSpaceCreateWithName(kCGColorSpaceSRGB); layer.colorspace = color; CGColorSpaceRelease(color);
  s->revoke(); s->generation = generation; s->view = viewId; s->layer = layer; s->logical = CGSizeZero;
  host->session = s; host->generation = generation;
  return host;
}
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"connect"]) {
    Api api;
    if (!number(args[@"runtime"]) || !api.load(_connect([args[@"runtime"] unsignedLongLongValue]))) { result(error(@"runtimeMismatch", @"Cannot attach to the loaded Rust runtime.")); return; }
    _api = api; _connected = true; result(nil); return;
  }
  if (!_connected) { result(error(@"notConnected", @"Connect the loaded Rust runtime first.")); return; }
  if ([call.method isEqualToString:@"diagnostics"]) {
    result(@{@"sessions": @(sessions.load()), @"renderers": @(_api.live()), @"retiring": @(_api.retiring()),
      @"heldDrawables": @(held.load()), @"submitted": @(submitted.load()), @"presented": @(presented.load()), @"readbackBytes": @(readbackBytes.load())}); return;
  }
  if ([call.method isEqualToString:@"create"]) {
    if (_sessions.size() >= 32 || _nextSession >= INT64_MAX) { result(error(@"capacity", @"Native scene capacity is exhausted.")); return; }
    uint64_t identity = _nextSession++;
    auto s = std::make_shared<Session>(_api); _sessions[identity] = s;
    __weak Gpu3dSceneViews *weak = self;
    dispatch_async(s->queue, ^{
      @autoreleasepool {
        s->renderer = s->api.create();
        id<MTLDevice> device = s->renderer ? CFBridgingRelease(s->api.device(s->renderer)) : nil;
        NSString *failure = device ? nil : s->api.error();
        if (failure && s->renderer) { s->api.destroy(s->renderer); s->renderer = 0; }
        dispatch_async(dispatch_get_main_queue(), ^{
          Gpu3dSceneViews *owner = weak;
          if (!owner || s->closed.load()) { result(error(@"disposed", @"Scene closed during creation.")); return; }
          if (failure) { owner->_sessions.erase(identity); result(error(@"backendUnavailable", failure)); return; }
          s->device = device;
          result(@{@"session": @(identity), @"adapter": device.name ?: @"Metal"});
        });
      }
    });
    return;
  }
  if (!number(args[@"session"])) { result(error(@"invalidSession", @"A native session ID is required.")); return; }
  auto found = _sessions.find([args[@"session"] unsignedLongLongValue]);
  if (found == _sessions.end()) {
    if ([call.method isEqualToString:@"close"] || [call.method isEqualToString:@"detach"] || [call.method isEqualToString:@"suspend"]) result(nil);
    else result(error(@"disposed", @"Native scene session has closed."));
    return;
  }
  auto s = found->second;
  if ([call.method isEqualToString:@"close"]) { _sessions.erase(found); close(s, result); return; }
  if ([call.method isEqualToString:@"detach"]) {
    if (!number(args[@"attachment"])) { result(error(@"invalidAttachment", @"An attachment ID is required.")); return; }
    s->detach([args[@"attachment"] unsignedLongLongValue]); result(nil); return;
  }
  if ([call.method isEqualToString:@"suspend"]) {
    if (!number(args[@"attachment"]) || !number(args[@"suspended"])) { result(error(@"invalidAttachment", @"An attachment and suspended flag are required.")); return; }
    if (s->generation == [args[@"attachment"] unsignedLongLongValue]) {
      bool suspended = [args[@"suspended"] boolValue];
      if (s->suspended != suspended) { s->suspended = suspended; s->revoke(); }
    }
    result(nil); return;
  }
  if ([call.method isEqualToString:@"prepare"]) {
    if (!matches(s, args) || !s->visible || s->suspended) { result(deferred()); return; }
    if (!number(args[@"width"]) || !number(args[@"height"])) { result(error(@"invalidSize", @"Physical dimensions are required.")); return; }
    int64_t width = [args[@"width"] longLongValue], height = [args[@"height"] longLongValue];
    if (width < 1 || height < 1 || width > 4096 || height > 4096) { result(error(@"invalidSize", @"Physical dimensions must be in [1, 4096].")); return; }
    CGSize size = CGSizeMake(width, height);
    if (!CGSizeEqualToSize(s->layer.drawableSize, size)) { s->revoke(); s->layer.drawableSize = size; }
    result(@{@"epoch": @(s->epoch.load())}); return;
  }
  if ([call.method isEqualToString:@"present"]) {
    if (!matches(s, args) || s->suspended || !s->visible || !number(args[@"epoch"]) || !number(args[@"frame"]) ||
        s->epoch.load() != [args[@"epoch"] unsignedLongLongValue] || s->pendingFrame != [args[@"frame"] unsignedLongLongValue] || !s->pending) { result(@NO); return; }
    [s->pending present]; s->discard(); presented.fetch_add(1); result(@YES); return;
  }
  const bool capture = [call.method isEqualToString:@"capture"];
  if (!capture && ![call.method isEqualToString:@"render"]) { result(FlutterMethodNotImplemented); return; }
  if (s->busy || s->pending) { result(deferred()); return; }
  if (![args[@"json"] isKindOfClass:NSString.class] || !number(args[@"width"]) || !number(args[@"height"]) || !number(args[@"frame"])) { result(error(@"invalidFrame", @"A scene packet, dimensions and frame ID are required.")); return; }
  int64_t width = [args[@"width"] longLongValue], height = [args[@"height"] longLongValue];
  NSData *packet = [args[@"json"] dataUsingEncoding:NSUTF8StringEncoding];
  if (width < 1 || height < 1 || width > 4096 || height > 4096 || packet.length == 0 || packet.length > 128 * 1024 * 1024) { result(error(@"invalidFrame", @"Scene packet or physical size exceeds its limit.")); return; }
  const uint64_t epoch = s->epoch.load(), frame = [args[@"frame"] unsignedLongLongValue];
  if (!capture && (!matches(s, args) || !number(args[@"epoch"]) || epoch != [args[@"epoch"] unsignedLongLongValue] || s->suspended || !s->visible)) { result(deferred()); return; }
  CAMetalLayer *layer = s->layer; s->busy = true;
  dispatch_async(s->queue, ^{
    @autoreleasepool {
      if (s->closed.load() || (!capture && s->epoch.load() != epoch)) {
        dispatch_async(dispatch_get_main_queue(), ^{ s->busy = false; result(@{@"applied": @NO, @"ready": @NO}); }); return;
      }
      id<CAMetalDrawable> drawable = capture ? nil : [layer nextDrawable];
      if (!capture && (!drawable || drawable.texture.width != width || drawable.texture.height != height || s->closed.load() || s->epoch.load() != epoch)) {
        dispatch_async(dispatch_get_main_queue(), ^{ s->busy = false; result(@{@"applied": @NO, @"ready": @NO}); }); return;
      }
      if (drawable) held.fetch_add(1);
      NSMutableData *pixels = capture ? [NSMutableData dataWithLength:width * height * 4] : nil;
      const uint64_t before = s->api.readback(s->renderer);
      bool ok = capture ? s->api.capture(s->renderer, static_cast<const uint8_t *>(packet.bytes), packet.length, static_cast<uint32_t>(width), static_cast<uint32_t>(height), static_cast<uint8_t *>(pixels.mutableBytes), pixels.length) == 1
        : s->api.render(s->renderer, static_cast<const uint8_t *>(packet.bytes), packet.length, (__bridge void *)drawable.texture, (__bridge void *)drawable) == 1;
      NSString *failure = ok ? nil : s->api.error();
      const uint64_t bytes = ok ? s->api.readback(s->renderer) - before : 0;
      if (ok) { submitted.fetch_add(1); readbackBytes.fetch_add(bytes); }
      dispatch_async(dispatch_get_main_queue(), ^{
        s->busy = false;
        const bool ready = ok && !s->closed.load() && (capture || s->epoch.load() == epoch);
        if (ready && drawable) { s->pending = drawable; s->pendingFrame = frame; }
        else if (drawable) held.fetch_sub(1);
        if (failure) { result(error(@"renderFailed", failure)); return; }
        if (capture && ready) result(@{@"applied": @YES, @"ready": @YES, @"readbackBytes": @(bytes), @"pixels": [FlutterStandardTypedData typedDataWithBytes:pixels]});
        else result(@{@"applied": @(ok), @"ready": @(ready), @"readbackBytes": @(bytes)});
      });
    }
  });
}
- (void)closeAll { for (auto &entry : _sessions) close(entry.second, nil); _sessions.clear(); }
- (void)dealloc { [self closeAll]; [_channel setMethodCallHandler:nil]; }
@end
