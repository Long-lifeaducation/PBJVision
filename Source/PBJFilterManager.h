//
//  PBJFilterManager.h
//  Pods
//
//  Created by Michael Harville on 1/27/15.
//
//

#import <UIKit/UIKit.h>

@interface PBJFilterManager : NSObject

- (CIImage*)filterImage:(CIImage*)image;

- (void)toggleFilter;

- (void)changeIntensity:(CGFloat)value;

@end
