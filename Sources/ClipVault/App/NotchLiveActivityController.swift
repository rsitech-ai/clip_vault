import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class NotchLiveActivityController {
    static let shared = NotchLiveActivityController()

    private let panelSize = NSSize(width: 700, height: 210)
    private let notchZoneSize = NSSize(width: 190, height: 24)
    private let menuBarInset: CGFloat = 30
    private var panel: NSPanel?
    private var monitorTimer: Timer?
    private var lastPointerInsideAt = Date.distantPast
    private var isVisible = false

    private init() {}

    func configure(model: ClipVaultViewModel) {
        if panel == nil {
            panel = makePanel(model: model)
        }
        startMonitoring()
        positionPanelForCurrentScreen()
    }

    func refreshPreferences() {
        if !isEnabled {
            hidePanel(immediately: true)
        }
    }

    private func makePanel(model: ClipVaultViewModel) -> NSPanel {
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
                allowsManualToggle: false
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

        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateVisibilityForPointer()
            }
        }
        monitorTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateVisibilityForPointer() {
        guard isEnabled else {
            hidePanel(immediately: true)
            return
        }

        let mouse = NSEvent.mouseLocation
        guard let screen = screen(containing: mouse) ?? NSScreen.main else {
            hidePanel()
            return
        }

        positionPanel(on: screen)
        let isInside = notchZone(on: screen).contains(mouse)
        if isInside {
            lastPointerInsideAt = Date()
            showPanel(on: screen)
        } else if isVisible, Date().timeIntervalSince(lastPointerInsideAt) > 0.08 {
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

    private var isEnabled: Bool {
        UserDefaults.standard.bool(
            forKey: ClipVaultSettingsKey.liveNotchEnabled,
            default: ClipVaultSettingsDefault.liveNotchEnabled
        )
    }

    private func screen(containing point: NSPoint) -> NSScreen? {
        NSScreen.screens.first { $0.frame.contains(point) }
    }
}
