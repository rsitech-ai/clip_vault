import ClipVaultCore
import Testing

@Suite("Screenshot capture modes")
struct ScreenshotCaptureModeTests {
    @Test("Area uses interactive screencapture; window/full-page use ClipVault picker")
    func argumentsMatchInteractiveModes() {
        #expect(ScreenshotCaptureMode.area.screencaptureArguments == ["-i", "-c", "-J", "selection"])
        #expect(ScreenshotCaptureMode.window.screencaptureArguments == nil)
        #expect(ScreenshotCaptureMode.fullPage.screencaptureArguments == nil)
        #expect(ScreenshotCaptureMode.window.hoverLabel == "Window")
        #expect(ScreenshotCaptureMode.fullPage.hoverLabel == "Scrolling page")
    }
}
