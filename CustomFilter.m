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

NSString *const kSwapRedGreenFragmentShaderString = SHADER_STRING
(
     kernel vec4 swapRedAndGreenAmount ( __sample s,float offset )
    {
        vec2 v0 = destCoord();
        float x = v0.x;
        
        if(x > offset) { return mix(s.rgba, s.grba, 1.0); }
        
        return vec4 ( s.rgb * .4, s.a ) ;
        
    }
 );

NSString *const kVignetteFragmentShaderString = SHADER_STRING
(
 kernel vec4 vignette ( __sample s ,
                       float offset )
{
    vec2 v0 = destCoord();
    float x = v0.x;
    
    if(x > offset) { return vec4 ( s.rgb * .4, s.a ) ; }
    
    return s ;
}
 );

NSString *const kHazeFragmentShaderString = SHADER_STRING
(
     kernel vec4 myHazeRemovalKernel(sampler src,             // 1
                                     __color color,
                                     float distance,
                                     float slope)
    {
        vec4   t;
        float  d;
        
        d = destCoord().y * slope  +  distance;              // 2
        t = unpremultiply(sample(src, samplerCoord(src)));   // 3
        t = (t - d*color) / (1.0-d);                         // 4
        
        return premultiply(t);                               // 5
}
 );

@implementation CustomFilter

static CIKernel *hazeRemovalKernel = nil;

- (CIKernel *) myKernel {
    static CIColorKernel *kernel = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        kernel = [CIColorKernel kernelWithString:@"kernel vec4 swapRedAndGreenAmount ( __sample s, float amount ){ return mix(s.rgba, s.grba, amount); }"];
    });
    return kernel;
}

- (CIImage *)outputImage
{
    CGRect dod = _inputImage.extent ;

//    CIKernel *kernel = [CIColorKernel kernelWithString:kVignetteFragmentShaderString];
//    CIImage *image = [kernel applyWithExtent : dod
//                              arguments : @[_inputImage, _inputAmount]];
    CIImage *image = nil;
    
    
    if(self.offset <= 1.0)
    {
        CGFloat offset = dod.size.width - (dod.size.width * self.offset);
        NSLog(@"%f", offset);
        CIKernel *kernel = [CIColorKernel kernelWithString:kVignetteFragmentShaderString];
        return [kernel applyWithExtent : dod
                                  arguments : @[_inputImage, @(offset)]];
    }
    
    else if(self.offset <= 2.0)
    {
        CGFloat offset = dod.size.width - (dod.size.width * (self.offset - 1.0));
        NSLog(@"%f", offset);
        CIKernel *kernel = [CIColorKernel kernelWithString:kSwapRedGreenFragmentShaderString];
        return [kernel applyWithExtent : dod
                             arguments : @[_inputImage, @(offset)]];
    }
    
    else
    {
        return _inputImage;
    }
    
    
}

@end
