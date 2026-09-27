#import "ZyrenMetalViews.h"
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <algorithm>
#include <atomic>
#include <cmath>
#include <dlfcn.h>
#include <map>
#include <memory>
#include <mutex>

namespace {
using Create = uint64_t (*)();
using Destroy = uint32_t (*)(uint64_t);
using CopyDevice = void *(*)(uint64_t);
using Render = uint32_t (*)(uint64_t, const uint8_t *, size_t, void *, void *);
using LastError = size_t (*)(uint8_t *, size_t);
using Count = size_t (*)();
using Readback = uint64_t (*)(uint64_t);
struct Api {
  Create create = nullptr;
  Destroy destroy = nullptr;
  CopyDevice copyDevice = nullptr;
  Render render = nullptr;
  LastError lastError = nullptr;
  Count live = nullptr;
  Count retiring = nullptr;
  Readback readback = nullptr;
  bool load(void *runtime) {
    if (!runtime) return false;
    create = reinterpret_cast<Create>(dlsym(runtime, "fg_create"));
    destroy = reinterpret_cast<Destroy>(dlsym(runtime, "fg_destroy"));
    copyDevice = reinterpret_cast<CopyDevice>(dlsym(runtime, "fg_metal_copy_device"));
    render = reinterpret_cast<Render>(dlsym(runtime, "fg_metal_render_texture"));
    lastError = reinterpret_cast<LastError>(dlsym(runtime, "fg_last_error"));
    live = reinterpret_cast<Count>(dlsym(runtime, "fg_live_renderer_count"));
    retiring = reinterpret_cast<Count>(dlsym(runtime, "fg_retiring_renderer_count"));
    readback = reinterpret_cast<Readback>(dlsym(runtime, "fg_metal_readback_bytes"));
    return create && destroy && copyDevice && render && lastError && live && retiring && readback;
  }
};
std::atomic<uint64_t> frames{0}, errors{0}, drawables{0}, timeouts{0};
std::atomic<uint64_t> readbackBytes{0};
std::atomic<uint64_t> liveSessions{0};

struct Session : std::enable_shared_from_this<Session> {
  Api api;
  CAMetalLayer *const layer;
  NSData *initial;
  NSData *steady;
  dispatch_queue_t queue;
  uint64_t renderer = 0; // Only accessed on queue.
  uint64_t lastReadback = 0;
  bool uploaded = false;
  std::atomic<bool> closed{false}, visible{false}, active{true};
  std::atomic<uint64_t> epoch{0}, completed{0};
  std::atomic<uint32_t> width{0}, height{0};
  std::mutex errorLock;
  NSString *error;

  Session(Api api, CAMetalLayer *layer, NSDictionary *args) : api(api), layer(layer) {
    initial = [args[@"initial"] dataUsingEncoding:NSUTF8StringEncoding];
    steady = [args[@"steady"] dataUsingEncoding:NSUTF8StringEncoding];
    queue = dispatch_queue_create("zyren.metal-proof", DISPATCH_QUEUE_SERIAL);
    layer.pixelFormat = MTLPixelFormatBGRA8Unorm_sRGB;
    layer.framebufferOnly = YES;
    layer.maximumDrawableCount = 3;
    layer.allowsNextDrawableTimeout = YES;
    layer.opaque = YES;
    CGColorSpaceRef colorSpace = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    layer.colorspace = colorSpace;
    CGColorSpaceRelease(colorSpace);
    liveSessions.fetch_add(1);
  }
  ~Session() { liveSessions.fetch_sub(1); }
  void fail() {
    uint8_t bytes[1024];
    size_t size = api.lastError(bytes, sizeof(bytes));
    std::lock_guard<std::mutex> lock(errorLock);
    error = [[NSString alloc] initWithBytes:bytes length:std::min(size, sizeof(bytes)) encoding:NSUTF8StringEncoding];
    if (!error) error = @"Native Metal renderer failed.";
    errors.fetch_add(1);
    closed.store(true);
  }
  void finish() {
    if (renderer) { api.destroy(renderer); renderer = 0; }
    initial = nil;
    steady = nil;
  }
  void close() {
    if (closed.exchange(true)) return;
    auto self = shared_from_this();
    dispatch_async(queue, ^{ self->finish(); });
  }
  void start() {
    auto self = shared_from_this();
    dispatch_async(queue, ^{
      @autoreleasepool {
        if (self->closed.load()) return;
        self->renderer = self->api.create();
        if (!self->renderer) { self->fail(); self->finish(); return; }
        id<MTLDevice> device = CFBridgingRelease(self->api.copyDevice(self->renderer));
        if (!device) { self->fail(); self->finish(); return; }
        dispatch_async(dispatch_get_main_queue(), ^{
          if (self->closed.load()) return;
          self->layer.device = device;
          self->schedule();
        });
      }
    });
  }
  void schedule() {
    if (closed.load()) return;
    auto self = shared_from_this();
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 16 * NSEC_PER_MSEC), queue, ^{
      @autoreleasepool { self->tick(); }
    });
  }
  void tick() {
    if (closed.load()) return;
    if (!visible.load() || !active.load()) { schedule(); return; }
    const uint64_t before = epoch.load();
    // nextDrawable can wait for the display pool. It only runs on this queue,
    // with a finite Core Animation timeout and at most one producer per view.
    id<CAMetalDrawable> drawable = [layer nextDrawable];
    if (!drawable) { timeouts.fetch_add(1); schedule(); return; }
    drawables.fetch_add(1);
    NSData *packet = uploaded ? steady : initial;
    bool ok = api.render(renderer, static_cast<const uint8_t *>(packet.bytes), packet.length,
                         (__bridge void *)drawable.texture, (__bridge void *)drawable) == 1;
    if (!ok) {
      // Rust keeps the whole drawable in its bounded retirement state.
      fail();
      drawable = nil;
      drawables.fetch_sub(1);
      finish();
      return;
    }
    const auto currentReadback = api.readback(renderer);
    readbackBytes.fetch_add(currentReadback - lastReadback);
    lastReadback = currentReadback;
    uploaded = true;
    auto self = shared_from_this();
    // The platform thread serializes publication with close and resize. GPU
    // completion has already been observed, so this block never waits for it.
    dispatch_async(dispatch_get_main_queue(), ^{
      if (!self->closed.load() && self->visible.load() && self->active.load() && before == self->epoch.load()) {
        [drawable present];
        self->width.store(static_cast<uint32_t>(drawable.texture.width));
        self->height.store(static_cast<uint32_t>(drawable.texture.height));
        self->completed.fetch_add(1);
        frames.fetch_add(1);
      }
      drawables.fetch_sub(1);
      self->schedule();
    });
  }
  void resize(CGSize size, CGFloat scale, bool attached) {
    // Platform-thread only. Raster dimensions are capped before allocation.
    const double w = ceil(size.width * scale), h = ceil(size.height * scale);
    bool valid = attached && std::isfinite(w) && std::isfinite(h) && w > 0 && h > 0 && w <= 4096 && h <= 4096;
    visible.store(valid);
    if (!valid) { epoch.fetch_add(1); return; }
    CGSize pixels = CGSizeMake(w, h);
    if (!CGSizeEqualToSize(layer.drawableSize, pixels)) {
      epoch.fetch_add(1);
      layer.contentsScale = scale;
      layer.drawableSize = pixels;
    }
  }
};
} // namespace

#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
@interface ZyrenMetalHost : NSView {
@public std::shared_ptr<Session> session;
}
@end
@implementation ZyrenMetalHost
- (void)layout { [super layout]; if (session) session->resize(self.bounds.size, self.window.backingScaleFactor ?: 1, self.window != nil); }
- (void)viewDidMoveToWindow { [super viewDidMoveToWindow]; [self setNeedsLayout:YES]; }
- (void)viewDidChangeBackingProperties { [super viewDidChangeBackingProperties]; [self setNeedsLayout:YES]; }
- (void)dealloc { if (session) session->close(); }
@end
#else
@interface ZyrenMetalHost : UIView <FlutterPlatformView> {
@public std::shared_ptr<Session> session;
}
@end
@implementation ZyrenMetalHost
+ (Class)layerClass { return CAMetalLayer.class; }
- (UIView *)view { return self; }
- (void)layoutSubviews { [super layoutSubviews]; if (session) session->resize(self.bounds.size, self.window.screen.scale ?: 1, self.window != nil); }
- (void)didMoveToWindow { [super didMoveToWindow]; [self setNeedsLayout]; }
- (void)dealloc { if (session) session->close(); }
@end
#endif

@implementation ZyrenMetalViews {
  Api _api;
  void *(^_connect)(uint64_t);
  FlutterMethodChannel *_channel;
  std::map<int64_t, std::weak_ptr<Session>> _sessions;
}
- (instancetype)initWithRegistrar:(NSObject<FlutterPluginRegistrar> *)registrar connect:(void *(^)(uint64_t))connect {
  self = [super init];
  if (self) {
    _connect = [connect copy];
    _channel = [FlutterMethodChannel methodChannelWithName:@"zyren/metal-proof" binaryMessenger:registrar.messenger];
    __weak ZyrenMetalViews *weak = self;
    [_channel setMethodCallHandler:^(FlutterMethodCall *call, FlutterResult result) {
      ZyrenMetalViews *owner = weak;
      if (owner) [owner handle:call result:result]; else result(FlutterMethodNotImplemented);
    }];
    [registrar registerViewFactory:self withId:@"zyren/metal-proof"];
  }
  return self;
}
- (NSObject<FlutterMessageCodec> *)createArgsCodec { return [FlutterStandardMessageCodec sharedInstance]; }
#if __has_include(<FlutterMacOS/FlutterMacOS.h>)
- (NSView *)createWithViewIdentifier:(int64_t)viewId arguments:(id)args {
  ZyrenMetalHost *host = [[ZyrenMetalHost alloc] initWithFrame:NSZeroRect];
  host.wantsLayer = YES;
  host.layer = [CAMetalLayer layer];
#else
- (NSObject<FlutterPlatformView> *)createWithFrame:(CGRect)frame viewIdentifier:(int64_t)viewId arguments:(id)args {
  ZyrenMetalHost *host = [[ZyrenMetalHost alloc] initWithFrame:frame];
#endif
  if (!_api.create || ![args isKindOfClass:NSDictionary.class] ||
      ![args[@"initial"] isKindOfClass:NSString.class] || ![args[@"steady"] isKindOfClass:NSString.class]) {
    errors.fetch_add(1);
    return host;
  }
  host->session = std::make_shared<Session>(_api, (CAMetalLayer *)host.layer, args);
  _sessions[viewId] = host->session;
  host->session->start();
  return host;
}
- (void)handle:(FlutterMethodCall *)call result:(FlutterResult)result {
  NSDictionary *args = [call.arguments isKindOfClass:NSDictionary.class] ? call.arguments : @{};
  if ([call.method isEqualToString:@"connect"]) {
    NSNumber *token = args[@"runtime"];
    Api api;
    if (![token isKindOfClass:NSNumber.class] || !api.load(_connect(token.unsignedLongLongValue))) {
      result([FlutterError errorWithCode:@"runtimeMismatch" message:@"The Metal view could not attach to the loaded GPU runtime." details:nil]); return;
    }
    _api = api;
    result(nil); return;
  }
  if ([call.method isEqualToString:@"close"]) {
    NSNumber *identity = args[@"view"];
    if (![identity isKindOfClass:NSNumber.class]) { result([FlutterError errorWithCode:@"invalidView" message:@"A platform view ID is required." details:nil]); return; }
    auto found = _sessions.find(identity.longLongValue);
    if (found != _sessions.end()) {
      if (auto session = found->second.lock()) session->close();
      _sessions.erase(found);
    }
    result(nil); return;
  }
  if ([call.method isEqualToString:@"suspend"]) {
    NSNumber *identity = args[@"view"], *suspended = args[@"suspended"];
    if (![identity isKindOfClass:NSNumber.class] || ![suspended isKindOfClass:NSNumber.class]) {
      result([FlutterError errorWithCode:@"invalidView" message:@"A platform view ID and suspended flag are required." details:nil]); return;
    }
    auto found = _sessions.find(identity.longLongValue);
    if (found != _sessions.end()) if (auto session = found->second.lock()) {
      session->active.store(!suspended.boolValue);
      session->epoch.fetch_add(1);
    }
    result(nil); return;
  }
  if ([call.method isEqualToString:@"diagnostics"]) {
    NSMutableDictionary *views = [NSMutableDictionary new];
    for (auto it = _sessions.begin(); it != _sessions.end();) {
      if (auto session = it->second.lock()) {
        std::lock_guard<std::mutex> lock(session->errorLock);
        views[@(it->first)] = @{@"frames": @(session->completed.load()), @"width": @(session->width.load()), @"height": @(session->height.load()), @"error": session->error ?: NSNull.null};
        ++it;
      } else { it = _sessions.erase(it); }
    }
    result(@{@"frames": @(frames.load()), @"errors": @(errors.load()), @"drawables": @(drawables.load()),
      @"timeouts": @(timeouts.load()), @"renderers": @(_api.live ? _api.live() : 0),
      @"retiring": @(_api.retiring ? _api.retiring() : 0), @"views": views,
      @"readbackBytes": @(readbackBytes.load()), @"sessions": @(liveSessions.load())}); return;
  }
  result(FlutterMethodNotImplemented);
}
- (void)closeAll {
  for (auto &entry : _sessions) if (auto session = entry.second.lock()) session->close();
  _sessions.clear();
}
- (void)dealloc { [self closeAll]; [_channel setMethodCallHandler:nil]; }
@end
