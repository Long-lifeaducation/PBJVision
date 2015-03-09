//
//  SplitFilter.m
//  Pods
//
//  Created by Michael Harville on 3/5/15.
//
//

#import "SplitFilter.h"
#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

NSString *const kSplitFilterFragmentShaderString = SHADER_STRING
(
 kernel vec4 splitFilterKernel ( __sample left, __sample right, float offset )
 {
     if(destCoord().x > offset) { return right; }
     return left ;
 }
);

@implementation SplitFilter

- (CIImage *)outputImage
{
    CGRect dod = _left.extent ;
    CGFloat offset = dod.size.width - (dod.size.width * self.offset);
    CIColorKernel *kernel = [CIColorKernel kernelWithString:kSplitFilterFragmentShaderString];
    return [kernel applyWithExtent : dod arguments : @[_left, _right, @(offset)]];
}

@end
