import AppKit
import ClipVaultCore
import SwiftData
import SwiftUI

@main
struct ClipVaultApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @Environment(\.openWindow) private var openWindow
    @State private var model = ClipVaultViewModel()

    var body: some Scene {
        WindowGroup("ClipVault", id: "workspace") {
            ContentView(model: model)
                .modelContainer(model.container)
                .frame(minWidth: 760, minHeight: 520)
                .task {
                    DockTileController.shared.configure(
                        copyClip: { id in
                            model.copyToClipboard(id: id)
                        },
                        toggleCapture: {
                            model.toggleCapture()
                        },
                        openWorkspace: {
                            NSApp.activate(ignoringOtherApps: true)
                            openWindow(id: "workspace")
                            recoverClipVaultWindows(after: 0.4)
                            recoverClipVaultWindows(after: 1.0)
                        }
                    )
                    await model.bootstrap()
                }
        }
        .defaultLaunchBehavior(.presented)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(after: .newItem) {
                Button("Open ClipVault") {
                    NSApp.activate(ignoringOtherApps: true)
                    openWindow(id: "workspace")
                    recoverClipVaultWindows(after: 0.4)
                    recoverClipVaultWindows(after: 1.0)
                }
                .keyboardShortcut("v", modifiers: [.command, .shift])
            }
        }

        MenuBarExtra {
            MenuBarView(model: model) {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "workspace")
                recoverClipVaultWindows(after: 0.4)
                recoverClipVaultWindows(after: 1.0)
            }
        } label: {
            Label("ClipVault", systemImage: model.isCapturing ? "doc.on.clipboard.fill" : "doc.on.clipboard")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            recoverOffscreenClipVaultWindows()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        recoverOffscreenClipVaultWindows()
        NSApp.windows.first?.makeKeyAndOrderFront(nil)
        return true
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        recoverClipVaultWindows(after: 0.5)
    }

    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        DockTileController.shared.makeDockMenu()
    }
}

@MainActor
private func recoverClipVaultWindows(after delay: TimeInterval = 0) {
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        recoverOffscreenClipVaultWindows()
    }
}

@MainActor
private func recoverOffscreenClipVaultWindows() {
    let visibleFrames = NSScreen.screens.map(\.visibleFrame)
    guard let targetFrame = NSScreen.main?.visibleFrame ?? visibleFrames.first else {
        return
    }

    for window in NSApp.windows where !window.isMiniaturized {
        let isOnVisibleDisplay = visibleFrames.contains { visibleFrame in
            window.frame.intersects(visibleFrame.insetBy(dx: -40, dy: -40))
        }
        guard !isOnVisibleDisplay else {
            continue
        }

        var frame = window.frame
        frame.size.width = min(max(frame.width, 900), targetFrame.width * 0.92)
        frame.size.height = min(max(frame.height, 620), targetFrame.height * 0.88)
        frame.origin.x = targetFrame.midX - frame.width / 2
        frame.origin.y = targetFrame.midY - frame.height / 2
        window.setFrame(frame, display: true)
        window.makeKeyAndOrderFront(nil)
    }
}
