//
//  BufferCopy.c
//  Pods
//
//  Created by David Wolstencroft  on 9/2/15.
//
//

#include "BufferCopy.h"
#include <string.h>

void CopyBufferNV12(uint8_t * __restrict srcY, uint8_t * __restrict srcUV, size_t srcYRowBytes, size_t srcUVRowBytes,
                           uint8_t * __restrict dstY, uint8_t * __restrict dstUV, size_t dstYRowBytes, size_t dstUVRowBytes,
                           size_t width, size_t height)
{
    size_t i;

    for (i = 0; i < height; i++)
    {
        memcpy(dstY, srcY, width);
        srcY += srcYRowBytes;
        dstY += dstYRowBytes;
    }

    for (i = 0; i < height/2; i++)
    {
        memcpy(dstUV, srcUV, width);
        srcUV += srcUVRowBytes;
        dstUV += dstUVRowBytes;
    }
}

// clang/llvm is nice enough do to a good job of autovectorizing this,
// though does not take alignment into consideration
// most of the time is spent in a vswap.64, not vld1.8/vst1.8, so I dunno how much
// hand tuning this uwould speed things p - xcode's version of clang doesn't yet take alignment hints :(
// nor do neon intrinsics in clang or gcc allow for it yet
void CopyBufferNV12Mirror(uint8_t * __restrict srcY, uint8_t * __restrict srcUV, size_t srcYRowBytes, size_t srcUVRowBytes,
                        uint8_t * __restrict dstY, uint8_t * __restrict dstUV, size_t dstYRowBytes, size_t dstUVRowBytes,
                        size_t width, size_t height)
{
    size_t i;
    size_t j;

    // Copy Y Plane Reversed
    for (i = 0; i < height; i++)
    {
        for (j = 0; j < width; j++)
        {
            dstY[width-j] = srcY[j];
        }
        srcY += srcYRowBytes;
        dstY += dstYRowBytes;
    }

    // Copy UV plane reversed.
    for (i = 0; i < height/2; i++)
    {
        for (j = 0; j < width; j++)
        {
            dstUV[width-j] = srcUV[j];
        }
        srcUV += srcUVRowBytes;
        dstUV += dstUVRowBytes;
    }
}
