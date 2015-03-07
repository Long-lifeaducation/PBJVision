//
//  SwapRedGreenFilter.h
//  Pods
//
//  Created by Michael Harville on 3/5/15.
//
//

#import <CoreImage/CoreImage.h>

@interface CustomFilter : CIFilter

@property (retain, nonatomic) CIImage *left;
@property (retain, nonatomic) CIImage *right;
@property (copy, nonatomic) NSNumber *inputAmount;
@property CGFloat offset;

@end
