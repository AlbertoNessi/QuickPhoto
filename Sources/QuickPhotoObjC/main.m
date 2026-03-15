#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <Carbon/Carbon.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOKit/audio/IOAudioTypes.h>

@class QPPreviewCoordinator;
static void QPWarmUpCaptureSession(AVCaptureSession *session);
static void QPWarmUpAutoExposure(AVCaptureDevice *device);

@interface QPVideoFrameCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) NSData *jpegData;
@property(nonatomic, strong) NSError *captureError;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) NSInteger processedFrames;
@property(nonatomic, strong) CIContext *ciContext;
@property(nonatomic, assign) BOOL captureRequested;
@property(nonatomic, copy) void (^completionHandler)(void);
- (void)requestCapture;
- (void)cancelCapture;
@end

@interface QPPreviewVideoView : NSView
@property(nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;
@property(nonatomic, weak) QPPreviewCoordinator *coordinator;
@end

@interface QPPreviewCoordinator : NSObject <NSWindowDelegate>
@property(nonatomic, strong) AVCaptureDevice *device;
@property(nonatomic, strong) AVCaptureSession *session;
@property(nonatomic, strong) AVCaptureDeviceInput *input;
@property(nonatomic, strong) AVCaptureVideoDataOutput *videoOutput;
@property(nonatomic, strong) dispatch_queue_t frameQueue;
@property(nonatomic, strong) QPVideoFrameCaptureDelegate *captureDelegate;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic, strong) NSTextField *statusLabel;
@property(nonatomic, strong) NSButton *captureButton;
@property(nonatomic, strong) NSButton *cancelButton;
- (instancetype)initWithDevice:(AVCaptureDevice *)device;
- (BOOL)prepareSession:(NSError **)errorOut;
- (NSData *)runHeadlessCaptureWithError:(NSError **)errorOut;
- (NSData *)runPreviewCaptureWithError:(NSError **)errorOut;
- (void)requestCapture;
- (void)cancelCapture;
@end

@implementation QPVideoFrameCaptureDelegate

- (instancetype)init {
  self = [super init];
  if (self) {
    _finished = NO;
    _processedFrames = 0;
    _ciContext = [CIContext contextWithOptions:nil];
  }
  return self;
}

- (void)finishWithError:(NSError *)error {
  if (self.finished) {
    return;
  }
  self.captureError = error;
  self.finished = YES;
  if (self.completionHandler != nil) {
    dispatch_async(dispatch_get_main_queue(), self.completionHandler);
  }
}

- (void)finishWithJPEG:(NSData *)jpegData {
  if (self.finished) {
    return;
  }
  self.jpegData = jpegData;
  self.finished = YES;
  if (self.completionHandler != nil) {
    dispatch_async(dispatch_get_main_queue(), self.completionHandler);
  }
}

- (void)requestCapture {
  self.captureRequested = YES;
}

- (void)cancelCapture {
  [self finishWithError:[NSError errorWithDomain:@"QuickPhoto"
                                            code:1013
                                        userInfo:@{
                                          NSLocalizedDescriptionKey : @"Capture cancelled."
                                        }]];
}

- (double)meanLumaForImage:(CIImage *)image {
  CIFilter *averageFilter = [CIFilter filterWithName:@"CIAreaAverage"];
  if (averageFilter == nil) {
    return 1.0;
  }

  [averageFilter setValue:image forKey:kCIInputImageKey];
  [averageFilter setValue:[CIVector vectorWithCGRect:image.extent] forKey:kCIInputExtentKey];
  CIImage *averageImage = averageFilter.outputImage;
  if (averageImage == nil) {
    return 1.0;
  }

  uint8_t rgba[4] = {0, 0, 0, 0};
  [self.ciContext render:averageImage
                toBitmap:rgba
                rowBytes:4
                  bounds:CGRectMake(0, 0, 1, 1)
                  format:kCIFormatRGBA8
              colorSpace:nil];

  double r = (double)rgba[0] / 255.0;
  double g = (double)rgba[1] / 255.0;
  double b = (double)rgba[2] / 255.0;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

- (void)captureOutput:(AVCaptureOutput *)output
didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer
       fromConnection:(AVCaptureConnection *)connection {
  if (self.finished) {
    return;
  }

  CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
  if (imageBuffer == nil) {
    return;
  }

  CIImage *ciImage = [CIImage imageWithCVImageBuffer:imageBuffer];
  if (ciImage == nil) {
    return;
  }

  self.processedFrames += 1;
  double luma = [self meanLumaForImage:ciImage];

  // Skip startup frames and near-black frames; exposure on built-in cameras can settle late.
  if (self.processedFrames < 6 || luma < 0.03) {
    return;
  }

  if (!self.captureRequested) {
    return;
  }

  CGImageRef cgImage = [self.ciContext createCGImage:ciImage fromRect:ciImage.extent];
  if (cgImage == nil) {
    [self finishWithError:[NSError errorWithDomain:@"QuickPhoto"
                                              code:1001
                                          userInfo:@{
                                            NSLocalizedDescriptionKey : @"Failed to produce image from camera frame."
                                          }]];
    return;
  }

  NSBitmapImageRep *bitmapRep = [[NSBitmapImageRep alloc] initWithCGImage:cgImage];
  CGImageRelease(cgImage);
  if (bitmapRep == nil) {
    [self finishWithError:[NSError errorWithDomain:@"QuickPhoto"
                                              code:1001
                                          userInfo:@{
                                            NSLocalizedDescriptionKey : @"Failed to encode bitmap from camera frame."
                                          }]];
    return;
  }

  NSData *jpegData = [bitmapRep representationUsingType:NSBitmapImageFileTypeJPEG
                                             properties:@{NSImageCompressionFactor : @0.95}];
  if (jpegData == nil) {
    [self finishWithError:[NSError errorWithDomain:@"QuickPhoto"
                                              code:1001
                                          userInfo:@{
                                            NSLocalizedDescriptionKey : @"Failed to encode JPEG from camera frame."
                                          }]];
    return;
  }

  [self finishWithJPEG:jpegData];
}

@end

@implementation QPPreviewVideoView

- (instancetype)initWithFrame:(NSRect)frameRect {
  self = [super initWithFrame:frameRect];
  if (self) {
    self.wantsLayer = YES;
  }
  return self;
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (void)setPreviewLayer:(AVCaptureVideoPreviewLayer *)previewLayer {
  _previewLayer = previewLayer;
  self.layer = previewLayer;
}

- (void)keyDown:(NSEvent *)event {
  switch (event.keyCode) {
  case kVK_Space:
  case kVK_Return:
  case kVK_ANSI_KeypadEnter:
    [self.coordinator requestCapture];
    return;
  case kVK_Escape:
    [self.coordinator cancelCapture];
    return;
  default:
    [super keyDown:event];
    return;
  }
}

@end

@implementation QPPreviewCoordinator

- (instancetype)initWithDevice:(AVCaptureDevice *)device {
  self = [super init];
  if (self) {
    _device = device;
  }
  return self;
}

- (BOOL)prepareSession:(NSError **)errorOut {
  NSError *localError = nil;
  if ([self.device lockForConfiguration:&localError]) {
    if ([self.device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
      self.device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    }
    if ([self.device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
      self.device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
    }
    [self.device unlockForConfiguration];
  }

  self.input = [AVCaptureDeviceInput deviceInputWithDevice:self.device error:&localError];
  if (self.input == nil) {
    if (errorOut != NULL) {
      *errorOut = localError;
    }
    return NO;
  }

  self.session = [[AVCaptureSession alloc] init];
  self.session.sessionPreset = AVCaptureSessionPresetPhoto;

  self.videoOutput = [[AVCaptureVideoDataOutput alloc] init];
  self.videoOutput.alwaysDiscardsLateVideoFrames = YES;
  self.videoOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
  };

  if (![self.session canAddInput:self.input] || ![self.session canAddOutput:self.videoOutput]) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1007
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Failed to configure camera capture session."
                                  }];
    }
    return NO;
  }

  [self.session addInput:self.input];
  [self.session addOutput:self.videoOutput];

  self.frameQueue = dispatch_queue_create("qp.video.frame", DISPATCH_QUEUE_SERIAL);
  self.captureDelegate = [[QPVideoFrameCaptureDelegate alloc] init];
  [self.videoOutput setSampleBufferDelegate:self.captureDelegate queue:self.frameQueue];

  AVCaptureConnection *videoConnection = [self.videoOutput connectionWithMediaType:AVMediaTypeVideo];
  if (videoConnection != nil && videoConnection.isVideoMirroringSupported &&
      self.device.position == AVCaptureDevicePositionFront) {
    videoConnection.videoMirrored = YES;
  }

  return YES;
}

- (void)startSession {
  [self.session startRunning];
  QPWarmUpCaptureSession(self.session);
  QPWarmUpAutoExposure(self.device);
}

- (void)stopSession {
  [self.videoOutput setSampleBufferDelegate:nil queue:NULL];
  [self.session stopRunning];
}

- (void)requestCapture {
  self.captureButton.enabled = NO;
  self.statusLabel.stringValue = @"Capturing...";
  [self.captureDelegate requestCapture];
}

- (void)cancelCapture {
  [self.captureDelegate cancelCapture];
}

- (void)closePreviewWindow {
  [self.window orderOut:nil];
  [self.window close];
  self.window = nil;
}

- (void)buildPreviewWindow {
  NSRect frame = NSMakeRect(0, 0, 920, 640);
  self.window = [[NSWindow alloc] initWithContentRect:frame
                                            styleMask:(NSWindowStyleMaskTitled | NSWindowStyleMaskClosable)
                                              backing:NSBackingStoreBuffered
                                                defer:NO];
  self.window.title = @"QuickPhoto Preview";
  self.window.delegate = self;
  [self.window center];

  NSView *contentView = [[NSView alloc] initWithFrame:frame];
  self.window.contentView = contentView;

  QPPreviewVideoView *previewView = [[QPPreviewVideoView alloc] initWithFrame:NSMakeRect(20, 80, 880, 520)];
  previewView.coordinator = self;
  AVCaptureVideoPreviewLayer *previewLayer = [AVCaptureVideoPreviewLayer layerWithSession:self.session];
  previewLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
  previewView.previewLayer = previewLayer;
  [contentView addSubview:previewView];

  self.statusLabel = [[NSTextField alloc] initWithFrame:NSMakeRect(20, 28, 520, 24)];
  self.statusLabel.editable = NO;
  self.statusLabel.bezeled = NO;
  self.statusLabel.drawsBackground = NO;
  self.statusLabel.selectable = NO;
  self.statusLabel.stringValue = @"Space/Return to capture, Esc to cancel.";
  [contentView addSubview:self.statusLabel];

  self.captureButton = [[NSButton alloc] initWithFrame:NSMakeRect(700, 20, 96, 32)];
  self.captureButton.title = @"Capture";
  self.captureButton.bezelStyle = NSBezelStyleRounded;
  self.captureButton.target = self;
  self.captureButton.action = @selector(requestCapture);
  [contentView addSubview:self.captureButton];

  self.cancelButton = [[NSButton alloc] initWithFrame:NSMakeRect(804, 20, 96, 32)];
  self.cancelButton.title = @"Cancel";
  self.cancelButton.bezelStyle = NSBezelStyleRounded;
  self.cancelButton.target = self;
  self.cancelButton.action = @selector(cancelCapture);
  [contentView addSubview:self.cancelButton];

  [self.window makeFirstResponder:previewView];
}

- (void)windowWillClose:(NSNotification *)notification {
  if (!self.captureDelegate.finished) {
    [self cancelCapture];
  }
}

- (NSData *)finalizeCaptureWithError:(NSError **)errorOut {
  [self stopSession];

  if (self.captureDelegate.captureError != nil) {
    if (errorOut != NULL) {
      *errorOut = self.captureDelegate.captureError;
    }
    return nil;
  }

  if (self.captureDelegate.jpegData == nil) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1012
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Capture completed without a valid frame."
                                  }];
    }
    return nil;
  }

  return self.captureDelegate.jpegData;
}

- (NSData *)runHeadlessCaptureWithError:(NSError **)errorOut {
  __weak typeof(self) weakSelf = self;
  self.captureDelegate.completionHandler = ^{
    // Headless mode polls its own run loop; completion is used to wake the main queue quickly.
    (void)weakSelf;
  };

  [self startSession];
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!self.captureDelegate.finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
    if (!self.captureDelegate.captureRequested && self.captureDelegate.processedFrames >= 6) {
      [self.captureDelegate requestCapture];
    }
  }

  if (!self.captureDelegate.finished) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1008
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Capture timed out."
                                  }];
    }
    [self stopSession];
    return nil;
  }

  return [self finalizeCaptureWithError:errorOut];
}

- (NSData *)runPreviewCaptureWithError:(NSError **)errorOut {
  NSApplication *app = [NSApplication sharedApplication];
  [app setActivationPolicy:NSApplicationActivationPolicyAccessory];

  __weak typeof(self) weakSelf = self;
  self.captureDelegate.completionHandler = ^{
    [NSApp stop:nil];
    [weakSelf closePreviewWindow];
  };

  [self buildPreviewWindow];
  [self startSession];
  [self.window makeKeyAndOrderFront:nil];
  [app activateIgnoringOtherApps:YES];
  [app run];

  return [self finalizeCaptureWithError:errorOut];
}

@end

static void QPPrintUsage(void) {
  printf("QuickPhoto (QP)\n");
  printf("Usage: qp [--delay <seconds>] [--save <path>] [--camera-list] [--headless] [--help]\n");
  printf("  --delay <seconds>   Wait before capture\n");
  printf("  --save <path>       Save captured JPEG to file for diagnostics\n");
  printf("  --camera-list       List video devices and selected built-in camera\n");
  printf("  --headless          Capture immediately without opening preview window\n");
  printf("  --help              Show help\n");
}

static BOOL QPParseArgs(int argc, const char *argv[], int *delayOut, NSString **savePathOut,
                        BOOL *cameraListOut, BOOL *headlessOut,
                        NSError **errorOut) {
  int delay = 0;
  NSString *savePath = nil;
  BOOL cameraList = NO;
  BOOL headless = NO;
  for (int i = 1; i < argc; i++) {
    const char *arg = argv[i];
    if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
      QPPrintUsage();
      exit(0);
    }

    if (strcmp(arg, "--camera-list") == 0) {
      cameraList = YES;
      continue;
    }

    if (strcmp(arg, "--headless") == 0) {
      headless = YES;
      continue;
    }

    if (strcmp(arg, "--save") == 0) {
      if (i + 1 >= argc) {
        if (errorOut != NULL) {
          *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                          code:1011
                                      userInfo:@{
                                        NSLocalizedDescriptionKey : @"Missing value for --save."
                                      }];
        }
        return NO;
      }
      savePath = [NSString stringWithUTF8String:argv[++i]];
      continue;
    }

    if (strcmp(arg, "--delay") == 0) {
      if (i + 1 >= argc) {
        if (errorOut != NULL) {
          *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                          code:1002
                                      userInfo:@{
                                        NSLocalizedDescriptionKey : @"Missing value for --delay."
                                      }];
        }
        return NO;
      }

      NSString *value = [NSString stringWithUTF8String:argv[++i]];
      NSScanner *scanner = [NSScanner scannerWithString:value];
      int parsed = 0;
      if (![scanner scanInt:&parsed] || !scanner.isAtEnd || parsed < 0) {
        if (errorOut != NULL) {
          *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                          code:1003
                                      userInfo:@{
                                        NSLocalizedDescriptionKey : @"--delay must be a non-negative integer."
                                      }];
        }
        return NO;
      }
      delay = parsed;
      continue;
    }

    if (errorOut != NULL) {
      NSString *message = [NSString stringWithFormat:@"Unknown argument: %s", arg];
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1004
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : message
                                  }];
    }
    return NO;
  }

  *delayOut = delay;
  *savePathOut = savePath;
  *cameraListOut = cameraList;
  *headlessOut = headless;
  return YES;
}

static BOOL QPEnsureCameraPermission(NSError **errorOut) {
  AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];

  if (status == AVAuthorizationStatusAuthorized) {
    return YES;
  }

  if (status == AVAuthorizationStatusNotDetermined) {
    __block BOOL granted = NO;
    dispatch_semaphore_t semaphore = dispatch_semaphore_create(0);
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                             completionHandler:^(BOOL accessGranted) {
                               granted = accessGranted;
                               dispatch_semaphore_signal(semaphore);
                             }];
    // Keep CLI behavior deterministic: we block once, then continue with a final permission state.
    dispatch_time_t timeout = dispatch_time(DISPATCH_TIME_NOW, 60 * NSEC_PER_SEC);
    dispatch_semaphore_wait(semaphore, timeout);
    if (granted) {
      return YES;
    }
  }

  if (errorOut != NULL) {
    *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                    code:1005
                                userInfo:@{
                                  NSLocalizedDescriptionKey :
                                      @"Camera permission denied. Enable it in System Settings > Privacy & Security > Camera."
                                }];
  }
  return NO;
}

static AVCaptureDevice *QPSelectBuiltInCamera(void) {
  AVCaptureDevice *selected = nil;
  if (@available(macOS 10.15, *)) {
    AVCaptureDeviceDiscoverySession *frontDiscovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionFront];
    for (AVCaptureDevice *candidate in frontDiscovery.devices) {
      if (candidate.transportType != kIOAudioDeviceTransportTypeBuiltIn) {
        continue;
      }
      if (candidate.isConnected) {
        return candidate;
      }
      if (selected == nil) {
        selected = candidate;
      }
    }

    AVCaptureDeviceDiscoverySession *discovery =
        [AVCaptureDeviceDiscoverySession discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                                               mediaType:AVMediaTypeVideo
                                                                position:AVCaptureDevicePositionUnspecified];
    for (AVCaptureDevice *candidate in discovery.devices) {
      if (candidate.transportType != kIOAudioDeviceTransportTypeBuiltIn) {
        continue;
      }
      if (candidate.isConnected) {
        return candidate;
      }
      if (selected == nil) {
        selected = candidate;
      }
    }
  }

  return selected;
}

static NSArray<AVCaptureDeviceType> *QPDiscoveryTypesForDiagnostics(void) {
  NSMutableArray<AVCaptureDeviceType> *types = [NSMutableArray arrayWithObject:AVCaptureDeviceTypeBuiltInWideAngleCamera];
  [types addObject:AVCaptureDeviceTypeExternal];
  [types addObject:AVCaptureDeviceTypeContinuityCamera];
  return types;
}

static const char *QPPositionName(AVCaptureDevicePosition position) {
  switch (position) {
  case AVCaptureDevicePositionFront:
    return "front";
  case AVCaptureDevicePositionBack:
    return "back";
  default:
    return "unspecified";
  }
}

static const char *QPTransportName(int32_t transportType) {
  switch (transportType) {
  case kIOAudioDeviceTransportTypeBuiltIn:
    return "built-in";
  case kIOAudioDeviceTransportTypeUSB:
    return "usb";
  case kIOAudioDeviceTransportTypeWireless:
    return "wireless";
  case kIOAudioDeviceTransportTypeVirtual:
    return "virtual";
  case kIOAudioDeviceTransportTypeBluetooth:
    return "bluetooth";
  case kIOAudioDeviceTransportTypeHdmi:
    return "hdmi";
  case kIOAudioDeviceTransportTypeDisplayPort:
    return "displayport";
  case kIOAudioDeviceTransportTypeThunderbolt:
    return "thunderbolt";
  default:
    return "other";
  }
}

static void QPPrintCameraList(void) {
  AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
      discoverySessionWithDeviceTypes:QPDiscoveryTypesForDiagnostics()
                            mediaType:AVMediaTypeVideo
                             position:AVCaptureDevicePositionUnspecified];
  NSArray<AVCaptureDevice *> *devices = discovery.devices;
  printf("Detected video devices (%lu):\n", (unsigned long)devices.count);
  for (NSUInteger i = 0; i < devices.count; i++) {
    AVCaptureDevice *device = devices[i];
    printf("  [%lu] %s | type=%s | position=%s | transport=%s | connected=%s\n",
           (unsigned long)i,
           device.localizedName.UTF8String, device.deviceType.UTF8String,
           QPPositionName(device.position), QPTransportName(device.transportType),
           device.isConnected ? "yes" : "no");
  }

  AVCaptureDevice *selected = QPSelectBuiltInCamera();
  if (selected != nil) {
    printf("Selected built-in camera: %s | type=%s | position=%s | transport=%s\n",
           selected.localizedName.UTF8String, selected.deviceType.UTF8String,
           QPPositionName(selected.position), QPTransportName(selected.transportType));
  } else {
    printf("Selected built-in camera: none\n");
  }
}

static void QPWarmUpCaptureSession(AVCaptureSession *session) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:3.0];
  while ([deadline timeIntervalSinceNow] > 0) {
    if (session.isRunning) {
      break;
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
}

static void QPWarmUpAutoExposure(AVCaptureDevice *device) {
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:2.5];
  while ([deadline timeIntervalSinceNow] > 0) {
    BOOL settled = !device.isAdjustingExposure;
    if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
      settled = settled && !device.isAdjustingFocus;
    }
    if (settled) {
      break;
    }
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
}

static NSData *QPCapturePhotoData(BOOL headless, NSError **errorOut) {
  if (!QPEnsureCameraPermission(errorOut)) {
    return nil;
  }

  AVCaptureDevice *device = QPSelectBuiltInCamera();
  if (device == nil) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1006
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"No built-in Mac camera found. Run with --camera-list to inspect detected devices."
                                  }];
    }
    return nil;
  }
  printf("Using built-in camera: %s\n", device.localizedName.UTF8String);

  QPPreviewCoordinator *coordinator = [[QPPreviewCoordinator alloc] initWithDevice:device];
  if (![coordinator prepareSession:errorOut]) {
    return nil;
  }

  if (headless) {
    return [coordinator runHeadlessCaptureWithError:errorOut];
  }
  return [coordinator runPreviewCaptureWithError:errorOut];
}

static BOOL QPWriteImageToClipboard(NSData *photoData, NSError **errorOut) {
  NSImage *image = [[NSImage alloc] initWithData:photoData];
  if (image == nil) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1009
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Captured bytes are not a valid image."
                                  }];
    }
    return NO;
  }

  NSData *tiffData = [image TIFFRepresentation];
  NSBitmapImageRep *bitmap = nil;
  if (tiffData != nil) {
    bitmap = [NSBitmapImageRep imageRepWithData:tiffData];
  }
  NSData *pngData = nil;
  if (bitmap != nil) {
    pngData = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
  }

  NSPasteboard *pasteboard = [NSPasteboard generalPasteboard];
  [pasteboard clearContents];
  [pasteboard declareTypes:@[ NSPasteboardTypePNG, NSPasteboardTypeTIFF, @"public.jpeg" ] owner:nil];

  BOOL wroteSomething = NO;
  if (pngData != nil) {
    wroteSomething = [pasteboard setData:pngData forType:NSPasteboardTypePNG] || wroteSomething;
  }
  if (tiffData != nil) {
    wroteSomething = [pasteboard setData:tiffData forType:NSPasteboardTypeTIFF] || wroteSomething;
  }
  wroteSomething = [pasteboard setData:photoData forType:@"public.jpeg"] || wroteSomething;

  if (!wroteSomething) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1010
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Failed to write image to clipboard."
                                  }];
    }
    return NO;
  }

  return YES;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSError *error = nil;

    int delay = 0;
    NSString *savePath = nil;
    BOOL cameraList = NO;
    BOOL headless = NO;
    if (!QPParseArgs(argc, argv, &delay, &savePath, &cameraList, &headless, &error)) {
      fprintf(stderr, "QuickPhoto error: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }

    if (cameraList) {
      QPPrintCameraList();
      return 0;
    }

    for (int seconds = delay; seconds >= 1; seconds--) {
      printf("Capturing in %d...\n", seconds);
      sleep(1);
    }

    NSData *photoData = QPCapturePhotoData(headless, &error);
    if (photoData == nil) {
      if (error.code == 1013) {
        fprintf(stderr, "QuickPhoto: capture cancelled.\n");
        return 0;
      }
      fprintf(stderr, "QuickPhoto error: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }

    if (savePath != nil) {
      if (![photoData writeToFile:savePath options:NSDataWritingAtomic error:&error]) {
        fprintf(stderr, "QuickPhoto error: Failed to save image to %s (%s)\n", savePath.UTF8String,
                error.localizedDescription.UTF8String);
        return 1;
      }
      printf("Saved captured JPEG: %s\n", savePath.UTF8String);
    }

    if (!QPWriteImageToClipboard(photoData, &error)) {
      fprintf(stderr, "QuickPhoto error: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }

    printf("Photo copied to clipboard.\n");
    printf("Tip: paste now with Cmd+V in another app.\n");
    return 0;
  }
}
