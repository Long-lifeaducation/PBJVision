//
//  PBJVision.m
//  Vision
//
//  Created by Patrick Piemonte on 4/30/13.
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

#import "PBJVision.h"
#import "PBJVisionUtilities.h"
#import "PBJMediaWriter.h"
#import "PBJGLProgram.h"
#import "VideoFilterManager.h"
#import "GPUImageSplitFilter.h"

#import <ImageIO/ImageIO.h>
#import <OpenGLES/EAGL.h>
#import <GLKit/GLKit.h>

#include <sys/types.h>
#include <sys/sysctl.h>
#import <client-magic/MagicLogger.h>
#import <client-magic/UIDevice+Magic.h> 

#import "GPUImage.h"

#define LOG_VISION 1
#ifndef DLog
#if !defined(NDEBUG) && LOG_VISION
#   define DLog(fmt, ...) NSLog((@"VISION: " fmt), ##__VA_ARGS__);
#else
#   define DLog(...)
#endif
#endif

NSString * const PBJVisionErrorDomain = @"PBJVisionErrorDomain";

static uint64_t const PBJVisionRequiredMinimumDiskSpaceInBytes = 49999872; // ~ 47 MB
static CGFloat const PBJVisionThumbnailWidth = 160.0f;

static CGColorSpaceRef sDeviceRgbColorSpace = NULL;

// KVO contexts

static NSString * const PBJVisionFocusObserverContext = @"PBJVisionFocusObserverContext";
static NSString * const PBJVisionExposureObserverContext = @"PBJVisionExposureObserverContext";
static NSString * const PBJVisionWhiteBalanceObserverContext = @"PBJVisionWhiteBalanceObserverContext";
static NSString * const PBJVisionFlashModeObserverContext = @"PBJVisionFlashModeObserverContext";
static NSString * const PBJVisionTorchModeObserverContext = @"PBJVisionTorchModeObserverContext";
static NSString * const PBJVisionFlashAvailabilityObserverContext = @"PBJVisionFlashAvailabilityObserverContext";
static NSString * const PBJVisionTorchAvailabilityObserverContext = @"PBJVisionTorchAvailabilityObserverContext";
static NSString * const PBJVisionCaptureStillImageIsCapturingStillImageObserverContext = @"PBJVisionCaptureStillImageIsCapturingStillImageObserverContext";

// photo dictionary key definitions

NSString * const PBJVisionPhotoMetadataKey = @"PBJVisionPhotoMetadataKey";
NSString * const PBJVisionPhotoJPEGKey = @"PBJVisionPhotoJPEGKey";
NSString * const PBJVisionPhotoImageKey = @"PBJVisionPhotoImageKey";
NSString * const PBJVisionPhotoThumbnailKey = @"PBJVisionPhotoThumbnailKey";

// video dictionary key definitions

NSString * const PBJVisionVideoPathKey = @"PBJVisionVideoPathKey";
NSString * const PBJVisionVideoThumbnailKey = @"PBJVisionVideoThumbnailKey";
NSString * const PBJVisionVideoCapturedDurationKey = @"PBJVisionVideoCapturedDurationKey";


// PBJGLProgram shader uniforms for pixel format conversion on the GPU
typedef NS_ENUM(GLint, PBJVisionUniformLocationTypes)
{
    PBJVisionUniformY,
    PBJVisionUniformUV,
    PBJVisionUniformCount
};

///

@interface PBJVision () <
    AVCaptureAudioDataOutputSampleBufferDelegate,
    AVCaptureVideoDataOutputSampleBufferDelegate,
    PBJMediaWriterDelegate>
{
    // AV

    AVCaptureSession *_captureSession;
    
    AVCaptureDevice *_captureDeviceFront;
    AVCaptureDevice *_captureDeviceBack;
    AVCaptureDevice *_captureDeviceAudio;
    
    AVCaptureDeviceInput *_captureDeviceInputFront;
    AVCaptureDeviceInput *_captureDeviceInputBack;
    AVCaptureDeviceInput *_captureDeviceInputAudio;

    AVCaptureStillImageOutput *_captureOutputPhoto;
    AVCaptureAudioDataOutput *_captureOutputAudio;
    AVCaptureVideoDataOutput *_captureOutputVideo;

    // vision core

    PBJMediaWriter *_mediaWriter;

    dispatch_queue_t _captureSessionDispatchQueue;
    dispatch_queue_t _captureVideoDispatchQueue;

    PBJCameraDevice _cameraDevice;
    PBJCameraMode _cameraMode;
    PBJCameraOrientation _cameraOrientation;
    
    PBJFocusMode _focusMode;
    PBJExposureMode _exposureMode;
    PBJFlashMode _flashMode;
    PBJMirroringMode _mirroringMode;

    NSString *_captureSessionPreset;
    PBJOutputFormat _outputFormat;
    
    CGFloat _videoBitRate;
    NSInteger _audioBitRate;
    NSInteger _videoFrameRate;
    NSDictionary *_additionalCompressionProperties;
    
    AVCaptureDevice *_currentDevice;
    AVCaptureDeviceInput *_currentInput;
    AVCaptureOutput *_currentOutput;
    
    AVCaptureVideoPreviewLayer *_previewLayer;
    CGRect _cleanAperture;
    GPUImageView *_filteredPreviewView;
    GPUImageView *_filteredSmallPreviewView;

    CMTime _startTimestamp;
    CMTime _lastTimestamp;
    CMTime _lastPauseTimestamp;
    CMTime _totalPauseTime;
    
    CMTime _maximumCaptureDuration;

    // sample buffer rendering

    PBJCameraDevice _bufferDevice;
    PBJCameraOrientation _bufferOrientation;
    size_t _bufferWidth;
    size_t _bufferHeight;
    CGRect _presentationFrame;

    EAGLContext *_context;
    EAGLContext *_contextPreview;
    PBJGLProgram *_program;
    CVOpenGLESTextureRef _lumaTexture;
    CVOpenGLESTextureRef _chromaTexture;
    CVOpenGLESTextureCacheRef _videoTextureCache;
    
    CIContext *_ciContext;
    CIContext *_ciContextPreview;
    
    NSMutableArray *_previousSecondTimestamps;
	Float64 _frameRate;
    
    CMTime _lastAudioTimestamp;
    
    CMTime _audioRecordOffset;
    
    CMTime _lastVideoDisplayTimestamp;
    CMTime _minDisplayDuration;
    
    unsigned long _recordedFrameCount;
    
    // flags
    
    struct {
        unsigned int previewRunning:1;
        unsigned int changingModes:1;
        unsigned int recording:1;
        unsigned int paused:1;
        unsigned int interrupted:1;
        unsigned int videoWritten:1;
        unsigned int videoRenderingEnabled:1;
        unsigned int audioCaptureEnabled:1;
        unsigned int thumbnailEnabled:1;
    } __block _flags;
}

@property (nonatomic) AVCaptureDevice *currentDevice;

@property (nonatomic, strong) GPUImageMovie *movieDataInput;
@property (nonatomic, strong) GPUImageFilterGroup *currentFilterGroup;
@property (nonatomic, strong) VideoFilterManager *filterManager;

@end


@implementation PBJVision

@synthesize delegate = _delegate;
@synthesize currentDevice = _currentDevice;
@synthesize previewLayer = _previewLayer;
@synthesize cleanAperture = _cleanAperture;
@synthesize cameraOrientation = _cameraOrientation;
@synthesize cameraDevice = _cameraDevice;
@synthesize cameraMode = _cameraMode;
@synthesize focusMode = _focusMode;
@synthesize exposureMode = _exposureMode;
@synthesize flashMode = _flashMode;
@synthesize mirroringMode = _mirroringMode;
@synthesize outputFormat = _outputFormat;
@synthesize context = _context;
@synthesize contextPreview = _contextPreview;
@synthesize presentationFrame = _presentationFrame;
@synthesize captureSessionPreset = _captureSessionPreset;
@synthesize audioBitRate = _audioBitRate;
@synthesize videoBitRate = _videoBitRate;
@synthesize additionalCompressionProperties = _additionalCompressionProperties;
@synthesize maximumCaptureDuration = _maximumCaptureDuration;

+ (NSString*)hardwareString
{
    size_t size = 100;
    char *hw_machine = malloc(size);
    int name[] = {CTL_HW,HW_MACHINE};
    sysctl(name, 2, hw_machine, &size, NULL, 0);
    NSString *hardware = [NSString stringWithUTF8String:hw_machine];
    free(hw_machine);
    return hardware;
}

#pragma mark - singleton

+ (PBJVision *)sharedInstance
{
    static PBJVision *singleton = nil;
    static dispatch_once_t once = 0;
    dispatch_once(&once, ^{
        singleton = [[PBJVision alloc] init];
    });
    return singleton;
}

#pragma mark - getters/setters

- (void)setPreviewFrameRate:(int)frameRate
{
    _minDisplayDuration = CMTimeMake(1, frameRate);
}

- (BOOL)isCaptureSessionActive
{
    return ([_captureSession isRunning]);
}

- (BOOL)isRecording
{
    return _flags.recording;
}

- (BOOL)isPaused
{
    return _flags.paused;
}

- (void)setVideoRenderingEnabled:(BOOL)videoRenderingEnabled
{
    _flags.videoRenderingEnabled = (unsigned int)videoRenderingEnabled;
}

- (BOOL)isVideoRenderingEnabled
{
    return _flags.videoRenderingEnabled;
}

- (void)setAudioCaptureEnabled:(BOOL)audioCaptureEnabled
{
    _flags.audioCaptureEnabled = (unsigned int)audioCaptureEnabled;
}

- (BOOL)isAudioCaptureEnabled
{
    return _flags.audioCaptureEnabled;
}

- (void)setThumbnailEnabled:(BOOL)thumbnailEnabled
{
    _flags.thumbnailEnabled = (unsigned int)thumbnailEnabled;
}

- (BOOL)thumbnailEnabled
{
    return _flags.thumbnailEnabled;
}

- (Float64)capturedAudioSeconds
{
    if (_mediaWriter && CMTIME_IS_VALID(_mediaWriter.audioTimestamp)) {
        return CMTimeGetSeconds(CMTimeSubtract(_mediaWriter.audioTimestamp, _startTimestamp));
    } else {
        return 0.0;
    }
}

- (Float64)capturedVideoSeconds
{
    if (_mediaWriter && CMTIME_IS_VALID(_mediaWriter.videoTimestamp)) {
        if (CMTimeGetSeconds(CMTimeSubtract(_mediaWriter.videoTimestamp, _startTimestamp)) < 0) {
            _startTimestamp = _mediaWriter.videoTimestamp;
        }
        //return CMTimeGetSeconds(CMTimeSubtract(_mediaWriter.videoTimestamp, _startTimestamp));
        return CMTimeGetSeconds(_mediaWriter.videoTimestamp);
    } else {
        return 0.0;
    }
}

- (void)setCameraOrientation:(PBJCameraOrientation)cameraOrientation
{
     if (cameraOrientation == _cameraOrientation)
        return;
     _cameraOrientation = cameraOrientation;
    
    if ([_previewLayer.connection isVideoOrientationSupported])
        [self _setOrientationForConnection:_previewLayer.connection];
    
    AVCaptureConnection *videoConnection = [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo];
    if (videoConnection.isVideoOrientationSupported) {
        [self _setOrientationForConnection:videoConnection];
    }
}

- (void)_setOrientationForConnection:(AVCaptureConnection *)connection
{
    if (!connection || ![connection isVideoOrientationSupported])
        return;

    AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
    switch (_cameraOrientation) {
        case PBJCameraOrientationPortraitUpsideDown:
            orientation = AVCaptureVideoOrientationPortraitUpsideDown;
            break;
        case PBJCameraOrientationLandscapeRight:
            orientation = AVCaptureVideoOrientationLandscapeRight;
            break;
        case PBJCameraOrientationLandscapeLeft:
            orientation = AVCaptureVideoOrientationLandscapeLeft;
            break;
        default:
        case PBJCameraOrientationPortrait:
            orientation = AVCaptureVideoOrientationPortrait;
            break;
    }

    [connection setVideoOrientation:orientation];
}

- (void)_setCameraMode:(PBJCameraMode)cameraMode cameraDevice:(PBJCameraDevice)cameraDevice outputFormat:(PBJOutputFormat)outputFormat
{
    BOOL changeDevice = (_cameraDevice != cameraDevice);
    BOOL changeMode = (_cameraMode != cameraMode);
    BOOL changeOutputFormat = (_outputFormat != outputFormat);
    
    DLog(@"change device (%d) mode (%d) format (%d)", changeDevice, changeMode, changeOutputFormat);
    
    if (!changeMode && !changeDevice && !changeOutputFormat)
        return;
    
    SEL targetDelegateMethodBeforeChange;
    SEL targetDelegateMethodAfterChange;

    if (changeDevice) {
        targetDelegateMethodBeforeChange = @selector(visionCameraDeviceWillChange:);
        targetDelegateMethodAfterChange = @selector(visionCameraDeviceDidChange:);
    }
    else if (changeMode) {
        targetDelegateMethodBeforeChange = @selector(visionCameraModeWillChange:);
        targetDelegateMethodAfterChange = @selector(visionCameraModeDidChange:);
    }
    else {
        targetDelegateMethodBeforeChange = @selector(visionOutputFormatWillChange:);
        targetDelegateMethodAfterChange = @selector(visionOutputFormatDidChange:);
    }

    if ([_delegate respondsToSelector:targetDelegateMethodBeforeChange]) {
        // At this point, `targetDelegateMethodBeforeChange` will always refer to a valid selector, as
        // from the sequence of conditionals above. Also the enclosing `if` statement ensures
        // that the delegate responds to it, thus safely ignore this compiler warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [_delegate performSelector:targetDelegateMethodBeforeChange withObject:self];
#pragma clang diagnostic pop
    }
    
    _flags.changingModes = YES;
    
    _cameraDevice = cameraDevice;
    _cameraMode = cameraMode;
    
    [self setMirroringMode:_mirroringMode];

    _outputFormat = outputFormat;
    
    // since there is no session in progress, set and bail
    if (!_captureSession) {
        _flags.changingModes = NO;
            
        if ([_delegate respondsToSelector:targetDelegateMethodAfterChange]) {
            // At this point, `targetDelegateMethodAfterChange` will always refer to a valid selector, as
            // from the sequence of conditionals above. Also the enclosing `if` statement ensures
            // that the delegate responds to it, thus safely ignore this compiler warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
            [_delegate performSelector:targetDelegateMethodAfterChange withObject:self];
#pragma clang diagnostic pop
        }
        
        return;
    }
    
    [self _enqueueBlockOnCaptureSessionQueue:^{
        // camera is already setup, no need to call _setupCamera
        [self _setupSession];
        
        [self _enqueueBlockOnMainQueue:^{
            _flags.changingModes = NO;
            
            if ([_delegate respondsToSelector:targetDelegateMethodAfterChange]) {
                // At this point, `targetDelegateMethodAfterChange` will always refer to a valid selector, as
                // from the sequence of conditionals above. Also the enclosing `if` statement ensures
                // that the delegate responds to it, thus safely ignore this compiler warning.
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
                [_delegate performSelector:targetDelegateMethodAfterChange withObject:self];
#pragma clang diagnostic pop
            }
        }];
    }];
}

- (void)setCameraDevice:(PBJCameraDevice)cameraDevice
{
    [self _setCameraMode:_cameraMode cameraDevice:cameraDevice outputFormat:_outputFormat];
}

- (void)setCameraMode:(PBJCameraMode)cameraMode
{
    [self _setCameraMode:cameraMode cameraDevice:_cameraDevice outputFormat:_outputFormat];
}

- (void)setOutputFormat:(PBJOutputFormat)outputFormat
{
    [self _setCameraMode:_cameraMode cameraDevice:_cameraDevice outputFormat:outputFormat];
}

- (BOOL)isCameraDeviceAvailable:(PBJCameraDevice)cameraDevice
{
    return [UIImagePickerController isCameraDeviceAvailable:(UIImagePickerControllerCameraDevice)cameraDevice];
}

- (BOOL)isFocusPointOfInterestSupported
{
    return [_currentDevice isFocusPointOfInterestSupported];
}

- (BOOL)isFocusLockSupported
{
    return [_currentDevice isFocusModeSupported:AVCaptureFocusModeLocked];
}

- (void)setFocusMode:(PBJFocusMode)focusMode
{
    BOOL shouldChangeFocusMode = (_focusMode != focusMode);
    if (![_currentDevice isFocusModeSupported:(AVCaptureFocusMode)focusMode] || !shouldChangeFocusMode)
        return;
    
    _focusMode = focusMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        [_currentDevice setFocusMode:(AVCaptureFocusMode)focusMode];
        [_currentDevice unlockForConfiguration];
    } else if (error) {
        DLog(@"error locking device for focus mode change (%@)", error);
    }
}

- (BOOL)isExposureLockSupported
{
    return [_currentDevice isExposureModeSupported:AVCaptureExposureModeLocked];
}

- (void)setExposureMode:(PBJExposureMode)exposureMode
{
    BOOL shouldChangeExposureMode = (_exposureMode != exposureMode);
    if (![_currentDevice isExposureModeSupported:(AVCaptureExposureMode)exposureMode] || !shouldChangeExposureMode)
        return;
    
    _exposureMode = exposureMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        [_currentDevice setExposureMode:(AVCaptureExposureMode)exposureMode];
        [_currentDevice unlockForConfiguration];
    } else if (error) {
        DLog(@"error locking device for exposure mode change (%@)", error);
    }

}

- (BOOL)isFlashAvailable
{
    return (_currentDevice && [_currentDevice hasFlash]);
}

- (void)setFlashMode:(PBJFlashMode)flashMode
{
    BOOL shouldChangeFlashMode = (_flashMode != flashMode);
    if (![_currentDevice hasFlash] || !shouldChangeFlashMode)
        return;

    _flashMode = flashMode;
    
    NSError *error = nil;
    if (_currentDevice && [_currentDevice lockForConfiguration:&error]) {
        
        switch (_cameraMode) {
          case PBJCameraModePhoto:
          {
            if ([_currentDevice isFlashModeSupported:(AVCaptureFlashMode)_flashMode]) {
                [_currentDevice setFlashMode:(AVCaptureFlashMode)_flashMode];
            }
            break;
          }
          case PBJCameraModeVideo:
          {
            if ([_currentDevice isFlashModeSupported:(AVCaptureFlashMode)_flashMode]) {
                [_currentDevice setFlashMode:AVCaptureFlashModeOff];
            }
            
            if ([_currentDevice isTorchModeSupported:(AVCaptureTorchMode)_flashMode]) {
                [_currentDevice setTorchMode:(AVCaptureTorchMode)_flashMode];
            }
            break;
          }
          default:
            break;
        }
    
        [_currentDevice unlockForConfiguration];
    
    } else if (error) {
        DLog(@"error locking device for flash mode change (%@)", error);
    }
}

// framerate

- (void)setVideoFrameRate:(NSInteger)videoFrameRate
{
    if (![self supportsVideoFrameRate:videoFrameRate]) {
        DLog(@"frame rate range not supported for current device format");
        return;
    }
    
    BOOL isRecording = _flags.recording;
    if (isRecording) {
        [self pauseVideoCapture];
    }

    CMTime fps = CMTimeMake(1, (int32_t)videoFrameRate);

    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_6_1) {
        
        AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        AVCaptureDeviceFormat *supportingFormat = nil;
        int32_t maxWidth = 0;

        NSArray *formats = [videoDevice formats];
        for (AVCaptureDeviceFormat *format in formats) {
            NSArray *videoSupportedFrameRateRanges = format.videoSupportedFrameRateRanges;
            for (AVFrameRateRange *range in videoSupportedFrameRateRanges) {
    
                CMFormatDescriptionRef desc = format.formatDescription;
                CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(desc);
                int32_t width = dimensions.width;
                if (range.minFrameRate <= videoFrameRate && videoFrameRate <= range.maxFrameRate && width >= maxWidth) {
                    supportingFormat = format;
                    maxWidth = width;
                }
                
            }
        }
        
        if (supportingFormat) {
            NSError *error = nil;
            if ([_currentDevice lockForConfiguration:&error]) {
                _currentDevice.activeVideoMinFrameDuration = fps;
                _currentDevice.activeVideoMaxFrameDuration = fps;
                _videoFrameRate = videoFrameRate;
                [_currentDevice unlockForConfiguration];
            } else if (error) {
                DLog(@"error locking device for frame rate change (%@)", error);
            }
        }
        
        AVCaptureDeviceFormat *activeFormat = [_currentDevice activeFormat];
        NSLog(@"%@", activeFormat);
        NSLog(@"%@ %@ %@", activeFormat.mediaType, activeFormat.formatDescription, activeFormat.videoSupportedFrameRateRanges);
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidChangeVideoFormatAndFrameRate:)])
                [_delegate visionDidChangeVideoFormatAndFrameRate:self];
        }];
            
    } else {

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVCaptureConnection *connection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
        if (connection.isVideoMaxFrameDurationSupported) {
            connection.videoMaxFrameDuration = fps;
        } else {
            DLog(@"failed to set frame rate");
        }
        
        if (connection.isVideoMinFrameDurationSupported) {
            connection.videoMinFrameDuration = fps;
            _videoFrameRate = videoFrameRate;
        } else {
            DLog(@"failed to set frame rate");
        }
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidChangeVideoFormatAndFrameRate:)])
                [_delegate visionDidChangeVideoFormatAndFrameRate:self];
        }];
#pragma clang diagnostic pop

    }
    
    if (isRecording) {
        [self resumeVideoCapture];
    }
}

- (NSInteger)videoFrameRate
{
    if (!_currentDevice)
        return 0;

    NSInteger frameRate = 0;
    
    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_6_1) {

        frameRate = _currentDevice.activeVideoMaxFrameDuration.timescale;
    
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVCaptureConnection *connection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
        frameRate = connection.videoMaxFrameDuration.timescale;
#pragma clang diagnostic pop
    }
	
	return frameRate;
}

- (BOOL)supportsVideoFrameRate:(NSInteger)videoFrameRate
{
    if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_6_1) {
        AVCaptureDevice *videoDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];

        NSArray *formats = [videoDevice formats];
        for (AVCaptureDeviceFormat *format in formats) {
            NSArray *videoSupportedFrameRateRanges = [format videoSupportedFrameRateRanges];
            for (AVFrameRateRange *frameRateRange in videoSupportedFrameRateRanges) {
                if ( (frameRateRange.minFrameRate <= videoFrameRate) && (videoFrameRate <= frameRateRange.maxFrameRate) ) {
                    return YES;
                }
            }
        }
        
    } else {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        AVCaptureConnection *connection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
        return (connection.isVideoMaxFrameDurationSupported && connection.isVideoMinFrameDurationSupported);
#pragma clang diagnostic pop
    }

    return NO;
}

- (void)setAudioStartTimestamp:(CMTime)audioStartTimestamp
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        _audioRecordOffset = CMTimeSubtract(_startTimestamp, audioStartTimestamp);
        DLog(@"_audioRecordOffset: %f", CMTimeGetSeconds(_audioRecordOffset));
        
        if (CMTIME_IS_INVALID(_lastTimestamp)) {
            _lastTimestamp = audioStartTimestamp;
            _startTimestamp = audioStartTimestamp;
        } else {
//            _lastTimestamp = CMTimeSubtract(audioStartTimestamp, _mediaWriter.videoTimestamp);
//            DLog(@"_mediaWriter.videoTimestamp: %f", CMTimeGetSeconds(_mediaWriter.videoTimestamp));
            
            if (CMTIME_IS_VALID(_lastPauseTimestamp)) {
                CMTime thisPauseTime = CMTimeSubtract(audioStartTimestamp, _lastPauseTimestamp);
                _totalPauseTime = CMTimeAdd(_totalPauseTime, thisPauseTime);
                _lastTimestamp = CMTimeAdd(_startTimestamp, _totalPauseTime);
                _lastPauseTimestamp = kCMTimeInvalid;
                NSLog(@"_totalPauseTime: %f", CMTimeGetSeconds(_totalPauseTime));
            }
        }
        
        DLog(@"_lastTimestamp: %lld %d", _lastTimestamp.value, _lastTimestamp.timescale);
        
        [_previousSecondTimestamps removeAllObjects];
    }];
}

- (void)setAudioStopTimestamp:(CMTime)audioStopTimestamp
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        // only set a new pause timestamp if the old one is invalid
        if ( CMTIME_IS_INVALID(_lastPauseTimestamp) ) {
            _lastPauseTimestamp = audioStopTimestamp;
        }
    }];
}

#pragma mark - init

- (id)init
{
    self = [super init];
    if (self) {
        
        // setup GLES
        _context = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!_context) {
            DLog(@"failed to create GL context");
        }
        _contextPreview = [[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2];
        if (!_contextPreview) {
            DLog(@"failed to create GL context");
        }
        [self _setupGL];
        
        sDeviceRgbColorSpace = CGColorSpaceCreateDeviceRGB();
        
        NSDictionary *options = @{ (id)kCIContextWorkingColorSpace : (id)kCFNull };
        _ciContext = [CIContext contextWithEAGLContext:_context options:options];
        _ciContextPreview = [CIContext contextWithEAGLContext:_contextPreview options:options];
        
        _centerPercentage = 0.5f;
        
        // set default capture preset
        _captureSessionPreset = AVCaptureSessionPresetMedium;

        // Average bytes per second based on video dimensions
        // lower the bitRate, higher the compression
        _videoBitRate = PBJVideoBitRate480x360;

        // default audio/video configuration
        _audioBitRate = 64000;
        
        // default flags
        _flags.thumbnailEnabled = YES;
        _flags.audioCaptureEnabled = NO;

        // setup queues
        _captureSessionDispatchQueue = dispatch_queue_create("PBJVisionSession", DISPATCH_QUEUE_SERIAL); // protects session
        _captureVideoDispatchQueue = dispatch_queue_create("PBJVisionVideo", DISPATCH_QUEUE_SERIAL); // protects capture
        
        _previewLayer = [[AVCaptureVideoPreviewLayer alloc] initWithSession:nil];
        _previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        
        [self setupPreviewViews];
        
        _maximumCaptureDuration = kCMTimeInvalid;
        
        [self setMirroringMode:PBJMirroringOff];
        
        _previousSecondTimestamps = [[NSMutableArray alloc] init];
        // controls max frame-rate for both capture preview (solo) and duet playback
        _minDisplayDuration = CMTimeMake(1, 15);

        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationWillEnterForeground:) name:@"UIApplicationWillEnterForegroundNotification" object:[UIApplication sharedApplication]];
        [[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(_applicationDidEnterBackground:) name:@"UIApplicationDidEnterBackgroundNotification" object:[UIApplication sharedApplication]];
        
        _filterManager = [[VideoFilterManager alloc] init];
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    _delegate = nil;

    [self _cleanUpTextures];
    
    if (_videoTextureCache) {
        CFRelease(_videoTextureCache);
        _videoTextureCache = NULL;
    }
    
    [self _destroyGL];
    [self _destroyCamera];
}

- (void)setupPreviewViews
{
    DLog(@"resetting preview views...");
    
    _filteredPreviewView = [[GPUImageView alloc] initWithFrame:CGRectMake(0, 0, 640, 640)];
    [_filteredPreviewView setFillMode:kGPUImageFillModePreserveAspectRatioAndFill];
    
    CGRect smallPreviewBounds = _filteredPreviewView.bounds;
    static const float scale = 0.2;
    smallPreviewBounds.size.width = smallPreviewBounds.size.width * scale;
    smallPreviewBounds.size.height = smallPreviewBounds.size.height * scale;
    
    _filteredSmallPreviewView = [[GPUImageView alloc] initWithFrame:smallPreviewBounds];
    [_filteredSmallPreviewView setFillMode:kGPUImageFillModePreserveAspectRatioAndFill];
    
    DLog(@"reset preview views!");
}

#pragma mark - queue helper methods

typedef void (^PBJVisionBlock)();

- (void)_enqueueBlockOnCaptureSessionQueue:(PBJVisionBlock)block
{
    dispatch_async(_captureSessionDispatchQueue, ^{
        block();
    });
}

- (void)_enqueueBlockOnCaptureVideoQueue:(PBJVisionBlock)block
{
    dispatch_async(_captureVideoDispatchQueue, ^{
        block();
    });
}

- (void)_enqueueBlockOnMainQueue:(PBJVisionBlock)block
{
    dispatch_async(dispatch_get_main_queue(), ^{
        block();
    });
}

- (void)_executeBlockOnMainQueue:(PBJVisionBlock)block
{
    dispatch_sync(dispatch_get_main_queue(), ^{
        block();
    });
}

#pragma mark - camera

// only call from the session queue
- (void)_setupCamera
{
    if (_captureSession)
        return;
    
#if COREVIDEO_USE_EAGLCONTEXT_CLASS_IN_API
    CVReturn cvError = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, _context, NULL, &_videoTextureCache);
#else
    CVReturn cvError = CVOpenGLESTextureCacheCreate(kCFAllocatorDefault, NULL, (__bridge void *)_context, NULL, &_videoTextureCache);
#endif
    if (cvError) {
        NSLog(@"error CVOpenGLESTextureCacheCreate (%d)", cvError);
    }

    // create session
    _captureSession = [[AVCaptureSession alloc] init];

    _captureSession.usesApplicationAudioSession = YES;
    _captureSession.automaticallyConfiguresApplicationAudioSession = NO;

    // capture devices
    _captureDeviceFront = [PBJVisionUtilities captureDeviceForPosition:AVCaptureDevicePositionFront];
    _captureDeviceBack = [PBJVisionUtilities captureDeviceForPosition:AVCaptureDevicePositionBack];

    // capture device inputs
    NSError *error = nil;
    _captureDeviceInputFront = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceFront error:&error];
    if (error) {
        DLog(@"error setting up front camera input (%@)", error);
        error = nil;
    }
    
    _captureDeviceInputBack = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceBack error:&error];
    if (error) {
        DLog(@"error setting up back camera input (%@)", error);
        error = nil;
    }
    
    if (_cameraMode != PBJCameraModePhoto && _flags.audioCaptureEnabled) {
        _captureDeviceAudio = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
        _captureDeviceInputAudio = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceAudio error:&error];

        if (error) {
            DLog(@"error setting up audio input (%@)", error);
        }
    }
    
    // capture device ouputs
    _captureOutputPhoto = [[AVCaptureStillImageOutput alloc] init];
    if (_cameraMode != PBJCameraModePhoto && _flags.audioCaptureEnabled) {
    	_captureOutputAudio = [[AVCaptureAudioDataOutput alloc] init];
    }
    _captureOutputVideo = [[AVCaptureVideoDataOutput alloc] init];
    
    if (_cameraMode != PBJCameraModePhoto && _flags.audioCaptureEnabled) {
    	[_captureOutputAudio setSampleBufferDelegate:self queue:_captureVideoDispatchQueue];
    }
    [_captureOutputVideo setSampleBufferDelegate:self queue:_captureVideoDispatchQueue];

    // capture device initial settings
    _videoFrameRate = 30;
    
    // when drawing the preview we need to scale it by screen scale to handle correct
    // pixel density. iphone 6+ has a different density than any other device, and it's
    // not reflected in the UIScreen scale because we aren't fully supporting that
    // screen size yet (the OS simulates it using a scale of 2 when the actual device pixel ratio is 2.6)
    
    if ([UIDevice isIOSVersion8x])
    {
        // Ensures proper scale regardless of zoom setting on iPhone display zoom setting.
        // Relevant for both iPhone 6 and 6Plus models. At some point we can stop initing
        // with default scale method above (when iOS8 is our min deployment target).
        
        self.screenScale = [UIScreen mainScreen].nativeScale;
    }
    else
    {
        self.screenScale = [UIScreen mainScreen].scale;
    }
    
    // add notification observers
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];
    
    // session notifications
    [notificationCenter addObserver:self selector:@selector(_sessionRuntimeErrored:) name:AVCaptureSessionRuntimeErrorNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionStarted:) name:AVCaptureSessionDidStartRunningNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionStopped:) name:AVCaptureSessionDidStopRunningNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:_captureSession];
    [notificationCenter addObserver:self selector:@selector(_sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:_captureSession];
    
    // capture input notifications
    [notificationCenter addObserver:self selector:@selector(_inputPortFormatDescriptionDidChange:) name:AVCaptureInputPortFormatDescriptionDidChangeNotification object:nil];
    
    // capture device notifications
    [notificationCenter addObserver:self selector:@selector(_deviceSubjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:nil];

    // current device KVO notifications
//    [self addObserver:self forKeyPath:@"currentDevice.adjustingFocus" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionFocusObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.adjustingExposure" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionExposureObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.adjustingWhiteBalance" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionWhiteBalanceObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.flashMode" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionFlashModeObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.torchMode" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionTorchModeObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.flashAvailable" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionFlashAvailabilityObserverContext];
//    [self addObserver:self forKeyPath:@"currentDevice.torchAvailable" options:NSKeyValueObservingOptionNew context:(__bridge void *)PBJVisionTorchAvailabilityObserverContext];

    // KVO is only used to monitor focus and capture events
    [_captureOutputPhoto addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:(__bridge void *)(PBJVisionCaptureStillImageIsCapturingStillImageObserverContext)];
    
    DLog(@"camera setup");
}

// only call from the session queue
- (void)_destroyCamera
{
    if (!_captureSession)
        return;
    
    // current device KVO notifications
//    [self removeObserver:self forKeyPath:@"currentDevice.adjustingFocus"];
//    [self removeObserver:self forKeyPath:@"currentDevice.adjustingExposure"];
//    [self removeObserver:self forKeyPath:@"currentDevice.adjustingWhiteBalance"];
//    [self removeObserver:self forKeyPath:@"currentDevice.flashMode"];
//    [self removeObserver:self forKeyPath:@"currentDevice.torchMode"];
//    [self removeObserver:self forKeyPath:@"currentDevice.flashAvailable"];
//    [self removeObserver:self forKeyPath:@"currentDevice.torchAvailable"];

    // remove notification observers (we don't want to just 'remove all' because we're also observing background notifications
    NSNotificationCenter *notificationCenter = [NSNotificationCenter defaultCenter];

    // session notifications
    [notificationCenter removeObserver:self name:AVCaptureSessionRuntimeErrorNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionDidStartRunningNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionDidStopRunningNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionWasInterruptedNotification object:_captureSession];
    [notificationCenter removeObserver:self name:AVCaptureSessionInterruptionEndedNotification object:_captureSession];
    
    // capture input notifications
    [notificationCenter removeObserver:self name:AVCaptureInputPortFormatDescriptionDidChangeNotification object:nil];
    
    // capture device notifications
    [notificationCenter removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:nil];

    // need to remove KVO observer before releasing to avoid crash
    [_captureOutputPhoto removeObserver:self forKeyPath:@"capturingStillImage"];
    _captureOutputPhoto = nil;
    
    _captureOutputAudio = nil;
    _captureOutputVideo = nil;
    
    _captureDeviceAudio = nil;
    _captureDeviceInputAudio = nil;
    _captureDeviceInputFront = nil;
    _captureDeviceInputBack = nil;
    _captureDeviceFront = nil;
    _captureDeviceBack = nil;

    _captureSession = nil;
    _currentDevice = nil;
    _currentInput = nil;
    _currentOutput = nil;
    
    DLog(@"camera destroyed");
}

#pragma mark - AVCaptureSession

- (BOOL)_canSessionCaptureWithOutput:(AVCaptureOutput *)captureOutput
{
    BOOL sessionContainsOutput = [[_captureSession outputs] containsObject:captureOutput];
    BOOL outputHasConnection = ([captureOutput connectionWithMediaType:AVMediaTypeVideo] != nil);
    return (sessionContainsOutput && outputHasConnection);
}

// _setupSession is always called from the captureSession queue
- (void)_setupSession
{
    if (!_captureSession) {
        DLog(@"error, no session running to setup");
        return;
    }
    
    BOOL shouldSwitchDevice = (_currentDevice == nil) ||
                              ((_currentDevice == _captureDeviceFront) && (_cameraDevice != PBJCameraDeviceFront)) ||
                              ((_currentDevice == _captureDeviceBack) && (_cameraDevice != PBJCameraDeviceBack));
    
    BOOL shouldSwitchMode = (_currentOutput == nil) ||
                            ((_currentOutput == _captureOutputPhoto) && (_cameraMode != PBJCameraModePhoto)) ||
                            ((_currentOutput == _captureOutputVideo) && (_cameraMode != PBJCameraModeVideo));
    
    DLog(@"switchDevice %d switchMode %d", shouldSwitchDevice, shouldSwitchMode);

    if (!shouldSwitchDevice && !shouldSwitchMode)
        return;
    
    AVCaptureDeviceInput *newDeviceInput = nil;
    AVCaptureOutput *newCaptureOutput = nil;
    AVCaptureDevice *newCaptureDevice = nil;
    
    [_captureSession beginConfiguration];
    
    // setup session device
    
    if (shouldSwitchDevice) {
        switch (_cameraDevice) {
          case PBJCameraDeviceFront:
          {
            if (_captureDeviceInputBack)
                [_captureSession removeInput:_captureDeviceInputBack];
            
            if (_captureDeviceInputFront && [_captureSession canAddInput:_captureDeviceInputFront]) {
                [_captureSession addInput:_captureDeviceInputFront];
                newDeviceInput = _captureDeviceInputFront;
                newCaptureDevice = _captureDeviceFront;
            }
            break;
          }
          case PBJCameraDeviceBack:
          {
            if (_captureDeviceInputFront)
                [_captureSession removeInput:_captureDeviceInputFront];
            
            if (_captureDeviceInputBack && [_captureSession canAddInput:_captureDeviceInputBack]) {
                [_captureSession addInput:_captureDeviceInputBack];
                newDeviceInput = _captureDeviceInputBack;
                newCaptureDevice = _captureDeviceBack;
            }
            break;
          }
          default:
            break;
        }
        
    } // shouldSwitchDevice
    
    // setup session input/output
    
    if (shouldSwitchMode) {
    
        // disable audio when in use for photos, otherwise enable it
        
    	if (self.cameraMode == PBJCameraModePhoto) {
            if (_captureDeviceInputAudio)
                [_captureSession removeInput:_captureDeviceInputAudio];
            
            if (_captureOutputAudio)
                [_captureSession removeOutput:_captureOutputAudio];
    	
        } else if (!_captureDeviceAudio && !_captureDeviceInputAudio && !_captureOutputAudio &&  _flags.audioCaptureEnabled) {
        
            NSError *error = nil;
            _captureDeviceAudio = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
            _captureDeviceInputAudio = [AVCaptureDeviceInput deviceInputWithDevice:_captureDeviceAudio error:&error];
            if (error) {
                DLog(@"error setting up audio input (%@)", error);
            }

            _captureOutputAudio = [[AVCaptureAudioDataOutput alloc] init];
            [_captureOutputAudio setSampleBufferDelegate:self queue:_captureVideoDispatchQueue];
            
        }
        
        [_captureSession removeOutput:_captureOutputVideo];
        [_captureSession removeOutput:_captureOutputPhoto];
        
        switch (_cameraMode) {
            case PBJCameraModeVideo:
            {
                // audio input
                if ([_captureSession canAddInput:_captureDeviceInputAudio]) {
                    [_captureSession addInput:_captureDeviceInputAudio];
                }
                // audio output
                if ([_captureSession canAddOutput:_captureOutputAudio]) {
                    [_captureSession addOutput:_captureOutputAudio];
                }
                // vidja output
                if ([_captureSession canAddOutput:_captureOutputVideo]) {
                    [_captureSession addOutput:_captureOutputVideo];
                    newCaptureOutput = _captureOutputVideo;
                }
                break;
            }
            case PBJCameraModePhoto:
            {
                // photo output
                if ([_captureSession canAddOutput:_captureOutputPhoto]) {
                    [_captureSession addOutput:_captureOutputPhoto];
                    newCaptureOutput = _captureOutputPhoto;
                }
                break;
            }
            default:
                break;
        }
        
    } // shouldSwitchMode
    
    if (!newCaptureDevice)
        newCaptureDevice = _currentDevice;

    if (!newCaptureOutput)
        newCaptureOutput = _currentOutput;

    // setup video connection
    AVCaptureConnection *videoConnection = [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo];
    
    // setup input/output
    
    NSString *sessionPreset = _captureSessionPreset;

    if ( newCaptureOutput && (newCaptureOutput == _captureOutputVideo) && videoConnection ) {
        
        // setup video orientation
        [self _setOrientationForConnection:videoConnection];
        
        // setup video stabilization, if available
        if ([videoConnection isVideoStabilizationSupported])
            [videoConnection setEnablesVideoStabilizationWhenAvailable:YES];

        // discard late frames
        [_captureOutputVideo setAlwaysDiscardsLateVideoFrames:YES];
        
        // specify video preset
        sessionPreset = _captureSessionPreset;

        // setup video settings
        // kCVPixelFormatType_420YpCbCr8BiPlanarFullRange Bi-Planar Component Y'CbCr 8-bit 4:2:0, full-range (luma=[0,255] chroma=[1,255])
        // baseAddr points to a big-endian CVPlanarPixelBufferInfo_YCbCrBiPlanar struct
        BOOL supportsFullRangeYUV = NO;
        BOOL supportsVideoRangeYUV = NO;
        NSArray *supportedPixelFormats = _captureOutputVideo.availableVideoCVPixelFormatTypes;
        for (NSNumber *currentPixelFormat in supportedPixelFormats) {
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
                supportsFullRangeYUV = YES;
            }
            if ([currentPixelFormat intValue] == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) {
                supportsVideoRangeYUV = YES;
            }
        }

        NSDictionary *videoSettings = nil;
        if (supportsFullRangeYUV) {
            videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) };
        } else if (supportsVideoRangeYUV) {
            videoSettings = @{ (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange) };
        }
        if (videoSettings)
            [_captureOutputVideo setVideoSettings:videoSettings];
        
        // setup video device configuration
        if (floor(NSFoundationVersionNumber) > NSFoundationVersionNumber_iOS_6_1) {

            NSError *error = nil;
            if ([newCaptureDevice lockForConfiguration:&error]) {
            
                // smooth autofocus for videos
                if ([newCaptureDevice isSmoothAutoFocusSupported])
                    [newCaptureDevice setSmoothAutoFocusEnabled:YES];
                
                [newCaptureDevice unlockForConfiguration];
        
            } else if (error) {
                DLog(@"error locking device for video device configuration (%@)", error);
            }
        
        }
        
    } else if ( newCaptureOutput && (newCaptureOutput == _captureOutputPhoto) ) {
    
        // specify photo preset
        sessionPreset = AVCaptureSessionPresetPhoto;
    
        // setup photo settings
        NSDictionary *photoSettings = [[NSDictionary alloc] initWithObjectsAndKeys:
                                        AVVideoCodecJPEG, AVVideoCodecKey,
                                        nil];
        [_captureOutputPhoto setOutputSettings:photoSettings];
        
        // setup photo device configuration
        NSError *error = nil;
        if ([newCaptureDevice lockForConfiguration:&error]) {
            
            if ([newCaptureDevice isLowLightBoostSupported])
                [newCaptureDevice setAutomaticallyEnablesLowLightBoostWhenAvailable:YES];
            
            [newCaptureDevice unlockForConfiguration];
        
        } else if (error) {
            DLog(@"error locking device for photo device configuration (%@)", error);
        }
            
    }

    // apply presets
    if ([_captureSession canSetSessionPreset:sessionPreset])
        [_captureSession setSessionPreset:sessionPreset];

    if (newDeviceInput)
        _currentInput = newDeviceInput;
    
    if (newCaptureOutput)
        _currentOutput = newCaptureOutput;

    // ensure there is a capture device setup
    if (_currentInput) {
        AVCaptureDevice *device = [_currentInput device];
        if (device) {
            [self willChangeValueForKey:@"currentDevice"];
            _currentDevice = device;
            [self didChangeValueForKey:@"currentDevice"];
        }
    }

    [_captureSession commitConfiguration];
    
    DLog(@"capture session setup");
}

#pragma mark - preview

- (void)startPreview
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        [self setupPreviewViews];
        [self clearPreviewView];
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionWillStartPreview:)]) {
                [_delegate visionSessionWillStartPreview:self];
            }
        }];
    }];
    
    [self _enqueueBlockOnCaptureSessionQueue:^{
        [self _setupCamera];
        [self _setupSession];
        
        _lastVideoDisplayTimestamp = kCMTimeInvalid;
        
        if (_previewLayer && _previewLayer.session != _captureSession) {
            _previewLayer.session = _captureSession;
            [self _setOrientationForConnection:_previewLayer.connection];
        }
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionDidSetup:)]) {
                [_delegate visionSessionDidSetup:self];
            }
        }];
        
        if (![_captureSession isRunning]) {
            [_captureSession startRunning];
            
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(visionSessionDidStartPreview:)]) {
                    [_delegate visionSessionDidStartPreview:self];
                }
            }];
            DLog(@"capture session running");
        }
        _flags.previewRunning = YES;
    }];
}

- (void)stopPreview
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if (!_flags.previewRunning)
            return;

        if (_previewLayer)
            _previewLayer.connection.enabled = YES;

        if ([_captureSession isRunning])
            [_captureSession stopRunning];

        [self _executeBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionDidStopPreview:)]) {
                [_delegate visionSessionDidStopPreview:self];
            }
        }];
        DLog(@"capture session stopped");
        _flags.previewRunning = NO;
    }];
}

- (void)unfreezePreview
{
    if (_previewLayer)
        _previewLayer.connection.enabled = YES;
}

#pragma mark - focus, exposure, white balance

- (void)_focusStarted
{
//    DLog(@"focus started");
    if ([_delegate respondsToSelector:@selector(visionWillStartFocus:)])
        [_delegate visionWillStartFocus:self];
}

- (void)_focusEnded
{
    AVCaptureFocusMode focusMode = [_currentDevice focusMode];
    BOOL isFocusing = [_currentDevice isAdjustingFocus];
    BOOL isAutoFocusEnabled = (focusMode == AVCaptureFocusModeAutoFocus ||
                               focusMode == AVCaptureFocusModeContinuousAutoFocus);
    if (!isFocusing && isAutoFocusEnabled) {
        NSError *error = nil;
        if ([_currentDevice lockForConfiguration:&error]) {
        
            [_currentDevice setSubjectAreaChangeMonitoringEnabled:YES];
            [_currentDevice unlockForConfiguration];
            
        } else if (error) {
            DLog(@"error locking device post exposure for subject area change monitoring (%@)", error);
        }
    }

    if ([_delegate respondsToSelector:@selector(visionDidStopFocus:)])
        [_delegate visionDidStopFocus:self];
//    DLog(@"focus ended");
}

- (void)_exposureChangeStarted
{
    //    DLog(@"exposure change started");
    if ([_delegate respondsToSelector:@selector(visionWillChangeExposure:)])
        [_delegate visionWillChangeExposure:self];
}

- (void)_exposureChangeEnded
{
    BOOL isContinuousAutoExposureEnabled = [_currentDevice exposureMode] == AVCaptureExposureModeContinuousAutoExposure;
    BOOL isExposing = [_currentDevice isAdjustingExposure];
    BOOL isFocusSupported = [_currentDevice isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus];

    if (isContinuousAutoExposureEnabled && !isExposing && !isFocusSupported) {

        NSError *error = nil;
        if ([_currentDevice lockForConfiguration:&error]) {
            
            [_currentDevice setSubjectAreaChangeMonitoringEnabled:YES];
            [_currentDevice unlockForConfiguration];
            
        } else if (error) {
            DLog(@"error locking device post exposure for subject area change monitoring (%@)", error);
        }

    }

    if ([_delegate respondsToSelector:@selector(visionDidChangeExposure:)])
        [_delegate visionDidChangeExposure:self];
    //    DLog(@"exposure change ended");
}

- (void)_whiteBalanceChangeStarted
{
}

- (void)_whiteBalanceChangeEnded
{
}

- (void)focusAtAdjustedPointOfInterest:(CGPoint)adjustedPoint
{
    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
        return;

    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
    
        BOOL isFocusAtPointSupported = [_currentDevice isFocusPointOfInterestSupported];
    
        if (isFocusAtPointSupported && [_currentDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
            AVCaptureFocusMode fm = [_currentDevice focusMode];
            [_currentDevice setFocusPointOfInterest:adjustedPoint];
            [_currentDevice setFocusMode:fm];
        }
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for focus adjustment (%@)", error);
    }
}

- (void)exposeAtAdjustedPointOfInterest:(CGPoint)adjustedPoint
{
    if ([_currentDevice isAdjustingExposure])
        return;

    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
    
        BOOL isExposureAtPointSupported = [_currentDevice isExposurePointOfInterestSupported];
        if (isExposureAtPointSupported && [_currentDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            AVCaptureExposureMode em = [_currentDevice exposureMode];
            [_currentDevice setExposurePointOfInterest:adjustedPoint];
            [_currentDevice setExposureMode:em];
        }
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for exposure adjustment (%@)", error);
    }
}

- (void)_adjustFocusExposureAndWhiteBalance
{
    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
        return;

    // only notify clients when focus is triggered from an event
    if ([_delegate respondsToSelector:@selector(visionWillStartFocus:)])
        [_delegate visionWillStartFocus:self];

    CGPoint focusPoint = CGPointMake(0.5f, 0.5f);
    [self focusAtAdjustedPointOfInterest:focusPoint];
}

// focusExposeAndAdjustWhiteBalanceAtAdjustedPoint: will put focus and exposure into auto
- (void)focusExposeAndAdjustWhiteBalanceAtAdjustedPoint:(CGPoint)adjustedPoint
{
    if ([_currentDevice isAdjustingFocus] || [_currentDevice isAdjustingExposure])
        return;

    NSError *error = nil;
    if ([_currentDevice lockForConfiguration:&error]) {
    
        BOOL isFocusAtPointSupported = [_currentDevice isFocusPointOfInterestSupported];
        BOOL isExposureAtPointSupported = [_currentDevice isExposurePointOfInterestSupported];
        BOOL isWhiteBalanceModeSupported = [_currentDevice isWhiteBalanceModeSupported:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
    
        if (isFocusAtPointSupported && [_currentDevice isFocusModeSupported:AVCaptureFocusModeAutoFocus]) {
            [_currentDevice setFocusPointOfInterest:adjustedPoint];
            [_currentDevice setFocusMode:AVCaptureFocusModeAutoFocus];
        }
        
        if (isExposureAtPointSupported && [_currentDevice isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
            [_currentDevice setExposurePointOfInterest:adjustedPoint];
            [_currentDevice setExposureMode:AVCaptureExposureModeContinuousAutoExposure];
        }
        
        if (isWhiteBalanceModeSupported) {
            [_currentDevice setWhiteBalanceMode:AVCaptureWhiteBalanceModeContinuousAutoWhiteBalance];
        }
        
        [_currentDevice setSubjectAreaChangeMonitoringEnabled:NO];
        
        [_currentDevice unlockForConfiguration];
        
    } else if (error) {
        DLog(@"error locking device for focus / exposure / white-balance adjustment (%@)", error);
    }
}

#pragma mark - mirroring

- (void)setMirroringMode:(PBJMirroringMode)mirroringMode
{
	_mirroringMode = mirroringMode;
    
    AVCaptureConnection *videoConnection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
	AVCaptureConnection *previewConnection = [_previewLayer connection];
	
    switch (_mirroringMode) {
		case PBJMirroringOff:
        {
			if ([videoConnection isVideoMirroringSupported]) {
				[videoConnection setVideoMirrored:NO];
			}
			if ([previewConnection isVideoMirroringSupported]) {
				[previewConnection setAutomaticallyAdjustsVideoMirroring:NO];
				[previewConnection setVideoMirrored:NO];
			}			
			break;
		}
        case PBJMirroringOn:
        {
			if ([videoConnection isVideoMirroringSupported]) {
				[videoConnection setVideoMirrored:YES];
			}
			if ([previewConnection isVideoMirroringSupported]) {
				[previewConnection setAutomaticallyAdjustsVideoMirroring:NO];
				[previewConnection setVideoMirrored:YES];
			}			
			break;
		}
        case PBJMirroringAuto:
        default:
		{
			BOOL mirror = (_cameraDevice == PBJCameraDeviceFront);
        
			if ([videoConnection isVideoMirroringSupported]) {
				[videoConnection setVideoMirrored:mirror];
			}
			if ([previewConnection isVideoMirroringSupported]) {
				[previewConnection setAutomaticallyAdjustsVideoMirroring:YES];
			}

			break;
		}
	}
}

#pragma mark - photo

- (BOOL)canCapturePhoto
{
    BOOL isDiskSpaceAvailable = [PBJVisionUtilities availableDiskSpaceInBytes] > PBJVisionRequiredMinimumDiskSpaceInBytes;
    return [self isCaptureSessionActive] && !_flags.changingModes && isDiskSpaceAvailable;
}

- (UIImage *)_uiimageFromJPEGData:(NSData *)jpegData
{
    CGImageRef jpegCGImage = NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpegData);
    
    UIImageOrientation imageOrientation = UIImageOrientationUp;
    
    if (provider) {
        CGImageSourceRef imageSource = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (imageSource) {
            if (CGImageSourceGetCount(imageSource) > 0) {
                jpegCGImage = CGImageSourceCreateImageAtIndex(imageSource, 0, NULL);
                
                // extract the cgImage properties
                CFDictionaryRef properties = CGImageSourceCopyPropertiesAtIndex(imageSource, 0, NULL);
                if (properties) {
                    // set orientation
                    CFNumberRef orientationProperty = CFDictionaryGetValue(properties, kCGImagePropertyOrientation);
                    if (orientationProperty) {
                        NSInteger exifOrientation = 1;
                        CFNumberGetValue(orientationProperty, kCFNumberIntType, &exifOrientation);
                        imageOrientation = [self _imageOrientationFromExifOrientation:exifOrientation];
                    }
                    
                    CFRelease(properties);
                }
                
            }
            CFRelease(imageSource);
        }
        CGDataProviderRelease(provider);
    }
    
    UIImage *image = nil;
    if (jpegCGImage) {
        image = [[UIImage alloc] initWithCGImage:jpegCGImage scale:1.0 orientation:imageOrientation];
        CGImageRelease(jpegCGImage);
    }
    return image;
}

- (UIImage *)_thumbnailJPEGData:(NSData *)jpegData
{
    CGImageRef thumbnailCGImage = NULL;
    CGDataProviderRef provider = CGDataProviderCreateWithCFData((__bridge CFDataRef)jpegData);
    
    if (provider) {
        CGImageSourceRef imageSource = CGImageSourceCreateWithDataProvider(provider, NULL);
        if (imageSource) {
            if (CGImageSourceGetCount(imageSource) > 0) {
                NSMutableDictionary *options = [[NSMutableDictionary alloc] initWithCapacity:3];
                [options setObject:@(YES) forKey:(id)kCGImageSourceCreateThumbnailFromImageAlways];
                [options setObject:@(PBJVisionThumbnailWidth) forKey:(id)kCGImageSourceThumbnailMaxPixelSize];
                [options setObject:@(YES) forKey:(id)kCGImageSourceCreateThumbnailWithTransform];
                thumbnailCGImage = CGImageSourceCreateThumbnailAtIndex(imageSource, 0, (__bridge CFDictionaryRef)options);
            }
            CFRelease(imageSource);
        }
        CGDataProviderRelease(provider);
    }
    
    UIImage *thumbnail = nil;
    if (thumbnailCGImage) {
        thumbnail = [[UIImage alloc] initWithCGImage:thumbnailCGImage];
        CGImageRelease(thumbnailCGImage);
    }
    return thumbnail;
}


- (UIImageOrientation)_imageOrientationFromExifOrientation:(NSInteger)exifOrientation
{
    UIImageOrientation imageOrientation = UIImageOrientationUp;
    
    switch (exifOrientation) {
        case 1:
            imageOrientation = UIImageOrientationUp;
            break;
        case 2:
            imageOrientation = UIImageOrientationUpMirrored;
            break;
        case 3:
            imageOrientation = UIImageOrientationDown;
            break;
        case 4:
            imageOrientation = UIImageOrientationDownMirrored;
            break;
        case 5:
            imageOrientation = UIImageOrientationLeftMirrored;
            break;
        case 6:
           imageOrientation = UIImageOrientationRight;
           break;
        case 7:
            imageOrientation = UIImageOrientationRightMirrored;
            break;
        case 8:
            imageOrientation = UIImageOrientationLeft;
            break;
        default:
            break;
    }
    
    return imageOrientation;
}

- (void)_willCapturePhoto
{
    DLog(@"will capture photo");
    if ([_delegate respondsToSelector:@selector(visionWillCapturePhoto:)])
        [_delegate visionWillCapturePhoto:self];
    
    // freeze preview
    _previewLayer.connection.enabled = NO;
}

- (void)_didCapturePhoto
{
    if ([_delegate respondsToSelector:@selector(visionDidCapturePhoto:)])
        [_delegate visionDidCapturePhoto:self];
    DLog(@"did capture photo");
}

- (void)capturePhoto
{
    if (![self _canSessionCaptureWithOutput:_currentOutput] || _cameraMode != PBJCameraModePhoto) {
        DLog(@"session is not setup properly for capture");
        return;
    }

    AVCaptureConnection *connection = [_currentOutput connectionWithMediaType:AVMediaTypeVideo];
    [self _setOrientationForConnection:connection];
    
    [_captureOutputPhoto captureStillImageAsynchronouslyFromConnection:connection completionHandler:
    ^(CMSampleBufferRef imageDataSampleBuffer, NSError *error) {
        
        if (!imageDataSampleBuffer) {
            DLog(@"failed to obtain image data sample buffer");
            return;
        }
    
        if (error) {
            if ([_delegate respondsToSelector:@selector(vision:capturedPhoto:error:)]) {
                [_delegate vision:self capturedPhoto:nil error:error];
            }
            return;
        }
    
        NSMutableDictionary *photoDict = [[NSMutableDictionary alloc] init];
        NSDictionary *metadata = nil;

        // add photo metadata (ie EXIF: Aperture, Brightness, Exposure, FocalLength, etc)
        metadata = (__bridge NSDictionary *)CMCopyDictionaryOfAttachments(kCFAllocatorDefault, imageDataSampleBuffer, kCMAttachmentMode_ShouldPropagate);
        if (metadata) {
            [photoDict setObject:metadata forKey:PBJVisionPhotoMetadataKey];
            CFRelease((__bridge CFTypeRef)(metadata));
        } else {
            DLog(@"failed to generate metadata for photo");
        }
        
        // add JPEG, UIImage, thumbnail
        NSData *jpegData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
        if (jpegData) {
            // add JPEG
            [photoDict setObject:jpegData forKey:PBJVisionPhotoJPEGKey];
            
            // add image
            UIImage *image = [self _uiimageFromJPEGData:jpegData];
            if (image) {
                [photoDict setObject:image forKey:PBJVisionPhotoImageKey];
            } else {
                DLog(@"failed to create image from JPEG");
                // TODO: return delegate on error
            }
            
            // add thumbnail
            if (_flags.thumbnailEnabled) {
                UIImage *thumbnail = [self _thumbnailJPEGData:jpegData];
                if (thumbnail)
                    [photoDict setObject:thumbnail forKey:PBJVisionPhotoThumbnailKey];
            }
            
        }
        
        if ([_delegate respondsToSelector:@selector(vision:capturedPhoto:error:)]) {
            [_delegate vision:self capturedPhoto:photoDict error:error];
        }
        
        // run a post shot focus
        [self performSelector:@selector(_adjustFocusExposureAndWhiteBalance) withObject:nil afterDelay:0.5f];
    }];
}

#pragma mark - video

- (BOOL)supportsVideoCapture
{
    return ([[AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo] count] > 0);
}

- (BOOL)canCaptureVideo
{
    BOOL isDiskSpaceAvailable = [PBJVisionUtilities availableDiskSpaceInBytes] > PBJVisionRequiredMinimumDiskSpaceInBytes;
    return [self supportsVideoCapture] && [self isCaptureSessionActive] && !_flags.changingModes && isDiskSpaceAvailable;
}

- (void)setupVideoCapture
{
    if (![self _canSessionCaptureWithOutput:_currentOutput]) {
        DLog(@"session is not setup properly for capture");
        return;
    }
    
    DLog(@"setting up video capture");
    
    if (_flags.recording || _flags.paused)
        return;
    
    NSString *guid = [[NSUUID new] UUIDString];
    NSString *outputPath = [NSString stringWithFormat:@"%@video_%@.mp4", NSTemporaryDirectory(), guid];
    NSURL *outputURL = [NSURL fileURLWithPath:outputPath];
    if ([[NSFileManager defaultManager] fileExistsAtPath:outputPath]) {
        NSError *error = nil;
        if (![[NSFileManager defaultManager] removeItemAtPath:outputPath error:&error]) {
            DLog(@"could not setup an output file");
            return;
        }
    }
    
    if (!outputPath || [outputPath length] == 0)
        return;
    
    if (_mediaWriter)
        _mediaWriter.delegate = nil;
    
    _mediaWriter = [[PBJMediaWriter alloc] initWithOutputURL:outputURL];
    _mediaWriter.delegate = self;
    
    AVCaptureConnection *videoConnection = [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo];
    [self _setOrientationForConnection:videoConnection];
    
    _flags.videoWritten = NO;
}

- (void)startVideoCapture
{
    if (!_mediaWriter) {
        [self setupVideoCapture];
    }
    
    DLog(@"starting video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
        _lastTimestamp = kCMTimeInvalid;
        //_lastTimestamp = _startTimestamp;
        _lastAudioTimestamp = kCMTimeInvalid;
        _audioRecordOffset = kCMTimeInvalid;
        _totalPauseTime = kCMTimeZero;
        _lastPauseTimestamp = kCMTimeInvalid;
        
        _flags.recording = YES;
        _flags.paused = NO;
        _flags.interrupted = NO;
        _flags.videoWritten = NO;
        
        [self _enqueueBlockOnMainQueue:^{                
            if ([_delegate respondsToSelector:@selector(visionDidStartVideoCapture:)])
                [_delegate visionDidStartVideoCapture:self];
        }];
    }];
}

- (void)pauseVideoCapture
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording)
            return;

        if (!_mediaWriter) {
            DLog(@"media writer unavailable to stop");
            return;
        }

        DLog(@"pausing video capture");

        _flags.paused = YES;
        _flags.interrupted = YES;
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidPauseVideoCapture:)])
                [_delegate visionDidPauseVideoCapture:self];
        }];
    }];    
}

- (void)resumeVideoCapture
{
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording || !_flags.paused)
            return;
 
        if (!_mediaWriter) {
            DLog(@"media writer unavailable to resume");
            return;
        }
 
        DLog(@"resuming video capture");
       
        //_audioRecordOffset = kCMTimeInvalid;
        _flags.paused = NO;
        _flags.interrupted = NO;
        

        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidResumeVideoCapture:)])
                [_delegate visionDidResumeVideoCapture:self];
        }];
    }];
}

- (void)endVideoCapture
{    
    DLog(@"ending video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        if (!_flags.recording)
            return;
        
        if (!_mediaWriter) {
            DLog(@"media writer unavailable to end");
            return;
        }
        
        _flags.recording = NO;
        _flags.paused = NO;
        
        void (^finishWritingCompletionHandler)(void) = ^{
            Float64 capturedDuration = self.capturedVideoSeconds;
            
            Float64 averageFrameRate = (Float64)_recordedFrameCount / capturedDuration;
            LogError(@"averageFrameRate %f", averageFrameRate)
            
            _lastTimestamp = kCMTimeInvalid;
            _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
            _flags.interrupted = NO;
            
            NSString *path = [_mediaWriter.outputURL path];
            NSError *error = [_mediaWriter error];
            _mediaWriter = nil;
            
            [self _enqueueBlockOnMainQueue:^{
                NSMutableDictionary *videoDict = [[NSMutableDictionary alloc] init];
                if (path)
                    [videoDict setObject:path forKey:PBJVisionVideoPathKey];
                else {
                    NSLog(@"no recorded video!");
                }

                [videoDict setObject:@(capturedDuration) forKey:PBJVisionVideoCapturedDurationKey];

                if ([_delegate respondsToSelector:@selector(vision:capturedVideo:error:)]) {
                    [_delegate vision:self capturedVideo:videoDict error:error];
                }
            }];
        };
        [_mediaWriter finishWritingWithCompletionHandler:finishWritingCompletionHandler];
    }];
}

- (void)cancelVideoCapture
{
    DLog(@"cancel video capture");
    
    [self _enqueueBlockOnCaptureVideoQueue:^{
        _flags.recording = NO;
        _flags.paused = NO;
        
        NSURL *outputURL = _mediaWriter.outputURL;
        
        void (^finishWritingCompletionHandler)(void) = ^{
            _lastTimestamp = kCMTimeInvalid;
            _startTimestamp = CMClockGetTime(CMClockGetHostTimeClock());
            _flags.interrupted = NO;

            NSString *path = [outputURL path];
            if ([[NSFileManager defaultManager] fileExistsAtPath:path]) {
                NSError *error = nil;
                if (![[NSFileManager defaultManager] removeItemAtPath:path error:&error]) {
                    DLog(@"could not setup an output file");
                }
            }
            
            [self _enqueueBlockOnMainQueue:^{
                NSError *error = [NSError errorWithDomain:PBJVisionErrorDomain code:PBJVisionErrorCancelled userInfo:nil];
                if ([_delegate respondsToSelector:@selector(vision:capturedVideo:error:)]) {
                    [_delegate vision:self capturedVideo:nil error:error];
                }
            }];
        };
        [_mediaWriter finishWritingWithCompletionHandler:finishWritingCompletionHandler];
        
        // we don't need the reference to this anymore!
        _mediaWriter = nil;
    }];
}

#pragma mark - sample buffer setup

- (BOOL)_setupMediaWriterAudioInputWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);

	const AudioStreamBasicDescription *asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription);
    if (!asbd) {
        DLog(@"audio stream description used with non-audio format description");
        return NO;
    }
    
	unsigned int channels = asbd->mChannelsPerFrame;
    double sampleRate = asbd->mSampleRate;

    DLog(@"audio stream setup, channels (%d) sampleRate (%f)", channels, sampleRate);
    
    size_t aclSize = 0;
	const AudioChannelLayout *currentChannelLayout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, &aclSize);
	NSData *currentChannelLayoutData = ( currentChannelLayout && aclSize > 0 ) ? [NSData dataWithBytes:currentChannelLayout length:aclSize] : [NSData data];
    
    NSDictionary *audioCompressionSettings = @{ AVFormatIDKey : @(kAudioFormatMPEG4AAC),
                                                AVNumberOfChannelsKey : @(channels),
                                                AVSampleRateKey :  @(sampleRate),
                                                AVEncoderBitRateKey : @(_audioBitRate),
                                                AVChannelLayoutKey : currentChannelLayoutData };

    return [_mediaWriter setupAudioOutputDeviceWithSettings:audioCompressionSettings];
}

- (BOOL)_setupMediaWriterVideoInputWithSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    CMFormatDescriptionRef formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer);
	CMVideoDimensions dimensions = CMVideoFormatDescriptionGetDimensions(formatDescription);
    
    CMVideoDimensions videoDimensions = dimensions;
    switch (_outputFormat) {
        case PBJOutputFormatSquare:
        {
            int32_t min = MIN(dimensions.width, dimensions.height);
            videoDimensions.width = min;
            videoDimensions.height = min;
            break;
        }
        case PBJOutputFormatWidescreen:
        {
            videoDimensions.width = dimensions.width;
            videoDimensions.height = (int32_t)(dimensions.width / 1.5f);
            break;
        }
        case PBJOutputFormatStandard:
        {
            videoDimensions.width = dimensions.width;
            videoDimensions.height = (int32_t)(dimensions.width * 3 / 4.0f);
            break;
        }
        case PBJOutputFormat360x360:
        {
            videoDimensions.width = 360.0f;
            videoDimensions.height = 360.0f;
        }
        case PBJOutputFormatPreset:
        default:
            break;
    }
    
    NSDictionary *compressionSettings = nil;
    
    if (_additionalCompressionProperties && [_additionalCompressionProperties count] > 0) {
        NSMutableDictionary *mutableDictionary = [NSMutableDictionary dictionaryWithDictionary:_additionalCompressionProperties];
        [mutableDictionary setObject:@(_videoBitRate) forKey:AVVideoAverageBitRateKey];
        [mutableDictionary setObject:@(_videoFrameRate) forKey:AVVideoMaxKeyFrameIntervalKey];
        compressionSettings = mutableDictionary;
    } else {
        compressionSettings = @{ AVVideoAverageBitRateKey : @(_videoBitRate),
                                 AVVideoMaxKeyFrameIntervalKey : @(_videoFrameRate) };
    }
    
	NSDictionary *videoSettings = @{ AVVideoCodecKey : AVVideoCodecH264,
                                     AVVideoScalingModeKey : AVVideoScalingModeResizeAspectFill,
                                     AVVideoWidthKey : @(videoDimensions.width),
                                     AVVideoHeightKey : @(videoDimensions.height),
                                     AVVideoCompressionPropertiesKey : compressionSettings };
    
    return [_mediaWriter setupVideoOutputDeviceWithSettings:videoSettings];
}

#pragma mark - AVCaptureAudioDataOutputSampleBufferDelegate, AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection
{
	CFRetain(sampleBuffer);
    
    if (!CMSampleBufferDataIsReady(sampleBuffer)) {
        DLog(@"sample buffer data is not ready");
        CFRelease(sampleBuffer);
        return;
    }

    // need for previewing too
//    if (!_flags.recording) {
//        CFRelease(sampleBuffer);
//        return;
//    }

    BOOL isAudio = (connection == [_captureOutputAudio connectionWithMediaType:AVMediaTypeAudio]);
    BOOL isVideo = (connection == [_captureOutputVideo connectionWithMediaType:AVMediaTypeVideo]);
    
    if (_flags.recording) {
        // setup media writer
        if (isAudio && !_mediaWriter.isAudioReady) {
            [self _setupMediaWriterAudioInputWithSampleBuffer:sampleBuffer];
            DLog(@"ready for audio (%d)", _mediaWriter.isAudioReady);
        }
        if (isVideo && !_mediaWriter.isVideoReady) {
            [self _setupMediaWriterVideoInputWithSampleBuffer:sampleBuffer];
            DLog(@"ready for video (%d)", _mediaWriter.isVideoReady);
        }

        BOOL isReadyToRecord = (_mediaWriter.isVideoReady && (_mediaWriter.isAudioReady || !_flags.audioCaptureEnabled));
        if (!isReadyToRecord) {
            CFRelease(sampleBuffer);
            return;
        }
    }

    CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (_flags.recording && CMTIME_IS_INVALID(_audioRecordOffset)) {
        // this will grab the info need to compute _audioRecordOffset
        if ([_delegate respondsToSelector:@selector(visionWillStartWritingVideo:)]) {
            [_delegate visionWillStartWritingVideo:self];
        }
    }
    
//    [self calculateFramerateAtTimestamp:currentTimestamp];
//    NSLog(@"fps: %f", _frameRate);

    // calculate the length of the interruption
//    if (_flags.paused || _flags.interrupted) {
//        // calculate the appropriate time offset
//        if (CMTIME_IS_VALID(currentTimestamp)) {
//            if (CMTIME_IS_VALID(_lastTimestamp)) {
//                currentTimestamp = CMTimeSubtract(currentTimestamp, _lastTimestamp);
//            }
//            
//            CMTime offset = CMTimeSubtract(currentTimestamp, _mediaWriter.videoTimestamp);
//            _lastTimestamp = (_lastTimestamp.value == 0) ? offset : CMTimeAdd(_lastTimestamp, offset);
//            DLog(@"new calculated offset %f valid (%d)", CMTimeGetSeconds(_lastTimestamp), CMTIME_IS_VALID(_lastTimestamp));
//        } else {
//            DLog(@"invalid timestamp, no offset update");
//        }
//        
//        // just needed the timestamp...
//        CFRelease(sampleBuffer);
//        return;
//    }
    
    CMSampleBufferRef bufferToWrite = NULL;
    
    //DLog(@"currentTimestamp (%lld / %d)", currentTimestamp.value, currentTimestamp.timescale);

    if (CMTIME_IS_VALID(_lastTimestamp)) {
        //DLog(@"currentTimestamp (%lld / %d)", currentTimestamp.value, currentTimestamp.timescale);
        bufferToWrite = [PBJVisionUtilities createOffsetSampleBufferWithSampleBuffer:sampleBuffer usingTimeOffset:_lastTimestamp];
        if (!bufferToWrite) {
            DLog(@"error subtracting the timeoffset from the sampleBuffer");
        }
        //DLog(@"subtracted lastTimestamp (%lld / %d)", _lastTimestamp.value, _lastTimestamp.timescale);
    }
    else if (CMTIME_IS_VALID(_startTimestamp)){
        bufferToWrite = [PBJVisionUtilities createOffsetSampleBufferWithSampleBuffer:sampleBuffer usingTimeOffset:_startTimestamp];
        if (!bufferToWrite) {
            DLog(@"error subtracting the timeoffset from the sampleBuffer");
        }
        //DLog(@"subtracted startTimestamp (%lld / %d)", _startTimestamp.value, _startTimestamp.timescale);
    }
    else {
        bufferToWrite = sampleBuffer;
        CFRetain(bufferToWrite);
    }
    
    if (isVideo) {
        
        if (bufferToWrite) {
            
            CMTime time = CMSampleBufferGetPresentationTimeStamp(bufferToWrite);
            
            // need to start writing so we have the pixel buffer pool alloc'd and ready...
            if (_flags.recording && !_flags.videoWritten) {
                [_mediaWriter startWritingAtTime:time];
                // TODO what if it doesn't start??
                
                _recordedFrameCount = 0;
            }
            
//            if (CMTIME_IS_VALID(_audioRecordOffset)) {
//                CMSampleBufferRef bufferToWriteTimedWithAudio = [PBJVisionUtilities createOffsetSampleBufferWithSampleBuffer:sampleBuffer usingTimeOffset:_audioRecordOffset];
//                if (!bufferToWriteTimedWithAudio) {
//                    DLog(@"error subtracting the audio timeoffset from the sampleBuffer");
//                }
//                DLog(@"subtracted _audioRecordOffset (%lld / %d)", _audioRecordOffset.value, _audioRecordOffset.timescale);
//                CFRelease(bufferToWrite);
//                bufferToWrite = bufferToWriteTimedWithAudio;
//            }
            
            // process the sample buffer for rendering
            CVPixelBufferRef filteredPixelBuffer = NULL;
            if (_flags.videoRenderingEnabled) {
                filteredPixelBuffer = [self _processSampleBuffer:bufferToWrite];
            }
            
            if (filteredPixelBuffer) {
                // update video and the last timestamp
                if (_flags.recording && !_flags.paused && CMTIME_IS_INVALID(_lastPauseTimestamp) && !_flags.interrupted && (!_flags.videoWritten || CMTIME_COMPARE_INLINE(time, >=, _mediaWriter.videoTimestamp))) {
                    [_mediaWriter writeSampleBuffer:bufferToWrite ofType:AVMediaTypeVideo withPixelBuffer:filteredPixelBuffer];
                    _flags.videoWritten = YES;
                    _recordedFrameCount++;
                    //DLog(@"wrote buffer at %lld %d", _mediaWriter.videoTimestamp.value, _mediaWriter.videoTimestamp.timescale);
                }
                else {
                    //DLog(@"buffer not written!  %lld %d / %lld %d (%d)", time.value, time.timescale, _mediaWriter.videoTimestamp.value, _mediaWriter.videoTimestamp.timescale, _flags.recording);
                }
                
                CVPixelBufferRelease(filteredPixelBuffer);
            }
            
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(vision:didCaptureVideoSampleBuffer:)]) {
                    [_delegate vision:self didCaptureVideoSampleBuffer:bufferToWrite];
                }
            }];
        }
        
    } else if (isAudio && !_flags.interrupted && _flags.recording) {

        if (bufferToWrite && _flags.videoWritten) {
            // update the last audio timestamp
            CMTime time = CMSampleBufferGetPresentationTimeStamp(bufferToWrite);
            CMTime duration = CMSampleBufferGetDuration(bufferToWrite);
            if (duration.value > 0)
                time = CMTimeAdd(time, duration);

            if (time.value > _mediaWriter.audioTimestamp.value) {
                //[_mediaWriter writeSampleBuffer:bufferToWrite ofType:AVMediaTypeAudio];
            }
            
            //printf("%f (v: %f)\n", CMTimeGetSeconds(time), CMTimeGetSeconds(_mediaWriter.videoTimestamp));
            
            if (CMTIME_IS_VALID(_lastAudioTimestamp) && CMTIME_COMPARE_INLINE(CMTimeSubtract(time, _lastAudioTimestamp), >, CMTimeMake(1, 2))) {
                NSLog(@"jump: %f %f %f\n", CMTimeGetSeconds(_lastAudioTimestamp), CMTimeGetSeconds(time), CMTimeGetSeconds(_mediaWriter.videoTimestamp));
            }
            
            //[self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(vision:didCaptureAudioSample:)]) {
                    [_delegate vision:self didCaptureAudioSample:bufferToWrite];
                }
            //}];
            
            _lastAudioTimestamp = time;
        }
    }
    
    currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    
    if (!_flags.interrupted && CMTIME_IS_VALID(currentTimestamp) && CMTIME_IS_VALID(_startTimestamp) && CMTIME_IS_VALID(_maximumCaptureDuration)) {
        
        if (CMTIME_IS_VALID(_lastTimestamp)) {
            // Current time stamp is actually timstamp with data from globalClock
            // In case, if we had interruption, then _lastTimeStamp
            // will have infromation about the time diff between globalClock and assetWriterClock
            // So in case if we had interruption we need to remove that offset from "currentTimestamp"
            currentTimestamp = CMTimeSubtract(currentTimestamp, _lastTimestamp);
        }
        CMTime currentCaptureDuration = CMTimeSubtract(currentTimestamp, _startTimestamp);
        if (CMTIME_IS_VALID(currentCaptureDuration)) {
            if (CMTIME_COMPARE_INLINE(currentCaptureDuration, >=, _maximumCaptureDuration)) {
                [self _enqueueBlockOnMainQueue:^{
                    [self endVideoCapture];
                }];
            }
        }
    }
        
    if (bufferToWrite)
        CFRelease(bufferToWrite);
    
    CFRelease(sampleBuffer);

}

- (void)calculateFramerateAtTimestamp:(CMTime)timestamp
{
	[_previousSecondTimestamps addObject:[NSValue valueWithCMTime:timestamp]];
    
	CMTime oneSecond = CMTimeMake(1, 1);
	CMTime oneSecondAgo = CMTimeSubtract(timestamp, oneSecond);
    
    //  while (CMTimeCompare([_previousSecondTimestamps[0] CMTimeValue], oneSecondAgo) < 0)
    //    ;
    
	while(CMTIME_COMPARE_INLINE([[_previousSecondTimestamps objectAtIndex:0] CMTimeValue], <, oneSecondAgo))
    {
		[_previousSecondTimestamps removeObjectAtIndex:0];
    }
    
	Float64 newRate = (Float64)[_previousSecondTimestamps count];
    
	_frameRate = (_frameRate + newRate) / 2;
}

#pragma mark - App NSNotifications

- (void)_applicationWillEnterForeground:(NSNotification *)notification
{
    DLog(@"applicationWillEnterForeground");
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if (!_flags.previewRunning)
            return;
        
        [self _enqueueBlockOnMainQueue:^{
            [self startPreview];
        }];
    }];
}

- (void)_applicationDidEnterBackground:(NSNotification *)notification
{
    DLog(@"applicationDidEnterBackground");
    if (_flags.recording)
        [self pauseVideoCapture];

    if (_flags.previewRunning) {
        [self stopPreview];
        [self _enqueueBlockOnCaptureSessionQueue:^{
            _flags.previewRunning = YES;
        }];
    }
}

#pragma mark - AV NSNotifications

// capture session handlers

- (void)_sessionRuntimeErrored:(NSNotification *)notification
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if ([notification object] == _captureSession) {
            NSError *error = [[notification userInfo] objectForKey:AVCaptureSessionErrorKey];
            if (error) {
                switch ([error code]) {
                    case AVErrorMediaServicesWereReset:
                    {
                        DLog(@"error media services were reset");
                        [self _destroyCamera];
                        if (_flags.previewRunning)
                            [self startPreview];
                        break;
                    }
                    case AVErrorDeviceIsNotAvailableInBackground:
                    {
                        DLog(@"error media services not available in background");
                        break;
                    }
                    default:
                    {
                        DLog(@"error media services failed, error (%@)", error);
                        [self _destroyCamera];
                        if (_flags.previewRunning)
                            [self startPreview];
                        break;
                    }
                }
            }
        }
    }];
}

- (void)_sessionStarted:(NSNotification *)notification
{
    [self _enqueueBlockOnMainQueue:^{
        if ([notification object] != _captureSession)
            return;

        DLog(@"session was started");
        
        // ensure there is a capture device setup
        if (_currentInput) {
            AVCaptureDevice *device = [_currentInput device];
            if (device) {
                [self willChangeValueForKey:@"currentDevice"];
                _currentDevice = device;
                [self didChangeValueForKey:@"currentDevice"];
            }
        }
    
        if ([_delegate respondsToSelector:@selector(visionSessionDidStart:)]) {
            [_delegate visionSessionDidStart:self];
        }
    }];
}

- (void)_sessionStopped:(NSNotification *)notification
{
    [self _enqueueBlockOnCaptureSessionQueue:^{
        if ([notification object] != _captureSession)
            return;
    
        DLog(@"session was stopped");
        
        if (_flags.recording)
            [self endVideoCapture];
    
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionDidStop:)]) {
                [_delegate visionSessionDidStop:self];
            }
        }];
    }];
}

- (void)_sessionWasInterrupted:(NSNotification *)notification
{
    if ([notification object] != _captureSession)
        return;
    
    [self _enqueueBlockOnCaptureVideoQueue:^{

        _flags.interrupted = YES;
        
        DLog(@"session was interrupted");
        
        if (_flags.recording) {
            [self _enqueueBlockOnMainQueue:^{
                if ([_delegate respondsToSelector:@selector(visionSessionDidStop:)]) {
                    [_delegate visionSessionDidStop:self];
                }
            }];
        }
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionWasInterrupted:)]) {
                [_delegate visionSessionWasInterrupted:self];
            }
        }];
    }];
}

- (void)_sessionInterruptionEnded:(NSNotification *)notification
{
    if ([notification object] != _captureSession)
        return;

    [self _enqueueBlockOnCaptureVideoQueue:^{
        
        _flags.interrupted = NO;

        DLog(@"session interruption ended");
        
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionSessionInterruptionEnded:)]) {
                [_delegate visionSessionInterruptionEnded:self];
            }
        }];
        
    }];
}

// capture input handler

- (void)_inputPortFormatDescriptionDidChange:(NSNotification *)notification
{
    // when the input format changes, store the clean aperture
    // (clean aperture is the rect that represents the valid image data for this display)
    AVCaptureInputPort *inputPort = (AVCaptureInputPort *)[notification object];
    if (inputPort) {
        CMFormatDescriptionRef formatDescription = [inputPort formatDescription];
        if (formatDescription) {
            _cleanAperture = CMVideoFormatDescriptionGetCleanAperture(formatDescription, YES);
            if ([_delegate respondsToSelector:@selector(vision:didChangeCleanAperture:)]) {
                [_delegate vision:self didChangeCleanAperture:_cleanAperture];
            }
        }
    }
}

// capture device handler

- (void)_deviceSubjectAreaDidChange:(NSNotification *)notification
{
    [self _adjustFocusExposureAndWhiteBalance];
}

#pragma mark - KVO

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
    if ( context == (__bridge void *)PBJVisionFocusObserverContext ) {
    
        BOOL isFocusing = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isFocusing) {
            [self _focusStarted];
        } else {
            [self _focusEnded];
        }
    
    }
    else if ( context == (__bridge void *)PBJVisionExposureObserverContext ) {
        
        BOOL isChangingExposure = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isChangingExposure) {
            [self _exposureChangeStarted];
        } else {
            [self _exposureChangeEnded];
        }
        
    }
    else if ( context == (__bridge void *)PBJVisionWhiteBalanceObserverContext ) {
        
        BOOL isWhiteBalanceChanging = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
        if (isWhiteBalanceChanging) {
            [self _whiteBalanceChangeStarted];
        } else {
            [self _whiteBalanceChangeEnded];
        }
        
    }
    else if ( context == (__bridge void *)PBJVisionFlashAvailabilityObserverContext ||
              context == (__bridge void *)PBJVisionTorchAvailabilityObserverContext ) {
        
        //        DLog(@"flash/torch availability did change");
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidChangeFlashAvailablility:)])
                [_delegate visionDidChangeFlashAvailablility:self];
        }];
        
	}
    else if ( context == (__bridge void *)PBJVisionFlashModeObserverContext ||
              context == (__bridge void *)PBJVisionTorchModeObserverContext ) {
        
        //        DLog(@"flash/torch mode did change");
        [self _enqueueBlockOnMainQueue:^{
            if ([_delegate respondsToSelector:@selector(visionDidChangeFlashMode:)])
                [_delegate visionDidChangeFlashMode:self];
        }];
        
	}
    else if ( context == (__bridge void *)PBJVisionCaptureStillImageIsCapturingStillImageObserverContext ) {
    
		BOOL isCapturingStillImage = [[change objectForKey:NSKeyValueChangeNewKey] boolValue];
		if ( isCapturingStillImage ) {
            [self _willCapturePhoto];
		} else {
            [self _didCapturePhoto];
        }
        
	} else {
        [super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
    }
}

#pragma mark - PBJMediaWriterDelegate

- (void)mediaWriterDidObserveAudioAuthorizationStatusDenied:(PBJMediaWriter *)mediaWriter
{
    [self _enqueueBlockOnMainQueue:^{
        [_delegate visionDidChangeAuthorizationStatus:PBJAuthorizationStatusAudioDenied];
    }];
}

- (void)mediaWriterDidObserveVideoAuthorizationStatusDenied:(PBJMediaWriter *)mediaWriter
{
}

#pragma mark - sample buffer processing

- (void)clearPreviewView
{
    // clear main preview
//    [EAGLContext setCurrentContext:_context];
//    [_filteredPreviewView bindDrawable];
//    glClearColor(0.0, 0.0, 0.0, 1.0);
//    glClear(GL_COLOR_BUFFER_BIT);
//    [_filteredPreviewView display];
    
    [self.currentFilterGroup removeAllTargets];
    [self.currentFilterGroup addTarget:_filteredPreviewView];
    
    // clear small preview if it is enabled
    if ( self.smallPreviewEnabled )
    {
//        [EAGLContext setCurrentContext:_contextPreview];
//        [_filteredSmallPreviewView bindDrawable];
//        glClearColor(0.0, 0.0, 0.0, 1.0);
//        glClear(GL_COLOR_BUFFER_BIT);
//        [_filteredSmallPreviewView display];
        
        [self.currentFilterGroup addTarget:_filteredSmallPreviewView];
    }
}

// convert CoreVideo YUV pixel buffer (Y luminance and Cb Cr chroma) into RGB
// processing is done on the GPU, operation WAY more efficient than converting on the CPU
- (CVPixelBufferRef)_processSampleBuffer:(CMSampleBufferRef)sampleBuffer
{
    if (!_context || !_videoTextureCache) {
        return NULL;
    }
    
    // convert to CV image buffer and lock the address to guarantee memory stays available
    CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
    if (CVPixelBufferLockBaseAddress(imageBuffer, 0) != kCVReturnSuccess) {
        return NULL;
    }
    
    // convert this sample buffer into a CIImage (null colorspace to avoid colormatching)
    NSDictionary *options = @{ (id)kCIImageColorSpace : (id)kCFNull };
    CIImage *image = [CIImage imageWithCVPixelBuffer:imageBuffer options:options];
    CGRect sourceExtent = image.extent;
    
    // manual mirroring!
    if (_cameraDevice == PBJCameraDeviceFront)
    {
        // this will mirror the image in the final output video
        CGSize size = [image extent].size;
        image = [image imageByApplyingTransform:CGAffineTransformMakeScale(-1.0, 1.0)];
        image = [image imageByApplyingTransform:CGAffineTransformMakeTranslation(size.width, 0)];
    }
    
    // center crop the source image to a square for video output
    CGRect squareRect = [self squareCropRect:sourceExtent withCenterPercent:self.centerPercentage];
    CIImage *cropImage = [image imageByCroppingToRect:squareRect];
    
    // deterine the scale and amount video should be moved over to fit the video output dimensions
    float scale = 1.0f;
    float xTrans = -squareRect.origin.x;
    float yTrans = -squareRect.origin.y;
    if ( _outputFormat == PBJOutputFormat360x360 ) {
        scale = (360.0f / squareRect.size.width);
        xTrans *= scale;
        yTrans *= scale;
    }
    
    // apply transform to make final image fit perfect in output video dimensions
    if ( scale != 1.0f ) {
        cropImage = [image imageByApplyingTransform:CGAffineTransformMakeScale(scale, scale)];
    }
    cropImage = [cropImage imageByApplyingTransform:CGAffineTransformMakeTranslation(xTrans, yTrans)];
    
    // render the filtered, square, center cropped image back to the outup video
    CVPixelBufferRef renderedOutputPixelBuffer = NULL;
    if ( _mediaWriter.videoReady ) {
        CVReturn err = [_mediaWriter createPixelBufferFromPool:&renderedOutputPixelBuffer];
        if ( !err && renderedOutputPixelBuffer ) {
            [_ciContext render:cropImage toCVPixelBuffer:renderedOutputPixelBuffer];
        }
    }
    
    // draw filtered image into preview view if enough time has past since last drawing
    CMTime currentTimestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer);
    if (CMTIME_IS_INVALID(_lastVideoDisplayTimestamp) ||
        CMTIME_COMPARE_INLINE(_lastVideoDisplayTimestamp, >, currentTimestamp) ||
        CMTIME_COMPARE_INLINE(CMTimeSubtract(currentTimestamp, _lastVideoDisplayTimestamp), >, _minDisplayDuration))
    {
        if(!_movieDataInput)
        {
            _movieDataInput = [[GPUImageMovie alloc] init];
            [_movieDataInput yuvConversionSetup];
        }
        
        if(_isSwipeEnabled)
        {
            // Get filter based on scrollview offset
            GPUImageFilterGroup *newFilterGroup = [_filterManager splitFilterGroupAtIndex:self.filterOffset];
            
            // Check if the filter needs to be changed
            if (![[_movieDataInput targets] containsObject:newFilterGroup])
            {
                [_movieDataInput removeTarget:_currentFilterGroup];
                [_currentFilterGroup removeAllTargets];
                
                _currentFilterGroup = newFilterGroup;
                [_movieDataInput addTarget:_currentFilterGroup];
                [_currentFilterGroup addTarget:_filteredPreviewView];
                
                // draw the small preview view if enabled (taking screen scale into consideration)
                if ( self.smallPreviewEnabled )
                {
                    [_currentFilterGroup addTarget:_filteredSmallPreviewView];
                }
            }
            
            // determine rotation used for mirroring
            GPUImageRotationMode rotation = (_cameraDevice == PBJCameraDeviceFront ?
                                             kGPUImageFlipHorizonal : kGPUImageNoRotation);
            
            // to handle mirroring with GPUImage, we just need to horizontal flip the
            // initial filters in the chain (as long as they aren't split filters). This
            // will flip image for left and right side of split, without flipping split direction
            for ( int i = 0; i < _currentFilterGroup.initialFilters.count; i++ )
            {
                GPUImageFilter *filter = (GPUImageFilter *)_currentFilterGroup.initialFilters[i];
                if ( ![filter isKindOfClass:[GPUImageSplitFilter class]] ) {
                    [filter setInputRotation:rotation atIndex:0];
                }
            }
            
            // Tell spilt filter what percentage should be left and right filter
            CGFloat filterPercent = ((self.filterOffset < 1) ? self.filterOffset :
                                     self.filterOffset - (truncf(self.filterOffset)));
            GPUImageSplitFilter *splitFilter = (GPUImageSplitFilter*)[_currentFilterGroup filterAtIndex:_currentFilterGroup.filterCount-1];
            [splitFilter setOffset:filterPercent];
        }
        
        else
        {
            if(!_currentFilterGroup)
            {
                _currentFilterGroup = [_filterManager splitFilterGroupAtIndex:_filterOffset];
                
                // determine rotation used for mirroring
                GPUImageRotationMode rotation = (_cameraDevice == PBJCameraDeviceFront ?
                                                 kGPUImageFlipHorizonal : kGPUImageNoRotation);
                
                // to handle mirroring with GPUImage, we just need to horizontal flip the
                // initial filters in the chain (as long as they aren't split filters). This
                // will flip image for left and right side of split, without flipping split direction
                for ( int i = 0; i < _currentFilterGroup.initialFilters.count; i++ )
                {
                    GPUImageFilter *filter = (GPUImageFilter *)_currentFilterGroup.initialFilters[i];
                    if ( ![filter isKindOfClass:[GPUImageSplitFilter class]] ) {
                        [filter setInputRotation:rotation atIndex:0];
                    }
                }
                
                [_movieDataInput addTarget:_currentFilterGroup];
                [_currentFilterGroup addTarget:_filteredPreviewView];
                
                // draw the small preview view if enabled (taking screen scale into consideration)
                if ( self.smallPreviewEnabled )
                {
                    [_currentFilterGroup addTarget:_filteredSmallPreviewView];
                }
            }
        }
        
        runSynchronouslyOnVideoProcessingQueue(^{
            [_movieDataInput processMovieFrame:sampleBuffer];
        });
        
        
        _lastVideoDisplayTimestamp = currentTimestamp;
        
        //[self calculateFramerateAtTimestamp:currentTimestamp];
        //NSLog(@"fps: %f", _frameRate);
    }
    
    // we are done with image buffer so unlock it before returning
    CVPixelBufferUnlockBaseAddress(imageBuffer, 0);
    
    return renderedOutputPixelBuffer;
}

- (CGRect)centerCropRect:(CGRect)sourceRect toAspectRatio:(CGFloat)newAspectRatio
{
    CGFloat sourceAspect = (sourceRect.size.width / sourceRect.size.height);
    
    // determine cropped rect based on comparison to new aspect ratio
    CGRect croppedRect = sourceRect;
    if ( sourceAspect > newAspectRatio )
    {
        // landscape. use full height of the video image, and center crop the width
        croppedRect.size.width = (croppedRect.size.height * newAspectRatio);
        croppedRect.origin.x = (sourceRect.size.width - croppedRect.size.width) * 0.5f;
    }
    else
    {
        // portrait. use full width of the video image, and center crop the height
        croppedRect.size.height = (croppedRect.size.width / newAspectRatio);
        croppedRect.origin.y = (sourceRect.size.height - croppedRect.size.height) * 0.5f;
    }
    
    return croppedRect;
}

- (CGRect)squareCropRect:(CGRect)sourceRect withCenterPercent:(CGFloat)centerPercent
{
    CGFloat sourceAspect = (sourceRect.size.width / sourceRect.size.height);
    
    // determine cropped rect based on comparison to new aspect ratio
    CGRect croppedRect = sourceRect;
    if ( sourceAspect > 1.0 )
    {
        // landscape. use full height of the video image, and determine horizontal centering by percentage
        croppedRect.size.width = croppedRect.size.height;
        CGFloat sourceCenterX = (sourceRect.size.width * centerPercent);
        croppedRect.origin.x = sourceCenterX - (croppedRect.size.width * 0.5f);
        
        // check bounds
        if ( croppedRect.origin.x < 0.0f ) {
            croppedRect.origin.x = 0.0f;
        }
        else if ( croppedRect.origin.x + croppedRect.size.width > sourceRect.size.width ) {
            croppedRect.origin.x = sourceRect.size.width - croppedRect.size.width;
        }
    }
    else
    {
        // portrait. use full width of the video image, and determine vertical centering by percentage
        croppedRect.size.height = croppedRect.size.width;
        CGFloat sourceCenterY = (sourceRect.size.height * (1.0f - centerPercent));
        croppedRect.origin.y = sourceCenterY - (croppedRect.size.height * 0.5f);
        
        // check bounds
        if ( croppedRect.origin.y < 0.0f ) {
            croppedRect.origin.y = 0.0f;
        }
        else if ( croppedRect.origin.y + croppedRect.size.height > sourceRect.size.height ) {
            croppedRect.origin.y = sourceRect.size.height - croppedRect.size.height;
        }
    }
    
    return croppedRect;
}

- (void)_cleanUpTextures
{
    CVOpenGLESTextureCacheFlush(_videoTextureCache, 0);

    if (_lumaTexture) {
        CFRelease(_lumaTexture);
        _lumaTexture = NULL;        
    }
    
    if (_chromaTexture) {
        CFRelease(_chromaTexture);
        _chromaTexture = NULL;
    }
}

#pragma mark - OpenGLES context support
// TODO: abstract this in future, put in separate file

- (void)_setupBuffers
{

// unit square for testing
//    static const GLfloat unitSquareVertices[] = {
//        -1.0f, -1.0f,
//        1.0f, -1.0f,
//        -1.0f,  1.0f,
//        1.0f,  1.0f,
//    };
    
    CGSize inputSize = CGSizeMake(_bufferWidth, _bufferHeight);
    CGRect insetRect = AVMakeRectWithAspectRatioInsideRect(inputSize, _presentationFrame);
    
    CGFloat widthScale = CGRectGetHeight(_presentationFrame) / CGRectGetHeight(insetRect);
    CGFloat heightScale = CGRectGetWidth(_presentationFrame) / CGRectGetWidth(insetRect);

    static GLfloat vertices[8];

    vertices[0] = (GLfloat) -widthScale;
    vertices[1] = (GLfloat) -heightScale;
    vertices[2] = (GLfloat) widthScale;
    vertices[3] = (GLfloat) -heightScale;
    vertices[4] = (GLfloat) -widthScale;
    vertices[5] = (GLfloat) heightScale;
    vertices[6] = (GLfloat) widthScale;
    vertices[7] = (GLfloat) heightScale;

    static const GLfloat textureCoordinates[] = {
        0.0f, 1.0f,
        1.0f, 1.0f,
        0.0f, 0.0f,
        1.0f, 0.0f,
    };
    
    static const GLfloat textureCoordinatesVerticalFlip[] = {
        1.0f, 1.0f,
        0.0f, 1.0f,
        1.0f, 0.0f,
        0.0f, 0.0f,
    };
    
    GLuint vertexAttributeLocation = [_program attributeLocation:PBJGLProgramAttributeVertex];
    GLuint textureAttributeLocation = [_program attributeLocation:PBJGLProgramAttributeTextureCoord];
    
    glEnableVertexAttribArray(vertexAttributeLocation);
    glVertexAttribPointer(vertexAttributeLocation, 2, GL_FLOAT, GL_FALSE, 0, vertices);
    
    if (_cameraDevice == PBJCameraDeviceFront) {
        glEnableVertexAttribArray(textureAttributeLocation);
        glVertexAttribPointer(textureAttributeLocation, 2, GL_FLOAT, GL_FALSE, 0, textureCoordinatesVerticalFlip);
    } else {
        glEnableVertexAttribArray(textureAttributeLocation);
        glVertexAttribPointer(textureAttributeLocation, 2, GL_FLOAT, GL_FALSE, 0, textureCoordinates);
    }
}

- (void)_setupGL
{
    static GLint uniforms[PBJVisionUniformCount];

    [EAGLContext setCurrentContext:_context];
    
    NSBundle *bundle = [NSBundle mainBundle];
    
    NSString *vertShaderName = [bundle pathForResource:@"Shader" ofType:@"vsh"];
    NSString *fragShaderName = [bundle pathForResource:@"Shader" ofType:@"fsh"];
    _program = [[PBJGLProgram alloc] initWithVertexShaderName:vertShaderName fragmentShaderName:fragShaderName];
    [_program addAttribute:PBJGLProgramAttributeVertex];
    [_program addAttribute:PBJGLProgramAttributeTextureCoord];
    [_program link];
    
    uniforms[PBJVisionUniformY] = [_program uniformLocation:@"u_samplerY"];
    uniforms[PBJVisionUniformUV] = [_program uniformLocation:@"u_samplerUV"];
    [_program use];
            
    glUniform1i(uniforms[PBJVisionUniformY], 0);
    glUniform1i(uniforms[PBJVisionUniformUV], 1);
}

- (void)_destroyGL
{
    [EAGLContext setCurrentContext:_context];

    _program = nil;
    
    if ([EAGLContext currentContext] == _context) {
        [EAGLContext setCurrentContext:nil];
    }
}

@end
