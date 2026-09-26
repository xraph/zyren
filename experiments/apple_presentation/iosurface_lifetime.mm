#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <atomic>
#include <cstdio>
#include <cstdlib>

static std::atomic<int> destroyed{0};
static char ownerKey;
static void require(bool condition, const char *message) {
  if (!condition) {
    std::fprintf(stderr, "FAIL: %s\n", message);
    std::exit(1);
  }
}
@interface SurfaceOwner : NSObject
@end
@implementation SurfaceOwner
- (void)dealloc { destroyed.fetch_add(1); }
@end

static NSDictionary *attributes() {
  return @{(id)kCVPixelBufferIOSurfacePropertiesKey : @{},
           (id)kCVPixelBufferMetalCompatibilityKey : @YES};
}

// Characterize the pinned Flutter importer: it keeps the MTLTexture after
// releasing the CVMetalTexture wrapper. A pool can then recycle its IOSurface.
static void poolCannotEstablishConsumerRelease(id<MTLDevice> device) {
  CVPixelBufferPoolRef pool = nullptr;
  NSMutableDictionary *description = [attributes() mutableCopy];
  description[(id)kCVPixelBufferWidthKey] = @64;
  description[(id)kCVPixelBufferHeightKey] = @64;
  description[(id)kCVPixelBufferPixelFormatTypeKey] = @(kCVPixelFormatType_32BGRA);
  require(CVPixelBufferPoolCreate(nullptr, nullptr,
              (__bridge CFDictionaryRef)description, &pool) == kCVReturnSuccess,
          "create pixel buffer pool");
  NSDictionary *limit = @{(id)kCVPixelBufferPoolAllocationThresholdKey : @1};
  CVPixelBufferRef first = nullptr;
  require(CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr, pool,
              (__bridge CFDictionaryRef)limit, &first) == kCVReturnSuccess,
          "acquire first pool buffer");
  IOSurfaceID firstId = IOSurfaceGetID(CVPixelBufferGetIOSurface(first));
  CVMetalTextureCacheRef cache = nullptr;
  require(CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache) ==
              kCVReturnSuccess, "create pool texture cache");
  id<MTLTexture> held;
  @autoreleasepool {
    CVMetalTextureRef wrapper = nullptr;
    require(CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, first,
                nullptr, MTLPixelFormatBGRA8Unorm, 64, 64, 0, &wrapper) ==
                kCVReturnSuccess, "import pool buffer");
    held = CVMetalTextureGetTexture(wrapper);
    CFRelease(wrapper);
    CVPixelBufferRelease(first);
    CVMetalTextureCacheFlush(cache, 0);
  }
  CVPixelBufferRef second = nullptr;
  CVReturn result = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(nullptr,
      pool, (__bridge CFDictionaryRef)limit, &second);
  const bool reused = result == kCVReturnSuccess &&
      IOSurfaceGetID(CVPixelBufferGetIOSurface(second)) == firstId;
  require(held.width == 64, "consumer still holds its texture");
  require(reused, "pool characterization changed; reassess ownership strategy");
  std::printf("pool: recycled IOSurface with consumer MTLTexture still held\n");
  if (second) CVPixelBufferRelease(second);
  held = nil;
  CFRelease(cache);
  CFRelease(pool);
}

static void commandRetainsSurface(id<MTLDevice> device) {
  destroyed.store(0);
  id<MTLCommandQueue> queue = [device newCommandQueue];
  id<MTLSharedEvent> gate = [device newSharedEvent];
  dispatch_semaphore_t completion = dispatch_semaphore_create(0);
  dispatch_semaphore_t released = dispatch_semaphore_create(0);
  // An independent timer releases the GPU even if a proof assertion fails.
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                 dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    gate.signaledValue = 1;
    dispatch_semaphore_signal(released);
  });
  @autoreleasepool {
    CVPixelBufferRef buffer = nullptr;
    require(CVPixelBufferCreate(nullptr, 63, 47, kCVPixelFormatType_32BGRA,
                (__bridge CFDictionaryRef)attributes(), &buffer) == kCVReturnSuccess,
            "allocate direct IOSurface buffer");
    IOSurfaceRef surface = CVPixelBufferGetIOSurface(buffer);
    require(surface != nullptr, "buffer has an IOSurface");
    objc_setAssociatedObject((__bridge id)surface, &ownerKey,
                             [SurfaceOwner new], OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    CVMetalTextureCacheRef cache = nullptr;
    require(CVMetalTextureCacheCreate(nullptr, nullptr, device, nullptr, &cache) ==
                kCVReturnSuccess, "create texture cache");
    CVMetalTextureRef wrapper = nullptr;
    require(CVMetalTextureCacheCreateTextureFromImage(nullptr, cache, buffer,
                nullptr, MTLPixelFormatBGRA8Unorm, 63, 47, 0, &wrapper) ==
                kCVReturnSuccess, "import direct buffer");
    id<MTLTexture> texture = CVMetalTextureGetTexture(wrapper);
    id<MTLCommandBuffer> command = [queue commandBuffer];
    require(command.retainedReferences, "Metal command retains used resources");
    [command encodeWaitForEvent:gate value:1];
    MTLRenderPassDescriptor *pass = [MTLRenderPassDescriptor renderPassDescriptor];
    pass.colorAttachments[0].texture = texture;
    pass.colorAttachments[0].loadAction = MTLLoadActionClear;
    pass.colorAttachments[0].storeAction = MTLStoreActionStore;
    pass.colorAttachments[0].clearColor = MTLClearColorMake(1, 0, 0, 1);
    id<MTLRenderCommandEncoder> encoder = [command renderCommandEncoderWithDescriptor:pass];
    require(encoder != nil, "create render encoder");
    [encoder endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> completed) {
      require(completed.status == MTLCommandBufferStatusCompleted, "GPU completed");
      dispatch_semaphore_signal(completion);
    }];
    [command commit];
    encoder = nil;
    pass = nil;
    texture = nil;
    command = nil;
    CFRelease(wrapper);
    CVPixelBufferRelease(buffer);
    CVMetalTextureCacheFlush(cache, 0);
    CFRelease(cache);
  }
  require(gate.signaledValue == 0, "command remains blocked for retention proof");
  require(destroyed.load() == 0, "owner survives pixel buffer and wrapper release");
  std::printf("direct: owner retained while only blocked GPU work owns texture\n");
  require(dispatch_semaphore_wait(completion,
              dispatch_time(DISPATCH_TIME_NOW, 5 * NSEC_PER_SEC)) == 0,
          "bounded wait for GPU completion");
  require(dispatch_semaphore_wait(released,
              dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC)) == 0,
          "timer released the gate");
  // Driver completion cleanup may follow the completed handler.
  for (int i = 0; i < 100 && destroyed.load() == 0; ++i) {
    [NSThread sleepForTimeInterval:0.01];
  }
  require(destroyed.load() == 1, "owner released once after GPU use");
  std::printf("direct: owner released once after GPU completion\n");
}
int main() {
  @autoreleasepool {
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    require(device != nil, "Metal device available");
    poolCannotEstablishConsumerRelease(device);
    commandRetainsSurface(device);
  }
  return 0;
}
