# QuickPhoto (QP)

QuickPhoto is a native macOS tool that captures one photo from your MacBook built-in camera and puts it in the clipboard, so you can paste it immediately with `Cmd+V` in other apps.

No third-party dependencies are used. It is built with Apple frameworks only (`AppKit`, `AVFoundation`, `CoreImage`, `Carbon`).

This project was fully developed by Codex with my supervision.

## Main features

- One-shot capture to clipboard
- Built-in camera selection (ignores external camera devices)
- Optional countdown (`--delay`)
- Optional save to JPEG for diagnostics (`--save`)
- Camera diagnostics (`--camera-list`)
- Global hotkey daemon (`Option + Space`)

## Requirements

- macOS
- Xcode Command Line Tools

Install command line tools (if not installed):

```bash
xcode-select --install
```

## Setup on a new Mac

1. Put this project folder on your Mac (for example `~/Projects/QuickPhoto`).
2. Open Terminal.
3. Go to the project root:

```bash
cd /path/to/QuickPhoto
```

## Run QuickPhoto

```bash
./qp
```

`qp` compiles and runs the native Objective-C capture binary.

## Recommended first verification

1. Check detected cameras:

```bash
./qp --camera-list
```

2. Capture one diagnostic file:

```bash
./qp --delay 1 --save /tmp/qp-capture.jpg
open /tmp/qp-capture.jpg
```

3. Run normal clipboard flow:

```bash
./qp
```

Paste in another app with `Cmd+V`.

## CLI commands

Show help:

```bash
./qp --help
```

Delay before capture:

```bash
./qp --delay 3
```

Save captured image:

```bash
./qp --save /tmp/qp-capture.jpg
```

Camera list and selected built-in camera:

```bash
./qp --camera-list
```

## Global shortcut (`Option + Space`)

Install and start the LaunchAgent daemon:

```bash
./install-qp-hotkey
```

After install, pressing `Option + Space` triggers a capture.

Uninstall daemon:

```bash
./uninstall-qp-hotkey
```

Hotkey self-test:

```bash
./qp-hotkey --self-test-hotkey
```

Check daemon status:

```bash
launchctl print gui/$(id -u)/com.quickphoto.hotkey
```

Hotkey logs:

- `~/Library/Logs/com.quickphoto.hotkey.out.log`
- `~/Library/Logs/com.quickphoto.hotkey.err.log`

## Permissions

Camera permission:

- `System Settings > Privacy & Security > Camera`
- Allow access for the app/process invoking capture.

Accessibility permission (only if fallback hotkey mode is needed):

- `System Settings > Privacy & Security > Accessibility`
- Allow access for `qp-hotkey`.

## Troubleshooting

Hotkey does nothing:

1. Reinstall daemon:
   `./uninstall-qp-hotkey && ./install-qp-hotkey`
2. Check logs:
   `tail -f ~/Library/Logs/com.quickphoto.hotkey.out.log ~/Library/Logs/com.quickphoto.hotkey.err.log`
3. Check conflicting keyboard shortcuts in:
   `System Settings > Keyboard > Keyboard Shortcuts`

Image is black:

1. Verify selected device:
   `./qp --camera-list`
2. Save to file and inspect in Preview:
   `./qp --delay 1 --save /tmp/qp-capture.jpg && open /tmp/qp-capture.jpg`
3. Close other camera apps and retry.

Permission denied:

1. Grant camera permission in System Settings.
2. Retry `./qp`.

## Project structure

- `qp`: QuickPhoto launcher/build script
- `qp-hotkey`: hotkey helper launcher/build script
- `install-qp-hotkey`: installs LaunchAgent daemon
- `uninstall-qp-hotkey`: removes LaunchAgent daemon
- `Sources/QuickPhotoObjC/main.m`: capture + clipboard implementation
- `Sources/QPHotkey/main.m`: global hotkey daemon implementation
