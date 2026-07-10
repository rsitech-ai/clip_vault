import AppKit
import ClipVaultCore
import Darwin
import SwiftData
import SwiftUI

@main
struct ClipVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model: ClipVaultViewModel

    init() {
        let model = ClipVaultViewModel()
        _model = State(initialValue: model)

        if let request = ClipVaultStoreProbeRequest.parse(arguments: CommandLine.arguments) {
            Self.runStoreProbe(request, model: model)
        }
    }

    var body: some Scene {
        WindowGroup("ClipVault", id: "workspace") {
            ContentView(model: model)
                .modelContainer(model.container)
                .frame(minWidth: 900, minHeight: 520)
                .task {
                    DockTileController.shared.configure(
                        copyClip: { id in
                            model.copyToClipboard(id: id)
                        },
                        toggleCapture: {
                            model.toggleCapture()
                        },
                        openWorkspace: {
                            presentClipVaultWorkspace {
                                openWindow(id: "workspace")
                            }
                        }
                    )
                    NotchLiveActivityController.shared.configure(
                        model: model,
                        openWorkspace: {
                            presentClipVaultWorkspace {
                                openWindow(id: "workspace")
                            }
                        }
                    )
                    await model.bootstrap()
                }
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open ClipVault") {
                    presentClipVaultWorkspace {
                        openWindow(id: "workspace")
                    }
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])

                Button("Capture Area Screenshot") {
                    model.captureInteractiveScreenshot()
                }
                .keyboardShortcut("2", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(model: model) {
                presentClipVaultWorkspace {
                    openWindow(id: "workspace")
                }
            }
        } label: {
            Label("ClipVault", systemImage: model.isCapturing ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }

    private static func runStoreProbe(
        _ request: ClipVaultStoreProbeRequest,
        model: ClipVaultViewModel
    ) -> Never {
        if let storageStartupError = model.storageStartupError {
            let message = "CLIPVAULT_STORE_PROBE_ERROR \(storageStartupError)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EX_IOERR)
        }

        do {
            let store = SwiftDataClipStore(context: ModelContext(model.container))
            let matches = try store.allClips().filter { $0.preview == request.token }
            let copyCount = matches.map(\.copyCount).max() ?? 0
            print("CLIPVAULT_STORE_PROBE row_count=\(matches.count) copy_count=\(copyCount)")
            fflush(stdout)
            Darwin.exit(EXIT_SUCCESS)
        } catch {
            let message = "CLIPVAULT_STORE_PROBE_ERROR \(error.localizedDescription)\n"
            FileHandle.standardError.write(Data(message.utf8))
            Darwin.exit(EX_IOERR)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationWillFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.removeObject(forKey: ClipVaultSettingsKey.captureReadyProcessID)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            recoverOffscreenClipVaultWindows(makeKey: true)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        NSApp.unhide(nil)
        NSApp.activate(ignoringOtherApps: true)
        recoverOffscreenClipVaultWindows(makeKey: true)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recoverClipVaultWindows(after: 0.1, makeKey: true)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockTileController.shared.makeDockMenu()
    }
}

@MainActor
func presentClipVaultWorkspace(openWindow: @escaping () -> Void) {
    NSApp.setActivationPolicy(.regular)
    NSApp.unhide(nil)
    NSApp.activate(ignoringOtherApps: true)
    openWindow()
    recoverClipVaultWindows(after: 0.05, makeKey: true)
    recoverClipVaultWindows(after: 0.35, makeKey: true)
    recoverClipVaultWindows(after: 1.0, makeKey: true)
}

@MainActor
func recoverClipVaultWindows(after delay: TimeInterval = 0, makeKey: Bool = false) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        recoverOffscreenClipVaultWindows(makeKey: makeKey)
    }
}

@MainActor
func recoverOffscreenClipVaultWindows(makeKey: Bool = false) {
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    guard let targetFrame = preferredRecoveryScreen()?.visibleFrame ?? NSScreen.main?.visibleFrame ?? visibleFrames.first else {
        return
    }

    for window in NSApp.windows where shouldRecover(window) {
        let isRecoverable = visibleFrames.contains { visibleFrame in
            let paddedFrame = visibleFrame.insetBy(dx: -40, dy: -40)
            return paddedFrame.intersects(window.frame)
                && paddedFrame.contains(NSPoint(x: window.frame.midX, y: window.frame.midY))
        }
        if !isRecoverable {
            center(window, in: targetFrame)
        }

        if makeKey {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        }
    }
}

@MainActor
private func shouldRecover(_ window: NSWindow) -> Bool {
    !window.isMiniaturized && window.canBecomeKey && window.title == "ClipVault"
}

@MainActor
private func preferredRecoveryScreen() -> NSScreen? {
    let mouseLocation = NSEvent.mouseLocation
    return NSScreen.screens.first { screen in
        screen.frame.contains(mouseLocation)
    }
}

@MainActor
private func center(_ window: NSWindow, in targetFrame: NSRect) {
    var frame = window.frame
    let minimumSize = NSSize(width: 900, height: 520)
    let maximumSize = NSSize(
        width: max(minimumSize.width, targetFrame.width * 0.92),
        height: max(minimumSize.height, targetFrame.height * 0.88)
    )
    frame.size.width = min(max(frame.width, minimumSize.width), maximumSize.width)
    frame.size.height = min(max(frame.height, minimumSize.height), maximumSize.height)
    frame.origin.x = targetFrame.midX - frame.width / 2
    frame.origin.y = targetFrame.midY - frame.height / 2
    window.setFrame(frame, display: true)
}
