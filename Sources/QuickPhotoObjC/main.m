#import <AppKit/AppKit.h>
#import <AVFoundation/AVFoundation.h>
#import <CoreImage/CoreImage.h>
#import <CoreVideo/CoreVideo.h>
#import <Foundation/Foundation.h>
#import <IOKit/audio/IOAudioTypes.h>

@interface QPVideoFrameCaptureDelegate : NSObject <AVCaptureVideoDataOutputSampleBufferDelegate>
@property(nonatomic, strong) NSData *jpegData;
@property(nonatomic, strong) NSError *captureError;
@property(nonatomic, assign) BOOL finished;
@property(nonatomic, assign) NSInteger processedFrames;
@property(nonatomic, strong) CIContext *ciContext;
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
}

- (void)finishWithJPEG:(NSData *)jpegData {
  if (self.finished) {
    return;
  }
  self.jpegData = jpegData;
  self.finished = YES;
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

static void QPPrintUsage(void) {
  printf("QuickPhoto (QP)\n");
  printf("Usage: qp [--delay <seconds>] [--save <path>] [--camera-list] [--help]\n");
  printf("  --delay <seconds>   Wait before capture\n");
  printf("  --save <path>       Save captured JPEG to file for diagnostics\n");
  printf("  --camera-list       List video devices and selected built-in camera\n");
  printf("  --help              Show help\n");
}

static BOOL QPParseArgs(int argc, const char *argv[], int *delayOut, NSString **savePathOut,
                        BOOL *cameraListOut,
                        NSError **errorOut) {
  int delay = 0;
  NSString *savePath = nil;
  BOOL cameraList = NO;
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

static NSData *QPCapturePhotoData(NSError **errorOut) {
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

  NSError *localError = nil;
  if ([device lockForConfiguration:&localError]) {
    if ([device isExposureModeSupported:AVCaptureExposureModeContinuousAutoExposure]) {
      device.exposureMode = AVCaptureExposureModeContinuousAutoExposure;
    }
    if ([device isFocusModeSupported:AVCaptureFocusModeContinuousAutoFocus]) {
      device.focusMode = AVCaptureFocusModeContinuousAutoFocus;
    }
    [device unlockForConfiguration];
  }

  AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&localError];
  if (input == nil) {
    if (errorOut != NULL) {
      *errorOut = localError;
    }
    return nil;
  }

  AVCaptureSession *session = [[AVCaptureSession alloc] init];
  session.sessionPreset = AVCaptureSessionPresetPhoto;

  AVCaptureVideoDataOutput *videoOutput = [[AVCaptureVideoDataOutput alloc] init];
  videoOutput.alwaysDiscardsLateVideoFrames = YES;
  videoOutput.videoSettings = @{
    (id)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
  };

  if (![session canAddInput:input] || ![session canAddOutput:videoOutput]) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1007
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Failed to configure camera capture session."
                                  }];
    }
    return nil;
  }

  [session addInput:input];
  [session addOutput:videoOutput];

  dispatch_queue_t frameQueue = dispatch_queue_create("qp.video.frame", DISPATCH_QUEUE_SERIAL);
  QPVideoFrameCaptureDelegate *delegate = [[QPVideoFrameCaptureDelegate alloc] init];
  [videoOutput setSampleBufferDelegate:delegate queue:frameQueue];

  AVCaptureConnection *videoConnection = [videoOutput connectionWithMediaType:AVMediaTypeVideo];
  if (videoConnection != nil && videoConnection.isVideoMirroringSupported &&
      device.position == AVCaptureDevicePositionFront) {
    videoConnection.videoMirrored = YES;
  }

  [session startRunning];
  QPWarmUpCaptureSession(session);
  QPWarmUpAutoExposure(device);

  // Keep the run loop alive so capture callbacks can fire even if AVFoundation uses this thread.
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:15.0];
  while (!delegate.finished && [deadline timeIntervalSinceNow] > 0) {
    [[NSRunLoop currentRunLoop] runMode:NSDefaultRunLoopMode
                             beforeDate:[NSDate dateWithTimeIntervalSinceNow:0.05]];
  }
  [videoOutput setSampleBufferDelegate:nil queue:NULL];
  [session stopRunning];

  if (!delegate.finished) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1008
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Capture timed out."
                                  }];
    }
    return nil;
  }

  if (delegate.captureError != nil) {
    if (errorOut != NULL) {
      *errorOut = delegate.captureError;
    }
    return nil;
  }

  if (delegate.jpegData == nil) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QuickPhoto"
                                      code:1012
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : @"Capture completed without a valid frame."
                                  }];
    }
    return nil;
  }

  return delegate.jpegData;
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
    if (!QPParseArgs(argc, argv, &delay, &savePath, &cameraList, &error)) {
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

    NSData *photoData = QPCapturePhotoData(&error);
    if (photoData == nil) {
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
