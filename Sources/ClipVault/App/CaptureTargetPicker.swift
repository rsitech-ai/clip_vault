import AppKit
import Foundation

/// Hover-to-preview window picker for Window / Scrolling page capture.
/// Highlights the window under the cursor and shows a mode label; click confirms, Esc cancels.
@MainActor
final class CaptureTargetPicker {
    struct Target: Equatable {
        let windowID: CGWindowID
        let bundleID: String
        let bounds: CGRect
        let pid: pid_t
        let ownerName: String
    }

    private static let clipVaultBundlePrefix = "com.andrzej.ClipVault"

    private var moveMonitor: Any?
    private var localMoveMonitor: Any?
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var globalKeyMonitor: Any?
    private var highlightWindow: NSWindow?
    private var labelWindow: NSWindow?
    private var completion: ((Target?) -> Void)?
    private var modeLabel = "Window"
    private var lastTarget: Target?

    func begin(modeLabel: String, completion: @escaping (Target?) -> Void) {
        cancelMonitorsOnly()
        self.modeLabel = modeLabel
        self.completion = completion
        self.lastTarget = nil

        let moveHandler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.updateHighlight()
            }
        }
        moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: moveHandler)
        localMoveMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged]) { event in
            moveHandler(event)
            return event
        }

        let clickHandler: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in
                self?.confirm()
            }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: clickHandler)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { event in
            clickHandler(event)
            return nil // consume so the click selects the target instead of activating UI
        }

        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 { // Escape
                Task { @MainActor in
                    self?.finish(nil)
                }
                return nil
            }
            return event
        }
        globalKeyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53 {
                Task { @MainActor in
                    self?.finish(nil)
                }
            }
        }

        updateHighlight()
        NSCursor.crosshair.set()
    }

    private func updateHighlight() {
        let mouse = NSEvent.mouseLocation
        guard let target = Self.window(under: mouse) else {
            lastTarget = nil
            hideOverlay()
            return
        }
        if lastTarget == target {
            return
        }
        lastTarget = target
        showOverlay(for: target)
    }

    private func confirm() {
        guard let target = lastTarget ?? Self.window(under: NSEvent.mouseLocation) else {
            return
        }
        finish(target)
    }

    private func finish(_ target: Target?) {
        cancelMonitorsOnly()
        hideOverlay()
        NSCursor.arrow.set()
        let done = completion
        completion = nil
        done?(target)
    }

    private func cancelMonitorsOnly() {
        if let moveMonitor {
            NSEvent.removeMonitor(moveMonitor)
            self.moveMonitor = nil
        }
        if let localMoveMonitor {
            NSEvent.removeMonitor(localMoveMonitor)
            self.localMoveMonitor = nil
        }
        if let clickMonitor {
            NSEvent.removeMonitor(clickMonitor)
            self.clickMonitor = nil
        }
        if let localClickMonitor {
            NSEvent.removeMonitor(localClickMonitor)
            self.localClickMonitor = nil
        }
        if let localKeyMonitor {
            NSEvent.removeMonitor(localKeyMonitor)
            self.localKeyMonitor = nil
        }
        if let globalKeyMonitor {
            NSEvent.removeMonitor(globalKeyMonitor)
            self.globalKeyMonitor = nil
        }
    }

    private func hideOverlay() {
        highlightWindow?.orderOut(nil)
        highlightWindow = nil
        labelWindow?.orderOut(nil)
        labelWindow = nil
    }

    private func showOverlay(for target: Target) {
        let cocoa = Self.cocoaFrame(fromQuartz: target.bounds)

        let highlight = highlightWindow ?? makeOverlayWindow()
        highlightWindow = highlight
        highlight.setFrame(cocoa, display: true)
        highlight.contentView = HighlightBorderView(frame: NSRect(origin: .zero, size: cocoa.size))
        highlight.orderFrontRegardless()

        let labelSize = NSSize(width: 240, height: 28)
        let labelOrigin = NSPoint(
            x: cocoa.midX - labelSize.width / 2,
            y: min(cocoa.maxY - 8 - labelSize.height, cocoa.maxY - labelSize.height)
        )
        let label = labelWindow ?? makeOverlayWindow()
        labelWindow = label
        label.setFrame(NSRect(origin: labelOrigin, size: labelSize), display: true)
        label.contentView = ModeLabelView(text: modeLabel, appName: target.ownerName)
        label.orderFrontRegardless()
    }

    private func makeOverlayWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: .zero,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = false
        window.level = .screenSaver
        window.ignoresMouseEvents = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        window.isReleasedWhenClosed = false
        return window
    }

    // MARK: - Window hit testing

    static func window(under cocoaPoint: NSPoint) -> Target? {
        let quartzPoint = quartzPoint(fromCocoa: cocoaPoint)
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }

        for entry in info {
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0 else {
                continue
            }
            guard let windowIDNumber = entry[kCGWindowNumber as String] as? NSNumber else {
                continue
            }
            let windowID = CGWindowID(windowIDNumber.uint32Value)
            guard let pidNumber = entry[kCGWindowOwnerPID as String] as? NSNumber else {
                continue
            }
            let pid = pid_t(pidNumber.int32Value)
            if pid == ProcessInfo.processInfo.processIdentifier {
                continue
            }
            var bounds = CGRect.zero
            if let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary {
                CGRectMakeWithDictionaryRepresentation(boundsDict, &bounds)
            }
            guard bounds.width >= 120, bounds.height >= 80 else {
                continue
            }
            guard bounds.contains(quartzPoint) else {
                continue
            }
            guard let app = NSRunningApplication(processIdentifier: pid),
                  let bundleID = app.bundleIdentifier,
                  !bundleID.hasPrefix(clipVaultBundlePrefix) else {
                continue
            }
            let ownerName = (entry[kCGWindowOwnerName as String] as? String)
                ?? app.localizedName
                ?? bundleID
            return Target(
                windowID: windowID,
                bundleID: bundleID,
                bounds: bounds,
                pid: pid,
                ownerName: ownerName
            )
        }
        return nil
    }

    static func cocoaFrame(fromQuartz bounds: CGRect) -> NSRect {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return NSRect(
            x: bounds.origin.x,
            y: primaryHeight - bounds.origin.y - bounds.height,
            width: bounds.width,
            height: bounds.height
        )
    }

    static func quartzPoint(fromCocoa point: NSPoint) -> CGPoint {
        let primaryHeight = NSScreen.screens.first { $0.frame.origin == .zero }?.frame.height
            ?? NSScreen.main?.frame.height
            ?? 0
        return CGPoint(x: point.x, y: primaryHeight - point.y)
    }
}

// MARK: - Overlay views

private final class HighlightBorderView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        let inset = bounds.insetBy(dx: 2, dy: 2)
        let path = NSBezierPath(roundedRect: inset, xRadius: 6, yRadius: 6)
        NSColor.systemBlue.withAlphaComponent(0.18).setFill()
        path.fill()
        path.lineWidth = 3
        NSColor.systemBlue.setStroke()
        path.stroke()
    }
}

private final class ModeLabelView: NSView {
    private let text: String
    private let appName: String

    init(text: String, appName: String) {
        self.text = text
        self.appName = appName
        super.init(frame: .zero)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draw(_ dirtyRect: NSRect) {
        let pill = NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 8, yRadius: 8)
        NSColor.black.withAlphaComponent(0.72).setFill()
        pill.fill()

        let title = "\(text) · \(appName)" as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 12, weight: .semibold),
            .foregroundColor: NSColor.white
        ]
        let size = title.size(withAttributes: attrs)
        let origin = NSPoint(
            x: (bounds.width - size.width) / 2,
            y: (bounds.height - size.height) / 2
        )
        title.draw(at: origin, withAttributes: attrs)
    }
}
