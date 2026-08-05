/// Screenshot capture modes.
///
/// Area/window use `/usr/sbin/screencapture` interactive flags.
/// Full-page uses scroll + stitch (see `FullPageScreenshotCapture`); screen APIs alone cannot see offscreen pixels.
public enum ScreenshotCaptureMode: String, Sendable, CaseIterable, Equatable {
    case area
    case window
    case fullPage

    public var menuTitle: String {
        switch self {
        case .area:
            return "Capture Area"
        case .window:
            return "Capture Window"
        case .fullPage:
            return "Capture Scrolling Page"
        }
    }

    public var statusMessage: String {
        switch self {
        case .area:
            return "Select screenshot area"
        case .window:
            return "Hover a window, then click to capture"
        case .fullPage:
            return "Hover a window, then click to capture scrolling page"
        }
    }

    /// Short label shown on the hover target overlay.
    public var hoverLabel: String {
        switch self {
        case .area:
            return "Area"
        case .window:
            return "Window"
        case .fullPage:
            return "Scrolling page"
        }
    }

    /// Interactive `screencapture` args for area mode only.
    /// Window / full-page use ClipVault's hover picker (native `-J window` has no mode label).
    public var screencaptureArguments: [String]? {
        // ponytail: shell out to system screencapture; ScreenCaptureKit if App Review rejects the binary.
        switch self {
        case .area:
            return ["-i", "-c", "-J", "selection"]
        case .window, .fullPage:
            return nil
        }
    }
}
