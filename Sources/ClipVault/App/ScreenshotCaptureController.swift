import AppKit
import Carbon.HIToolbox
import ClipVaultCore
import Foundation

@MainActor
final class ScreenshotCaptureController {
    static let shared = ScreenshotCaptureController()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var completion: ((Bool, String) -> Void)?
    private var isCapturingScreenshot = false
    private let targetPicker = CaptureTargetPicker()

    private init() {}

    @discardableResult
    func configure(completion: @escaping (Bool, String) -> Void) -> Bool {
        self.completion = completion
        return registerGlobalHotKey()
    }

    func captureInteractiveScreenshot(mode: ScreenshotCaptureMode = .area) {
        guard !isCapturingScreenshot else {
            return
        }

        switch mode {
        case .area:
            guard let arguments = mode.screencaptureArguments else {
                completion?(false, "Screenshot mode unavailable")
                return
            }
            runScreencapture(arguments: arguments)

        case .window:
            isCapturingScreenshot = true
            targetPicker.begin(modeLabel: mode.hoverLabel) { [weak self] target in
                guard let self else { return }
                guard let target else {
                    self.isCapturingScreenshot = false
                    self.completion?(false, "Screenshot cancelled")
                    return
                }
                self.runScreencapture(arguments: ["-x", "-c", "-o", "-l\(target.windowID)"])
            }

        case .fullPage:
            isCapturingScreenshot = true
            targetPicker.begin(modeLabel: mode.hoverLabel) { [weak self] target in
                guard let self else { return }
                guard let target else {
                    self.isCapturingScreenshot = false
                    self.completion?(false, "Screenshot cancelled")
                    return
                }
                Task { @MainActor in
                    let outcome = await FullPageScreenshotCapture.capture(targetPickerTarget: target)
                    self.isCapturingScreenshot = false
                    switch outcome {
                    case .success:
                        self.completion?(true, "Scrolling page copied to clipboard")
                    case .cancelled:
                        self.completion?(false, "Screenshot cancelled")
                    case .failure(let message):
                        self.completion?(false, message)
                        Self.presentFailureAlert(message)
                    }
                }
            }
        }
    }

    private func runScreencapture(arguments: [String]) {
        isCapturingScreenshot = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = arguments
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.isCapturingScreenshot = false
                if process.terminationStatus == 0 {
                    self?.completion?(true, "Screenshot copied to clipboard")
                } else {
                    self?.completion?(false, "Screenshot cancelled")
                }
            }
        }

        do {
            try process.run()
        } catch {
            isCapturingScreenshot = false
            completion?(false, "Could not start screenshot capture")
        }
    }

    private static func presentFailureAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Scrolling page capture failed"
        alert.informativeText = message
        alert.alertStyle = .warning
        let needsScreenRecording = message.localizedCaseInsensitiveContains("Screen Recording")
        if needsScreenRecording {
            alert.addButton(withTitle: "Open Screen Recording Settings")
            alert.addButton(withTitle: "Quit ClipVault")
            alert.addButton(withTitle: "OK")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                ScreenRecordingAccess.openSystemSettings()
            case .alertSecondButtonReturn:
                NSApp.terminate(nil)
            default:
                break
            }
        } else {
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    private func registerGlobalHotKey() -> Bool {
        guard hotKeyRef == nil else {
            return true
        }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: OSType(kEventHotKeyPressed)
        )

        let handler: EventHandlerUPP = { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(
                event,
                EventParamName(kEventParamDirectObject),
                EventParamType(typeEventHotKeyID),
                nil,
                MemoryLayout<EventHotKeyID>.size,
                nil,
                &hotKeyID
            )

            if hotKeyID.signature == ScreenshotCaptureController.hotKeySignature,
               hotKeyID.id == ScreenshotCaptureController.hotKeyID {
                Task { @MainActor in
                    ScreenshotCaptureController.shared.captureInteractiveScreenshot(mode: .area)
                }
            }

            return noErr
        }

        let handlerStatus = InstallEventHandler(
            GetApplicationEventTarget(),
            handler,
            1,
            &eventType,
            nil,
            &eventHandlerRef
        )
        guard handlerStatus == noErr else {
            eventHandlerRef = nil
            return false
        }

        let hotKeyID = EventHotKeyID(
            signature: Self.hotKeySignature,
            id: Self.hotKeyID
        )

        let registrationStatus = RegisterEventHotKey(
            UInt32(kVK_ANSI_2),
            UInt32(cmdKey | shiftKey),
            hotKeyID,
            GetApplicationEventTarget(),
            0,
            &hotKeyRef
        )
        guard registrationStatus == noErr else {
            if let eventHandlerRef {
                RemoveEventHandler(eventHandlerRef)
            }
            eventHandlerRef = nil
            hotKeyRef = nil
            return false
        }

        return true
    }

    private static let hotKeySignature = OSType(
        UInt32(UInt8(ascii: "C")) << 24
            | UInt32(UInt8(ascii: "V")) << 16
            | UInt32(UInt8(ascii: "S")) << 8
            | UInt32(UInt8(ascii: "S"))
    )
    private static let hotKeyID = UInt32(1)
}
