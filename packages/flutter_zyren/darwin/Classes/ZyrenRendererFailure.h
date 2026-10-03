#import <Foundation/Foundation.h>

// These prefixes are emitted only after the Rust renderer has been poisoned.
// Validation and allocation errors keep their normal manual retry behavior.
static inline NSString *ZyrenRendererFailureCode(NSString *message) {
  for (NSString *prefix in @[
    @"GPU completion failed; recreate this renderer:",
    @"GPU resource command failed; recreate this renderer",
    @"Graph device failed; recreate this renderer",
    @"Native shader device failed; recreate this renderer"
  ]) {
    if ([message hasPrefix:prefix]) return @"deviceLost";
  }
  return @"renderFailed";
}
