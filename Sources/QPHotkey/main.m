#import <AppKit/AppKit.h>
#import <Carbon/Carbon.h>
#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, QPMode) {
  QPModeDaemon = 0,
  QPModeRunOnce = 1,
  QPModeSelfTestHotkey = 2,
  QPModeHelp = 3,
};

static NSString *gQuickPhotoPath = nil;
static dispatch_queue_t gCaptureQueue = nil;
static dispatch_semaphore_t gCaptureLock = nil;
static EventHotKeyRef gHotKeyRef = NULL;
static EventHandlerRef gHotKeyHandlerRef = NULL;
static CFMachPortRef gEventTap = NULL;
static CFRunLoopSourceRef gEventTapRunLoopSource = NULL;
static const OSType QPHotKeySignature = 'QPHK';
static const UInt32 QPHotKeyID = 1;

static void QPPrintUsage(void) {
  printf("QP Hotkey Helper\n");
  printf("Usage: qp-hotkey [--qp-path <path>] [--run-once] [--self-test-hotkey] [--help]\n");
  printf("  --qp-path <path>      Path to QuickPhoto launcher (default: ./qp)\n");
  printf("  --run-once            Trigger one capture immediately and exit\n");
  printf("  --self-test-hotkey    Register and unregister Option+Space once, then exit\n");
  printf("  --help                Show help\n");
}

static BOOL QPPathIsExecutable(NSString *path) {
  if (path.length == 0) {
    return NO;
  }
  return [[NSFileManager defaultManager] isExecutableFileAtPath:path];
}

static int QPRunQuickPhotoCapture(void) {
  NSError *error = nil;
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:gQuickPhotoPath];
  task.standardOutput = [NSFileHandle fileHandleWithStandardOutput];
  task.standardError = [NSFileHandle fileHandleWithStandardError];

  if (![task launchAndReturnError:&error]) {
    fprintf(stderr, "QP Hotkey error: cannot launch %s (%s)\n", gQuickPhotoPath.UTF8String,
            error.localizedDescription.UTF8String);
    return 127;
  }

  [task waitUntilExit];
  return task.terminationStatus;
}

static void QPTriggerCaptureAsync(void) {
  fprintf(stderr, "QP Hotkey: trigger received.\n");
  if (dispatch_semaphore_wait(gCaptureLock, DISPATCH_TIME_NOW) != 0) {
    // Ignore repeated key presses while a capture is already in flight.
    fprintf(stderr, "QP Hotkey: capture already in progress, ignoring key press.\n");
    return;
  }

  dispatch_async(gCaptureQueue, ^{
    @autoreleasepool {
      int exitCode = QPRunQuickPhotoCapture();
      if (exitCode != 0) {
        fprintf(stderr, "QP Hotkey: capture command exited with code %d\n", exitCode);
      } else {
        fprintf(stderr, "QP Hotkey: capture command completed successfully.\n");
      }
      dispatch_semaphore_signal(gCaptureLock);
    }
  });
}

static OSStatus QPHotKeyHandler(EventHandlerCallRef nextHandler, EventRef event, void *userData) {
  EventHotKeyID hotKeyID;
  OSStatus status = GetEventParameter(event, kEventParamDirectObject, typeEventHotKeyID, NULL,
                                      sizeof(hotKeyID), NULL, &hotKeyID);
  if (status != noErr) {
    return status;
  }

  if (hotKeyID.signature == QPHotKeySignature && hotKeyID.id == QPHotKeyID) {
    QPTriggerCaptureAsync();
    return noErr;
  }

  return eventNotHandledErr;
}

static BOOL QPIsOptionSpaceEvent(CGEventRef event) {
  int64_t keycode = CGEventGetIntegerValueField(event, kCGKeyboardEventKeycode);
  CGEventFlags flags = CGEventGetFlags(event);
  CGEventFlags required = kCGEventFlagMaskAlternate;
  CGEventFlags disallowed = kCGEventFlagMaskCommand | kCGEventFlagMaskControl;

  if (keycode != kVK_Space) {
    return NO;
  }
  if ((flags & required) == 0) {
    return NO;
  }
  if ((flags & disallowed) != 0) {
    return NO;
  }
  return YES;
}

static CGEventRef QPEventTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event,
                                     void *userInfo) {
  if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
    if (gEventTap != NULL) {
      CGEventTapEnable(gEventTap, true);
    }
    return event;
  }

  if (type == kCGEventKeyDown && QPIsOptionSpaceEvent(event)) {
    QPTriggerCaptureAsync();
  }
  return event;
}

static BOOL QPStartEventTapFallback(NSError **errorOut) {
  CGEventMask mask = CGEventMaskBit(kCGEventKeyDown);
  gEventTap = CGEventTapCreate(kCGSessionEventTap, kCGHeadInsertEventTap, kCGEventTapOptionListenOnly,
                               mask, QPEventTapCallback, NULL);
  if (gEventTap == NULL) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QPHotkey"
                                      code:2005
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        @"Could not create event tap fallback. Grant Accessibility permission to this helper if needed."
                                  }];
    }
    return NO;
  }

  gEventTapRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, gEventTap, 0);
  CFRunLoopAddSource(CFRunLoopGetCurrent(), gEventTapRunLoopSource, kCFRunLoopCommonModes);
  CGEventTapEnable(gEventTap, true);
  return YES;
}

static void QPStopEventTapFallback(void) {
  if (gEventTapRunLoopSource != NULL) {
    CFRunLoopRemoveSource(CFRunLoopGetCurrent(), gEventTapRunLoopSource, kCFRunLoopCommonModes);
    CFRelease(gEventTapRunLoopSource);
    gEventTapRunLoopSource = NULL;
  }
  if (gEventTap != NULL) {
    CFRelease(gEventTap);
    gEventTap = NULL;
  }
}

static BOOL QPRegisterHotKey(NSError **errorOut) {
  EventTypeSpec eventType = {kEventClassKeyboard, kEventHotKeyPressed};
  OSStatus status = InstallApplicationEventHandler(&QPHotKeyHandler, 1, &eventType, NULL,
                                                   &gHotKeyHandlerRef);
  if (status != noErr) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QPHotkey"
                                      code:2001
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        [NSString stringWithFormat:@"InstallApplicationEventHandler failed (%d)", (int)status]
                                  }];
    }
    return NO;
  }

  EventHotKeyID hotKeyID = {QPHotKeySignature, QPHotKeyID};
  status = RegisterEventHotKey((UInt32)kVK_Space, optionKey, hotKeyID, GetApplicationEventTarget(),
                               0, &gHotKeyRef);
  if (status != noErr) {
    if (errorOut != NULL) {
      *errorOut = [NSError errorWithDomain:@"QPHotkey"
                                      code:2002
                                  userInfo:@{
                                    NSLocalizedDescriptionKey :
                                        [NSString stringWithFormat:@"RegisterEventHotKey failed (%d). Option+Space may already be in use.", (int)status]
                                  }];
    }
    return NO;
  }

  return YES;
}

static void QPUnregisterHotKey(void) {
  if (gHotKeyRef != NULL) {
    UnregisterEventHotKey(gHotKeyRef);
    gHotKeyRef = NULL;
  }
  if (gHotKeyHandlerRef != NULL) {
    RemoveEventHandler(gHotKeyHandlerRef);
    gHotKeyHandlerRef = NULL;
  }
}

static NSString *QPDefaultQuickPhotoPath(void) {
  NSString *cwd = [[NSFileManager defaultManager] currentDirectoryPath];
  return [cwd stringByAppendingPathComponent:@"qp"];
}

static BOOL QPParseArgs(int argc, const char *argv[], NSString **pathOut, QPMode *modeOut,
                        NSError **errorOut) {
  NSString *qpPath = nil;
  QPMode mode = QPModeDaemon;

  for (int i = 1; i < argc; i++) {
    const char *arg = argv[i];
    if (strcmp(arg, "--help") == 0 || strcmp(arg, "-h") == 0) {
      mode = QPModeHelp;
      continue;
    }
    if (strcmp(arg, "--run-once") == 0) {
      mode = QPModeRunOnce;
      continue;
    }
    if (strcmp(arg, "--self-test-hotkey") == 0) {
      mode = QPModeSelfTestHotkey;
      continue;
    }
    if (strcmp(arg, "--qp-path") == 0) {
      if (i + 1 >= argc) {
        if (errorOut != NULL) {
          *errorOut = [NSError errorWithDomain:@"QPHotkey"
                                          code:2003
                                      userInfo:@{
                                        NSLocalizedDescriptionKey : @"Missing value for --qp-path."
                                      }];
        }
        return NO;
      }
      qpPath = [NSString stringWithUTF8String:argv[++i]];
      continue;
    }

    if (errorOut != NULL) {
      NSString *message = [NSString stringWithFormat:@"Unknown argument: %s", arg];
      *errorOut = [NSError errorWithDomain:@"QPHotkey"
                                      code:2004
                                  userInfo:@{
                                    NSLocalizedDescriptionKey : message
                                  }];
    }
    return NO;
  }

  if (qpPath == nil) {
    qpPath = QPDefaultQuickPhotoPath();
  }

  *pathOut = qpPath;
  *modeOut = mode;
  return YES;
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    setvbuf(stdout, NULL, _IONBF, 0);
    setvbuf(stderr, NULL, _IONBF, 0);

    NSError *error = nil;
    QPMode mode = QPModeDaemon;
    NSString *qpPath = nil;

    if (!QPParseArgs(argc, argv, &qpPath, &mode, &error)) {
      fprintf(stderr, "QP Hotkey error: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }

    if (mode == QPModeHelp) {
      QPPrintUsage();
      return 0;
    }

    gQuickPhotoPath = [qpPath copy];
    if (!QPPathIsExecutable(gQuickPhotoPath)) {
      fprintf(stderr, "QP Hotkey error: %s is not executable.\n", gQuickPhotoPath.UTF8String);
      return 1;
    }

    if (mode == QPModeRunOnce) {
      return QPRunQuickPhotoCapture();
    }

    NSApplication *app = [NSApplication sharedApplication];
    [app setActivationPolicy:NSApplicationActivationPolicyProhibited];
    gCaptureQueue = dispatch_queue_create("quickphoto.hotkey.capture", DISPATCH_QUEUE_SERIAL);
    gCaptureLock = dispatch_semaphore_create(1);

    BOOL usingCarbonHotKey = QPRegisterHotKey(&error);
    if (!usingCarbonHotKey) {
      NSError *fallbackError = nil;
      if (!QPStartEventTapFallback(&fallbackError)) {
        fprintf(stderr, "QP Hotkey error: %s\n", error.localizedDescription.UTF8String);
        if (fallbackError != nil) {
          fprintf(stderr, "QP Hotkey fallback error: %s\n",
                  fallbackError.localizedDescription.UTF8String);
        }
        return 1;
      }
      fprintf(stderr, "QP Hotkey: Carbon registration failed (%s), using event-tap fallback.\n",
              error.localizedDescription.UTF8String);
    }

    if (mode == QPModeSelfTestHotkey) {
      if (usingCarbonHotKey) {
        printf("QP Hotkey self-test passed: Option+Space registered via Carbon hotkey API.\n");
      } else {
        printf("QP Hotkey self-test passed: Option+Space monitored via event-tap fallback.\n");
      }
      QPUnregisterHotKey();
      QPStopEventTapFallback();
      return 0;
    }

    printf("QP Hotkey active: press Option+Space to capture (%s).\n",
           usingCarbonHotKey ? "Carbon" : "event-tap fallback");
    printf("Using QuickPhoto command: %s\n", gQuickPhotoPath.UTF8String);
    [app run];
    QPUnregisterHotKey();
    QPStopEventTapFallback();
    return 0;
  }
}
