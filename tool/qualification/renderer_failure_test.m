#import "../../packages/flutter_zyren/darwin/Classes/ZyrenRendererFailure.h"
#include <assert.h>

int main(void) {
  @autoreleasepool {
    assert([ZyrenRendererFailureCode(@"GPU completion failed; recreate this renderer: wait timed out") isEqualToString:@"deviceLost"]);
    assert([ZyrenRendererFailureCode(@"Graph device failed; recreate this renderer") isEqualToString:@"deviceLost"]);
    assert([ZyrenRendererFailureCode(@"resource allocation exceeds the device budget") isEqualToString:@"renderFailed"]);
    assert([ZyrenRendererFailureCode(@"Invalid scene packet") isEqualToString:@"renderFailed"]);
    assert([ZyrenRendererFailureCode(@"Native renderer failed.") isEqualToString:@"renderFailed"]);
  }
  return 0;
}
