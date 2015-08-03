//
//   SMALLer.mm
//  SMule Audio Layer Library (extra reliable)
//
//  Created by Nick Kruge on 11/28/11.
//  Copyright (c) 2011 Smule, Inc. All rights reserved.
//

#import "SMALLer.h"
#import <AudioUnit/AudioUnit.h>
#import <AudioToolbox/AudioToolbox.h>
#import <AVFoundation/AVFoundation.h>
#import <MediaPlayer/MediaPlayer.h>
#import <mach/mach_time.h>

#define NUM_CHANNELS 2

//
// note: enabling bluetooth was forcing a buffer size of 2823
// not sure what the upper bound could be here, but 8k feels safe
//
#define MAX_BUFFSIZE 8192

#define kSpeaker @"Speaker"
#define kSpeakerAndMicrophone @"SpeakerAndMicrophone"



#ifdef __REMOTE_IO_USE_C_CALLBACK__
static AudioCallbackCStyle g_audioCallbackCStyle;
static void *              g_callbackUserData;
#endif




#pragma mark callback declarations
void audioRouteChangeListenerCallback (void *inUserData, AudioSessionPropertyID inPropertyID,                                
                                       UInt32 inPropertyValueSize, const void *inPropertyValue );

// used for audio callback
OSStatus inputProc( void * inRefCon, AudioUnitRenderActionFlags * ioActionFlags, 
                    const AudioTimeStamp * inTimeStamp, UInt32 inBusNumber, 
                    UInt32 inNumberFrames, AudioBufferList * ioData );


// we'll be needing a buffer for flt pt conversion
// NOTE: If the samples are interleaved, bufferL will be twice the size, and bufferR will be NULL.
static Float32 g_ioBufferL[MAX_BUFFSIZE * NUM_CHANNELS];
static Float32 g_ioBufferR[MAX_BUFFSIZE];

//static CMSampleBufferRef g_sampleBuffer = NULL;
static CMFormatDescriptionRef g_format = NULL;


#pragma mark - private interface
@interface SMALLer() <AVAudioSessionDelegate>
{
    // are we forcing an overriding to the speaker? (iOS default is to send audio to the 
    // headset if we are both playing back and receiving audio simultaneously)
    BOOL m_speakerOverride;
    
    // have we started the session yet
    
}



// setup and tear down the actual audio unit
- (void)setSessionStarted:(BOOL)val;


- (BOOL)setupAudioUnit;
- (BOOL)disposeSMALLer;

// poll the hardware to ask for the current route
- (BOOL)isOtherAudioPlaying;

- (NSString*)getCurrentRoute;

@property(nonatomic, copy) NSString *lastRoute;
@property(nonatomic) BOOL m_sessionStarted;
@property(nonatomic) BOOL m_sessionFailure;


@end


#pragma mark - main implementation

@implementation SMALLer {
    BOOL m_starting;
    BOOL m_sessionInterrupted;
    dispatch_queue_t serialDispatchQueue;
}
@synthesize srate, buffsize, audioUnit, useMic, hasMic, audioCallbackBlock, delegate;
@synthesize lastRoute = _lastRoute;


@synthesize initializeAudioUnit = _initializeAudioUnit;
@synthesize m_sessionStarted = _m_sessionStarted;
@synthesize m_sessionFailure = _m_sessionFailure;
@synthesize sampleBufferCallbackBlock = _sampleBufferCallbackBlock;
#pragma mark - initializing

// just used to avoid redundancy within the different main inits
- (void)initializeWithRate:(double)_srate bufferSize:(UInt16)_buffsize
{
    m_starting = NO;

    serialDispatchQueue = dispatch_queue_create("com.smule.SMALLer.serialQueue", DISPATCH_QUEUE_SERIAL);

    // store sample rate and clamped buffer size
    srate = _srate;
    buffsize = MIN(_buffsize,MAX_BUFFSIZE);
    
    // by default, mic input is off
    useMic = NO;
    
    // we have not done anything yet
    [self setSessionStarted:NO];

    // make sure we didn't define both callback styles
    #ifdef __REMOTE_IO_USE_OBJ_C_CALLBACK__
    #ifdef __REMOTE_IO_USE_C_CALLBACK__

    [NSException raise:@"[SMALLer] Multiple Callbacks Defined" 
                format:@"Must define only ONE callback style, either __REMOTE_IO_USE_OBJ_C_CALLBACK__ one __REMOTE_IO_USE_C_CALLBACK__"];
    
    #endif
    #endif
}

#ifdef __REMOTE_IO_USE_OBJ_C_CALLBACK__
- (id)initWithSampleRate:(double)_srate bufferSize:(UInt16)_buffsize callback:(AudioCallbackBlock)_callback
{
    self = [super init];
    if ( self )
    {        
        // generic initialization
        [self initializeWithRate:_srate bufferSize:_buffsize];
        
        // store the callback block
        self.audioCallbackBlock = _callback;
    }
    return self;
}
#endif

#ifdef __REMOTE_IO_USE_C_CALLBACK__
- (id)initWithSampleRate:(double)_srate bufferSize:(UInt16)_buffsize CStyleCallback:(AudioCallbackCStyle)_callback
                userData:(void*)_data
{
    self = [super init];
    if ( self )
    {        
        // generic initialization
        [self initializeWithRate:_srate bufferSize:_buffsize];
        
        // store the callback
        g_audioCallbackCStyle = _callback;
        
        // store the user data
        g_callbackUserData = _data;
    }
    return self;
}
#endif

//- (void)dealloc
//{
//    [audioCallbackBlock release];
//    
//    [super dealloc];
//}

- (void)startupSmaller {
    @try {
        NSLog( @"[SMALLer] pre - starting audio session... : %d  - %d", m_starting, self.m_sessionStarted );

        // prevent starting multiple times
        if (!m_starting && !self.m_sessionStarted)
        {
            m_starting = YES;

            self.m_sessionFailure = NO; // clear the flag

            NSLog( @"[SMALLer] starting audio session..." );

            NSError *error = nil;

            // set the sample rate
            [[AVAudioSession sharedInstance] setPreferredSampleRate:srate error:&error];

            // print error if any
            if ( error ) {
                NSLog(@"[SMALLer] couldn't set sample rate to %lf: %@",srate, error.description);

                @throw ([NSException exceptionWithName:@"SMALLer setPreferredHardwareSampleRate" reason:error.description userInfo:nil]);
            }

            // set the buffer size
            NSTimeInterval buffTime = buffsize/srate;
            [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:buffTime error:&error];

            // print error if any
            if ( error )  {
                NSLog(@"[SMALLer] couldn't set buffer size to %lf: %@",buffTime, error.description);

                @throw ([NSException exceptionWithName:@"SMALLer setPreferredIOBufferDuration" reason:error.description userInfo:nil]);
            }
            
            // TODO: nickr: temporary fix for iOS 8 deprecation warnings (which are treated as errors in this file).
            // The entire AVAudioSession delegate has been deprecated and we should switch to using
            // NSNotifications (look at the deprecation notes for the delegate property in AVAudioSession.h).
            // However, I did not see a notification that can serve as a substitute for the intputIsAvailableChanged
            // delegate method. For now I'm supressing the deprecation warning, but we should fix this up soon.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            // set self to be the delegate
            [[AVAudioSession sharedInstance] setDelegate:self];
#pragma clang diagnostic pop

            // turn the audio session active
            [[AVAudioSession sharedInstance] setActive:YES error:&error];

            // print error if any
            if ( error )
            {
                NSLog(@"[SMALLer] couldn't start session: %@",error.description);

                @throw ([NSException exceptionWithName:@"SMALLer setActive" reason:error.description userInfo:nil]);
            }

//			// set the audio input mode
//			[[AVAudioSession sharedInstance] setMode:AVAudioSessionModeMeasurement error:&error];
//			if ( error )
//            {
//                NSLog(@"[SMALLer] couldn't set mode: %@",error.description);
//
//                @throw ([NSException exceptionWithName:@"SMALLer setMode" reason:error.description userInfo:nil]);
//            }

            // assign the interrupt callback
            AudioSessionPropertyID routeChangeID = kAudioSessionProperty_AudioRouteChange;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
            AudioSessionAddPropertyListener ( routeChangeID, audioRouteChangeListenerCallback, (__bridge void*)self );
#pragma clang diagnostic pop
            
            hasMic = ((AVAudioSession *)[AVAudioSession sharedInstance]).isInputAvailable;

            if(self.initializeAudioUnit) {
                // status code
                OSStatus err;

                NSLog(@"pre setupSMALLer m_sessionStarted : %d, %d", self.m_sessionStarted, m_starting);

                // set up remote IO
                if ([self setupAudioUnit] )
                {
                    NSLog(@"pre AudioOutputUnitStart m_sessionStarted : %d, %d", self.m_sessionStarted, m_starting);

                    // start audio unit
                    err = AudioOutputUnitStart( audioUnit );
                    if( err )
                    {
                        NSLog(@"[SMALLer] couldn't start audio unit...");

                        @throw ([NSException exceptionWithName:@"SMALLer" reason:@"[SMALLer] couldn't start audio unit..." userInfo:nil]);
                    }
                }

				[self adjustInputGain];
            }

            [self setSessionStarted:YES];
        }
    } @catch(NSException *e) {
        [self setSessionStarted:NO];
        m_starting = NO; // clear flag before re-throwing

        // GT: disabled this - we will auto-retry the init
    }

    m_starting = NO; // clear flag
}

- (void)startAudioSession
{
    if ( self.m_sessionStarted )
    {
        NSLog(@"[SMALLer] WARNING started session with an already active session");
        return;
        //return YES;
    }

    if([self isOtherAudioPlaying] || m_sessionInterrupted) {
        NSLog(@"[SMALLer] other audio playing : otherAudio: %d / interrupted: %d", [self isOtherAudioPlaying] ? 1 : 0, m_sessionInterrupted ? 1 : 0);

        if ([MPMusicPlayerController iPodMusicPlayer].playbackState != MPMusicPlaybackStatePlaying) {
            // this while loop was necessary to handle ALL cases when getting a phone call while performing.

            // 1 - get a phone call and dismiss it
            // 2 - get a phone call, answer it and hang up
            // 3 - get a phone call, answer it and other caller hangs up

            // for some reason our startAudioSession call would crash if we did not wait for the OS to stop the audio

            float timeElapsed = 0.0;
            while (([self isOtherAudioPlaying] ||
                    m_sessionInterrupted) && timeElapsed < 3.0)  // timeout 3s
            {
                NSLog(@"waiting for other audio to stop... %f  otherAudio: %d interrupted: %d",
                timeElapsed, [self isOtherAudioPlaying] ? 1 : 0, m_sessionInterrupted);

                [NSThread sleepForTimeInterval:0.1];
                timeElapsed += 0.1;
            }

            NSLog(@"waited for %f secs", timeElapsed);
        }

        __weak SMALLer *weakSelf = self;
        dispatch_async(dispatch_get_main_queue(), ^{
            [weakSelf startupSmaller];
        });

    } else {
        [self startupSmaller];
    }
}

- (void)setSessionStarted:(BOOL)val
{
    BOOL changed = NO;

    if (val != self.m_sessionStarted)
        changed = YES;

    self.m_sessionStarted = val;
    NSLog(@"[SMALLer] setSessionStarted - m_sessionStarted: %d", self.m_sessionStarted);

    if (changed && self.delegate)
        [self.delegate SMALLerSessionStateChanged:self];
}

- (BOOL)sessionStarted
{
    return self.m_sessionStarted;
}

- (BOOL)sessionFailure {
    return self.m_sessionFailure;
}

- (BOOL)sessionInterrupted {
    return m_sessionInterrupted;
}

- (void)resetBufferDuration
{
    NSError *error = nil;
    
    // set the sample rate
    [[AVAudioSession sharedInstance] setPreferredSampleRate:srate error:&error];
    
    // print error if any
    if ( error )
        NSLog(@"[SMALLer] couldn't set sample rate to %lf: %@",srate, error.description);
    
    // set the buffer size
    NSTimeInterval buffTime = buffsize/srate;
    [[AVAudioSession sharedInstance] setPreferredIOBufferDuration:buffTime error:&error];
    
    // print error if any
    if ( error )
        NSLog(@"[SMALLer] couldn't set buffer size to %lf: %@",buffTime, error.description);
}

- (void)adjustInputGain
{
    return;

//	float inputGain = [[AVAudioSession sharedInstance] inputGain];
//	NSLog(@"[SMALLer] input gain: %f", inputGain);
//
//    // SWF-6632 - special case for iPad 2 and headset
//    BOOL isIPad2 = [[UIDevice currentDevice] isIPad2];
//    BOOL isIPhone4s = [[UIDevice currentDevice] hardware] == IPHONE_4S;
//    BOOL isIpadMini = [[UIDevice currentDevice] isIPadMini];
//
//	if ([[AVAudioSession sharedInstance] isInputGainSettable] && (isIPad2 || isIPhone4s || isIpadMini)) {
//		float desiredInputGain = inputGain;
//
//        if ([self isHeadsetRoute:[self getCurrentRoute]]) {
//            // note, an ipad mini also is an ipad 2, so the isIpadMini check *must* be first
//            if (isIpadMini) {
//                // ipad mini input gains with headsets feedback *super easily*
//                // bring it down from a gain of ~.59
//                //
//                // note: it was impossible to come up with a useful value, but we chose
//                // a value where the user should not feedback by default.
//                desiredInputGain = 0.3;
//            } else {
//                // ipad 2 and iphone4s input gains with headsets are too effin' loud.
//                // bring them down from a gain of 1.0
//                desiredInputGain = 0.6;
//            }
//		}
//
//		if (inputGain != desiredInputGain)
//		{
//			NSError* err = nil;
//			if (![[AVAudioSession sharedInstance] setInputGain:desiredInputGain error:&err])
//			{
//				NSLog(@"[SMALLer] error setting input gain! %@", err);
//			}
//			else
//			{
//				NSLog(@"[SMALLer] new input gain! %f", [[AVAudioSession sharedInstance] inputGain]);
//			}
//		}
//	}
//	else
//	{
//		NSLog(@"[SMALLer] input gain not settable!");
//	}
}

#pragma mark - SMALLer

- (BOOL)setupAudioUnit
{
    NSLog(@"[SMALLer] setupSMALLer");

    AURenderCallbackStruct renderProc;
    
    // set the callback to our local callback
    renderProc.inputProc = inputProc;
    
    // pass the audio unit
    renderProc.inputProcRefCon = (__bridge void*)self;
    
    // desired data format
    AudioStreamBasicDescription dataFormat;
    dataFormat.mSampleRate = srate;
    dataFormat.mFormatID = kAudioFormatLinearPCM;
    dataFormat.mChannelsPerFrame = NUM_CHANNELS;
    dataFormat.mBitsPerChannel = 32;
    dataFormat.mBytesPerPacket = dataFormat.mChannelsPerFrame * sizeof(SInt32);
    dataFormat.mBytesPerFrame  = dataFormat.mChannelsPerFrame * sizeof(SInt32);
    dataFormat.mFramesPerPacket = 1;
    dataFormat.mReserved = 0;
    dataFormat.mFormatFlags = kLinearPCMFormatFlagIsSignedInteger;
    
    // the desciption for the audio component
    AudioComponentDescription desc;
    desc.componentType = kAudioUnitType_Output;
    desc.componentSubType = kAudioUnitSubType_RemoteIO;
    desc.componentManufacturer = kAudioUnitManufacturer_Apple;
    desc.componentFlags = 0;
    desc.componentFlagsMask = 0;
    
    // find next component
    AudioComponent comp = AudioComponentFindNext( NULL, &desc );
    
    // status code
    OSStatus err;
    
    // open remote I/O unit with the component
    err = AudioComponentInstanceNew( comp, &audioUnit );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't open the remote I/O unit");
        return NO;
    }
    
    if (self.useMic) {
        // determines if mic input is available
        UInt32 one = (UInt32) [AVAudioSession sharedInstance].inputAvailable;
        
        // enable input
        
        err = AudioUnitSetProperty( audioUnit, kAudioOutputUnitProperty_EnableIO,
                                   kAudioUnitScope_Input, 1, &one, sizeof(one) );
        if( err )
        {
            NSLog(@"[SMALLer] couldn't enable input on the remote I/O unit\n" );
            return NO;
        }
    }
    
    // set render proc, the internal audio callback
    err = AudioUnitSetProperty( audioUnit, kAudioUnitProperty_SetRenderCallback,
                               kAudioUnitScope_Input, 0, &renderProc, sizeof(renderProc) );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't set remote i/o render callback\n" );
        return NO;
    }
    
    // the stream description
    AudioStreamBasicDescription localFormat;
    
    UInt32 size = sizeof(localFormat);
    // get and set client format
    err = AudioUnitGetProperty( audioUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &localFormat, &size );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't get the remote I/O unit's output client format" );
        return NO;
    }
    
    localFormat.mSampleRate = dataFormat.mSampleRate;
    localFormat.mFormatFlags = kAudioFormatFlagIsSignedInteger |
    kAudioFormatFlagIsPacked |
    kAudioFormatFlagIsNonInterleaved |
    (24 << kLinearPCMFormatFlagsSampleFractionShift);
    localFormat.mChannelsPerFrame = dataFormat.mChannelsPerFrame;
    localFormat.mBytesPerFrame = 4;
    localFormat.mBytesPerPacket = 4;
    localFormat.mBitsPerChannel = 32;
    // set stream property
    err = AudioUnitSetProperty( audioUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &localFormat, sizeof(localFormat) );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't set the remote I/O unit's input client format" );
        return NO;
    }
    
    size = sizeof(dataFormat);
    // get it again
    err = AudioUnitGetProperty( audioUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Input, 0, &dataFormat, &size );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't get the remote I/O unit's output client format" );
        return NO;
    }
    err = AudioUnitSetProperty( audioUnit, kAudioUnitProperty_StreamFormat,
                               kAudioUnitScope_Output, 1, &dataFormat, sizeof(dataFormat) );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't set the remote I/O unit's output client format" );
        return NO;
    }
    
    // initialize remote I/O unit
    err = AudioUnitInitialize( audioUnit );
    if( err )
    {
        NSLog(@"[SMALLer] couldn't initialize the remote I/O unit" );
        return NO;
	}

    err = CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &dataFormat, 0, NULL, 0, NULL, NULL, &g_format);
    if( err )
    {
        NSLog(@"[SMALLer] couldn't create CMFormatDescriptionRef" );
        return NO;
	}


    if( err )
    {
        NSLog(@"[SMALLer] couldn't initialize the remote I/O unit" );
        return NO;
	}

    // if we've made it all is well
    return YES;
}


- (BOOL)disposeSMALLer
{
    NSLog(@"[SMALLer] disposeSMALLer");
    if ( !self.m_sessionStarted )
    {
        NSLog(@"[SMALLer] WARNING tried to dispose a non existing session");
        return NO;
    }
    
    // status code
    OSStatus err;
    
    err = AudioOutputUnitStop(audioUnit);
    if( err )
    {
        NSLog(@"[SMALLer] couldn't uninitialize the remote I/O unit");

        [self setSessionStarted:NO];
        m_sessionInterrupted = NO;
        return NO;
    }
    
    // open remote I/O unit
    err = AudioComponentInstanceDispose(audioUnit);
    if( err )
    {
        NSLog(@"[SMALLer] couldn't dispose of the remote I/O component");

        [self setSessionStarted:NO];
        m_sessionInterrupted = NO;
        return NO;
    }

    // remove the callback
    AudioSessionPropertyID routeChangeID = kAudioSessionProperty_AudioRouteChange;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    AudioSessionRemovePropertyListenerWithUserData( routeChangeID, audioRouteChangeListenerCallback, (__bridge void*)self );
#pragma clang diagnostic pop

    [self setSessionStarted:NO];
    m_sessionInterrupted = NO;
    audioUnit = nil;
    NSLog(@"[SMALLer] audio session correctly disposed");
    
    return YES;
}


#pragma mark - use for FAS

- (BOOL)suspendSession
{
    NSLog(@"[SMALLer] suspendSession");

    [self disposeSMALLer];
    
    // if we've made it all is well
    return YES;
}

- (void)restartSession
{
    NSLog(@"[SMALLer] restartSession");

    // recreate session
    return [self startAudioSession];
}


#pragma mark - routing

- (BOOL)isOtherAudioPlaying
{
    OSStatus err;
    BOOL result = NO;

    UInt32 val;
    UInt32 size = sizeof(CFStringRef);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    err = AudioSessionGetProperty( kAudioSessionProperty_OtherAudioIsPlaying, &size, &val );
#pragma clang diagnostic pop
    if (err)
    {
        NSLog(@"could not get kAudioSessionProperty_OtherAudioIsPlaying property");
    }
    else
    {
        result = val ? YES : NO;
    }

    return result;
}

- (NSString*)getCurrentRoute
{
    OSStatus err;

    CFStringRef route = NULL; // make sure to init to NULL
    UInt32 size = sizeof(CFStringRef);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    err = AudioSessionGetProperty( kAudioSessionProperty_AudioRoute, &size, &route );
#pragma clang diagnostic pop

    /* Known values of route:
    * "Headset"
    * "Headphone"
    * "Speaker"
    * "SpeakerAndMicrophone"
    * "HeadphonesAndMicrophone"
    * "HeadsetInOut"
    * "ReceiverAndMicrophone"
    * "Lineout"
    */

    if( err )
    {
        NSLog(@"couldn't determine new audio route : %ld", (long)err);
        return nil;
    }
    
    
    // fancy stuff to be able to release the route
    NSString * nsRoute = (__bridge NSString*)route; // formerly [[(NSString*)route retain] autorelease];
    
    // dispose of the route
    if ( route != NULL ) {
        CFRelease(route);
    }
    
    //NSLog(@"[SMALLer] current route is %@", nsRoute);
    
    return nsRoute;
}

- (BOOL)isAirPlayRoute:(NSString *)route {
    return [route rangeOfString:@"AirTunes"].location != NSNotFound;
}

- (BOOL)isRouteHeadphonesOrAirplay {
    NSString *route = [self getCurrentRoute];

    BOOL result = [self isHeadphoneRoute:route];
    if(!result) {
        result = [self isAirPlayRoute:route];
    }
    return result;
}

- (BOOL)isHeadphoneRoute:(NSString *)route {
    BOOL result = NO;
    if ([route rangeOfString:@"Headset"].location != NSNotFound) {
        result = YES;
    } else if ([route rangeOfString:@"Headphone"].location != NSNotFound) {
        result = YES;
    }
    return result;
}

- (BOOL)isHeadsetRoute:(NSString *)route {
	NSRange range = [route rangeOfString:@"Headset"];
	return (range.location != NSNotFound);
}

- (BOOL)hasHeadphonesPluggedIn {
    NSString *route = [self getCurrentRoute];
    return [self isHeadphoneRoute:route];
}

- (BOOL)hasHeadsetPluggedIn {
    NSString *route = [self getCurrentRoute];
    return [self isHeadsetRoute:route];
}

- (OSStatus)enableBluetooth:(BOOL)val {
    // if not, just playback
    UInt32 allowBluetoothInput = val ? 1 : 0;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    OSStatus err = AudioSessionSetProperty(
            kAudioSessionProperty_OverrideCategoryEnableBluetoothInput,
            sizeof (allowBluetoothInput),
            &allowBluetoothInput);
#pragma clang diagnostic pop
    if(err) {
        NSLog(@"[SMALLer] kAudioSessionProperty_OverrideCategoryEnableBluetoothInput failed with err: %i", (int)err);
    }

    return err;
}

- (BOOL)useMicInput:(BOOL)_useMic
{    
    NSError * error = nil;
    
    useMic = _useMic;
    
    // check if we have a mic at all
    hasMic = ((AVAudioSession *)[AVAudioSession sharedInstance]).isInputAvailable;
    
    // if we both want and have a mic, we'll set it to be active
    if( useMic && hasMic ) {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];

    } else {
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
    }

    if ( error )
    {
        NSLog(@"[SMALLer] switch mic input: %@",error.description);
        return NO;
    }
    
    return YES;
}

- (BOOL)overrideToSpeaker:(BOOL)shouldOverride
{
    if ( TARGET_IPHONE_SIMULATOR ) return NO;

    if (!self.m_sessionStarted)
        return NO;

    OSStatus err   = 0;
    UInt32 override= kAudioSessionOverrideAudioRoute_None;
    
    // make sure we have the most up to date route
    NSString *currentRoute = [self getCurrentRoute];
    //NSLog(@"currentRoute: %@", currentRoute);

    NSLog(@"overrideToSpeaker - %d", shouldOverride);

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // if it is a call to use the receiver, just immediately switch it
    if ( !shouldOverride )
    {
        m_speakerOverride = false;

        err= AudioSessionSetProperty( kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override );
    }
    else if ( currentRoute )
    {
        m_speakerOverride = true;
        
        if ( [self isRouteHeadphonesOrAirplay] ) {
            err= AudioSessionSetProperty( kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override );
        } else
        {
            override= kAudioSessionOverrideAudioRoute_Speaker;
            err= AudioSessionSetProperty( kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override );
        }
    }
    else 
    {
        override= kAudioSessionOverrideAudioRoute_Speaker;
        err= AudioSessionSetProperty( kAudioSessionProperty_OverrideAudioRoute, sizeof(override), &override );
    }
#pragma clang diagnostic pop

    return err == 0;
}

#pragma mark - callback handlers

- (void)routeChangedCallback:(NSString*)newRoute
{
    NSLog(@"routeChangedCallback: %@", newRoute);
    // this is called just in case we need to use it only if we are in override mode
    if ( m_speakerOverride ) [self overrideToSpeaker:YES];

    // check if we have a mic at all
    hasMic = ((AVAudioSession *)[AVAudioSession sharedInstance]).isInputAvailable;

    NSError * error = nil;

    // also, override based on whether it is even available, is not on IPOD_3G
    if ( hasMic == NO )
        [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayback error:&error];

    else if ( hasMic == YES && useMic == YES )
	{
        [[AVAudioSession sharedInstance] setCategory: AVAudioSessionCategoryPlayAndRecord error:&error];

        [self adjustInputGain];
	}

    // only broadcast if the route really did change
    if(![newRoute isEqualToString:self.lastRoute]) {

        if ( error ) {
            NSLog(@"[SMALLer] error switching mic input: %@",error.description);
        } else if (self.delegate) {
            [self.delegate SMALLerRouteChanged:self];
        }

        self.lastRoute = newRoute;
    }
}

- (void)handleAudioCallback:(Float32*)bufferL R:(Float32*)bufferR frames:(UInt16)frames
{
    // NOTE: If the samples are interleaved, bufferL will be twice the size, and bufferR will be NULL.
    if ( audioCallbackBlock ) audioCallbackBlock( bufferL, bufferR, frames );
}

#pragma mark - AVAudioSessionDelegate methods
- (void)beginInterruption
{
    NSLog(@"beginInterruption");

    // it's possible for this method to be invoked even when app is in Background, so we need to be specific here
    if ([UIApplication sharedApplication].applicationState != UIApplicationStateBackground)
    {
        NSLog(@"[SMALLer] audio session interrupted");
        m_sessionInterrupted = YES;
        [self disposeSMALLer];
    }

    if(self.delegate && [self.delegate respondsToSelector:@selector(SMALLerDidBeginInterruption:)]) {
        [self.delegate SMALLerDidBeginInterruption:self];
    }
}

- (void)endInterruption
{
    NSLog(@"endInterruption");

    if (m_sessionInterrupted)
    {
        NSLog(@"[SMALLer] audio session interruption is over");
        m_sessionInterrupted = NO;
        if(self.delegate && [self.delegate respondsToSelector:@selector(SMALLerInterruptionEnded:)]) {
            [self.delegate SMALLerInterruptionEnded:self];
        } else {
            [self startAudioSession];
        }
    }
}

- (void)inputIsAvailableChanged:(BOOL)isInputAvailable
{
    NSLog(@"[SMALLer] audio input is %@ available", isInputAvailable ? @"now" : @"no longer");
    
    // if we are shutting off, mark now
    if ( !isInputAvailable )
        hasMic = NO;
    
    // we changed in such a way that we gained or lost audio input, restart SMALLer
    [self disposeSMALLer];
    [self startAudioSession];
    
    // if we are turning on, mark now
    if ( isInputAvailable )
        hasMic = YES;
}

@end










#pragma mark - C-style callbacks

//-----------------------------------------------------------------------------
// name: audioRouteChangeListenerCallback()
// desc: called when the audio route changes, as in plugging in headphones
//-----------------------------------------------------------------------------
void audioRouteChangeListenerCallback (void *inUserData, AudioSessionPropertyID inPropertyID,                                
                                       UInt32 inPropertyValueSize, const void *inPropertyValue ) 
{
    if (inPropertyID != kAudioSessionProperty_AudioRouteChange) return;
    
    OSStatus err;
    
    CFStringRef route;
    UInt32 size = sizeof(CFStringRef);
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    err = AudioSessionGetProperty( kAudioSessionProperty_AudioRoute, &size, &route );
#pragma clang diagnostic pop
    if( err )
    {
        NSLog(@"couldn't determine new audio route");
    }
    else
    {
        NSString *currentRoute = (__bridge NSString*)route;
        NSLog(@"[SMALLer] route is %@", currentRoute);
        [(__bridge SMALLer*)inUserData routeChangedCallback:currentRoute];
    }    
    
    // dispose of the route
    CFRelease(route);
}

// do one time calcs

// fixed to float scaling factor will scale audio from -1.0 to 1.0
#define BIT_DEPTH (24)

static Float32 fromFltFactor = (Float32)(1 << BIT_DEPTH);
static Float32 toFltFactor = 1.0 / ((Float32)(1 << BIT_DEPTH));



//-----------------------------------------------------------------------------
// name: convertToUser()
// desc: convert to user data (stereo)
//-----------------------------------------------------------------------------
void convertToFloating( AudioBufferList * inData, Float32 * buffyL, Float32 *buffyR, 
                       UInt32 numFrames, UInt32 * actualFrames, BOOL useInterleavedSamples );


void convertToFloating( AudioBufferList * inData, Float32 * buffyL, Float32 *buffyR, 
                       UInt32 numFrames, UInt32 * actualFrames, BOOL useInterleavedSamples )
{    
    // make sure there are exactly two channels
    assert( inData->mNumberBuffers == NUM_CHANNELS );
    // get number of frames
    UInt32 inFrames = inData->mBuffers[0].mDataByteSize / 4; // 4 is size of int
    // make sure enough space
    assert( inFrames <= numFrames );
    
    // TODO? apply device specific gains here:
    // fromFltFactor *= specificGain;

    if (useInterleavedSamples) {
    // interleave (AU is by default non interleaved)
    for( UInt32 i = 0; i < inFrames; i++ )
        // convert (AU is by default 8.24 fixed)
        for(UInt32 c = 0; c < NUM_CHANNELS; c++)
            buffyL[NUM_CHANNELS * i + c] = ((Float32)(((SInt32 *)inData->mBuffers[c].mData)[i])) * toFltFactor;
    } else {
    // convert (AU is by default 8.24 fixed)
    // iOS input is always mono, so this is just shared to the two buffers
    for (UInt32 i = 0; i < inData->mNumberBuffers; i++)
    {
        SInt32 *ibuf = (SInt32 *)inData->mBuffers[0].mData;
        for (UInt32 s = 0; s < inFrames; s++)
            g_ioBufferL[s] = g_ioBufferR[s] = (Float32) ibuf[s] * toFltFactor;
    }
    }
    
    // return
    *actualFrames = inFrames;
}




//-----------------------------------------------------------------------------
// name: convertFromUser()
// desc: convert from user data (stereo)
//-----------------------------------------------------------------------------

void convertFromFloating( AudioBufferList * inData, Float32 * buffyL, Float32 * buffyR, UInt32 numFrames, BOOL useInterleavedSamples );

void convertFromFloating( AudioBufferList * inData, Float32 * buffyL, Float32 * buffyR, UInt32 numFrames, BOOL useInterleavedSamples )
{
    // make sure there are exactly the right number of channels
    assert( inData->mNumberBuffers == NUM_CHANNELS );
    // get number of frames
    UInt32 inFrames = inData->mBuffers[0].mDataByteSize / 4; // 4 is size of int
    // make sure enough space
    assert( inFrames <= numFrames );
    
    // TODO? apply device specific gains here:
    // fromFltFactor *= specificGain;
        
    if (useInterleavedSamples) {
    // interleave (AU is by default non interleaved)
    for( UInt32 i = 0; i < inFrames; i++ )
        // convert (AU is by default 8.24 fixed)
        for(UInt32 c = 0; c < NUM_CHANNELS; c++)
                ((SInt32 *)inData->mBuffers[c].mData)[i] = (SInt32)(buffyL[NUM_CHANNELS * i + c] * fromFltFactor);
    } else {
    // convert (AU is by default 8.24 fixed)
    SInt32 *ibuf = (SInt32 *)inData->mBuffers[0].mData;
    for (UInt32 s = 0; s < inFrames; s++)
        ibuf[s] = (SInt32) ( buffyL[s] * fromFltFactor );
    ibuf = (SInt32 *)inData->mBuffers[1].mData;
    for (UInt32 s = 0; s < inFrames; s++)
        ibuf[s] = (SInt32) ( buffyR[s] * fromFltFactor );
    }
    
}





//-----------------------------------------------------------------------------
// name: inputProc()
// desc: handles the audio unit callback and sends it up
//-----------------------------------------------------------------------------
OSStatus inputProc( void * inRefCon, AudioUnitRenderActionFlags * ioActionFlags, 
                    const AudioTimeStamp * inTimeStamp, UInt32 inBusNumber, 
                    UInt32 inNumberFrames, AudioBufferList * ioData ) 
{
    OSStatus err = noErr;

    // grab our instance of SMALLer from the data
    SMALLer *rio = (__bridge SMALLer*)inRefCon;

    if (![rio isKindOfClass:[SMALLer class]])
    {
        NSLog(@"wrong rio: %@", rio);
        return noErr;
    }

    // handle the input if we're using the mic
    if ( rio.hasMic && rio.useMic && [rio sessionStarted] )
    {
        // renders the audio input from the mic
        err = AudioUnitRender( rio.audioUnit, ioActionFlags, inTimeStamp, 1, inNumberFrames, ioData );
        if( err )
        {
            // print error if we got one
            NSLog(@"[SMALLer] input render procedure encountered error %ld", (long)err);

            // set this flag so the system can attempt a restart if necessary
            rio.m_sessionFailure = YES;

            return err;
        }
    }
    
    // this value will hold the actual frames we received from this callback
    UInt32 actualFrames = 0;
    
    // convert input to floating point if we're using a mic, will add to "actualFrames" internally
    if ( rio.hasMic && rio.useMic )
            convertToFloating( ioData, g_ioBufferL, g_ioBufferR, MAX_BUFFSIZE, &actualFrames, NO );

    // zero out mic input otherwise
    else
    {
        // assumes 32 bit samples
            memset( g_ioBufferL, 0, MIN(inNumberFrames * 4, MAX_BUFFSIZE));
            memset( g_ioBufferR, 0, MIN(inNumberFrames * 4, MAX_BUFFSIZE));

        // add to actual frames
        actualFrames = inNumberFrames;
    }


    // make sure to only give out the right number of frames in the main callback, can end up slicing things
    // up a bit especially in simulator
    UInt32 totalFramesReceived = 0;

    // keep sending to audio callback until total frames received is on par with actual frames we received
    while(totalFramesReceived < actualFrames)
    {
        // determine how many frames will be in this round of callbacking
        UInt32 framesRequested = MIN(actualFrames - totalFramesReceived, rio.buffsize);

        // send the buffers out for real work!
        [rio handleAudioCallback:g_ioBufferL + totalFramesReceived R:g_ioBufferR + totalFramesReceived frames:(UInt16) framesRequested];

        // keep track of total frames that were received
        totalFramesReceived += framesRequested;
    }

    // void *callback(CMSampleBufferRef pBuffer) = nil;

    if (rio.sampleBufferCallbackBlock) {

        /*
        if (g_sampleBuffer) {
            CFRelease(g_sampleBuffer);
             g_sampleBuffer = nil;
        }
        */

        assert(inTimeStamp->mFlags&kAudioTimeStampHostTimeValid);

        // we need to convert host time to something useful. read this: http://stackoverflow.com/questions/675626/coreaudio-audiotimestamp-mhosttime-clock-frequency
        mach_timebase_info_data_t info;
        mach_timebase_info(&info);

        UInt64 presTime = inTimeStamp->mHostTime * info.numer;
        presTime /= info.denom;

        int32_t kDeviceTimeScale = 1000000000; // need to convert from nanoseconds

        CMTime cmPresTime = CMTimeMake((int64_t)presTime, kDeviceTimeScale);
        CMSampleTimingInfo timing = { CMTimeMake(1, 44100), cmPresTime, kCMTimeInvalid };

        CMSampleBufferRef sampleBuffer = nil;
        err = CMSampleBufferCreate(kCFAllocatorDefault,NULL,false,NULL,NULL, g_format, (CMItemCount)inNumberFrames, 1, &timing, 0, NULL, &sampleBuffer);

        if( err )
        {
            NSLog(@"[SMALLer] couldn't create CMSampleBufferRef" );
    	}

        err = CMSampleBufferSetDataBufferFromAudioBufferList(
            sampleBuffer,
            kCFAllocatorDefault,
            kCFAllocatorDefault,
            0,
            ioData);

        if (err) {
            NSLog(@"CMSampleBufferSetDataBufferFromAudioBufferList failed with err: %d", (int)err);
        }


        rio.sampleBufferCallbackBlock(sampleBuffer);
    }

    // convert back to fixed point if we are using the mic
    convertFromFloating( ioData, g_ioBufferL, g_ioBufferR, MAX_BUFFSIZE, NO );

    return err;
}
