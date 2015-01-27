//
//  PBJFilterManager.m
//  Pods
//
//  Created by Michael Harville on 1/27/15.
//
//

#import "PBJFilterManager.h"

typedef enum {
    FILTER_TYPE_PIXELLATE,
    FILTER_TYPE_SEPIA,
    FILTER_TYPE_PROCESS,
    FILTER_TYPE_CHROME
} FILTER_TYPE;

@interface PBJFilterManager ()
{
    NSMutableArray *_filters;
    FILTER_TYPE _filterType;
    CGFloat _intensity;
}

@end

@implementation PBJFilterManager

- (id)init
{
    self = [super init];
    if(self) {
        _filterType = FILTER_TYPE_PIXELLATE;
        _intensity = 0.5;
    }
    return self;
}

#pragma mark - Filtering

- (CIImage*)filterImage:(CIImage *)image
{
    switch (_filterType) {
        case FILTER_TYPE_PIXELLATE:
            return [self filterImageWithPixellate:image];
            break;
        case FILTER_TYPE_SEPIA:
            return [self filterImageWithSepia:image];
            break;
        case FILTER_TYPE_PROCESS:
            return [self filterImageWithProcess:image];
            break;
        case FILTER_TYPE_CHROME:
            return [self filterImageWithChrome:image];
            break;
        default:
            break;
    }
}

- (CIImage*)filterImageWithPixellate:(CIImage *)image
{
    CIFilter *filter = [CIFilter filterWithName:@"CIPixellate"];
    [filter setValue:image forKey:kCIInputImageKey];
    return filter.outputImage;
}

- (CIImage*)filterImageWithSepia:(CIImage *)image
{
    CIFilter *filter = [CIFilter filterWithName:@"CISepiaTone"];
    [filter setValue:image forKey:kCIInputImageKey];
    return filter.outputImage;
}

- (CIImage*)filterImageWithProcess:(CIImage *)image
{
    CIFilter *filter = [CIFilter filterWithName:@"CIPhotoEffectProcess"];
    [filter setValue:image forKey:kCIInputImageKey];
    return filter.outputImage;
}

- (CIImage*)filterImageWithChrome:(CIImage *)image
{
    CIFilter *filter = [CIFilter filterWithName:@"CIPhotoEffectChrome"];
    [filter setValue:image forKey:kCIInputImageKey];
    return filter.outputImage;
}

#pragma mark - Change filters

- (void)toggleFilter
{
    if(_filterType== FILTER_TYPE_PIXELLATE) _filterType = FILTER_TYPE_SEPIA;
    else if(_filterType == FILTER_TYPE_SEPIA) _filterType = FILTER_TYPE_PROCESS;
    else if(_filterType == FILTER_TYPE_PROCESS) _filterType = FILTER_TYPE_CHROME;
    else if(_filterType == FILTER_TYPE_CHROME) _filterType = FILTER_TYPE_PIXELLATE;
}

- (void)changeIntensity:(CGFloat)value
{
    //[_filter setValue:[NSNumber numberWithFloat:value] forKey:@"inputIntensity"];
}

@end
