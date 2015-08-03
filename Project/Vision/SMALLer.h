//
//  SMALLer.h
//  SMule Audio Layer Library (extra reliable)
//
//  Created by Nick Kruge on 11/28/11.
//  Copyright (c) 2011 Smule, Inc. All rights reserved.
//

#pragma once

// define ONLY ONE of these, based on if you want a C or obj-C style callback
 #define __REMOTE_IO_USE_OBJ_C_CALLBACK__
// #define __REMOTE_IO_USE_C_CALLBACK__

#import <AudioUnit/AudioUnit.h>
#import <CoreMedia/CoreMedia.h>

typedef void(^AudioCallbackBlock)( Float32 *bufferL, Float32 *bufferR, UInt16 framesize) ;
typedef void (*AudioCallbackCStyle)( Float32 *bufferL, Float32 *bufferR, unsigned int numFrames, void * userData );
typedef void(^SampleBufferCallbackBlock)( CMSampleBufferRef sampleBuffer) ;


@protocol SMALLerDelegate;

@interface SMALLer : NSObject

#ifdef __REMOTE_IO_USE_OBJ_C_CALLBACK__
// initializing with obj c callback
- (id)initWithSampleRate:(double)_srate bufferSize:(UInt16)_buffsize callback:(AudioCallbackBlock)_callback;
#endif

#ifdef __REMOTE_IO_USE_C_CALLBACK__
// initializing with c callback
- (id)initWithSampleRate:(double)_srate bufferSize:(UInt16)_buffsize CStyleCallback:(AudioCallbackCStyle)_callback userData:(void*)_data;
#endif

// for fast app switching support
- (BOOL)suspendSession;
- (void)restartSession;

- (NSString*)getCurrentRoute;
- (BOOL)hasHeadphonesPluggedIn;
- (BOOL)isRouteHeadphonesOrAirplay;
- (BOOL)hasHeadsetPluggedIn;

// set if we are to use mic input or not
- (BOOL)useMicInput:(BOOL)useMic;

/** ability to toggle bluetooth support on and off */
- (OSStatus)enableBluetooth:(BOOL)val;

// set if we are going to override to the speaker or not
- (BOOL)overrideToSpeaker:(BOOL)override;

- (void)startAudioSession;

- (BOOL)sessionStarted;

- (BOOL)sessionFailure;

- (BOOL)sessionInterrupted;

- (void)resetBufferDuration;

@property (nonatomic, weak) id<SMALLerDelegate> delegate;

// track these things publicly with accessors
@property (nonatomic,readonly) double srate;
@property (nonatomic,readonly) UInt16 buffsize;
@property (nonatomic,readonly) BOOL   useMic;
@property (nonatomic,readonly) BOOL   hasMic;
@property (nonatomic,assign) BOOL   initializeAudioUnit;
@property (nonatomic,readwrite) AudioUnit audioUnit;

// stores the block that contains the audio callback
@property (nonatomic,copy) AudioCallbackBlock audioCallbackBlock;

@property (nonatomic,copy) SampleBufferCallbackBlock sampleBufferCallbackBlock;

@end


@protocol SMALLerDelegate <NSObject>

- (void)SMALLerSessionStateChanged:(SMALLer*)SMALLer;
- (void)SMALLerRouteChanged:(SMALLer*)SMALLer;
- (void)SMALLerInterruptionEnded:(SMALLer*)SMALLer;
- (void)SMALLerDidBeginInterruption:(SMALLer*)SMALLer;

@end
