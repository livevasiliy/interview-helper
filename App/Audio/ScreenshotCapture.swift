import AppKit
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenshotError: Error, LocalizedError {
    case unsupportedSystem
    case noDisplay
    case encodingFailed
    case underlying(Error)

    var errorDescription: String? {
        switch self {
        case .unsupportedSystem: return tr("Screenshots need macOS 14 or newer.")
        case .noDisplay: return tr("No display found to take a screenshot of.")
        case .encodingFailed: return tr("The screenshot could not be encoded.")
        case .underlying(let error): return error.localizedDescription
        }
    }
}

/// Takes one screenshot of the display under the mouse cursor, without this app's own windows
/// (so the overlay never covers the task), scaled down and JPEG-encoded for the vision model.
enum ScreenshotCapture {
    /// Long edge in pixels: enough to read code, small enough to upload quickly.
    static let maxEdge = 1_800
    static let jpegQuality = 0.72

    static func captureJPEG() async throws -> Data {
        guard #available(macOS 14.0, *) else { throw ScreenshotError.unsupportedSystem }
        return try await capture()
    }

    @available(macOS 14.0, *)
    private static func capture() async throws -> Data {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            throw ScreenshotError.underlying(error)
        }
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? NSScreen.main
        let displayID = (screen?.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
        guard let display = content.displays.first(where: { $0.displayID == displayID }) ?? content.displays.first else {
            throw ScreenshotError.noDisplay
        }
        let ours = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: ours, exceptingWindows: [])

        let config = SCStreamConfiguration()
        let scale = min(1, Double(maxEdge) / Double(max(display.width, display.height)))
        config.width = max(1, Int(Double(display.width) * scale))
        config.height = max(1, Int(Double(display.height) * scale))
        config.showsCursor = false

        let image: CGImage
        do {
            image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
        } catch {
            throw ScreenshotError.underlying(error)
        }
        return try encodeJPEG(image)
    }

    private static func encodeJPEG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else {
            throw ScreenshotError.encodingFailed
        }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: jpegQuality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotError.encodingFailed }
        return data as Data
    }
}
