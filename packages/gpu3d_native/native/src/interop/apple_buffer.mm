#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceRef.h>
#import <Metal/Metal.h>
#import <objc/runtime.h>
#include <cstdint>

typedef void (*ReleaseOwner)(void *);
@interface Gpu3dSurfaceAllocation : NSObject
@property(nonatomic, assign) void *context;
@property(nonatomic, assign) ReleaseOwner releaseOwner;
@end
@implementation Gpu3dSurfaceAllocation
- (void)dealloc { if (_releaseOwner) _releaseOwner(_context); }
@end
static char allocationKey;

extern "C" uint64_t fg_apple_allocation_size(uint32_t width, uint32_t height) {
  size_t row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4);
  return IOSurfaceAlignProperty(kIOSurfaceAllocSize, row * height);
}
// Consumes context only on success. Its guard follows the IOSurface through
// pixel buffers and Metal views until the last native owner releases storage.
extern "C" void *fg_apple_buffer_create(uint32_t width, uint32_t height,
                                         void *context, ReleaseOwner release) {
  @autoreleasepool {
    size_t row = IOSurfaceAlignProperty(kIOSurfaceBytesPerRow, width * 4);
    uint64_t bytes = fg_apple_allocation_size(width, height);
    NSDictionary *properties = @{(id)kIOSurfaceWidth: @(width),
      (id)kIOSurfaceHeight: @(height), (id)kIOSurfaceBytesPerElement: @4,
      (id)kIOSurfaceBytesPerRow: @(row), (id)kIOSurfaceAllocSize: @(bytes),
      (id)kIOSurfacePixelFormat: @(kCVPixelFormatType_32BGRA)};
    IOSurfaceRef surface = IOSurfaceCreate((__bridge CFDictionaryRef)properties);
    if (!surface) return nullptr;
    if (IOSurfaceGetAllocSize(surface) != bytes) { CFRelease(surface); return nullptr; }
    CVPixelBufferRef buffer = nullptr;
    NSDictionary *attributes = @{(id)kCVPixelBufferMetalCompatibilityKey: @YES};
    CVReturn status = CVPixelBufferCreateWithIOSurface(nullptr, surface,
                            (__bridge CFDictionaryRef)attributes, &buffer);
    if (status == kCVReturnSuccess) {
      Gpu3dSurfaceAllocation *owner = [Gpu3dSurfaceAllocation new];
      owner.context = context;
      owner.releaseOwner = release;
      objc_setAssociatedObject((__bridge id)surface, &allocationKey, owner,
                               OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    CFRelease(surface);
    return buffer;
  }
}
extern "C" void *fg_apple_buffer_texture(void *buffer, void *metalDevice) {
  @autoreleasepool {
    CVPixelBufferRef pixels = static_cast<CVPixelBufferRef>(buffer);
    id<MTLDevice> device = (__bridge id<MTLDevice>)metalDevice;
    MTLTextureDescriptor *descriptor = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm_sRGB
      width:CVPixelBufferGetWidth(pixels) height:CVPixelBufferGetHeight(pixels)
      mipmapped:NO];
    descriptor.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
    descriptor.storageMode = MTLStorageModeShared;
    id<MTLTexture> texture = [device newTextureWithDescriptor:descriptor
      iosurface:CVPixelBufferGetIOSurface(pixels) plane:0];
    return (__bridge_retained void *)texture;
  }
}
extern "C" void fg_apple_buffer_retain(void *buffer) { CFRetain(buffer); }
extern "C" void fg_apple_buffer_release(void *buffer) {
  @autoreleasepool { CFRelease(buffer); }
}
