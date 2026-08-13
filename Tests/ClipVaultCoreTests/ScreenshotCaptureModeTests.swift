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

    @Test("Every screenshot mode prepares Screen Recording before interaction")
    func everyModeRequiresScreenRecordingPreparation() {
        #expect(ScreenshotCaptureMode.area.requiresScreenRecordingAccess)
        #expect(ScreenshotCaptureMode.window.requiresScreenRecordingAccess)
        #expect(ScreenshotCaptureMode.fullPage.requiresScreenRecordingAccess)
    }
}
