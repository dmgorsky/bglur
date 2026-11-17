import Cocoa
import QuartzCore

// MARK: - Private CoreGraphics Blur SPI

typealias CGSConnectionID = UInt32

@_silgen_name("CGSMainConnectionID")
func CGSMainConnectionID() -> CGSConnectionID

@_silgen_name("CGSSetWindowBackgroundBlurRadius")
@discardableResult
func CGSSetWindowBackgroundBlurRadius(
    _ cid: CGSConnectionID,
    _ wid: UInt32,
    _ radius: Int32
) -> OSStatus

// MARK: - Settings

final class Settings {
    private enum Keys {
        static let isEnabled = "bglur.isEnabled"
        static let blurRadius = "bglur.blurRadius"
        static let transitionDuration = "bglur.transitionDuration"
        static let dimAlpha = "bglur.dimAlpha"
    }

    static let defaultIsEnabled = true
    static let defaultBlurRadius: Double = 24.0
    static let defaultTransitionDuration: Double = 0.18
    static let defaultDimAlpha: Double = 0.05

    static let blurRadiusRange: ClosedRange<Double> = 0.0...60.0
    static let transitionDurationRange: ClosedRange<Double> = 0.05...0.60
    static let dimAlphaRange: ClosedRange<Double> = 0.0...0.40

    private let defaults: UserDefaults
    var onChange: (() -> Void)?

    var isEnabled: Bool {
        didSet {
            guard isEnabled != oldValue else { return }
            defaults.set(isEnabled, forKey: Keys.isEnabled)
            onChange?()
        }
    }

    var blurRadius: Double {
        didSet {
            let clamped = Self.clamp(blurRadius, to: Self.blurRadiusRange)
            if clamped != blurRadius {
                blurRadius = clamped
                return
            }
            guard blurRadius != oldValue else { return }
            defaults.set(blurRadius, forKey: Keys.blurRadius)
            onChange?()
        }
    }

    var transitionDuration: Double {
        didSet {
            let clamped = Self.clamp(transitionDuration, to: Self.transitionDurationRange)
            if clamped != transitionDuration {
                transitionDuration = clamped
                return
            }
            guard transitionDuration != oldValue else { return }
            defaults.set(transitionDuration, forKey: Keys.transitionDuration)
            onChange?()
        }
    }

    var dimAlpha: Double {
        didSet {
            let clamped = Self.clamp(dimAlpha, to: Self.dimAlphaRange)
            if clamped != dimAlpha {
                dimAlpha = clamped
                return
            }
            guard dimAlpha != oldValue else { return }
            defaults.set(dimAlpha, forKey: Keys.dimAlpha)
            onChange?()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if defaults.object(forKey: Keys.isEnabled) != nil {
            self.isEnabled = defaults.bool(forKey: Keys.isEnabled)
        } else {
            self.isEnabled = Self.defaultIsEnabled
        }

        if defaults.object(forKey: Keys.blurRadius) != nil {
            self.blurRadius = Self.clamp(
                defaults.double(forKey: Keys.blurRadius),
                to: Self.blurRadiusRange
            )
        } else {
            self.blurRadius = Self.defaultBlurRadius
        }

        if defaults.object(forKey: Keys.transitionDuration) != nil {
            self.transitionDuration = Self.clamp(
                defaults.double(forKey: Keys.transitionDuration),
                to: Self.transitionDurationRange
            )
        } else {
            self.transitionDuration = Self.defaultTransitionDuration
        }

        if defaults.object(forKey: Keys.dimAlpha) != nil {
            self.dimAlpha = Self.clamp(
                defaults.double(forKey: Keys.dimAlpha),
                to: Self.dimAlphaRange
            )
        } else {
            self.dimAlpha = Self.defaultDimAlpha
        }
    }

    func resetDefaults() {
        isEnabled = Self.defaultIsEnabled
        blurRadius = Self.defaultBlurRadius
        transitionDuration = Self.defaultTransitionDuration
        dimAlpha = Self.defaultDimAlpha
    }

    private static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

// MARK: - Transition Math

enum BlurTransitionMath {
    static func easeOutCubic(_ progress: Double) -> Double {
        let p = min(max(progress, 0.0), 1.0)
        return 1.0 - pow(1.0 - p, 3.0)
    }

    /// Computes primary (outgoing), secondary (incoming), and unblur (newly active window) visibilities.
    /// Primary remains at 1.0 until secondary has ramped past p = 0.35 (~72.5% blur),
    /// ensuring deeper background windows never flash unblurred during focus switches,
    /// while unblur clears the newly focused window in sync (1.0 -> 0.0).
    static func overlayVisibilities(progress: Double) -> (primary: Double, secondary: Double, unblur: Double) {
        let p = min(max(progress, 0.0), 1.0)
        let secondary = easeOutCubic(p)
        let unblur = max(0.0, 1.0 - secondary)
        let primary: Double
        if p <= 0.35 {
            primary = 1.0
        } else {
            let q = (p - 0.35) / 0.65
            primary = max(0.0, 1.0 - easeOutCubic(q))
        }
        return (primary, secondary, unblur)
    }

    static func fadeOutVisibility(from startVisibility: Double, progress: Double) -> Double {
        let p = min(max(progress, 0.0), 1.0)
        return max(0.0, startVisibility * (1.0 - easeOutCubic(p)))
    }

    static func fadeInVisibility(from startVisibility: Double, progress: Double) -> Double {
        let p = min(max(progress, 0.0), 1.0)
        return min(1.0, startVisibility + (1.0 - startVisibility) * easeOutCubic(p))
    }
}

// MARK: - Pure Blur View & Screen Overlay Window

final class PureBlurView: NSVisualEffectView {
    var blurRadius: CGFloat = 24.0 {
        didSet {
            if blurRadius != oldValue {
                applyVisualState()
            }
        }
    }

    var dimAlpha: CGFloat = 0.05 {
        didSet {
            if dimAlpha != oldValue {
                applyVisualState()
            }
        }
    }

    var cornerRadius: CGFloat = 0.0 {
        didSet {
            if cornerRadius != oldValue {
                applyVisualState()
            }
        }
    }

    private(set) var currentVisibility: CGFloat = 0.0
    private let tintLayer = CALayer()
    private let maskShapeLayer = CAShapeLayer()
    private static let suppressedLayerNames: Set<String> = ["fill", "tone", "Chameleon"]

    var currentMaskPath: CGPath? {
        maskShapeLayer.path
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit(initialRect: NSRect(origin: .zero, size: frameRect.size))
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit(initialRect: bounds)
    }

    private func commonInit(initialRect: NSRect) {
        blendingMode = .behindWindow
        material = .fullScreenUI
        state = .active
        wantsLayer = true
        autoresizingMask = [.width, .height]

        tintLayer.name = "bglur.tint"
        tintLayer.zPosition = 1000
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]

        maskShapeLayer.frame = initialRect
        maskShapeLayer.path = CGPath(rect: initialRect, transform: nil)
    }

    override func layout() {
        super.layout()
        applyVisualState()
    }

    override func updateLayer() {
        super.updateLayer()
        applyVisualState()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyVisualState()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyVisualState()
    }

    func setMaskPath(_ path: CGPath?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if let root = layer {
            maskShapeLayer.frame = root.bounds
            if root.mask !== maskShapeLayer {
                root.mask = maskShapeLayer
            }
        }
        maskShapeLayer.path = path
        CATransaction.commit()
    }

    func apply(blurRadius: CGFloat, dimAlpha: CGFloat, visibility: CGFloat) {
        let clamped = min(max(visibility, 0.0), 1.0)
        currentVisibility = clamped
        self.blurRadius = blurRadius * clamped
        self.dimAlpha = dimAlpha * clamped
        alphaValue = clamped > 0.001 ? min(1.0, clamped / 0.25) : 0.0
    }

    func applyVisualState() {
        guard let root = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        root.cornerRadius = cornerRadius
        root.cornerCurve = .continuous
        root.masksToBounds = cornerRadius > 0

        maskShapeLayer.frame = root.bounds
        if root.mask !== maskShapeLayer {
            root.mask = maskShapeLayer
        }

        if tintLayer.superlayer !== root {
            root.addSublayer(tintLayer)
        }
        tintLayer.frame = root.bounds
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
        tintLayer.isHidden = dimAlpha <= 0.0001

        for sublayer in root.sublayers ?? [] where sublayer !== tintLayer {
            configureBackdropHierarchy(in: sublayer)
        }
    }

    private func configureBackdropHierarchy(in layer: CALayer) {
        if layer.name == "backdrop" {
            layer.isHidden = false
            layer.opacity = 1.0
            layer.setValue(blurRadius < 8.0 ? 1.0 : 0.5, forKey: "scale")
            layer.setValue(1.0, forKeyPath: "filters.colorSaturate.inputAmount")
            layer.setValue(blurRadius, forKeyPath: "filters.gaussianBlur.inputRadius")
            return
        }

        if let name = layer.name, Self.suppressedLayerNames.contains(name) {
            layer.isHidden = true
            layer.opacity = 0.0
            return
        }

        for child in layer.sublayers ?? [] where child !== tintLayer {
            configureBackdropHierarchy(in: child)
        }
    }

    // Inspection helpers for self-tests
    func findBackdropLayer() -> CALayer? {
        layer.flatMap { findLayer(named: "backdrop", in: $0) }
    }

    func findSuppressedLayers() -> [CALayer] {
        guard let root = layer else { return [] }
        var found: [CALayer] = []
        collectLayers(named: Self.suppressedLayerNames, in: root, into: &found)
        return found
    }

    private func findLayer(named name: String, in root: CALayer) -> CALayer? {
        if root.name == name { return root }
        for child in root.sublayers ?? [] where child !== tintLayer {
            if let match = findLayer(named: name, in: child) {
                return match
            }
        }
        return nil
    }

    private func collectLayers(named names: Set<String>, in root: CALayer, into result: inout [CALayer]) {
        if let name = root.name, names.contains(name) {
            result.append(root)
        }
        for child in root.sublayers ?? [] where child !== tintLayer {
            collectLayers(named: names, in: child, into: &result)
        }
    }
}

final class ScreenOverlayWindow: NSWindow {
    let baseView: PureBlurView
    let unblurView: PureBlurView
    let blurInView: PureBlurView
    private let containerView: NSView
    private let emptyPath: CGPath = CGMutablePath()
    private static let windowCornerRadius: CGFloat = 11.0

    var currentBaseVisibility: CGFloat {
        baseView.currentVisibility
    }

    init(frame: NSRect, blurRadius: CGFloat = 24.0, dimAlpha: CGFloat = 0.05) {
        let localBounds = NSRect(origin: .zero, size: frame.size)
        let container = NSView(frame: localBounds)
        container.wantsLayer = true
        container.autoresizingMask = [.width, .height]

        let base = PureBlurView(frame: localBounds)
        let blurIn = PureBlurView(frame: localBounds)
        let unblur = PureBlurView(frame: localBounds)

        container.addSubview(base)
        container.addSubview(blurIn)
        container.addSubview(unblur)

        self.containerView = container
        self.baseView = base
        self.blurInView = blurIn
        self.unblurView = unblur

        super.init(
            contentRect: frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false
        )
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        level = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1)
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = container

        // Pre-warm all 3 backdrop layers in WindowServer; unblurView stays hot at target
        // blur radius behind an empty mask so Frame 0 of any switch starts blurred with zero lag.
        orderFrontRegardless()
        hideAll(blurRadius: blurRadius, dimAlpha: dimAlpha)
        container.layoutSubtreeIfNeeded()
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func updateFrame(_ newFrame: NSRect) {
        if frame != newFrame {
            setFrame(newFrame, display: true)
            let localBounds = NSRect(origin: .zero, size: newFrame.size)
            containerView.frame = localBounds
            baseView.frame = localBounds
            blurInView.frame = localBounds
            unblurView.frame = localBounds
        }
    }

    func showSteadyState(
        activeRectGlobal: NSRect?,
        blurRadius: CGFloat,
        dimAlpha: CGFloat,
        visibility: CGFloat
    ) {
        let screenPath = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        let basePath = localCutoutPath(for: activeRectGlobal).map { screenPath.subtracting($0) } ?? screenPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseView.setMaskPath(basePath)
        baseView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: visibility)

        // Keep unblurView hot at full target blur behind an empty mask while blur is active.
        unblurView.setMaskPath(emptyPath)
        unblurView.apply(
            blurRadius: blurRadius,
            dimAlpha: dimAlpha,
            visibility: visibility > 0.001 ? 1.0 : 0.0
        )

        blurInView.setMaskPath(emptyPath)
        blurInView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)
        CATransaction.commit()
    }

    func showSwitchTransition(
        oldRectGlobal: NSRect?,
        newRectGlobal: NSRect?,
        blurRadius: CGFloat,
        dimAlpha: CGFloat,
        primaryVis: CGFloat,
        blurInVis: CGFloat,
        unblurVis: CGFloat
    ) {
        let screenPath = CGPath(rect: CGRect(origin: .zero, size: frame.size), transform: nil)
        let oldPath = localCutoutPath(for: oldRectGlobal)
        let newPath = localCutoutPath(for: newRectGlobal)

        let basePath: CGPath
        if let oldPath, let newPath {
            basePath = screenPath.subtracting(oldPath.union(newPath))
        } else if let oldPath {
            basePath = screenPath.subtracting(oldPath)
        } else if let newPath {
            basePath = screenPath.subtracting(newPath)
        } else {
            basePath = screenPath
        }

        let blurInPath: CGPath
        if let oldPath {
            blurInPath = newPath.map { oldPath.subtracting($0) } ?? oldPath
        } else {
            blurInPath = emptyPath
        }

        let unblurPath = newPath ?? emptyPath

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseView.setMaskPath(basePath)
        baseView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: primaryVis)

        blurInView.setMaskPath(blurInPath)
        blurInView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: blurInVis)

        unblurView.setMaskPath(unblurPath)
        unblurView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: unblurVis)
        CATransaction.commit()
    }

    func hideAll(blurRadius: CGFloat, dimAlpha: CGFloat) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        baseView.setMaskPath(emptyPath)
        baseView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)

        unblurView.setMaskPath(emptyPath)
        unblurView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)

        blurInView.setMaskPath(emptyPath)
        blurInView.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)
        CATransaction.commit()
    }

    private func localCutoutPath(for globalRect: NSRect?) -> CGPath? {
        guard let globalRect else { return nil }
        let localRect = NSRect(
            x: globalRect.origin.x - frame.origin.x,
            y: globalRect.origin.y - frame.origin.y,
            width: globalRect.size.width,
            height: globalRect.size.height
        )
        let screenLocalBounds = NSRect(origin: .zero, size: frame.size)
        let clipped = localRect.intersection(screenLocalBounds)
        guard !clipped.isNull, clipped.width > 0.5, clipped.height > 0.5 else {
            return nil
        }
        let corner = min(Self.windowCornerRadius, min(localRect.width, localRect.height) / 2.0)
        return CGPath(roundedRect: localRect, cornerWidth: corner, cornerHeight: corner, transform: nil)
    }
}

// MARK: - Active Window Detection

struct WindowZOrderSnapshot {
    let activeWindowID: CGWindowID?
    let activeWindowBounds: NSRect?
    let orderedWindowNumbers: [Int]
}

enum ActiveWindowDetector {
    static func snapshot(ignoringPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> WindowZOrderSnapshot {
        let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0.0
        return resolveActiveWindowID(
            from: rawList,
            frontPID: frontPID,
            ignoringPID: ignoringPID,
            primaryScreenHeight: primaryHeight
        )
    }

    static func windowAtScreenPoint(
        _ appKitPoint: NSPoint,
        ignoringPID: pid_t = ProcessInfo.processInfo.processIdentifier
    ) -> (id: CGWindowID, bounds: NSRect)? {
        let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let primaryFrame = NSScreen.screens.first?.frame ?? .zero
        return resolveWindowAtScreenPoint(
            appKitPoint,
            from: rawList,
            ignoringPID: ignoringPID,
            primaryScreenSize: primaryFrame.size
        )
    }

    static func resolveWindowAtScreenPoint(
        _ appKitPoint: NSPoint,
        from rawList: [[String: Any]],
        ignoringPID: pid_t,
        primaryScreenSize: CGSize
    ) -> (id: CGWindowID, bounds: NSRect)? {
        var hasFullscreenBackdrop = false
        var qualifyingWindowCount = 0
        var hit: (id: CGWindowID, bounds: NSRect)?

        for info in rawList {
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let windowName = info[kCGWindowName as String] as? String
            if ownerName == "WindowManager" && windowName == "Fullscreen Backdrop" {
                hasFullscreenBackdrop = true
            }

            guard let layer = info[kCGWindowLayer as String] as? Int,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ignoringPID else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.05,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let cgBounds = CGRect(dictionaryRepresentation: boundsDict) else {
                continue
            }

            let appKitBounds = convertCGWindowBoundsToAppKit(
                cgBounds,
                primaryScreenHeight: primaryScreenSize.height
            )

            // If a click hits the menu bar, Dock, Control Center, or a popup menu above layer 0,
            // do not treat it as clicking a background app window.
            if layer > 0 {
                let isFullScreenHelper = primaryScreenSize.width > 0 &&
                    primaryScreenSize.height > 0 &&
                    appKitBounds.width >= primaryScreenSize.width * 0.9 &&
                    appKitBounds.height >= primaryScreenSize.height * 0.9
                if hit == nil && !isFullScreenHelper && appKitBounds.contains(appKitPoint) {
                    return nil
                }
                continue
            }

            guard layer == 0,
                  cgBounds.width >= 80.0,
                  cgBounds.height >= 80.0,
                  let windowNum = info[kCGWindowNumber as String] as? Int else {
                continue
            }

            qualifyingWindowCount += 1

            if hit == nil && appKitBounds.contains(appKitPoint) {
                hit = (CGWindowID(windowNum), appKitBounds)
            }
        }

        if hasFullscreenBackdrop && qualifyingWindowCount <= 1 {
            return nil
        }

        return hit
    }

    static func convertCGWindowBoundsToAppKit(_ cgRect: CGRect, primaryScreenHeight: CGFloat) -> NSRect {
        NSRect(
            x: cgRect.origin.x,
            y: primaryScreenHeight - (cgRect.origin.y + cgRect.size.height),
            width: cgRect.size.width,
            height: cgRect.size.height
        )
    }

    static func resolveActiveWindowID(
        from rawList: [[String: Any]],
        frontPID: pid_t?,
        ignoringPID: pid_t,
        primaryScreenHeight: CGFloat = NSScreen.screens.first?.frame.height ?? 0.0
    ) -> WindowZOrderSnapshot {
        var hasFullscreenBackdrop = false
        var qualifyingWindowCount = 0
        var frontAppWindowID: CGWindowID?
        var frontAppCGBounds: CGRect?
        var topmostAnyWindowID: CGWindowID?
        var topmostAnyCGBounds: CGRect?
        var orderedNumbers: [Int] = []
        orderedNumbers.reserveCapacity(rawList.count)

        for info in rawList {
            let ownerName = info[kCGWindowOwnerName as String] as? String
            let windowName = info[kCGWindowName as String] as? String
            if ownerName == "WindowManager" && windowName == "Fullscreen Backdrop" {
                hasFullscreenBackdrop = true
            }

            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowNum = info[kCGWindowNumber as String] as? Int else {
                continue
            }

            orderedNumbers.append(windowNum)

            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != ignoringPID else {
                continue
            }

            let alpha = (info[kCGWindowAlpha as String] as? Double) ?? 1.0
            guard alpha > 0.05 else { continue }

            guard let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 80.0,
                  bounds.height >= 80.0 else {
                continue
            }

            qualifyingWindowCount += 1

            if topmostAnyWindowID == nil {
                topmostAnyWindowID = CGWindowID(windowNum)
                topmostAnyCGBounds = bounds
            }

            if let frontPID, frontPID != ignoringPID, ownerPID == frontPID, frontAppWindowID == nil {
                frontAppWindowID = CGWindowID(windowNum)
                frontAppCGBounds = bounds
            }
        }

        let activeID: CGWindowID?
        let activeBounds: NSRect?
        if hasFullscreenBackdrop && qualifyingWindowCount <= 1 {
            activeID = nil
            activeBounds = nil
        } else if let frontAppWindowID, let frontAppCGBounds {
            activeID = frontAppWindowID
            activeBounds = convertCGWindowBoundsToAppKit(frontAppCGBounds, primaryScreenHeight: primaryScreenHeight)
        } else if let topmostAnyWindowID, let topmostAnyCGBounds {
            activeID = topmostAnyWindowID
            activeBounds = convertCGWindowBoundsToAppKit(topmostAnyCGBounds, primaryScreenHeight: primaryScreenHeight)
        } else {
            activeID = nil
            activeBounds = nil
        }

        return WindowZOrderSnapshot(
            activeWindowID: activeID,
            activeWindowBounds: activeBounds,
            orderedWindowNumbers: orderedNumbers
        )
    }
}

// MARK: - Blur Coordinator

final class BlurCoordinator {
    private enum TransitionKind {
        case none
        case switchWindow(
            newID: CGWindowID,
            oldBounds: NSRect?,
            newBounds: NSRect?,
            primaryStartVisibility: Double
        )
        case fadeOut(bounds: NSRect?, startVisibility: Double)
        case fadeIn(windowID: CGWindowID, bounds: NSRect?, startVisibility: Double)
    }

    private let settings: Settings
    private var screens: [CGDirectDisplayID: ScreenOverlayWindow] = [:]
    private var currentActiveWindowID: CGWindowID?
    private var currentActiveWindowBounds: NSRect?
    private var predictedWindowID: CGWindowID?
    private var predictedBounds: NSRect?
    private var predictedUntil: CFTimeInterval = 0
    private var activeTransition: TransitionKind = .none
    private var transitionStartTime: CFTimeInterval = 0
    private var animationTimer: Timer?
    private var pollTimer: Timer?
    private var mouseMonitor: Any?
    private var workspaceObservers: [NSObjectProtocol] = []
    private var defaultObservers: [NSObjectProtocol] = []

    init(settings: Settings) {
        self.settings = settings
        syncScreens()
        installMonitors()
        evaluateActiveWindow()
    }

    func stop() {
        animationTimer?.invalidate()
        animationTimer = nil
        pollTimer?.invalidate()
        pollTimer = nil

        if let mouseMonitor {
            NSEvent.removeMonitor(mouseMonitor)
            self.mouseMonitor = nil
        }

        let wsCenter = NSWorkspace.shared.notificationCenter
        for observer in workspaceObservers {
            wsCenter.removeObserver(observer)
        }
        workspaceObservers.removeAll()

        let defCenter = NotificationCenter.default
        for observer in defaultObservers {
            defCenter.removeObserver(observer)
        }
        defaultObservers.removeAll()

        for window in screens.values {
            window.close()
        }
        screens.removeAll()
    }

    func handleSettingsChanged() {
        if !settings.isEnabled {
            beginFadeOutIfNeeded()
            return
        }

        let snapshot = ActiveWindowDetector.snapshot()
        if let activeID = snapshot.activeWindowID {
            if currentActiveWindowID != activeID {
                predictedWindowID = nil
                predictedBounds = nil
                predictedUntil = 0
                transitionToActiveWindow(activeID, newBounds: snapshot.activeWindowBounds)
            } else if case .none = activeTransition {
                currentActiveWindowBounds = snapshot.activeWindowBounds
                let currentVis = screens.values.first?.currentBaseVisibility ?? 0.0
                if currentVis < 0.999 {
                    beginFadeIn(
                        to: activeID,
                        bounds: snapshot.activeWindowBounds,
                        startVisibility: Double(currentVis)
                    )
                } else {
                    applySteadyStateSettings()
                }
            } else {
                // Mid-transition: animation tick reads live settings directly.
                tickTransition()
            }
        } else {
            currentActiveWindowID = nil
            currentActiveWindowBounds = nil
            beginFadeOutIfNeeded()
        }
    }

    private func installMonitors() {
        let wsCenter = NSWorkspace.shared.notificationCenter
        let wsNames: [NSNotification.Name] = [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
            NSWorkspace.activeSpaceDidChangeNotification
        ]
        for name in wsNames {
            let obs = wsCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.evaluateActiveWindow()
            }
            workspaceObservers.append(obs)
        }

        let screenObs = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.syncScreens()
            self?.evaluateActiveWindow()
        }
        defaultObservers.append(screenObs)

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            DispatchQueue.main.async {
                if event.type == .leftMouseDown {
                    self?.handleMouseDown(event)
                } else {
                    self?.evaluateActiveWindow()
                }
            }
        }

        let poll = Timer(timeInterval: 0.016, repeats: true) { [weak self] _ in
            self?.evaluateActiveWindow()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
    }

    private func handleMouseDown(_ event: NSEvent) {
        guard settings.isEnabled else { return }
        guard !event.modifierFlags.contains(.command) else { return }

        guard let hit = ActiveWindowDetector.windowAtScreenPoint(NSEvent.mouseLocation) else {
            return
        }

        guard hit.id != currentActiveWindowID else { return }

        predictedWindowID = hit.id
        predictedBounds = hit.bounds
        predictedUntil = CACurrentMediaTime() + 0.2
        transitionToActiveWindow(hit.id, newBounds: hit.bounds)
    }

    private func syncScreens() {
        var activeDisplayIDs = Set<CGDirectDisplayID>()

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? CGDirectDisplayID(index + 1)
            activeDisplayIDs.insert(displayID)

            if let existing = screens[displayID] {
                existing.updateFrame(screen.frame)
            } else {
                let overlay = ScreenOverlayWindow(
                    frame: screen.frame,
                    blurRadius: CGFloat(settings.blurRadius),
                    dimAlpha: CGFloat(settings.dimAlpha)
                )
                screens[displayID] = overlay
            }
        }

        let removedIDs = screens.keys.filter { !activeDisplayIDs.contains($0) }
        for id in removedIDs {
            screens[id]?.close()
            screens.removeValue(forKey: id)
        }
    }

    private func evaluateActiveWindow() {
        guard settings.isEnabled else {
            beginFadeOutIfNeeded()
            return
        }

        let snapshot = ActiveWindowDetector.snapshot()

        if let predictedID = predictedWindowID {
            if snapshot.activeWindowID == predictedID {
                predictedWindowID = nil
                predictedBounds = nil
                predictedUntil = 0
            } else if CACurrentMediaTime() < predictedUntil {
                return
            } else {
                predictedWindowID = nil
                predictedBounds = nil
                predictedUntil = 0
            }
        }

        guard let activeID = snapshot.activeWindowID else {
            currentActiveWindowID = nil
            currentActiveWindowBounds = nil
            beginFadeOutIfNeeded()
            return
        }

        if activeID != currentActiveWindowID {
            transitionToActiveWindow(activeID, newBounds: snapshot.activeWindowBounds)
            return
        }

        // In steady state, update cutout mask immediately if the active window moved or resized.
        if case .none = activeTransition {
            if snapshot.activeWindowBounds != currentActiveWindowBounds {
                currentActiveWindowBounds = snapshot.activeWindowBounds
                applySteadyStateSettings()
            }
        }
    }

    private func transitionToActiveWindow(_ newID: CGWindowID, newBounds: NSRect?) {
        let previousID = currentActiveWindowID
        let oldBounds = currentActiveWindowBounds
        currentActiveWindowID = newID
        currentActiveWindowBounds = newBounds

        let currentVis = screens.values.map { Double($0.currentBaseVisibility) }.max() ?? 0.0
        if previousID == nil || currentVis <= 0.01 {
            beginFadeIn(to: newID, bounds: newBounds, startVisibility: currentVis)
            return
        }

        activeTransition = .switchWindow(
            newID: newID,
            oldBounds: oldBounds,
            newBounds: newBounds,
            primaryStartVisibility: currentVis
        )
        startAnimationLoop()
    }

    private func beginFadeIn(to windowID: CGWindowID, bounds: NSRect?, startVisibility: Double) {
        currentActiveWindowID = windowID
        currentActiveWindowBounds = bounds
        activeTransition = .fadeIn(windowID: windowID, bounds: bounds, startVisibility: startVisibility)
        startAnimationLoop()
    }

    private func beginFadeOutIfNeeded() {
        let currentVis = screens.values.map { Double($0.currentBaseVisibility) }.max() ?? 0.0
        guard currentVis > 0.001 else {
            if case .none = activeTransition { return }
            finishTransitionToZero()
            return
        }

        if case .fadeOut = activeTransition {
            return
        }

        activeTransition = .fadeOut(
            bounds: currentActiveWindowBounds,
            startVisibility: currentVis
        )
        startAnimationLoop()
    }

    private func applySteadyStateSettings() {
        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)
        for window in screens.values {
            window.showSteadyState(
                activeRectGlobal: currentActiveWindowBounds,
                blurRadius: radius,
                dimAlpha: dim,
                visibility: 1.0
            )
        }
    }

    private func startAnimationLoop() {
        animationTimer?.invalidate()
        transitionStartTime = CACurrentMediaTime()

        let timer = Timer(timeInterval: 0.008, repeats: true) { [weak self] _ in
            self?.tickTransition()
        }
        RunLoop.main.add(timer, forMode: .common)
        animationTimer = timer
        tickTransition()
    }

    private func tickTransition() {
        let elapsed = CACurrentMediaTime() - transitionStartTime
        let duration = max(0.01, settings.transitionDuration)
        let progress = min(max(elapsed / duration, 0.0), 1.0)
        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)

        switch activeTransition {
        case .none:
            animationTimer?.invalidate()
            animationTimer = nil

        case let .switchWindow(_, oldBounds, newBounds, primaryStartVisibility):
            let (_, secondaryFactor, unblurFactor) = BlurTransitionMath.overlayVisibilities(progress: progress)
            let primaryVis = CGFloat(BlurTransitionMath.fadeInVisibility(from: primaryStartVisibility, progress: progress))
            let blurInVis = CGFloat(secondaryFactor)
            let unblurVis = CGFloat(primaryStartVisibility * unblurFactor)

            if progress >= 1.0 {
                animationTimer?.invalidate()
                animationTimer = nil
                activeTransition = .none
                applySteadyStateSettings()
                return
            }

            for window in screens.values {
                window.showSwitchTransition(
                    oldRectGlobal: oldBounds,
                    newRectGlobal: newBounds,
                    blurRadius: radius,
                    dimAlpha: dim,
                    primaryVis: primaryVis,
                    blurInVis: blurInVis,
                    unblurVis: unblurVis
                )
            }

        case let .fadeIn(_, bounds, startVisibility):
            let vis = CGFloat(BlurTransitionMath.fadeInVisibility(from: startVisibility, progress: progress))
            for window in screens.values {
                window.showSteadyState(
                    activeRectGlobal: bounds,
                    blurRadius: radius,
                    dimAlpha: dim,
                    visibility: vis
                )
            }
            if progress >= 1.0 {
                animationTimer?.invalidate()
                animationTimer = nil
                activeTransition = .none
            }

        case let .fadeOut(bounds, startVisibility):
            let vis = CGFloat(BlurTransitionMath.fadeOutVisibility(from: startVisibility, progress: progress))
            if progress >= 1.0 {
                finishTransitionToZero()
                return
            }
            for window in screens.values {
                window.showSteadyState(
                    activeRectGlobal: bounds,
                    blurRadius: radius,
                    dimAlpha: dim,
                    visibility: vis
                )
            }
        }
    }

    private func finishTransitionToZero() {
        animationTimer?.invalidate()
        animationTimer = nil
        activeTransition = .none
        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)
        for window in screens.values {
            window.hideAll(blurRadius: radius, dimAlpha: dim)
        }
    }
}

// MARK: - Menu Bar Slider Custom View

final class SliderMenuItemView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let valueLabel = NSTextField(labelWithString: "")
    let slider: NSSlider
    private let formatter: (Double) -> String
    private let onValueChanged: (Double) -> Void

    init(
        title: String,
        minValue: Double,
        maxValue: Double,
        initialValue: Double,
        formatter: @escaping (Double) -> String,
        onValueChanged: @escaping (Double) -> Void
    ) {
        self.formatter = formatter
        self.onValueChanged = onValueChanged
        self.slider = NSSlider(
            value: initialValue,
            minValue: minValue,
            maxValue: maxValue,
            target: nil,
            action: nil
        )
        super.init(frame: NSRect(x: 0, y: 0, width: 256, height: 50))

        titleLabel.stringValue = title
        titleLabel.font = NSFont.systemFont(ofSize: 12, weight: .medium)
        titleLabel.textColor = .labelColor

        valueLabel.stringValue = formatter(initialValue)
        valueLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.alignment = .right

        slider.isContinuous = true
        slider.controlSize = .small
        slider.target = self
        slider.action = #selector(sliderDidMove(_:))

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        valueLabel.translatesAutoresizingMaskIntoConstraints = false
        slider.translatesAutoresizingMaskIntoConstraints = false

        addSubview(titleLabel)
        addSubview(valueLabel)
        addSubview(slider)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 6),

            valueLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            valueLabel.centerYAnchor.constraint(equalTo: titleLabel.centerYAnchor),
            valueLabel.leadingAnchor.constraint(greaterThanOrEqualTo: titleLabel.trailingAnchor, constant: 8),

            slider.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            slider.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            slider.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 4),
            slider.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6)
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(value: Double) {
        slider.doubleValue = value
        valueLabel.stringValue = formatter(value)
    }

    @objc private func sliderDidMove(_ sender: NSSlider) {
        let value = sender.doubleValue
        valueLabel.stringValue = formatter(value)
        onValueChanged(value)
    }
}

// MARK: - AppDelegate & Menu Bar UI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let settings = Settings()
    private var coordinator: BlurCoordinator?
    private var statusItem: NSStatusItem!
    private var toggleMenuItem: NSMenuItem!
    private var blurSliderView: SliderMenuItemView!
    private var transitionSliderView: SliderMenuItemView!
    private var dimSliderView: SliderMenuItemView!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            if let image = NSImage(
                systemSymbolName: "sparkles.rectangle.stack",
                accessibilityDescription: "bglur"
            ) {
                image.isTemplate = true
                button.image = image
            } else {
                button.title = "bglur"
            }
            button.toolTip = "bglur — Focus Window Blur"
        }

        setupMenu()
        syncMenuState()

        let coordinator = BlurCoordinator(settings: settings)
        self.coordinator = coordinator

        settings.onChange = { [weak self, weak coordinator] in
            self?.syncMenuState()
            coordinator?.handleSettingsChanged()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    private func setupMenu() {
        let menu = NSMenu()

        toggleMenuItem = NSMenuItem(
            title: "Enable Blur",
            action: #selector(toggleEnabled(_:)),
            keyEquivalent: "b"
        )
        toggleMenuItem.target = self
        menu.addItem(toggleMenuItem)

        menu.addItem(.separator())

        blurSliderView = SliderMenuItemView(
            title: "Blur Radius",
            minValue: Settings.blurRadiusRange.lowerBound,
            maxValue: Settings.blurRadiusRange.upperBound,
            initialValue: settings.blurRadius,
            formatter: { "\(Int($0.rounded())) px" },
            onValueChanged: { [weak self] value in
                self?.settings.blurRadius = value
            }
        )
        let blurItem = NSMenuItem()
        blurItem.view = blurSliderView
        menu.addItem(blurItem)

        transitionSliderView = SliderMenuItemView(
            title: "Transition Speed",
            minValue: Settings.transitionDurationRange.lowerBound,
            maxValue: Settings.transitionDurationRange.upperBound,
            initialValue: settings.transitionDuration,
            formatter: { value in
                let ms = Int((value * 1000.0).rounded())
                return "\(ms) ms"
            },
            onValueChanged: { [weak self] value in
                self?.settings.transitionDuration = value
            }
        )
        let transitionItem = NSMenuItem()
        transitionItem.view = transitionSliderView
        menu.addItem(transitionItem)

        dimSliderView = SliderMenuItemView(
            title: "Dimming",
            minValue: Settings.dimAlphaRange.lowerBound,
            maxValue: Settings.dimAlphaRange.upperBound,
            initialValue: settings.dimAlpha,
            formatter: { "\(Int(($0 * 100.0).rounded()))%" },
            onValueChanged: { [weak self] value in
                self?.settings.dimAlpha = value
            }
        )
        let dimItem = NSMenuItem()
        dimItem.view = dimSliderView
        menu.addItem(dimItem)

        menu.addItem(.separator())

        let resetItem = NSMenuItem(
            title: "Reset Defaults",
            action: #selector(resetDefaults(_:)),
            keyEquivalent: ""
        )
        resetItem.target = self
        menu.addItem(resetItem)

        let quitItem = NSMenuItem(
            title: "Quit bglur",
            action: #selector(quitApp(_:)),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func syncMenuState() {
        toggleMenuItem?.state = settings.isEnabled ? .on : .off
        blurSliderView?.update(value: settings.blurRadius)
        transitionSliderView?.update(value: settings.transitionDuration)
        dimSliderView?.update(value: settings.dimAlpha)

        if let button = statusItem?.button {
            button.appearsDisabled = !settings.isEnabled
        }
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        settings.isEnabled.toggle()
    }

    @objc private func resetDefaults(_ sender: Any?) {
        settings.resetDefaults()
    }

    @objc private func quitApp(_ sender: Any?) {
        NSApp.terminate(nil)
    }
}

// MARK: - Self-Test Runner

enum SelfTest {
    static func check(_ condition: Bool, _ message: String) {
        if !condition {
            fputs("SELF-TEST FAILED: \(message)\n", stderr)
            exit(1)
        }
    }

    static func run() -> Never {
        _ = NSApplication.shared

        // 1. Verify easing math & anti-flash overlap curve
        check(abs(BlurTransitionMath.easeOutCubic(0.0) - 0.0) < 1e-9, "easeOutCubic(0) must be 0")
        check(abs(BlurTransitionMath.easeOutCubic(0.5) - 0.875) < 1e-9, "easeOutCubic(0.5) must be 0.875")
        check(abs(BlurTransitionMath.easeOutCubic(1.0) - 1.0) < 1e-9, "easeOutCubic(1) must be 1")

        let start = BlurTransitionMath.overlayVisibilities(progress: 0.0)
        check(
            start.primary == 1.0 && start.secondary == 0.0 && start.unblur == 1.0,
            "At t=0 primary=1.0, secondary=0.0, unblur=1.0"
        )

        let midOverlap = BlurTransitionMath.overlayVisibilities(progress: 0.35)
        check(midOverlap.primary == 1.0 && midOverlap.secondary > 0.72, "At t=0.35 primary remains 1.0 while secondary > 0.72")
        check(abs(midOverlap.unblur + midOverlap.secondary - 1.0) < 1e-9, "At t=0.35 unblur + secondary must equal 1.0")

        for sampleT in [0.1, 0.25, 0.5, 0.75, 0.9] {
            let sample = BlurTransitionMath.overlayVisibilities(progress: sampleT)
            check(abs(sample.unblur + sample.secondary - 1.0) < 1e-9, "At t=\(sampleT) unblur + secondary must equal 1.0")
        }

        let end = BlurTransitionMath.overlayVisibilities(progress: 1.0)
        check(
            abs(end.primary - 0.0) < 1e-9 && abs(end.secondary - 1.0) < 1e-9 && abs(end.unblur - 0.0) < 1e-9,
            "At t=1 primary=0.0, secondary=1.0, unblur=0.0"
        )

        // 2. Verify ScreenOverlayWindow (level 1, 3 pre-warmed masked PureBlurViews, bidirectional switch masks)
        let overlay = ScreenOverlayWindow(
            frame: NSRect(x: 0, y: 0, width: 400, height: 300),
            blurRadius: 36.0,
            dimAlpha: 0.12
        )
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        overlay.baseView.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 1.0)
        overlay.baseView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let backdrop = overlay.baseView.findBackdropLayer() else {
            fputs("SELF-TEST FAILED: CABackdropLayer 'backdrop' not found in PureBlurView\n", stderr)
            exit(1)
        }

        let appliedRadius = (backdrop.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
        let appliedSaturate = (backdrop.value(forKeyPath: "filters.colorSaturate.inputAmount") as? NSNumber)?.doubleValue
        check(appliedRadius == 36.0, "Expected backdrop gaussianBlur.inputRadius == 36.0, got \(String(describing: appliedRadius))")
        check(appliedSaturate == 1.0, "Expected backdrop colorSaturate.inputAmount == 1.0, got \(String(describing: appliedSaturate))")

        let suppressed = overlay.baseView.findSuppressedLayers()
        check(!suppressed.isEmpty, "Expected suppressed fill/tone/Chameleon layers to be present")
        for layer in suppressed {
            check(layer.isHidden && layer.opacity == 0.0, "Expected \(layer.name ?? "?") to be hidden with opacity 0")
        }

        overlay.baseView.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 0.5)
        let halfRadius = (backdrop.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
        check(halfRadius == 18.0, "Expected half-visibility gaussianBlur.inputRadius == 18.0, got \(String(describing: halfRadius))")
        check(abs(overlay.baseView.alphaValue - 1.0) < 0.001, "Expected alphaValue == 1.0 at visibility 0.5")

        overlay.baseView.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 0.125)
        let lowRadius = (backdrop.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
        let lowScale = (backdrop.value(forKey: "scale") as? NSNumber)?.doubleValue
        check(lowRadius == 4.5, "Expected low-visibility gaussianBlur.inputRadius == 4.5, got \(String(describing: lowRadius))")
        check(lowScale == 1.0, "Expected backdrop scale == 1.0 for blurRadius < 8.0, got \(String(describing: lowScale))")
        check(abs(overlay.baseView.alphaValue - 0.5) < 0.001, "Expected alphaValue == 0.5 at visibility 0.125")

        let rectA = NSRect(x: 20, y: 40, width: 140, height: 180)
        let rectB = NSRect(x: 200, y: 40, width: 160, height: 180)
        let centerA = CGPoint(x: rectA.midX, y: rectA.midY)
        let centerB = CGPoint(x: rectB.midX, y: rectB.midY)

        // Steady state on Window A: baseView excludes A, includes B; unblurView stays hot at 1.0 behind empty mask
        overlay.showSteadyState(activeRectGlobal: rectA, blurRadius: 24.0, dimAlpha: 0.05, visibility: 1.0)
        check(overlay.baseView.currentVisibility == 1.0, "Steady state baseView must be at visibility 1.0")
        check(overlay.unblurView.currentVisibility == 1.0, "Steady state unblurView must remain pre-warmed at 1.0")
        check(overlay.blurInView.currentVisibility == 0.0, "Steady state blurInView must be at 0.0")
        check(overlay.baseView.currentMaskPath?.contains(centerA) == false, "baseView mask must exclude active Window A")
        check(overlay.baseView.currentMaskPath?.contains(centerB) == true, "baseView mask must include inactive Window B")
        check(overlay.unblurView.currentMaskPath?.isEmpty == true, "Steady state unblurView mask must be empty")

        // Switch start (p = 0.0): newly active Window B starts at unblurView visibility 1.0
        overlay.showSwitchTransition(
            oldRectGlobal: rectA,
            newRectGlobal: rectB,
            blurRadius: 24.0,
            dimAlpha: 0.05,
            primaryVis: 1.0,
            blurInVis: 0.0,
            unblurVis: 1.0
        )
        check(overlay.unblurView.currentVisibility == 1.0, "Switch p=0 unblurView must start at visibility 1.0")
        check(overlay.unblurView.currentMaskPath?.contains(centerB) == true, "Switch p=0 unblurView mask must cover Window B")
        check(overlay.unblurView.currentMaskPath?.contains(centerA) == false, "Switch p=0 unblurView mask must not cover Window A")
        check(overlay.blurInView.currentMaskPath?.contains(centerA) == true, "Switch p=0 blurInView mask must cover Window A")
        check(overlay.baseView.currentMaskPath?.contains(centerA) == false && overlay.baseView.currentMaskPath?.contains(centerB) == false, "baseView mask must exclude both A and B during switch")

        // Mid-switch (p = 0.5)
        overlay.showSwitchTransition(
            oldRectGlobal: rectA,
            newRectGlobal: rectB,
            blurRadius: 24.0,
            dimAlpha: 0.05,
            primaryVis: 1.0,
            blurInVis: 0.5,
            unblurVis: 0.5
        )
        check(overlay.unblurView.currentVisibility == 0.5, "Mid-switch unblurView visibility must be 0.5")
        check(overlay.blurInView.currentVisibility == 0.5, "Mid-switch blurInView visibility must be 0.5")

        // Completion (p = 1.0 -> steady state on Window B)
        overlay.showSteadyState(activeRectGlobal: rectB, blurRadius: 24.0, dimAlpha: 0.05, visibility: 1.0)
        check(overlay.baseView.currentMaskPath?.contains(centerA) == true, "Completed steady state baseView must blur Window A")
        check(overlay.baseView.currentMaskPath?.contains(centerB) == false, "Completed steady state baseView must exclude Window B")
        check(overlay.unblurView.currentVisibility == 1.0 && overlay.unblurView.currentMaskPath?.isEmpty == true, "Completed unblurView must re-warm at 1.0 behind empty mask")

        overlay.hideAll(blurRadius: 24.0, dimAlpha: 0.05)
        check(overlay.baseView.alphaValue == 0.0 && overlay.unblurView.alphaValue == 0.0, "hideAll must zero view alphas")
        check(overlay.level == NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue + 1), "ScreenOverlayWindow must sit at normal + 1")
        check(!overlay.collectionBehavior.contains(.fullScreenAuxiliary), "Overlay must not use .fullScreenAuxiliary")
        let fullScreenRect = NSRect(x: 0, y: 0, width: 3360, height: 1890)
        check(overlay.constrainFrameRect(fullScreenRect, to: NSScreen.main) == fullScreenRect, "Overlay constrainFrameRect must not clip frame below menu bar")
        overlay.close()

        // 3. Verify ActiveWindowDetector coordinate conversion and fullscreen/space-switch resolution rules
        let converted = ActiveWindowDetector.convertCGWindowBoundsToAppKit(
            CGRect(x: 100, y: 30, width: 800, height: 600),
            primaryScreenHeight: 1000
        )
        check(
            converted == NSRect(x: 100, y: 370, width: 800, height: 600),
            "Expected Quartz->AppKit conversion (100, 370, 800, 600), got \(converted)"
        )
        let makeWindow: (Int, Int, pid_t, String?, String?, Double, CGRect) -> [String: Any] = {
            num, layer, pid, owner, name, alpha, rect in
            var dict: [String: Any] = [
                kCGWindowNumber as String: num,
                kCGWindowLayer as String: layer,
                kCGWindowOwnerPID as String: pid,
                kCGWindowAlpha as String: alpha,
                kCGWindowBounds as String: [
                    "X": rect.origin.x,
                    "Y": rect.origin.y,
                    "Width": rect.size.width,
                    "Height": rect.size.height
                ]
            ]
            if let owner { dict[kCGWindowOwnerName as String] = owner }
            if let name { dict[kCGWindowName as String] = name }
            return dict
        }

        let fullscreenSample: [[String: Any]] = [
            makeWindow(101, 0, 500, "Zed", "Workspace", 1.0, CGRect(x: 0, y: 30, width: 1440, height: 870)),
            makeWindow(102, -2147483622, 10, "WindowManager", "Fullscreen Backdrop", 1.0, CGRect(x: 0, y: 0, width: 1440, height: 900))
        ]
        let fullscreenResolved = ActiveWindowDetector.resolveActiveWindowID(
            from: fullscreenSample,
            frontPID: 500,
            ignoringPID: 999
        )
        check(fullscreenResolved.activeWindowID == nil, "Single-window Fullscreen Space must resolve activeWindowID to nil")

        let spaceSwitchSample: [[String: Any]] = [
            makeWindow(201, 0, 600, "Xcode", "Project", 1.0, CGRect(x: 100, y: 100, width: 1200, height: 800)),
            makeWindow(202, 0, 700, "Safari", "Docs", 1.0, CGRect(x: 0, y: 50, width: 1000, height: 700))
        ]
        let spaceSwitchResolved = ActiveWindowDetector.resolveActiveWindowID(
            from: spaceSwitchSample,
            frontPID: 500, // front app lives on a different Space
            ignoringPID: 999
        )
        check(spaceSwitchResolved.activeWindowID == 201, "Space-switch fallback must pick topmost window (201) on current Space")

        let frontAppResolved = ActiveWindowDetector.resolveActiveWindowID(
            from: spaceSwitchSample,
            frontPID: 700,
            ignoringPID: 999
        )
        check(frontAppResolved.activeWindowID == 202, "Frontmost app window (202) should be preferred when present on Space")

        let hitSample: [[String: Any]] = [
            makeWindow(300, 1, 999, "bglur", "", 1.0, CGRect(x: 0, y: 0, width: 1440, height: 900)), // own level-1 overlay
            makeWindow(301, 24, 1, "Window Server", "Menubar", 1.0, CGRect(x: 0, y: 0, width: 1440, height: 30)),
            makeWindow(302, 0, 600, "Xcode", "Project", 1.0, CGRect(x: 100, y: 100, width: 600, height: 400)),
            makeWindow(303, 0, 700, "Safari", "Docs", 1.0, CGRect(x: 500, y: 100, width: 600, height: 400))
        ]
        let menuClick = ActiveWindowDetector.resolveWindowAtScreenPoint(
            NSPoint(x: 200, y: 885), // inside top 30px menubar in AppKit (900 - 30 = 870..900)
            from: hitSample,
            ignoringPID: 999,
            primaryScreenSize: CGSize(width: 1440, height: 900)
        )
        check(menuClick == nil, "Click on menubar must not hit-test a layer-0 window")

        let bgWindowClick = ActiveWindowDetector.resolveWindowAtScreenPoint(
            NSPoint(x: 900, y: 600), // inside Safari (500..1100, yQuartz 100..500 -> yAppKit 400..800)
            from: hitSample,
            ignoringPID: 999,
            primaryScreenSize: CGSize(width: 1440, height: 900)
        )
        check(bgWindowClick?.id == 303, "Click on background Safari window must hit window 303")

        // 4. Verify CGWindowListCopyWindowInfo live query runs cleanly
        let snapshot = ActiveWindowDetector.snapshot()
        print("Self-test window snapshot: activeWindowID=\(snapshot.activeWindowID.map(String.init) ?? "none"), layer0Count=\(snapshot.orderedWindowNumbers.count)")

        print("ALL SELF-TESTS PASSED")
        exit(0)
    }
}

// MARK: - Entry Point

if CommandLine.arguments.contains("--self-test") {
    SelfTest.run()
} else {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
