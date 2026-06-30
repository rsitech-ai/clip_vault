import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class ScreenshotCaptureController {
    static let shared = ScreenshotCaptureController()

    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var completion: ((Bool) -> Void)?
    private var isCapturingScreenshot = false

    private init() {}

    @discardableResult
    func configure(completion: @escaping (Bool) -> Void) -> Bool {
        self.completion = completion
        return registerGlobalHotKey()
    }

    func captureInteractiveScreenshot() {
        guard !isCapturingScreenshot else {
            return
        }

        isCapturingScreenshot = true
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-i", "-c"]
        process.terminationHandler = { [weak self] process in
            Task { @MainActor in
                self?.isCapturingScreenshot = false
                self?.completion?(process.terminationStatus == 0)
            }
        }

        do {
            try process.run()
        } catch {
            isCapturingScreenshot = false
            completion?(false)
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
                    ScreenshotCaptureController.shared.captureInteractiveScreenshot()
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
