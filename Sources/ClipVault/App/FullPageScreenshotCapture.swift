import AppKit
import ApplicationServices
import ClipVaultCore
import CoreGraphics
import Foundation
import OSLog
import ScreenCaptureKit
import Security

/// Scroll + stitch full-page capture for a chosen (or frontmost) non-ClipVault window.
///
/// Prefer browser JS scroll (Chrome family / Safari) via Apple Events; fall back to
/// Accessibility scroll-wheel events. Screen APIs only ever see the visible framebuffer.
///
/// Limits / failure modes (ponytail ceilings):
/// - sticky headers and lazy-loaded content can duplicate or leave gaps
/// - Chrome/Safari need "Allow JavaScript from Apple Events" for the JS path
/// - max 40 frames / ~16k canvas height — raise if real pages need more
@MainActor
enum FullPageScreenshotCapture {
    enum Outcome: Equatable {
        case success
        case cancelled
        case failure(String)
    }

    private static let logger = Logger(subsystem: "com.andrzej.ClipVault", category: "FullPageCapture")
    private static let maxFrames = 40
    private static let maxCanvasHeight = 16_384
    private static let settleNanoseconds: UInt64 = 280_000_000
    private static let clipVaultBundlePrefix = "com.andrzej.ClipVault"

    static func capture(targetPickerTarget: CaptureTargetPicker.Target) async -> Outcome {
        await capture(
            target: TargetWindow(
                windowID: targetPickerTarget.windowID,
                bundleID: targetPickerTarget.bundleID,
                bounds: targetPickerTarget.bounds,
                pid: targetPickerTarget.pid,
                ownerName: targetPickerTarget.ownerName
            )
        )
    }

    static func capture(target: TargetWindow) async -> Outcome {
        if let denial = await ScreenRecordingAccess.ensureReady() {
            return .failure(denial)
        }

        NSRunningApplication(processIdentifier: target.pid)?.activate()
        try? await Task.sleep(nanoseconds: settleNanoseconds)

        let browser = BrowserScroller.kind(for: target.bundleID)
        var lastAutomationError: String?
        var useJS = false

        if let browser {
            let ping = BrowserScroller.ping(bundleID: target.bundleID)
            if let error = ping.error {
                lastAutomationError = error
                logger.error("Automation ping failed: \(error, privacy: .public)")
            }
            let scrolledTop = BrowserScroller.scrollTo(bundleID: target.bundleID, kind: browser, y: 0)
            if scrolledTop.value == true {
                useJS = true
            } else if let error = scrolledTop.error {
                lastAutomationError = error
                logger.error("JS scroll failed: \(error, privacy: .public)")
            }
        }

        var pageMetrics: BrowserScroller.Metrics?
        if let browser {
            let result = BrowserScroller.metrics(bundleID: target.bundleID, kind: browser)
            pageMetrics = result.value
            if result.value == nil, let error = result.error {
                lastAutomationError = error
                logger.error("JS metrics failed: \(error, privacy: .public)")
            }
            if pageMetrics != nil {
                useJS = true
            }
        }

        // Short page: one frame is enough.
        let pageIsShort = pageMetrics.map { $0.scrollHeight <= $0.clientHeight + 2 } ?? false
        let knownLongPage = pageMetrics.map { $0.scrollHeight > $0.clientHeight + 2 } ?? false

        if !useJS {
            requestAccessibilityIfNeeded()
            if !AXIsProcessTrusted() && !pageIsShort {
                return .failure(permissionFailureMessage(
                    browserBundleID: browser != nil ? target.bundleID : nil,
                    ownerName: target.ownerName,
                    automationError: lastAutomationError,
                    needsAccessibility: true
                ))
            }
            ScrollEventPoster.scrollPixels(-2_000, around: target.bounds)
            try? await Task.sleep(nanoseconds: settleNanoseconds)
        }

        var pngFrames: [Data] = []
        var previousPNG: Data?
        var stepCSS = 0
        var estimatedHeight = 0
        let scale = targetScaleFactor(for: target.bounds)

        var lastCaptureError: String?
        for frameIndex in 0..<maxFrames {
            let frameResult = await captureWindowPNG(windowID: target.windowID, bounds: target.bounds)
            guard var png = frameResult.data else {
                lastCaptureError = frameResult.error
                logger.error("Window capture failed at frame \(frameIndex): \(frameResult.error ?? "unknown", privacy: .public)")
                if pngFrames.isEmpty {
                    if await ScreenRecordingAccess.hasShareableContent() == false {
                        return .failure(ScreenRecordingAccess.denialMessage())
                    }
                    return .failure(
                        lastCaptureError
                            ?? "Could not capture window \(target.windowID) (\(target.ownerName))."
                    )
                }
                break
            }

            // Crop browser chrome so tab bars are not duplicated while stitching.
            if let metrics = pageMetrics, metrics.clientHeight > 0,
               let cropped = cropBrowserChrome(png: png, clientHeightCSS: metrics.clientHeight, scale: scale) {
                png = cropped
            }

            if let previousPNG, ImageStitcher.areVisuallyIdentical(previousPNG, png) {
                break
            }

            pngFrames.append(png)
            previousPNG = png
            let imageHeight = pngImageHeight(png) ?? Int(target.bounds.height)
            estimatedHeight += frameIndex == 0 ? imageHeight : Int(Double(imageHeight) * 0.85)
            if estimatedHeight > maxCanvasHeight {
                break
            }

            if pageIsShort {
                break
            }

            if stepCSS == 0 {
                if let metrics = pageMetrics, metrics.clientHeight > 0 {
                    stepCSS = max(Int(Double(metrics.clientHeight) * 0.8), 1)
                } else {
                    stepCSS = max(Int(Double(imageHeight) * 0.8), 1)
                }
            }

            if useJS, let browser, let metrics = pageMetrics {
                let maxScroll = max(metrics.scrollHeight - metrics.clientHeight, 0)
                let nextScrollY = min(metrics.scrollY + stepCSS, maxScroll)
                if nextScrollY <= metrics.scrollY {
                    break
                }
                let scrolledOK = BrowserScroller.scrollTo(bundleID: target.bundleID, kind: browser, y: nextScrollY)
                if scrolledOK.value != true {
                    if let error = scrolledOK.error {
                        lastAutomationError = error
                    }
                    useJS = false
                    pageMetrics = nil
                    requestAccessibilityIfNeeded()
                    if !AXIsProcessTrusted() {
                        break
                    }
                    ScrollEventPoster.scrollPixels(stepCSS, around: target.bounds)
                }
            } else {
                if !AXIsProcessTrusted() {
                    requestAccessibilityIfNeeded()
                    if !AXIsProcessTrusted() {
                        break
                    }
                }
                ScrollEventPoster.scrollPixels(stepCSS, around: target.bounds)
            }

            try? await Task.sleep(nanoseconds: settleNanoseconds)

            if useJS, let browser {
                pageMetrics = BrowserScroller.metrics(bundleID: target.bundleID, kind: browser).value
            }
        }

        guard !pngFrames.isEmpty else {
            let detail = lastCaptureError.map { " (\($0))" } ?? ""
            return .failure("No frames captured from \(target.ownerName).\(detail)")
        }

        if pngFrames.count == 1, knownLongPage {
            // Metrics said the page scrolls, but we only ever got one viewport.
            return .failure(permissionFailureMessage(
                browserBundleID: browser != nil ? target.bundleID : nil,
                ownerName: target.ownerName,
                automationError: lastAutomationError,
                needsAccessibility: true
            ))
        }

        do {
            let stitched = try ImageStitcher.stitchScrollingCapture(pngFrames: pngFrames)
            guard let image = NSImage(data: stitched) else {
                return .failure("Stitched image could not be read.")
            }
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            let wrote = pasteboard.writeObjects([image])
            logger.info("Full-page capture frames=\(pngFrames.count) wrote=\(wrote)")
            return wrote ? .success : .failure("Could not write image to the clipboard.")
        } catch {
            logger.error("Stitch failed: \(error.localizedDescription, privacy: .public)")
            return .failure("Could not stitch scrolling frames: \(error.localizedDescription)")
        }
    }

    struct TargetWindow {
        let windowID: CGWindowID
        let bundleID: String
        let bounds: CGRect
        let pid: pid_t
        let ownerName: String
    }

    private static func permissionFailureMessage(
        browserBundleID: String?,
        ownerName: String,
        automationError: String?,
        needsAccessibility: Bool
    ) -> String {
        let appPath = Bundle.main.bundlePath
        let isAdHoc = (Bundle.main.infoDictionary?["AppSigningIdentity"] as? String) == nil
            && {
                // Team ID absent ⇒ ad-hoc / unsigned; TCC grants reset on rebuild.
                var code: SecStaticCode?
                SecStaticCodeCreateWithPath(URL(fileURLWithPath: appPath) as CFURL, [], &code)
                guard let code else { return true }
                var info: CFDictionary?
                SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info)
                let team = (info as? [String: Any])?["teamid"] as? String
                return team == nil || team?.isEmpty == true
            }()

        var parts: [String] = []
        if let automationError, automationError.localizedCaseInsensitiveContains("JavaScript") {
            parts.append(
                "Enable “Allow JavaScript from Apple Events” in the browser Develop menu, then retry."
            )
        } else if let browserBundleID {
            parts.append(
                "Could not scroll \(ownerName) via Automation. Grant ClipVault control of that browser in System Settings → Privacy & Security → Automation."
            )
            _ = browserBundleID
        } else {
            parts.append("Could not scroll \(ownerName).")
        }
        if needsAccessibility {
            parts.append(
                "Enable ClipVault under Accessibility (System Settings → Privacy & Security → Accessibility)."
            )
        }
        if isAdHoc {
            parts.append(
                "This build is ad-hoc signed — after each rebuild, remove ClipVault from Automation/Accessibility and re-add \(appPath)."
            )
        } else {
            parts.append("Grant permissions for: \(appPath)")
        }
        if let automationError {
            parts.append("Detail: \(automationError)")
        }
        return parts.joined(separator: " ")
    }

    private struct CaptureFrameResult {
        var data: Data?
        var error: String?
    }

    /// Prefer ScreenCaptureKit (correct TCC for this process). Fall back to `screencapture -l`.
    private static func captureWindowPNG(windowID: CGWindowID, bounds: CGRect) async -> CaptureFrameResult {
        let viaSC = await captureWindowPNGViaScreenCaptureKit(windowID: windowID, bounds: bounds)
        if viaSC.data != nil {
            return viaSC
        }
        // Window missing from SC list is common for some apps — try screencapture before failing.
        if viaSC.error?.contains("not in shareable content") == true {
            let viaCLI = captureWindowPNGViaScreencapture(windowID: windowID)
            if viaCLI.data != nil {
                return viaCLI
            }
            return CaptureFrameResult(
                data: nil,
                error: [viaSC.error, viaCLI.error].compactMap { $0 }.joined(separator: " ")
            )
        }
        // Permission / SC failure: still try CLI in case SCShareableContent lied; keep both errors.
        let viaCLI = captureWindowPNGViaScreencapture(windowID: windowID)
        if viaCLI.data != nil {
            return viaCLI
        }
        return CaptureFrameResult(
            data: nil,
            error: [viaSC.error, viaCLI.error].compactMap { $0 }.joined(separator: " ")
        )
    }

    private static func captureWindowPNGViaScreenCaptureKit(
        windowID: CGWindowID,
        bounds: CGRect
    ) async -> CaptureFrameResult {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
                return CaptureFrameResult(
                    data: nil,
                    error: "Window \(windowID) not in shareable content (\(content.windows.count) windows listed)."
                )
            }
            let scale = targetScaleFactor(for: bounds)
            let filter = SCContentFilter(desktopIndependentWindow: window)
            let config = SCStreamConfiguration()
            config.width = max(Int(window.frame.width * scale), 1)
            config.height = max(Int(window.frame.height * scale), 1)
            config.showsCursor = false
            config.captureResolution = .best
            let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
            guard let png = pngData(from: image) else {
                return CaptureFrameResult(data: nil, error: "ScreenCaptureKit image could not be encoded as PNG.")
            }
            return CaptureFrameResult(data: png, error: nil)
        } catch {
            logger.error("ScreenCaptureKit capture failed: \(error.localizedDescription, privacy: .public)")
            return CaptureFrameResult(data: nil, error: "ScreenCaptureKit: \(error.localizedDescription)")
        }
    }

    private static func captureWindowPNGViaScreencapture(windowID: CGWindowID) -> CaptureFrameResult {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clipvault-fullpage-\(windowID)-\(UUID().uuidString).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        // -o omits window shadow so overlap matching stays stable.
        process.arguments = ["-x", "-o", "-l\(windowID)", url.path]
        let errPipe = Pipe()
        process.standardError = errPipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return CaptureFrameResult(data: nil, error: "Could not start screencapture: \(error.localizedDescription)")
        }
        defer { try? FileManager.default.removeItem(at: url) }
        let stderr = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            let detail = stderr.isEmpty ? "no stderr" : stderr
            return CaptureFrameResult(
                data: nil,
                error: "screencapture -l\(windowID) exited \(process.terminationStatus) (\(detail))."
            )
        }
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            return CaptureFrameResult(data: nil, error: "screencapture produced an empty file.")
        }
        return CaptureFrameResult(data: data, error: nil)
    }

    private static func pngData(from image: CGImage) -> Data? {
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func pngImageHeight(_ data: Data) -> Int? {
        guard data.count >= 24,
              data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 else {
            return nil
        }
        let height = (UInt32(data[20]) << 24)
            | (UInt32(data[21]) << 16)
            | (UInt32(data[22]) << 8)
            | UInt32(data[23])
        return Int(height)
    }

    private static func pngImageWidth(_ data: Data) -> Int? {
        guard data.count >= 24,
              data[1] == 0x50, data[2] == 0x4E, data[3] == 0x47 else {
            return nil
        }
        let width = (UInt32(data[16]) << 24)
            | (UInt32(data[17]) << 16)
            | (UInt32(data[18]) << 8)
            | UInt32(data[19])
        return Int(width)
    }

    private static func targetScaleFactor(for bounds: CGRect) -> CGFloat {
        let screen = NSScreen.screens.first { $0.frame.intersects(CaptureTargetPicker.cocoaFrame(fromQuartz: bounds)) }
            ?? NSScreen.main
        return screen?.backingScaleFactor ?? 2
    }

    /// Keep the webpage viewport; drop toolbar/tab strip above `clientHeight`.
    private static func cropBrowserChrome(png: Data, clientHeightCSS: Int, scale: CGFloat) -> Data? {
        guard let width = pngImageWidth(png),
              let height = pngImageHeight(png) else {
            return nil
        }
        let contentHeight = min(height, max(Int(CGFloat(clientHeightCSS) * scale), 1))
        let top = max(height - contentHeight, 0)
        guard top > 0, top < height else {
            return png
        }
        // ponytail: assumes chrome is only above the viewport (no bottom status bar crop).
        return cropPNG(png, x: 0, y: top, width: width, height: contentHeight)
    }

    private static func cropPNG(_ png: Data, x: Int, y: Int, width: Int, height: Int) -> Data? {
        guard let source = CGImageSourceCreateWithData(png as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let cropped = image.cropping(to: CGRect(x: x, y: y, width: width, height: height)) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output,
            "public.png" as CFString,
            1,
            nil
        ) else {
            return nil
        }
        CGImageDestinationAddImage(destination, cropped, nil)
        guard CGImageDestinationFinalize(destination) else {
            return nil
        }
        return output as Data
    }

    private static func requestAccessibilityIfNeeded() {
        // Literal key avoids Swift 6 shared-mutable CFStringRef diagnostics.
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Screen Recording TCC

/// Accurate Screen Recording gate. `CGPreflightScreenCaptureAccess` alone is not trustworthy:
/// it stays false until relaunch after a grant, and can disagree when another ClipVault binary
/// (different code-signing designated requirement) is the one enabled in System Settings.
enum ScreenRecordingAccess {
    /// Returns a user-facing denial message, or `nil` when capture is allowed.
    @MainActor
    static func ensureReady() async -> String? {
        if await hasShareableContent() {
            return nil
        }

        let preflightBefore = CGPreflightScreenCaptureAccess()
        _ = CGRequestScreenCaptureAccess()
        openSystemSettings()

        // Give the system prompt a moment; grant still requires quit+relaunch to take effect.
        try? await Task.sleep(nanoseconds: 400_000_000)

        if await hasShareableContent() {
            return nil
        }

        // Preflight flipped true mid-process ⇒ TCC recorded a grant, but this process
        // cannot use it until relaunch (classic ScreenCaptureKit invariant).
        if !preflightBefore, CGPreflightScreenCaptureAccess() {
            return """
            Screen Recording was just enabled for \(Bundle.main.bundlePath). \
            Fully quit ClipVault (⌘Q) and relaunch, then retry scrolling page capture.
            """
        }

        return denialMessage()
    }

    static func hasShareableContent() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            return true
        } catch {
            return false
        }
    }

    static func denialMessage() -> String {
        let path = Bundle.main.bundlePath
        return """
        Screen Recording permission is required for this running binary:
        \(path)

        In System Settings → Privacy & Security → Screen Recording, enable this ClipVault \
        (drag this .app in if another ClipVault copy is listed — /Applications and dist builds \
        are different identities when signing certificates differ). Then fully quit ClipVault (⌘Q) and relaunch.
        """
    }

    static func openSystemSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture",
            "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension?Privacy_ScreenCapture"
        ]
        for candidate in candidates {
            if let url = URL(string: candidate), NSWorkspace.shared.open(url) {
                return
            }
        }
    }
}

// MARK: - Browser JS scroll (Apple Events)

private enum BrowserScroller {
    enum Kind {
        case chromeFamily
        case safari
    }

    struct Metrics: Equatable {
        var scrollHeight: Int
        var clientHeight: Int
        var scrollY: Int
    }

    struct ScriptResult<T> {
        var value: T?
        var error: String?
    }

    static func kind(for bundleID: String) -> Kind? {
        switch bundleID {
        case "com.google.Chrome",
             "com.google.Chrome.canary",
             "com.brave.Browser",
             "com.microsoft.edgemac",
             "company.thebrowser.Browser",
             "org.chromium.Chromium",
             "com.operasoftware.Opera",
             "com.vivaldi.Vivaldi":
            return .chromeFamily
        case "com.apple.Safari":
            return .safari
        default:
            return nil
        }
    }

    static func ping(bundleID: String) -> ScriptResult<String> {
        run(script: "tell application id \"\(bundleID)\" to get name")
    }

    static func metrics(bundleID: String, kind: Kind) -> ScriptResult<Metrics> {
        let js = """
        (function(){
          var se = document.scrollingElement || document.documentElement;
          return JSON.stringify({
            scrollHeight: Math.max(se.scrollHeight||0, document.documentElement.scrollHeight||0, document.body?document.body.scrollHeight:0),
            clientHeight: window.innerHeight||document.documentElement.clientHeight||0,
            scrollY: window.scrollY||window.pageYOffset||0
          });
        })()
        """
        let evaluated = evaluateJavaScript(js, bundleID: bundleID, kind: kind)
        guard let raw = evaluated.value,
              let data = raw.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return ScriptResult(value: nil, error: evaluated.error)
        }
        return ScriptResult(
            value: Metrics(
                scrollHeight: intValue(json["scrollHeight"]),
                clientHeight: intValue(json["clientHeight"]),
                scrollY: intValue(json["scrollY"])
            ),
            error: nil
        )
    }

    static func scrollTo(bundleID: String, kind: Kind, y: Int) -> ScriptResult<Bool> {
        let evaluated = evaluateJavaScript("window.scrollTo(0, \(y)); true", bundleID: bundleID, kind: kind)
        if evaluated.value != nil {
            return ScriptResult(value: true, error: nil)
        }
        return ScriptResult(value: nil, error: evaluated.error)
    }

    private static func evaluateJavaScript(_ javascript: String, bundleID: String, kind: Kind) -> ScriptResult<String> {
        let escaped = javascript
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let script: String
        switch kind {
        case .chromeFamily:
            script = """
            tell application id "\(bundleID)"
              if (count of windows) is 0 then return ""
              tell active tab of front window
                return execute javascript "\(escaped)"
              end tell
            end tell
            """
        case .safari:
            script = """
            tell application id "com.apple.Safari"
              if (count of documents) is 0 then return ""
              return do JavaScript "\(escaped)" in front document
            end tell
            """
        }
        return run(script: script)
    }

    private static func run(script: String) -> ScriptResult<String> {
        var error: NSDictionary?
        guard let appleScript = NSAppleScript(source: script) else {
            return ScriptResult(value: nil, error: "Could not compile AppleScript.")
        }
        let result = appleScript.executeAndReturnError(&error)
        if let error {
            let message = (error[NSAppleScript.errorMessage] as? String)
                ?? (error["NSAppleScriptErrorMessage"] as? String)
                ?? "Apple Events failed (\(error[NSAppleScript.errorNumber] as? Int ?? 0))"
            return ScriptResult(value: nil, error: message)
        }
        return ScriptResult(value: result.stringValue, error: nil)
    }

    private static func intValue(_ any: Any?) -> Int {
        if let number = any as? NSNumber {
            return number.intValue
        }
        if let value = any as? Int {
            return value
        }
        if let value = any as? Double {
            return Int(value)
        }
        return 0
    }
}

// MARK: - Accessibility scroll fallback

private enum ScrollEventPoster {
    static func scrollPixels(_ deltaY: Int, around bounds: CGRect) {
        // CGWindow bounds and CGEvent positions share Quartz (top-left) space.
        let point = CGPoint(x: bounds.midX, y: bounds.midY)
        let move = CGEvent(
            mouseEventSource: nil,
            mouseType: .mouseMoved,
            mouseCursorPosition: point,
            mouseButton: .left
        )
        move?.post(tap: .cghidEventTap)

        // ponytail: pixel scroll units; switch to line units if HID ignores pixel deltas.
        let event = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 1,
            wheel1: Int32(-deltaY),
            wheel2: 0,
            wheel3: 0
        )
        event?.post(tap: .cghidEventTap)
    }
}
