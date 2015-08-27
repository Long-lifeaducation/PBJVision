//
//  PBJMediaWriter.m
//  Vision
//
//  Created by Patrick Piemonte on 1/27/14.
//  Copyright (c) 2013-present, Patrick Piemonte, http://patrickpiemonte.com
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy of
//  this software and associated documentation files (the "Software"), to deal in
//  the Software without restriction, including without limitation the rights to
//  use, copy, modify, merge, publish, distribute, sublicense, and/or sell copies of
//  the Software, and to permit persons to whom the Software is furnished to do so,
//  subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY, FITNESS
//  FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR
//  COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER
//  IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN
//  CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
//

#import "PBJMediaWriter.h"
#import "PBJVisionUtilities.h"

#import <UIKit/UIDevice.h>
#import <MobileCoreServices/UTCoreTypes.h>

#define LOG_WRITER 1
#if !defined(NDEBUG) && LOG_WRITER
#   define DLog(fmt, ...) NSLog((@"writer: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif

@interface PBJMediaWriter ()
{
    __weak id <PBJMediaWriterDelegate> _delegate;
    dispatch_queue_t _delegateQueue;

    AVAssetWriter *_assetWriter;
	AVAssetWriterInput *_assetWriterAudioIn;
	AVAssetWriterInput *_assetWriterVideoIn;
    AVAssetWriterInputPixelBufferAdaptor *_assetWriterInputPixelBufferAdaptor;
    
    NSURL *_outputURL;
    
    NSDictionary *_videoSettings;
    NSDictionary *_audioSettings;
    CMFormatDescriptionRef _audioTrackSourceFormatDescription;
    CMFormatDescriptionRef _videoTrackSourceFormatDescription;

    CMTime _audioTimestamp;
    CMTime _videoTimestamp;
    
    BOOL _audioReady;
    BOOL _videoReady;
}

@end

@implementation PBJMediaWriter

@synthesize outputURL = _outputURL;

@synthesize audioTimestamp = _audioTimestamp;
@synthesize videoTimestamp = _videoTimestamp;

#pragma mark - getters/setters

- (BOOL)isAudioReady
{
    return _audioReady;
}

- (BOOL)isVideoReady
{
    return _videoReady;
}

- (NSError *)error
{
    return _assetWriter.error;
}

- (id<PBJMediaWriterDelegate>)delegate
{
    id <PBJMediaWriterDelegate> delegate = nil;
    @synchronized(self)
    {
        delegate = _delegate;
    }
    return delegate;
}

- (void)setDelegate:(id<PBJMediaWriterDelegate>)delegate callbackQueue:(dispatch_queue_t)delegateCallbackQueue;
{

     // debug
     if (_delegate && (delegateCallbackQueue == NULL))
     {
        //@throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Caller must provide a delegateCallbackQueue" userInfo:nil];
     }

    @synchronized(self)
    {
        _delegate = delegate;
        _delegateQueue = delegateCallbackQueue;
    }
}

#pragma mark - init

- (id)initWithOutputURL:(NSURL *)outputURL
{
    self = [super init];
    if (self) {
        NSError *error = nil;
        _assetWriter = [[AVAssetWriter alloc] initWithURL:outputURL fileType:(NSString *)kUTTypeMPEG4 error:&error];
        if (error) {
            DLog(@"error setting up the asset writer (%@)", error);
            _assetWriter = nil;
            return nil;
        }

        _outputURL = outputURL;
        _assetWriter.shouldOptimizeForNetworkUse = YES;
        _assetWriter.metadata = [self _metadataArray];

        _audioTimestamp = kCMTimeInvalid;
        _videoTimestamp = kCMTimeInvalid;

        // It's possible to capture video without audio or audio without video.
        // If the user has denied access to a device, we don't need to set it up
        if ([[AVCaptureDevice class] respondsToSelector:@selector(authorizationStatusForMediaType:)]) {
            
            if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeAudio] == AVAuthorizationStatusDenied) {
                _audioReady = YES;
                if ([_delegate respondsToSelector:@selector(mediaWriterDidObserveAudioAuthorizationStatusDenied:)]) {
                    [_delegate mediaWriterDidObserveAudioAuthorizationStatusDenied:self];
                }
            }
            
            if ([AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] == AVAuthorizationStatusDenied) {
                _videoReady = YES;
                if ([_delegate respondsToSelector:@selector(mediaWriterDidObserveVideoAuthorizationStatusDenied:)]) {
                    [_delegate mediaWriterDidObserveVideoAuthorizationStatusDenied:self];
                }
            }
            
        }
    }
    return self;
}

#pragma mark - private

- (NSArray *)_metadataArray
{
    UIDevice *currentDevice = [UIDevice currentDevice];
    
    // device model
    AVMutableMetadataItem *modelItem = [[AVMutableMetadataItem alloc] init];
    [modelItem setKeySpace:AVMetadataKeySpaceCommon];
    [modelItem setKey:AVMetadataCommonKeyModel];
    [modelItem setValue:[currentDevice localizedModel]];

    // software
    AVMutableMetadataItem *softwareItem = [[AVMutableMetadataItem alloc] init];
    [softwareItem setKeySpace:AVMetadataKeySpaceCommon];
    [softwareItem setKey:AVMetadataCommonKeySoftware];
    [softwareItem setValue:[NSString stringWithFormat:@"%@ %@ PBJVision", [currentDevice systemName], [currentDevice systemVersion]]];

    // creation date
    AVMutableMetadataItem *creationDateItem = [[AVMutableMetadataItem alloc] init];
    [creationDateItem setKeySpace:AVMetadataKeySpaceCommon];
    [creationDateItem setKey:AVMetadataCommonKeyCreationDate];
    [creationDateItem setValue:[NSString PBJformattedTimestampStringFromDate:[NSDate date]]];

    return @[modelItem, softwareItem, creationDateItem];
}

#pragma mark - sample buffer setup

- (void)addAudioTrackWithFormatDescription:(CMFormatDescriptionRef)formatDescription settings:(NSDictionary *)audioSettings
{
    @synchronized(self)
    {
        _audioTrackSourceFormatDescription = (CMFormatDescriptionRef)CFRetain( formatDescription );
        _audioSettings = [audioSettings copy];
    }
}

- (void)addVideoTrackWithFormatDescription:(CMFormatDescriptionRef)formatDescription settings:(NSDictionary *)videoSettings
{
    @synchronized(self)
    {
        _videoTrackSourceFormatDescription = (CMFormatDescriptionRef)CFRetain( formatDescription );
        _videoSettings = [videoSettings copy];
    }
}

- (BOOL)setupAudioOutputDeviceWithSettings:(NSDictionary *)audioSettings
{
    //HACK
    _audioReady = YES;
    
//	if ([_assetWriter canApplyOutputSettings:audioSettings forMediaType:AVMediaTypeAudio]) {
//    
//		_assetWriterAudioIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio outputSettings:audioSettings];
//		_assetWriterAudioIn.expectsMediaDataInRealTime = YES;
//        
//        DLog(@"prepared audio-in with compression settings sampleRate (%f) channels (%lu) bitRate (%ld)",
//                    [[audioSettings objectForKey:AVSampleRateKey] floatValue],
//                    (unsigned long)[[audioSettings objectForKey:AVNumberOfChannelsKey] unsignedIntegerValue],
//                    (long)[[audioSettings objectForKey:AVEncoderBitRateKey] integerValue]);
//        
//		if ([_assetWriter canAddInput:_assetWriterAudioIn]) {
//			[_assetWriter addInput:_assetWriterAudioIn];
//            _audioReady = YES;
//		} else {
//			DLog(@"couldn't add asset writer audio input");
//		}
//        
//	} else {
//    
//		DLog(@"couldn't apply audio output settings");
//        
//	}
    
    return _audioReady;
}

- (BOOL)setupVideoOutputDeviceWithSettings:(NSDictionary *)videoSettings
{
    BOOL success = NO;
	if ([_assetWriter canApplyOutputSettings:videoSettings forMediaType:AVMediaTypeVideo]) {
    
		_assetWriterVideoIn = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo outputSettings:videoSettings];
		_assetWriterVideoIn.expectsMediaDataInRealTime = YES;
		_assetWriterVideoIn.transform = CGAffineTransformIdentity;

#if !defined(NDEBUG) && LOG_WRITER
        NSDictionary *videoCompressionProperties = [videoSettings objectForKey:AVVideoCompressionPropertiesKey];
        if (videoCompressionProperties)
            DLog(@"prepared video-in with compression settings bps (%f) frameInterval (%ld)",
                    [[videoCompressionProperties objectForKey:AVVideoAverageBitRateKey] floatValue],
                    (long)[[videoCompressionProperties objectForKey:AVVideoMaxKeyFrameIntervalKey] integerValue]);
#endif
        
        // create a pixel buffer adaptor for the asset writer; we need to obtain pixel buffers for rendering later from its pixel buffer pool
        _assetWriterInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_assetWriterVideoIn sourcePixelBufferAttributes:
                                               [NSDictionary dictionaryWithObjectsAndKeys:
                                                [NSNumber numberWithInteger:kCVPixelFormatType_32BGRA], (id)kCVPixelBufferPixelFormatTypeKey,
                                                videoSettings[AVVideoWidthKey], (id)kCVPixelBufferWidthKey,
                                                videoSettings[AVVideoWidthKey], (id)kCVPixelBufferHeightKey,
                                                (id)kCFBooleanTrue, (id)kCVPixelFormatOpenGLESCompatibility,
                                                nil]];

		if ([_assetWriter canAddInput:_assetWriterVideoIn]) {
			[_assetWriter addInput:_assetWriterVideoIn];
            success = YES;
		} else {
			DLog(@"couldn't add asset writer video input");
		}
        
	} else {
    
		DLog(@"couldn't apply video output settings");
        
	}
    
    return success;
}

- (void)prepareToRecord
{
    /*
    @synchronized(self)
    {
        // TODO, check state
    }
     */


    dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_LOW, 0 ), ^{

        @autoreleasepool
        {
            [self setupVideoOutputDeviceWithSettings:_videoSettings];
            [self setupAudioOutputDeviceWithSettings:_audioSettings];

            BOOL success = [_assetWriter startWriting];
            if (!success)
            {
                dispatch_async( _delegateQueue, ^{

                    @autoreleasepool
                    {
                        if ([_delegate respondsToSelector:@selector(mediaWriterDidObserveAssetWriterFailed:)]) {
                            [_delegate mediaWriterDidObserveAssetWriterFailed:self];
                        }
                    }
                } );
            }
            else
            {
                // we're ready to start recording
                _videoReady = YES;

                dispatch_async( _delegateQueue, ^{

                    @autoreleasepool
                    {
                        if ([_delegate respondsToSelector:@selector(mediaWriterDidFinishPreparing:)]) {
                            [_delegate mediaWriterDidFinishPreparing:self];
                        }
                    }
                } );
            }

        }
    } );
}

#pragma mark - 

- (CVReturn)createPixelBufferFromPool:(CVPixelBufferRef*)renderedOutputPixelBuffer
{
    CVReturn err = CVPixelBufferPoolCreatePixelBuffer(nil, _assetWriterInputPixelBufferAdaptor.pixelBufferPool, renderedOutputPixelBuffer);
    if (err || !renderedOutputPixelBuffer)
    {
        NSLog(@"Cannot obtain a pixel buffer from the buffer pool %d", err);
    }
    return err;
}

#pragma mark - sample buffer writing

- (BOOL)startWritingAtTime:(CMTime)startTime
{
    DLog(@"about to start writing... (%lld %d)", startTime.value, startTime.timescale);
    BOOL didStart = NO;
    if ( _assetWriter.status == AVAssetWriterStatusWriting ) {
        didStart = YES;
        if (didStart) {
            [_assetWriter startSessionAtSourceTime:startTime];
            _videoTimestamp = startTime;
            DLog(@"started writing with status (%ld)", (long)_assetWriter.status);
        } else {
            DLog(@"error when starting to write (%@)", [_assetWriter error]);
        }
    }
    return didStart;
}

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType
{
    [self writeSampleBuffer:sampleBuffer ofType:mediaType withPixelBuffer:NULL];
}

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType withPixelBuffer:(CVPixelBufferRef)filteredPixelBuffer
{
	if ( _assetWriter.status == AVAssetWriterStatusUnknown ) {
        CMTime startTime = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        [self startWritingAtTime:startTime];
	}
    
    if ( _assetWriter.status == AVAssetWriterStatusFailed ) {
        DLog(@"writer failure, (%@)", _assetWriter.error.localizedDescription);
        
        if ([_delegate respondsToSelector:@selector(mediaWriterDidObserveAssetWriterFailed:)]) {
            [_delegate mediaWriterDidObserveAssetWriterFailed:self];
        }
        
        return;
    }
	
	if ( _assetWriter.status == AVAssetWriterStatusWriting ) {
		
        CMTime timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
        CMTime duration = CMSampleBufferGetDuration(sampleBuffer);
		if (mediaType == AVMediaTypeVideo) {
			if (_assetWriterVideoIn.readyForMoreMediaData) {
                if (filteredPixelBuffer) {
                    if ([_assetWriterInputPixelBufferAdaptor appendPixelBuffer:filteredPixelBuffer withPresentationTime:timestamp]) {
                        if (CMTIME_IS_VALID(duration)) {
                            _videoTimestamp = CMTimeAdd(timestamp, duration);
                        }
                        else {
                            _videoTimestamp = timestamp;
                        }
                        //DLog(@"videoTimestamp: %lld %d", _videoTimestamp.value, _videoTimestamp.timescale);
                    } else {
                        DLog(@"writer error appending video (%@)", [_assetWriter error]);
                    }
                } else {
                    if ([_assetWriterVideoIn appendSampleBuffer:sampleBuffer]) {
                        _videoTimestamp = CMTimeAdd(timestamp, duration);
                        //DLog(@"videoTimestamp: %lld %d", _videoTimestamp.value, _videoTimestamp.timescale);
                    } else {
                        DLog(@"writer error appending video (%@)", [_assetWriter error]);
                    }
                }
			} else {
                DLog(@"writer error NOT readyForMoreMediaData");
            }
		} else if (mediaType == AVMediaTypeAudio) {
			if (_assetWriterAudioIn.readyForMoreMediaData) {
				if ([_assetWriterAudioIn appendSampleBuffer:sampleBuffer]) {
                    _audioTimestamp = timestamp;
				} else {
					DLog(@"writer error appending audio (%@)", [_assetWriter error]);
                }
			}
		}
        
	}
    
}

- (void)finishWritingWithCompletionHandler:(void (^)(void))handler
{
    if (_assetWriter.status == AVAssetWriterStatusUnknown) {
        DLog(@"asset writer is in an unknown state, wasn't recording");
        return;
    }

    [_assetWriter finishWritingWithCompletionHandler:handler];
    
    _audioReady = NO;
    _videoReady = NO;    
}

#pragma mark - dw

- (void)dealloc
{
    if ( _audioTrackSourceFormatDescription )
    {
        CFRelease( _audioTrackSourceFormatDescription );
    }

    if ( _videoTrackSourceFormatDescription )
    {
        CFRelease( _videoTrackSourceFormatDescription );
    }
}

@end
