//
//  BufferCopy.c
//  Pods
//
//  Created by David Wolstencroft  on 9/2/15.
//
//

#include "BufferCopy.h"
#include <string.h>

#ifdef __ARM_NEON
#include <arm_neon.h>
#endif

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
// hand tuning this would speed things up - xcode's version of clang doesn't yet take alignment hints :(
// nor do neon intrinsics in clang or gcc allow for it yet
void CopyBufferNV12Mirror(uint8_t * __restrict srcY, uint8_t * __restrict srcUV, size_t srcYRowBytes, size_t srcUVRowBytes,
                          uint8_t * __restrict dstY, uint8_t * __restrict dstUV, size_t dstYRowBytes, size_t dstUVRowBytes,
                          size_t width, size_t height)
{
    size_t i;
    size_t j;
    size_t widthIndexY = width - 1;

    // Copy Y Plane Reversed
    for (i = 0; i < height; i++)
    {
#pragma clang loop vectorize(enable) interleave(enable)
        for (j = 0; j < width; j++)
        {
            dstY[widthIndexY-j] = srcY[j];
        }
        srcY += srcYRowBytes;
        dstY += dstYRowBytes;
    }

    // Copy UV plane reversed.
    // below to help clang autovectorize
    uint16_t *srcUV16 = (uint16_t*)srcUV;
    uint16_t *dstUV16 = (uint16_t*)dstUV;
    size_t widthIndexUV = (width/2) - 1;
    for (i = 0; i < height/2; i++)
    {
#pragma clang loop vectorize(enable) interleave(enable)
        for (j = 0; j < width/2; j++)
        {
            dstUV16[widthIndexUV-j] = srcUV16[j];
        }
        srcUV16 += srcUVRowBytes/2;
        dstUV16 += dstUVRowBytes/2;
    }
}

#ifdef __ARM_NEON

uint32_t Luminance(uint8_t *Y, size_t YRowBytes, size_t width, size_t height)
{
    size_t i, j, overrun;
    uint32_t luminance = 0;
    uint32x4_t lumAccumulation = {0};

    overrun = width & 0xF;

    for (i = 0; i < height; i++)
    {
        uint8_t *y = Y;
        uint16x8_t rowLumAccumulation = {0};

        for (j = 0; j <= (width-16); j+=16)
        {
            uint8x16_t yVec = vld1q_u8(y);
            rowLumAccumulation = vpadalq_u8(rowLumAccumulation, yVec);
            y += 16;
        }

        // past vector end if needed
        for (j = 0; j < overrun; j++)
        {
            luminance += *y++;
        }

        lumAccumulation = vpadalq_u16(lumAccumulation, rowLumAccumulation);
        Y+= YRowBytes;
    }

    luminance += vgetq_lane_u32(lumAccumulation, 0);
    luminance += vgetq_lane_u32(lumAccumulation, 1);
    luminance += vgetq_lane_u32(lumAccumulation, 2);
    luminance += vgetq_lane_u32(lumAccumulation, 3);

    return (luminance/(width*height));
}

#else

uint32_t Luminance(uint8_t *Y, size_t YRowBytes, size_t width, size_t height)
{
    size_t i;
    size_t j;
    uint32_t luminance = 0;

    for (i = 0; i < height; i++)
    {
        uint8_t *y = Y;
#pragma clang loop vectorize(enable) interleave(enable)
        for (j = 0; j < width; j++)
        {
            luminance += y++;
        }
        Y += YRowBytes;
    }

    return (luminance/(width*height));;
}
#endif


