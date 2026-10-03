#pragma once
#include <cstdint>

// A fixed WSI extent can lag the SurfaceHolder callback during rotation.
// Never substitute it for the dimensions used by ARCore calibration.
inline bool xrSurfaceExtentMatches(uint32_t requestedWidth, uint32_t requestedHeight,
                                  uint32_t currentWidth, uint32_t currentHeight,
                                  uint32_t minWidth, uint32_t minHeight,
                                  uint32_t maxWidth, uint32_t maxHeight) {
 return requestedWidth && requestedHeight && requestedWidth<=4096 && requestedHeight<=4096 &&
        requestedWidth>=minWidth && requestedHeight>=minHeight &&
        requestedWidth<=maxWidth && requestedHeight<=maxHeight &&
        (currentWidth==UINT32_MAX || currentWidth==requestedWidth) &&
        (currentHeight==UINT32_MAX || currentHeight==requestedHeight);
}
