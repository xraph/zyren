#include "../../main/cpp/xr_surface_extent.h"
#include <cassert>

int main() {
 auto matches=[](uint32_t w,uint32_t h,uint32_t actualW,uint32_t actualH) {
  return xrSurfaceExtentMatches(w,h,actualW,actualH,1,1,4096,4096);
 };
 assert(matches(1080,1920,1080,1920));
 // A queued landscape callback can arrive before the WSI window resizes.
 assert(!matches(1920,1080,1080,1920));
 // A revoked portrait drawable can be discarded after the window resizes.
 assert(!matches(1080,1920,1920,1080));
 assert(matches(1920,1080,1920,1080));
 assert(matches(1920,1080,UINT32_MAX,UINT32_MAX));
 assert(!matches(0,1080,UINT32_MAX,UINT32_MAX));
 assert(!matches(4097,1080,UINT32_MAX,UINT32_MAX));
 assert(!xrSurfaceExtentMatches(1080,1920,UINT32_MAX,UINT32_MAX,1,1,1024,2048));
}
