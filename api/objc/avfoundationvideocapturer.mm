/*
 *  Copyright 2015 The WebRTC project authors. All Rights Reserved.
 *
 *  Use of this source code is governed by a BSD-style license
 *  that can be found in the LICENSE file in the root of the source
 *  tree. An additional intellectual property rights grant can be found
 *  in the file PATENTS.  All contributing project authors may
 *  be found in the AUTHORS file in the root of the source tree.
 */

#include "webrtc/api/objc/avfoundationvideocapturer.h"

#include "webrtc/base/bind.h"

#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "webrtc/base/objc/RTCDispatcher.h"

// TODO(tkchin): support other formats.
static NSString* const kDefaultPreset = AVCaptureSessionPreset640x480;
static cricket::VideoFormat const kDefaultFormat =
    cricket::VideoFormat(640,
                         480,
                         cricket::VideoFormat::FpsToInterval(30),
                         cricket::FOURCC_NV12);

// This class used to capture frames using AVFoundation APIs on iOS. It is meant
// to be owned by an instance of AVFoundationVideoCapturer. The reason for this
// because other webrtc objects own cricket::VideoCapturer, which is not
// ref counted. To prevent bad behavior we do not expose this class directly.
@interface RTCAVFoundationVideoCapturerInternal : NSObject
    <AVCaptureVideoDataOutputSampleBufferDelegate>

@property(nonatomic, readonly) AVCaptureSession *captureSession;
@property(nonatomic, readonly) BOOL isRunning;
@property(nonatomic, assign) BOOL useBackCamera;  // Defaults to NO.

// We keep a pointer back to AVFoundationVideoCapturer to make callbacks on it
// when we receive frames. This is safe because this object should be owned by
// it.
- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer;
- (void)startCaptureAsync;
- (void)stopCaptureAsync;

@end

@implementation RTCAVFoundationVideoCapturerInternal {
  // Keep pointers to inputs for convenience.
  AVCaptureDeviceInput *_frontDeviceInput;
  AVCaptureDeviceInput *_backDeviceInput;
  AVCaptureVideoDataOutput *_videoOutput;
  // The cricket::VideoCapturer that owns this class. Should never be NULL.
  webrtc::AVFoundationVideoCapturer *_capturer;
  BOOL _orientationHasChanged;
}

@synthesize captureSession = _captureSession;
@synthesize useBackCamera = _useBackCamera;
@synthesize isRunning = _isRunning;

- (instancetype)initWithCapturer:(webrtc::AVFoundationVideoCapturer *)capturer {
  NSParameterAssert(capturer);
  if (self = [super init]) {
    _capturer = capturer;
    if (![self setupCaptureSession]) {
      return nil;
    }
    NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
    [center addObserver:self
               selector:@selector(deviceOrientationDidChange:)
                   name:UIDeviceOrientationDidChangeNotification
                 object:nil];
    [center addObserverForName:AVCaptureSessionRuntimeErrorNotification
                        object:nil
                         queue:nil
                    usingBlock:^(NSNotification *notification) {
      NSLog(@"Capture session error: %@", notification.userInfo);
    }];
  }
  return self;
}

- (void)dealloc {
  [self stopCaptureAsync];
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  _capturer = nullptr;
}

- (void)setUseBackCamera:(BOOL)useBackCamera {
  if (_useBackCamera == useBackCamera) {
    return;
  }
  _useBackCamera = useBackCamera;
  [self updateSessionInput];
}

- (void)startCaptureAsync {
  if (_isRunning) {
    return;
  }
  _orientationHasChanged = NO;
  [[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
  AVCaptureSession* session = _captureSession;
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    [session startRunning];
  }];
  _isRunning = YES;
}

- (void)stopCaptureAsync {
  if (!_isRunning) {
    return;
  }
  [_videoOutput setSampleBufferDelegate:nil queue:nullptr];
  AVCaptureSession* session = _captureSession;
  [RTCDispatcher dispatchAsyncOnType:RTCDispatcherTypeCaptureSession
                               block:^{
    [session stopRunning];
  }];
  [[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
  _isRunning = NO;
}

#pragma mark AVCaptureVideoDataOutputSampleBufferDelegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
           fromConnection:(AVCaptureConnection *)connection {
  NSParameterAssert(captureOutput == _videoOutput);
  if (!_isRunning) {
    return;
  }
  _capturer->CaptureSampleBuffer(sampleBuffer);
}

- (void)captureOutput:(AVCaptureOutput *)captureOutput
    didDropSampleBuffer:(CMSampleBufferRef)sampleBuffer
    fromConnection:(AVCaptureConnection *)connection {
  NSLog(@"Dropped sample buffer.");
}

#pragma mark - Private

- (BOOL)setupCaptureSession {
  _captureSession = [[AVCaptureSession alloc] init];
#if defined(__IPHONE_7_0) && __IPHONE_OS_VERSION_MAX_ALLOWED >= __IPHONE_7_0
  NSString *version = [[UIDevice currentDevice] systemVersion];
  if ([version integerValue] >= 7) {
    _captureSession.usesApplicationAudioSession = NO;
  }
#endif
  if (![_captureSession canSetSessionPreset:kDefaultPreset]) {
    NSLog(@"Default video capture preset unsupported.");
    return NO;
  }
  _captureSession.sessionPreset = kDefaultPreset;

  // Make the capturer output NV12. Ideally we want I420 but that's not
  // currently supported on iPhone / iPad.
  _videoOutput = [[AVCaptureVideoDataOutput alloc] init];
  _videoOutput.videoSettings = @{
    (NSString *)kCVPixelBufferPixelFormatTypeKey :
        @(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange)
  };
  _videoOutput.alwaysDiscardsLateVideoFrames = NO;
  [_videoOutput setSampleBufferDelegate:self
                                  queue:dispatch_get_main_queue()];
  if (![_captureSession canAddOutput:_videoOutput]) {
    NSLog(@"Default video capture output unsupported.");
    return NO;
  }
  [_captureSession addOutput:_videoOutput];

  // Find the capture devices.
  AVCaptureDevice *frontCaptureDevice = nil;
  AVCaptureDevice *backCaptureDevice = nil;
  for (AVCaptureDevice *captureDevice in
       [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo]) {
    if (captureDevice.position == AVCaptureDevicePositionBack) {
      backCaptureDevice = captureDevice;
    }
    if (captureDevice.position == AVCaptureDevicePositionFront) {
      frontCaptureDevice = captureDevice;
    }
  }
  if (!frontCaptureDevice || !backCaptureDevice) {
    NSLog(@"Failed to get capture devices.");
    return NO;
  }

  // Set up the session inputs.
  NSError *error = nil;
  _frontDeviceInput =
      [AVCaptureDeviceInput deviceInputWithDevice:frontCaptureDevice
                                            error:&error];
  if (!_frontDeviceInput) {
    NSLog(@"Failed to get capture device input: %@",
          error.localizedDescription);
    return NO;
  }
  _backDeviceInput =
      [AVCaptureDeviceInput deviceInputWithDevice:backCaptureDevice
                                            error:&error];
  if (!_backDeviceInput) {
    NSLog(@"Failed to get capture device input: %@",
          error.localizedDescription);
    return NO;
  }

  // Add the inputs.
  if (![_captureSession canAddInput:_frontDeviceInput] ||
      ![_captureSession canAddInput:_backDeviceInput]) {
    NSLog(@"Session does not support capture inputs.");
    return NO;
  }
  [self updateSessionInput];

  return YES;
}

- (void)deviceOrientationDidChange:(NSNotification *)notification {
  _orientationHasChanged = YES;
  [self updateOrientation];
}

- (void)updateOrientation {
  AVCaptureConnection *connection =
      [_videoOutput connectionWithMediaType:AVMediaTypeVideo];
  if (!connection.supportsVideoOrientation) {
    // TODO(tkchin): set rotation bit on frames.
    return;
  }
  AVCaptureVideoOrientation orientation = AVCaptureVideoOrientationPortrait;
  switch ([UIDevice currentDevice].orientation) {
    case UIDeviceOrientationPortrait:
      orientation = AVCaptureVideoOrientationPortrait;
      break;
    case UIDeviceOrientationPortraitUpsideDown:
      orientation = AVCaptureVideoOrientationPortraitUpsideDown;
      break;
    case UIDeviceOrientationLandscapeLeft:
      orientation = AVCaptureVideoOrientationLandscapeRight;
      break;
    case UIDeviceOrientationLandscapeRight:
      orientation = AVCaptureVideoOrientationLandscapeLeft;
      break;
    case UIDeviceOrientationFaceUp:
    case UIDeviceOrientationFaceDown:
    case UIDeviceOrientationUnknown:
      if (!_orientationHasChanged) {
        connection.videoOrientation = orientation;
      }
      return;
  }
  connection.videoOrientation = orientation;
}

- (void)updateSessionInput {
  // Update the current session input to match what's stored in _useBackCamera.
  [_captureSession beginConfiguration];
  AVCaptureDeviceInput *oldInput = _backDeviceInput;
  AVCaptureDeviceInput *newInput = _frontDeviceInput;
  if (_useBackCamera) {
    oldInput = _frontDeviceInput;
    newInput = _backDeviceInput;
  }
  // Ok to remove this even if it's not attached. Will be no-op.
  [_captureSession removeInput:oldInput];
  [_captureSession addInput:newInput];
  [self updateOrientation];
  [_captureSession commitConfiguration];
}

@end

namespace webrtc {

AVFoundationVideoCapturer::AVFoundationVideoCapturer()
    : _capturer(nil), _startThread(nullptr) {
  // Set our supported formats. This matches kDefaultPreset.
  std::vector<cricket::VideoFormat> supportedFormats;
  supportedFormats.push_back(cricket::VideoFormat(kDefaultFormat));
  SetSupportedFormats(supportedFormats);
  _capturer =
      [[RTCAVFoundationVideoCapturerInternal alloc] initWithCapturer:this];
}

AVFoundationVideoCapturer::~AVFoundationVideoCapturer() {
  _capturer = nil;
}

cricket::CaptureState AVFoundationVideoCapturer::Start(
    const cricket::VideoFormat& format) {
  if (!_capturer) {
    LOG(LS_ERROR) << "Failed to create AVFoundation capturer.";
    return cricket::CaptureState::CS_FAILED;
  }
  if (_capturer.isRunning) {
    LOG(LS_ERROR) << "The capturer is already running.";
    return cricket::CaptureState::CS_FAILED;
  }
  if (format != kDefaultFormat) {
    LOG(LS_ERROR) << "Unsupported format provided.";
    return cricket::CaptureState::CS_FAILED;
  }

  // Keep track of which thread capture started on. This is the thread that
  // frames need to be sent to.
  RTC_DCHECK(!_startThread);
  _startThread = rtc::Thread::Current();

  SetCaptureFormat(&format);
  // This isn't super accurate because it takes a while for the AVCaptureSession
  // to spin up, and this call returns async.
  // TODO(tkchin): make this better.
  [_capturer startCaptureAsync];
  SetCaptureState(cricket::CaptureState::CS_RUNNING);

  return cricket::CaptureState::CS_STARTING;
}

void AVFoundationVideoCapturer::Stop() {
  [_capturer stopCaptureAsync];
  SetCaptureFormat(NULL);
  _startThread = nullptr;
}

bool AVFoundationVideoCapturer::IsRunning() {
  return _capturer.isRunning;
}

AVCaptureSession* AVFoundationVideoCapturer::GetCaptureSession() {
  return _capturer.captureSession;
}

void AVFoundationVideoCapturer::SetUseBackCamera(bool useBackCamera) {
  _capturer.useBackCamera = useBackCamera;
}

bool AVFoundationVideoCapturer::GetUseBackCamera() const {
  return _capturer.useBackCamera;
}

void AVFoundationVideoCapturer::CaptureSampleBuffer(
    CMSampleBufferRef sampleBuffer) {
  if (CMSampleBufferGetNumSamples(sampleBuffer) != 1 ||
      !CMSampleBufferIsValid(sampleBuffer) ||
      !CMSampleBufferDataIsReady(sampleBuffer)) {
    return;
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == NULL) {
    return;
  }

  // Base address must be unlocked to access frame data.
  CVOptionFlags lockFlags = kCVPixelBufferLock_ReadOnly;
  CVReturn ret = CVPixelBufferLockBaseAddress(imageBuffer, lockFlags);
  if (ret != kCVReturnSuccess) {
    return;
  }

  static size_t const kYPlaneIndex = 0;
  static size_t const kUVPlaneIndex = 1;
  uint8_t *yPlaneAddress =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, kYPlaneIndex);
  size_t yPlaneHeight =
      CVPixelBufferGetHeightOfPlane(imageBuffer, kYPlaneIndex);
  size_t yPlaneWidth =
      CVPixelBufferGetWidthOfPlane(imageBuffer, kYPlaneIndex);
  size_t yPlaneBytesPerRow =
      CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, kYPlaneIndex);
  size_t uvPlaneHeight =
      CVPixelBufferGetHeightOfPlane(imageBuffer, kUVPlaneIndex);
  size_t uvPlaneBytesPerRow =
      CVPixelBufferGetBytesPerRowOfPlane(imageBuffer, kUVPlaneIndex);
  size_t frameSize =
      yPlaneBytesPerRow * yPlaneHeight + uvPlaneBytesPerRow * uvPlaneHeight;

  // Sanity check assumption that planar bytes are contiguous.
  uint8_t *uvPlaneAddress =
      (uint8_t *)CVPixelBufferGetBaseAddressOfPlane(imageBuffer, kUVPlaneIndex);
  RTC_DCHECK(
      uvPlaneAddress == yPlaneAddress + yPlaneHeight * yPlaneBytesPerRow);

  // Stuff data into a cricket::CapturedFrame.
  int64_t currentTime = rtc::TimeNanos();
  cricket::CapturedFrame frame;
  frame.width = yPlaneWidth;
  frame.height = yPlaneHeight;
  frame.pixel_width = 1;
  frame.pixel_height = 1;
  frame.fourcc = static_cast<uint32_t>(cricket::FOURCC_NV12);
  frame.time_stamp = currentTime;
  frame.data = yPlaneAddress;
  frame.data_size = frameSize;

  if (_startThread->IsCurrent()) {
    SignalFrameCaptured(this, &frame);
  } else {
    _startThread->Invoke<void>(
        rtc::Bind(&AVFoundationVideoCapturer::SignalFrameCapturedOnStartThread,
                  this, &frame));
  }
  CVPixelBufferUnlockBaseAddress(imageBuffer, lockFlags);
}

void AVFoundationVideoCapturer::SignalFrameCapturedOnStartThread(
    const cricket::CapturedFrame *frame) {
  RTC_DCHECK(_startThread->IsCurrent());
  // This will call a superclass method that will perform the frame conversion
  // to I420.
  SignalFrameCaptured(this, frame);
}

}  // namespace webrtc
