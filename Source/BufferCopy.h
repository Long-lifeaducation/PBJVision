//
//  BufferCopy.h
//  Pods
//
//  Created by David Wolstencroft  on 9/2/15.
//
//

#ifndef __Pods__BufferCopy__
#define __Pods__BufferCopy__

#include <inttypes.h>

void CopyBufferNV12(uint8_t *srcY, uint8_t *srcUV, size_t srcYRowBytes, size_t srcYVRowBytes,
                           uint8_t *dstY, uint8_t *dstUV, size_t dstYRowBytes, size_t dstYVRowBytes,
                           size_t height, size_t width);

void CopyBufferNV12Mirror(uint8_t *srcY, uint8_t *srcUV, size_t srcYRowBytes, size_t srcYVRowBytes,
                           uint8_t *dstY, uint8_t *dstUV, size_t dstYRowBytes, size_t dstYVRowBytes,
                           size_t height, size_t width);

#endif /* defined(__Pods__BufferCopy__) */
