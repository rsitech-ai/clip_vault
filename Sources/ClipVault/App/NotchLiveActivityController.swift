import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotchLiveActivityController: NSObject {
    static let shared = NotchLiveActivityController()

    private let panelSize = NSSize(width: 700, height: 210)
    private let notchZoneSize = NSSize(width: 190, height: 24)
    private let menuBarInset: CGFloat = 30
    private let monitorInterval: TimeInterval = 0.12
    private let hideGraceInterval: TimeInterval = 0.18
    private var panel: NSPanel?
    private var monitorTimer: Timer?
    private var lastPointerInsideAt = Date.distantPast
    private var liveNotchEnabled = ClipVaultSettingsDefault.liveNotchEnabled
    private var isVisible = false

    private override init() {
        super.init()
    }

    func configure(model: ClipVaultViewModel, openWorkspace: @escaping () -> Void) {
        liveNotchEnabled = Self.readLiveNotchPreference()
        if panel == nil {
            panel = makePanel(model: model, openWorkspace: openWorkspace)
        }
        startMonitoring()
        positionPanelForCurrentScreen()
    }

    func refreshPreferences() {
        liveNotchEnabled = Self.readLiveNotchPreference()
        if !liveNotchEnabled {
            hidePanel(immediately: true)
        }
    }

    private func makePanel(model: ClipVaultViewModel, openWorkspace: @escaping () -> Void) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .utilityWindow
        panel.collectionBehavior = [
            .canJoinAllSpaces,
            .fullScreenAuxiliary,
            .stationary,
            .ignoresCycle
        ]

        let root = ZStack(alignment: .top) {
            Color.clear
            LiveActivityIslandView(
                model: model,
                defaultExpanded: true,
                expandsOnHover: false,
                allowsManualToggle: false,
                openWorkspace: openWorkspace
            )
            .padding(.top, 10)
        }
        .frame(width: panelSize.width, height: panelSize.height)

        let hostingView = NSHostingView(rootView: root)
        hostingView.frame = NSRect(origin: .zero, size: panelSize)
        hostingView.wantsLayer = true
        hostingView.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = hostingView
        panel.alphaValue = 0
        panel.orderOut(nil)
        return panel
    }

    private func startMonitoring() {
        guard monitorTimer == nil else {
            return
        }

        let timer = Timer(
            timeInterval: monitorInterval,
            target: self,
            selector: #selector(handleMonitorTimer),
            userInfo: nil,
            repeats: true
        )
        monitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    @objc private func handleMonitorTimer() {
        updateVisibilityForPointer()
    }

    private func updateVisibilityForPointer() {
        guard liveNotchEnabled else {
            hidePanel(immediately: true)
            return
        }

        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse) ?? NSScreen.main else {
            hidePanel()
            return
        }

        let isInsideNotch = notchZone(on: screen).contains(mouse)
        if isVisible {
            positionPanel(on: screen)
        }
        let isInsidePanel = isVisible && (panel?.frame.contains(mouse) ?? false)
        if isInsideNotch || isInsidePanel {
            lastPointerInsideAt = Date()
            if isInsideNotch {
                showPanel(on: screen)
            }
        } else if isVisible, Date().timeIntervalSince(lastPointerInsideAt) > hideGraceInterval {
            hidePanel()
        }
    }

    private func showPanel(on screen: NSScreen) {
        guard let panel else {
            return
        }

        positionPanel(on: screen)
        guard !isVisible else {
            return
        }

        isVisible = true
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
        }
    }

    private func hidePanel(immediately: Bool = false) {
        guard let panel, isVisible else {
            return
        }

        isVisible = false
        if immediately {
            panel.alphaValue = 0
            panel.orderOut(nil)
            return
        }

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.14
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
        } completionHandler: {
            Task { @MainActor in
                if !self.isVisible {
                    panel.orderOut(nil)
                }
            }
        }
    }

    private func positionPanelForCurrentScreen() {
        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse) ?? NSScreen.main else {
            return
        }
        positionPanel(on: screen)
    }

    private func positionPanel(on screen: NSScreen) {
        guard let panel else {
            return
        }

        let screenFrame = screen.frame
        let x = screenFrame.midX - panelSize.width / 2
        let y = screenFrame.maxY - panelSize.height - menuBarInset
        let frame = NSRect(x: x, y: y, width: panelSize.width, height: panelSize.height)
        if panel.frame != frame {
            panel.setFrame(frame, display: false)
        }
    }

    private func notchZone(on screen: NSScreen) -> NSRect {
        let screenFrame = screen.frame
        return NSRect(
            x: screenFrame.midX - notchZoneSize.width / 2,
            y: screenFrame.maxY - notchZoneSize.height,
            width: notchZoneSize.width,
            height: notchZoneSize.height
        )
    }

    private static func readLiveNotchPreference() -> Bool {
        UserDefaults.standard.bool(
            forKey: ClipVaultSettingsKey.liveNotchEnabled,
            default: ClipVaultSettingsDefault.liveNotchEnabled
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
