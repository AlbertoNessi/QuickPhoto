import AppKit
import AVFoundation
import Foundation

@main
struct QuickPhoto {
    static func main() {
        do {
            let options = try CLIOptions.parse(CommandLine.arguments.dropFirst())

            if options.showHelp {
                printUsage()
                return
            }

            if options.delaySeconds > 0 {
                for second in stride(from: options.delaySeconds, through: 1, by: -1) {
                    print("Capturing in \(second)...")
                    Thread.sleep(forTimeInterval: 1)
                }
            }

            let data = try CameraCapture().capturePhotoData()
            guard let image = NSImage(data: data) else {
                throw QuickPhotoError.captureFailed("Captured data is not a valid image.")
            }

            try Clipboard.write(image: image)

            print("Photo copied to clipboard.")
            print("Tip: paste now with Cmd+V in another app.")
        } catch let error as QuickPhotoError {
            fputs("QuickPhoto error: \(error.description)\n", stderr)
            exit(1)
        } catch {
            fputs("QuickPhoto error: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func printUsage() {
        print(
            """
            QuickPhoto (qp)
            Usage: qp [--delay <seconds>] [--help]

            Options:
              --delay <seconds>  Wait before capturing. Default: 0
              --help             Show this help

            Notes:
              - Requires camera access.
              - If permission is denied, enable camera for your terminal app in:
                System Settings > Privacy & Security > Camera
            """
        )
    }
}

struct CLIOptions {
    let delaySeconds: Int
    let showHelp: Bool

    static func parse(_ args: ArraySlice<String>) throws -> CLIOptions {
        var delay = 0
        var help = false
        var index = args.startIndex

        while index < args.endIndex {
            let arg = args[index]
            switch arg {
            case "--help", "-h":
                help = true
                index = args.index(after: index)
            case "--delay":
                let next = args.index(after: index)
                guard next < args.endIndex else {
                    throw QuickPhotoError.invalidArguments("Missing value for --delay.")
                }
                guard let parsed = Int(args[next]), parsed >= 0 else {
                    throw QuickPhotoError.invalidArguments("--delay must be a non-negative integer.")
                }
                delay = parsed
                index = args.index(after: next)
            default:
                throw QuickPhotoError.invalidArguments("Unknown argument: \(arg)")
            }
        }

        return CLIOptions(delaySeconds: delay, showHelp: help)
    }
}

enum QuickPhotoError: Error {
    case invalidArguments(String)
    case permissionDenied
    case cameraUnavailable
    case configurationFailed(String)
    case captureFailed(String)
    case captureTimeout
    case clipboardFailed

    var description: String {
        switch self {
        case .invalidArguments(let message):
            return message
        case .permissionDenied:
            return "Camera permission denied."
        case .cameraUnavailable:
            return "No camera device available."
        case .configurationFailed(let message):
            return message
        case .captureFailed(let message):
            return message
        case .captureTimeout:
            return "Capture timed out."
        case .clipboardFailed:
            return "Failed to write image to clipboard."
        }
    }
}

final class CameraCapture {
    private let session = AVCaptureSession()
    private let output = AVCapturePhotoOutput()

    func capturePhotoData() throws -> Data {
        guard ensurePermission() else {
            throw QuickPhotoError.permissionDenied
        }

        guard let device = AVCaptureDevice.default(for: .video) else {
            throw QuickPhotoError.cameraUnavailable
        }

        let input: AVCaptureDeviceInput
        do {
            input = try AVCaptureDeviceInput(device: device)
        } catch {
            throw QuickPhotoError.configurationFailed("Failed to create camera input: \(error.localizedDescription)")
        }

        session.beginConfiguration()
        session.sessionPreset = .photo

        guard session.canAddInput(input) else {
            session.commitConfiguration()
            throw QuickPhotoError.configurationFailed("Cannot add camera input to capture session.")
        }
        session.addInput(input)

        guard session.canAddOutput(output) else {
            session.commitConfiguration()
            throw QuickPhotoError.configurationFailed("Cannot add photo output to capture session.")
        }
        session.addOutput(output)
        session.commitConfiguration()

        session.startRunning()
        defer { session.stopRunning() }

        let delegate = PhotoCaptureDelegate()
        let settings = AVCapturePhotoSettings()
        output.capturePhoto(with: settings, delegate: delegate)

        return try delegate.waitForData(timeout: 15)
    }

    private func ensurePermission() -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .video)
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            let semaphore = DispatchSemaphore(value: 0)
            var granted = false
            AVCaptureDevice.requestAccess(for: .video) { isGranted in
                granted = isGranted
                semaphore.signal()
            }
            _ = semaphore.wait(timeout: .now() + 60)
            return granted
        default:
            return false
        }
    }
}

final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    private let semaphore = DispatchSemaphore(value: 0)
    private var result: Result<Data, Error>?
    private var finished = false

    func waitForData(timeout: TimeInterval) throws -> Data {
        let waitResult = semaphore.wait(timeout: .now() + timeout)
        guard waitResult == .success else {
            throw QuickPhotoError.captureTimeout
        }
        guard let result else {
            throw QuickPhotoError.captureFailed("No image was captured.")
        }
        return try result.get()
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        if let error {
            finish(.failure(QuickPhotoError.captureFailed(error.localizedDescription)))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            finish(.failure(QuickPhotoError.captureFailed("Could not build photo data representation.")))
            return
        }
        finish(.success(data))
    }

    func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishCaptureFor resolvedSettings: AVCaptureResolvedPhotoSettings,
        error: Error?
    ) {
        if let error {
            finish(.failure(QuickPhotoError.captureFailed(error.localizedDescription)))
        }
    }

    private func finish(_ outcome: Result<Data, Error>) {
        guard !finished else { return }
        finished = true
        result = outcome
        semaphore.signal()
    }
}

enum Clipboard {
    static func write(image: NSImage) throws {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.writeObjects([image]) else {
            throw QuickPhotoError.clipboardFailed
        }
    }
}
