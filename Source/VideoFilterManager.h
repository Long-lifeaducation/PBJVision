//
//  VideoFilterManager.h
//  Sing
//
//  Created by Michael Harville on 1/30/15.
//  Copyright (c) 2015 Smule. All rights reserved.
//

#import <UIKit/UIKit.h>

@interface VideoFilterManager : NSObject

+ (NSUInteger)numFilters;

+ (CIImage*)filterImage:(CIImage*)image withFilterIndex:(NSUInteger)index;

@end
