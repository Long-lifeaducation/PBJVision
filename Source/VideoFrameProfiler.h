//
//  VideoFrameProfiler.h
//  Pods
//
//  Created by Joel Davis on 6/10/15.
//
//

#import <Foundation/Foundation.h>

@interface VideoFrameProfiler : NSObject

+ (VideoFrameProfiler *)sharedProfiler;

- (id) init;

- (void) reset;

- (void)beginNextFrame;
- (void)beginFrame: (uint32_t)frameNumber;
- (void)addFrameEvent: (NSString*)desc;

- (void)writeVideoLog: (NSString*)vidlog;

@end
