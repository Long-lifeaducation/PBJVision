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

typedef NS_ENUM( NSInteger, PBJMediaWriterStatus)
{
    PBJMediaWriterStatusIdle = 0,
    PBJMediaWriterStausPreparingToRecord,
    PBJMediaWriterStatusRecording,
    PBJMediaWriterStatusFlushInFlightBuffers,
    PBJMediaWriterStatusStopRecording,
    PBJMediaWriterStatusFinished,
    PBJMediaWriterStatusFailed,
};

@interface PBJMediaWriter ()
{
    PBJMediaWriterStatus _status;

    __weak id <PBJMediaWriterDelegate> _delegate;
    dispatch_queue_t _delegateQueue;

    dispatch_queue_t _writerQueue;

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
    BOOL _didWriteFirstPacket;
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
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Caller must provide a delegateCallbackQueue" userInfo:nil];
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

        _status = PBJMediaWriterStatusIdle;

        _writerQueue = dispatch_queue_create( "PBJMediaWriterWriting", DISPATCH_QUEUE_SERIAL );

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
        if ( _status != PBJMediaWriterStatusIdle ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add tracks while not idle" userInfo:nil];
            return;
        }

        if ( _audioTrackSourceFormatDescription ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add more than one audio track" userInfo:nil];
            return;
        }

        _audioSettings = [audioSettings copy];
    }
}

- (void)addVideoTrackWithFormatDescription:(CMFormatDescriptionRef)formatDescription settings:(NSDictionary *)videoSettings
{
    @synchronized(self)
    {
        if ( _status != PBJMediaWriterStatusIdle ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add tracks while not idle" userInfo:nil];
            return;
        }

        if ( _videoTrackSourceFormatDescription ) {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Cannot add more than one video track" userInfo:nil];
            return;
        }

        _videoTrackSourceFormatDescription = (CMFormatDescriptionRef)CFRetain( formatDescription );
        _videoSettings = [videoSettings copy];
    }
}

- (NSError *)setupAudioOutputDeviceWithSettings:(NSDictionary *)audioSettings
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

    return nil;
}

- (NSError *)setupVideoOutputDeviceWithSettings:(NSDictionary *)videoSettings
{
    NSError *ret = nil;
    NSDictionary *errorDict = nil;

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
        CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(_videoTrackSourceFormatDescription);

        // TODO: will we always be square?
        int32_t squareDim = MIN(dimensions.width, dimensions.height);

        _assetWriterInputPixelBufferAdaptor = [AVAssetWriterInputPixelBufferAdaptor assetWriterInputPixelBufferAdaptorWithAssetWriterInput:_assetWriterVideoIn sourcePixelBufferAttributes:
                                               [NSDictionary dictionaryWithObjectsAndKeys:
                                                [NSNumber numberWithInteger:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange], (id)kCVPixelBufferPixelFormatTypeKey,
                                                @(squareDim), (id)kCVPixelBufferWidthKey,
                                                @(squareDim), (id)kCVPixelBufferHeightKey,
                                                (id)kCFBooleanFalse, (id)kCVPixelFormatOpenGLESCompatibility,
                                                nil]];

        if (!_assetWriterInputPixelBufferAdaptor)
        {
            DLog(@"couldn't set up assetwriterinputpixeladapter");
            errorDict = @{ NSLocalizedDescriptionKey : @"MediaWriter cannot start recording.",
                           NSLocalizedFailureReasonErrorKey : @"Cannot get pixel buffer adapter" };
        }


		if ([_assetWriter canAddInput:_assetWriterVideoIn]) {
			[_assetWriter addInput:_assetWriterVideoIn];
		} else {
			DLog(@"couldn't add asset writer video input");
            errorDict = @{ NSLocalizedDescriptionKey : @"MediaWriter cannot start recording.",
                            NSLocalizedFailureReasonErrorKey : @"Cannot add input" };
		}
        
	} else {
    
		DLog(@"couldn't apply video output settings");
        errorDict = @{ NSLocalizedDescriptionKey : @"MediaWriter cannot start recording.",
                       NSLocalizedFailureReasonErrorKey : @"Cannot apply settings" };

	}

    if (errorDict)
    {
        ret = [NSError errorWithDomain:@"com.smule.sing.mediawriter" code:0 userInfo:errorDict];
    }
    
    return ret;
}

- (void)prepareToRecord
{

    @synchronized(self)
    {
        if ( _status != PBJMediaWriterStatusIdle )
        {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Already prepared, cannot prepare again" userInfo:nil];
            return;
        }

        [self transitionToStatus:PBJMediaWriterStausPreparingToRecord error:nil];
    }



    dispatch_async( dispatch_get_global_queue( DISPATCH_QUEUE_PRIORITY_LOW, 0 ), ^{

        @autoreleasepool
        {
            NSError *error = nil;

            if (!error && _videoSettings)
            {
                error = [self setupVideoOutputDeviceWithSettings:_videoSettings];
            }

            if (!error && _audioSettings)
            {
                 error = [self setupAudioOutputDeviceWithSettings:_audioSettings];
            }

            if (!error && [_assetWriter startWriting])
            {
                error = _assetWriter.error;
            }

            if (error)
            {
                [self transitionToStatus:PBJMediaWriterStatusFailed error:error];
            }
            else
            {
                // we're ready to start recording
                [self transitionToStatus:PBJMediaWriterStatusRecording error:nil];
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
    @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"Write this method" userInfo:nil];
    //[self writeSampleBuffer:sampleBuffer ofType:mediaType withPixelBuffer:NULL];
}

- (void)writeSampleBuffer:(CMSampleBufferRef)sampleBuffer ofType:(NSString *)mediaType withPixelBuffer:(CVPixelBufferRef)filteredPixelBuffer atTimestamp:(CMTime)timestamp withDuration:(CMTime)duration
{
    if (!sampleBuffer && mediaType == AVMediaTypeAudio )
    {
        @throw [NSException exceptionWithName:NSInvalidArgumentException reason:@"No sample buffer" userInfo:nil];
    }


    @synchronized(self)
    {
        if (_status < PBJMediaWriterStatusRecording)
        {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Not ready to record" userInfo:nil];
        }

        if (_assetWriter.status == AVAssetWriterStatusFailed)
        {
            @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"odd stuff..." userInfo:nil];
        }

        // update the _videoTimestamp for here now...
        if (mediaType == AVMediaTypeVideo)
        {
            _videoTimestamp = timestamp;
            if (CMTIME_IS_VALID(duration))
            {
                _videoTimestamp = CMTimeAdd(timestamp,duration);
            }
        }
        else if (mediaType == AVMediaTypeAudio)
        {
            _audioTimestamp = timestamp;
        }

    }

    if (sampleBuffer)
    {
        CFRetain(sampleBuffer);
    }
    if (filteredPixelBuffer)
    {
        CFRetain(filteredPixelBuffer);
    }


    dispatch_async( _writerQueue, ^{

        // bail if we've transitioned past writing by the time this hits the writerQueue
        @synchronized(self)
        {
            if (_status > PBJMediaWriterStatusFlushInFlightBuffers)
            {
                if (sampleBuffer)
                {
                    CFRelease(sampleBuffer);
                }
                if (filteredPixelBuffer)
                {
                    CFRelease(filteredPixelBuffer);
                }
                return;
            }
        }

        if (!_didWriteFirstPacket)
        {
            [_assetWriter startSessionAtSourceTime:timestamp];
            _didWriteFirstPacket = YES;
        }

        // avoiding one arrow...
        AVAssetWriterInput *currentInput = (mediaType == AVMediaTypeVideo) ? _assetWriterVideoIn : _assetWriterAudioIn;
        BOOL success = YES;
        if (currentInput && currentInput.readyForMoreMediaData)
        {
            if (mediaType == AVMediaTypeVideo && filteredPixelBuffer)
            {
                success = [_assetWriterInputPixelBufferAdaptor appendPixelBuffer:filteredPixelBuffer withPresentationTime:timestamp];
                //DLog(@"appending pixel buffer");
            }
            else
            {
                success = [currentInput appendSampleBuffer:sampleBuffer];
            }
        }
        else
        {
            DLog(@"Dropping %@ buffer because AssetWriter not ready", mediaType);
        }

        if (!success)
        {
            DLog(@"Error appending sample buffer");
            NSError *error = _assetWriter.error;
            @synchronized(self)
            {
                [self transitionToStatus:PBJMediaWriterStatusFailed error:error];
            }
        }

        if (sampleBuffer)
        {
         CFRelease(sampleBuffer);
        }
        if (filteredPixelBuffer)
        {
            CFRelease(filteredPixelBuffer);
        }

    } );

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

- (void)finishWriting
{
    BOOL shouldFinishWriting = NO;
    @synchronized(self)
    {
        switch (_status)
        {
            case PBJMediaWriterStatusIdle:
            case PBJMediaWriterStausPreparingToRecord:
            case PBJMediaWriterStatusFlushInFlightBuffers:
            case PBJMediaWriterStatusFinished:
                @throw [NSException exceptionWithName:NSInternalInconsistencyException reason:@"Not recording" userInfo:nil];
                break;
            case PBJMediaWriterStatusFailed:
                NSLog( @"nothing to do" );
                break;
            case PBJMediaWriterStatusRecording:
                shouldFinishWriting = YES;
                break;
            default:
                break;
        }

        if (shouldFinishWriting)
        {
            // begin to flush buffers
            [self transitionToStatus:PBJMediaWriterStatusFlushInFlightBuffers error:nil];
        }
        else
        {
            return;
        }
    }


    dispatch_async(_writerQueue, ^{

        @autoreleasepool
        {
            @synchronized(self)
            {
                // potential error case
                if ( _status != PBJMediaWriterStatusFlushInFlightBuffers ) {
                    return;
                }

                [self transitionToStatus:PBJMediaWriterStatusStopRecording error:nil];
            }

            if (_assetWriterAudioIn)
            {
                [_assetWriterAudioIn markAsFinished];
            }
            if (_assetWriterVideoIn)
            {
                [_assetWriterVideoIn markAsFinished];
            }

            [_assetWriter finishWritingWithCompletionHandler:^{
                @synchronized( self )
                {
                    NSError *error = _assetWriter.error;
                    if ( error ) {
                        [self transitionToStatus:PBJMediaWriterStatusFailed error:error];
                    }
                    else {
                        [self transitionToStatus:PBJMediaWriterStatusFinished error:nil];
                    }
                }
            }];
        }

    });

}

- (void)transitionToStatus:(PBJMediaWriterStatus)newStatus error:(NSError *)error
{
    BOOL doNotify = NO;

    if (newStatus != _status)
    {
        // check end states
        if ( (newStatus == PBJMediaWriterStatusFinished) || (newStatus == PBJMediaWriterStatusFailed))
        {
            doNotify = YES;
            dispatch_async( _writerQueue, ^{
                [self teardown];
            } );
        }
        else if (newStatus == PBJMediaWriterStatusRecording)
        {
             _videoReady = YES;
            doNotify = YES;
        }

        _status = newStatus;
    }

    if (doNotify && self.delegate)
    {
        dispatch_async(_delegateQueue, ^{

            @autoreleasepool
            {
                switch(newStatus)
                {
                    case PBJMediaWriterStatusRecording:
                        [_delegate mediaWriterDidFinishPreparing:self];
                        break;
                    case PBJMediaWriterStatusFinished:
                        [_delegate mediaWriterDidFinishRecording:self];
                        break;
                    case PBJMediaWriterStatusFailed:
                        [_delegate mediaWriterDidObserveAssetWriterFailed:self withError:error];
                        break;
                    default:
                        break;
                }
            }
        });
    }

}

- (void)teardown
{
    _assetWriterVideoIn = nil;
    _assetWriterAudioIn = nil;
    _assetWriterInputPixelBufferAdaptor = nil;
    _assetWriter = nil;
}

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
