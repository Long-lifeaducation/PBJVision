//
//  SwapRedGreenFilter.m
//  Pods
//
//  Created by Michael Harville on 3/5/15.
//
//

#import "CustomFilter.h"
#define STRINGIZE(x) #x
#define STRINGIZE2(x) STRINGIZE(x)
#define SHADER_STRING(text) @ STRINGIZE2(text)

NSString *const kSplitFilterShaderString = SHADER_STRING
(
 kernel vec4 vignette ( __sample left ,
                       __sample right ,
                       float offset )
{
    vec2 v0 = destCoord();
    float x = v0.x;
    
    if(x > offset) { return right ; }
    
    return left ;
}
 );

@implementation CustomFilter

- (CIImage *)outputImage
{
    CGRect dod = self.left.extent ;
    NSLog(@"%f", self.offset);
    if(self.offset <= 1.0)
    {
//        CGFloat offset = dod.size.width - (dod.size.width * self.offset);
//        CIKernel *kernel = [CIColorKernel kernelWithString:kVignetteFragmentShaderString];
//        return [kernel applyWithExtent : dod
//                                  arguments : @[_inputImage, @(offset)]];
        
        CGFloat offset = dod.size.width - (dod.size.width * self.offset);
        CIColorKernel *kernel = [CIColorKernel kernelWithString:kSplitFilterShaderString];
        return [kernel applyWithExtent:dod arguments:@[self.left, self.right, @(offset)]];
    }
    
    else
    {
        return self.left;
    }
    
    
}

@end
