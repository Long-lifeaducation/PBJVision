//
//  SplitFilter.h
//  Pods
//
//  Created by Michael Harville on 3/5/15.
//
//

#import <CoreImage/CoreImage.h>

@interface SplitFilter : CIFilter

@property (retain, nonatomic) CIImage *left;
@property (retain, nonatomic) CIImage *right;
@property CGFloat offset;

@end
