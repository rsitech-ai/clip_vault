import AppKit
import ClipVaultCore

@MainActor
final class DockTileController: NSObject {
    static let shared = DockTileController()

    private let tileView = ClipVaultDockTileView(frame: NSRect(x: 0, y: 0, width: 128, height: 128))
    private var animationTimer: Timer?
    private var clips: [Clip] = []
    private var isCapturing = false
    private var captureStatus = "Ready"

    private var copyClip: ((String) -> Void)?
    private var toggleCapture: (() -> Void)?
    private var openWorkspace: (() -> Void)?

    private override init() {
        super.init()
    }

    func configure(
        copyClip: @escaping (String) -> Void,
        toggleCapture: @escaping () -> Void,
        openWorkspace: @escaping () -> Void
    ) {
        self.copyClip = copyClip
        self.toggleCapture = toggleCapture
        self.openWorkspace = openWorkspace
        installTileViewIfNeeded()
    }

    func update(clips: [Clip], isCapturing: Bool, captureStatus: String) {
        self.clips = clips
        self.isCapturing = isCapturing
        self.captureStatus = captureStatus

        installTileViewIfNeeded()
        let settings = DockTileSettings.current
        NSApp.dockTile.badgeLabel = settings.showsBadge && !clips.isEmpty ? clippedCountLabel(clips.count) : nil
        tileView.snapshot = DockTileSnapshot(
            count: clips.count,
            isCapturing: isCapturing,
            captureStatus: captureStatus,
            recentKinds: settings.showsKindBars ? Array(clips.prefix(6).map(\.kind)) : []
        )
        NSApp.dockTile.display()
        updateAnimationTimer(isEnabled: settings.animatesWhileCapturing)
    }

    func makeDockMenu() -> NSMenu {
        let menu = NSMenu(title: "ClipVault")

        menu.addItem(menuItem("Open ClipVault", action: #selector(openClipVaultFromDock), keyEquivalent: ""))

        let captureItem = menuItem(
            isCapturing ? "Pause Capture" : "Resume Capture",
            action: #selector(toggleCaptureFromDock),
            keyEquivalent: ""
        )
        menu.addItem(captureItem)

        let statusItem = NSMenuItem(title: captureStatus, action: nil, keyEquivalent: "")
        statusItem.isEnabled = false
        menu.addItem(statusItem)
        menu.addItem(.separator())

        let recent = Array(clips.prefix(DockTileSettings.current.recentClipLimit))
        if recent.isEmpty {
            let emptyItem = NSMenuItem(title: "No clips yet", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for clip in recent {
                let item = menuItem("Copy \(shortTitle(for: clip))", action: #selector(copyRecentClipFromDock(_:)), keyEquivalent: "")
                item.representedObject = clip.id
                item.image = NSImage(systemSymbolName: symbolName(for: clip.kind), accessibilityDescription: nil)
                menu.addItem(item)
            }
        }

        return menu
    }

    @objc private func openClipVaultFromDock() {
        openWorkspace?()
    }

    @objc private func toggleCaptureFromDock() {
        toggleCapture?()
    }

    @objc private func copyRecentClipFromDock(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else {
            return
        }
        copyClip?(id)
    }

    private func installTileViewIfNeeded() {
        if NSApp.dockTile.contentView !== tileView {
            NSApp.dockTile.contentView = tileView
        }
    }

    private func updateAnimationTimer(isEnabled: Bool) {
        guard isCapturing, isEnabled else {
            animationTimer?.invalidate()
            animationTimer = nil
            tileView.phase = 0
            NSApp.dockTile.display()
            return
        }

        guard animationTimer == nil else {
            return
        }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.7, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else {
                    return
                }
                self.tileView.phase = self.tileView.phase >= 1 ? 0 : self.tileView.phase + 0.18
                NSApp.dockTile.display()
            }
        }
    }

    private func menuItem(_ title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    private func clippedCountLabel(_ count: Int) -> String {
        count > 99 ? "99+" : "\(count)"
    }

    private func shortTitle(for clip: Clip) -> String {
        let rawTitle = clip.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = rawTitle.isEmpty ? clip.kind.title : rawTitle
        if title.count <= 32 {
            return title
        }
        return "\(title.prefix(29))..."
    }

    private func symbolName(for kind: ClipKind) -> String {
        switch kind {
        case .text: "doc.text"
        case .code: "curlybraces"
        case .sql: "tablecells"
        case .url: "link"
        case .richText: "text.append"
        case .image: "photo"
        case .file: "folder"
        case .error: "exclamationmark.triangle"
        case .unknown: "tray"
        }
    }
}

private struct DockTileSnapshot {
    var count: Int
    var isCapturing: Bool
    var captureStatus: String
    var recentKinds: [ClipKind]

    static let empty = DockTileSnapshot(count: 0, isCapturing: false, captureStatus: "Ready", recentKinds: [])
}

private struct DockTileSettings {
    var showsBadge: Bool
    var animatesWhileCapturing: Bool
    var showsKindBars: Bool
    var recentClipLimit: Int

    static var current: DockTileSettings {
        let defaults = UserDefaults.standard
        let limit = defaults.integer(
            forKey: ClipVaultSettingsKey.dockRecentClipLimit,
            default: ClipVaultSettingsDefault.dockRecentClipLimit
        )
        return DockTileSettings(
            showsBadge: defaults.bool(
                forKey: ClipVaultSettingsKey.dockBadgeEnabled,
                default: ClipVaultSettingsDefault.dockBadgeEnabled
            ),
            animatesWhileCapturing: defaults.bool(
                forKey: ClipVaultSettingsKey.dockAnimationEnabled,
                default: ClipVaultSettingsDefault.dockAnimationEnabled
            ),
            showsKindBars: defaults.bool(
                forKey: ClipVaultSettingsKey.dockKindBarsEnabled,
                default: ClipVaultSettingsDefault.dockKindBarsEnabled
            ),
            recentClipLimit: min(max(limit, 3), 10)
        )
    }
}

private final class ClipVaultDockTileView: NSView {
    var snapshot = DockTileSnapshot.empty {
        didSet {
            needsDisplay = true
        }
    }

    var phase: CGFloat = 0 {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let context = NSGraphicsContext.current?.cgContext else {
            return
        }

        let tileRect = bounds.insetBy(dx: 8, dy: 8)
        let basePath = NSBezierPath(roundedRect: tileRect, xRadius: 26, yRadius: 26)
        context.saveGState()
        context.setShadow(offset: CGSize(width: 0, height: 7), blur: 18, color: NSColor.black.withAlphaComponent(0.28).cgColor)
        gradient().draw(in: basePath, angle: 135 + phase * 34)
        context.restoreGState()

        drawGlow(in: tileRect)
        drawClipboardGlyph(in: tileRect)
        drawCount(in: tileRect)
        drawKindBars(in: tileRect)
    }

    private func gradient() -> NSGradient {
        let colors: [NSColor]
        if snapshot.isCapturing {
            colors = [
                NSColor(calibratedRed: 0.14, green: 0.46, blue: 0.95, alpha: 1),
                NSColor(calibratedRed: 0.44, green: 0.23, blue: 0.98, alpha: 1),
                NSColor(calibratedRed: 0.00, green: 0.78, blue: 0.70, alpha: 1)
            ]
        } else {
            colors = [
                NSColor(calibratedRed: 0.24, green: 0.25, blue: 0.31, alpha: 1),
                NSColor(calibratedRed: 0.13, green: 0.14, blue: 0.18, alpha: 1)
            ]
        }
        return NSGradient(colors: colors) ?? NSGradient(starting: .darkGray, ending: .black)!
    }

    private func drawGlow(in rect: NSRect) {
        guard snapshot.isCapturing else {
            return
        }

        let pulse = (sin(phase * CGFloat.pi * 2) + 1) / 2
        let glowRect = rect.insetBy(dx: -2 - pulse * 2, dy: -2 - pulse * 2)
        let glow = NSBezierPath(roundedRect: glowRect, xRadius: 29, yRadius: 29)
        NSColor.white.withAlphaComponent(0.18 + pulse * 0.18).setStroke()
        glow.lineWidth = 3
        glow.stroke()
    }

    private func drawClipboardGlyph(in rect: NSRect) {
        let bodyRect = NSRect(x: rect.midX - 25, y: rect.minY + 25, width: 50, height: 54)
        let body = NSBezierPath(roundedRect: bodyRect, xRadius: 10, yRadius: 10)
        NSColor.white.withAlphaComponent(0.22).setFill()
        body.fill()
        NSColor.white.withAlphaComponent(0.72).setStroke()
        body.lineWidth = 2
        body.stroke()

        let clipRect = NSRect(x: rect.midX - 14, y: rect.minY + 17, width: 28, height: 15)
        let clip = NSBezierPath(roundedRect: clipRect, xRadius: 6, yRadius: 6)
        NSColor.white.withAlphaComponent(0.84).setFill()
        clip.fill()

        for index in 0..<3 {
            let y = bodyRect.minY + 18 + CGFloat(index) * 12
            let width = index == 2 ? 24.0 : 31.0
            let line = NSBezierPath(roundedRect: NSRect(x: bodyRect.minX + 10, y: y, width: width, height: 4), xRadius: 2, yRadius: 2)
            NSColor.white.withAlphaComponent(0.58).setFill()
            line.fill()
        }
    }

    private func drawCount(in rect: NSRect) {
        let countText = snapshot.count > 99 ? "99+" : "\(snapshot.count)"
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center

        let countAttributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: snapshot.count > 99 ? 22 : 26, weight: .bold),
            .foregroundColor: NSColor.white,
            .paragraphStyle: paragraph
        ]
        (countText as NSString).draw(
            in: NSRect(x: rect.minX + 16, y: rect.maxY - 42, width: rect.width - 32, height: 31),
            withAttributes: countAttributes
        )
    }

    private func drawKindBars(in rect: NSRect) {
        guard !snapshot.recentKinds.isEmpty else {
            return
        }
        let kinds = snapshot.recentKinds
        let maxBars = min(kinds.count, 6)
        let totalWidth = CGFloat(maxBars) * 10 + CGFloat(maxBars - 1) * 4
        let startX = rect.midX - totalWidth / 2
        let y = rect.maxY - 13

        for (index, kind) in kinds.prefix(maxBars).enumerated() {
            let barRect = NSRect(x: startX + CGFloat(index) * 14, y: y, width: 10, height: 5)
            let path = NSBezierPath(roundedRect: barRect, xRadius: 2.5, yRadius: 2.5)
            color(for: kind).setFill()
            path.fill()
        }
    }

    private func color(for kind: ClipKind) -> NSColor {
        switch kind {
        case .text: NSColor(calibratedRed: 0.94, green: 0.95, blue: 1.00, alpha: 0.92)
        case .code: NSColor(calibratedRed: 0.24, green: 0.85, blue: 0.53, alpha: 0.95)
        case .sql: NSColor(calibratedRed: 1.00, green: 0.69, blue: 0.24, alpha: 0.95)
        case .url: NSColor(calibratedRed: 0.18, green: 0.78, blue: 1.00, alpha: 0.95)
        case .richText: NSColor(calibratedRed: 0.96, green: 0.42, blue: 0.78, alpha: 0.95)
        case .image: NSColor(calibratedRed: 0.72, green: 0.42, blue: 1.00, alpha: 0.95)
        case .file: NSColor(calibratedRed: 0.62, green: 0.88, blue: 0.31, alpha: 0.95)
        case .error: NSColor(calibratedRed: 1.00, green: 0.28, blue: 0.24, alpha: 0.95)
        case .unknown: NSColor.white.withAlphaComponent(0.72)
        }
    }
}
