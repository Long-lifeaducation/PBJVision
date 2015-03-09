//
//  VideoFilterManager.m
//  Sing
//
//  Created by Michael Harville on 1/30/15.
//  Copyright (c) 2015 Smule. All rights reserved.
//

#import "VideoFilterManager.h"

typedef enum FILTER_TYPE : NSUInteger{
    FILTER_TYPE_NONE,
    FILTER_TYPE_BLACKNWHITE,
    FILTER_TYPE_SEPIA,
    FILTER_TYPE_VINTAGE,
    FILTER_TYPE_FACE,
    FILTER_TYPE_TURKEY,
    FILTER_TYPE_HALFTONE,
    FILTER_TYPE_PINKEDGE
} FILTER_TYPE;

@implementation VideoFilterManager

+ (NSUInteger)numFilters
{
    return 8;
}

+ (CIImage*)filterImage:(CIImage*)image withFilterIndex:(NSUInteger)index
{
    switch (index) {
        case FILTER_TYPE_NONE:
            return image;
            break;
        case FILTER_TYPE_BLACKNWHITE:
        {
            CIImage *blackAndWhite = [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, image, @"inputBrightness", [NSNumber numberWithFloat:0.0], @"inputContrast", [NSNumber numberWithFloat:1.1], @"inputSaturation", [NSNumber numberWithFloat:0.0], nil].outputImage;
            return [CIFilter filterWithName:@"CIExposureAdjust" keysAndValues:kCIInputImageKey, blackAndWhite, @"inputEV", [NSNumber numberWithFloat:0.7], nil].outputImage;
            break;
        }
        case FILTER_TYPE_SEPIA:
        {
            CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
            [filter setValue:@0.8 forKey:@"InputIntensity"];
            [filter setValue:image forKey:kCIInputImageKey];
            return [filter valueForKey:kCIOutputImageKey];
            break;
        }
        case FILTER_TYPE_VINTAGE:
        {
            CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
            [filter setValue:@0.1 forKey:@"InputIntensity"];
            [filter setValue:image forKey:kCIInputImageKey];
            return [filter valueForKey:kCIOutputImageKey];
            break;
        }
        case FILTER_TYPE_FACE:
        {
            CIFilter *filter = [CIFilter filterWithName:@"CIColorControls"];
            [filter setValue:@2.0 forKey:@"inputContrast"];
            [filter setValue:image forKey:kCIInputImageKey];
            return [filter valueForKey:kCIOutputImageKey];
            break;
        }
        case FILTER_TYPE_TURKEY:
        {
            CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
            [filter setValue:@0.8 forKey:@"InputIntensity"];
            [filter setValue:image forKey:kCIInputImageKey];
            return [filter valueForKey:kCIOutputImageKey];
            break;
        }
        case FILTER_TYPE_HALFTONE:
        {
            CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
            [filter setValue:@0.1 forKey:@"InputIntensity"];
            [filter setValue:image forKey:kCIInputImageKey];
            return [filter valueForKey:kCIOutputImageKey];
            break;
        }
        case FILTER_TYPE_PINKEDGE:
        {
            CIImage *blackAndWhite = [CIFilter filterWithName:@"CIColorControls" keysAndValues:kCIInputImageKey, image, @"inputBrightness", [NSNumber numberWithFloat:0.0], @"inputContrast", [NSNumber numberWithFloat:1.1], @"inputSaturation", [NSNumber numberWithFloat:0.0], nil].outputImage;
            return [CIFilter filterWithName:@"CIExposureAdjust" keysAndValues:kCIInputImageKey, blackAndWhite, @"inputEV", [NSNumber numberWithFloat:0.7], nil].outputImage;
            break;
        }
        default:
            return nil;
            break;
    }
}

@end
