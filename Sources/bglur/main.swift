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

    /// Computes primary (outgoing) and secondary (incoming) overlay visibilities.
    /// Primary remains at 1.0 until secondary has ramped past p = 0.35 (~72.5% blur),
    /// ensuring deeper background windows never flash unblurred during focus switches.
    static func overlayVisibilities(progress: Double) -> (primary: Double, secondary: Double) {
        let p = min(max(progress, 0.0), 1.0)
        let secondary = easeOutCubic(p)
        let primary: Double
        if p <= 0.35 {
            primary = 1.0
        } else {
            let q = (p - 0.35) / 0.65
            primary = max(0.0, 1.0 - easeOutCubic(q))
        }
        return (primary, secondary)
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

// MARK: - Pure Blur View & Overlay Window

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

    private let tintLayer = CALayer()
    private static let suppressedLayerNames: Set<String> = ["fill", "tone", "Chameleon"]

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        blendingMode = .behindWindow
        material = .fullScreenUI
        state = .active
        wantsLayer = true
        autoresizingMask = [.width, .height]

        tintLayer.name = "bglur.tint"
        tintLayer.zPosition = 1000
        tintLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
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

    func applyVisualState() {
        guard let root = layer else { return }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }

        if tintLayer.superlayer !== root {
            root.addSublayer(tintLayer)
        }
        tintLayer.frame = root.bounds
        tintLayer.backgroundColor = NSColor.black.withAlphaComponent(dimAlpha).cgColor
        tintLayer.isHidden = dimAlpha <= 0.0001

        for sublayer in root.sublayers ?? [] where sublayer !== tintLayer {
            configureBackdropHierarchy(in: sublayer)
        }

        if let win = window, win.windowNumber > 0 {
            CGSSetWindowBackgroundBlurRadius(
                CGSMainConnectionID(),
                UInt32(win.windowNumber),
                Int32(blurRadius.rounded())
            )
        }
    }

    private func configureBackdropHierarchy(in layer: CALayer) {
        if layer.name == "backdrop" {
            layer.isHidden = false
            layer.opacity = 1.0
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

final class BlurOverlayWindow: NSWindow {
    let blurView: PureBlurView
    private(set) var currentVisibility: CGFloat = 0.0

    init(frame: NSRect) {
        let contentFrame = NSRect(origin: .zero, size: frame.size)
        self.blurView = PureBlurView(frame: contentFrame)
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
        level = .normal
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = blurView
    }

    override func constrainFrameRect(_ frameRect: NSRect, to screen: NSScreen?) -> NSRect {
        frameRect
    }

    func apply(blurRadius: CGFloat, dimAlpha: CGFloat, visibility: CGFloat) {
        let clamped = min(max(visibility, 0.0), 1.0)
        currentVisibility = clamped
        blurView.blurRadius = blurRadius * clamped
        blurView.dimAlpha = dimAlpha * clamped
        alphaValue = clamped > 0.001 ? min(1.0, clamped * 1.25) : 0.0
    }
}

// MARK: - Active Window Detection

struct WindowZOrderSnapshot {
    let activeWindowID: CGWindowID?
    let orderedWindowNumbers: [Int]
}

enum ActiveWindowDetector {
    static func snapshot(ignoringPID: pid_t = ProcessInfo.processInfo.processIdentifier) -> WindowZOrderSnapshot {
        let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        let frontPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        return resolveActiveWindowID(from: rawList, frontPID: frontPID, ignoringPID: ignoringPID)
    }

    static func orderedLayer0WindowNumbers() -> [Int] {
        let rawList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return rawList.compactMap { info in
            guard let layer = info[kCGWindowLayer as String] as? Int, layer == 0 else {
                return nil
            }
            return info[kCGWindowNumber as String] as? Int
        }
    }

    static func resolveActiveWindowID(
        from rawList: [[String: Any]],
        frontPID: pid_t?,
        ignoringPID: pid_t
    ) -> WindowZOrderSnapshot {
        var hasFullscreenBackdrop = false
        var qualifyingWindowCount = 0
        var frontAppWindowID: CGWindowID?
        var topmostAnyWindowID: CGWindowID?
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
            }

            if let frontPID, frontPID != ignoringPID, ownerPID == frontPID, frontAppWindowID == nil {
                frontAppWindowID = CGWindowID(windowNum)
            }
        }

        let activeID: CGWindowID?
        if hasFullscreenBackdrop && qualifyingWindowCount <= 1 {
            activeID = nil
        } else {
            activeID = frontAppWindowID ?? topmostAnyWindowID
        }

        return WindowZOrderSnapshot(
            activeWindowID: activeID,
            orderedWindowNumbers: orderedNumbers
        )
    }
}

// MARK: - Screen Overlay Pair & Blur Coordinator

final class ScreenOverlayPair {
    var primary: BlurOverlayWindow
    var secondary: BlurOverlayWindow

    init(frame: NSRect, blurRadius: CGFloat, dimAlpha: CGFloat) {
        primary = BlurOverlayWindow(frame: frame)
        secondary = BlurOverlayWindow(frame: frame)

        // Pre-warm both overlay windows on-screen at alpha = 0 so CABackdropLayer
        // initializes and suppresses AppKit's white fill layer before first blur.
        primary.orderBack(nil)
        secondary.orderBack(nil)
        primary.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)
        secondary.apply(blurRadius: blurRadius, dimAlpha: dimAlpha, visibility: 0.0)
        primary.blurView.layoutSubtreeIfNeeded()
        secondary.blurView.layoutSubtreeIfNeeded()
    }

    func swap() {
        Swift.swap(&primary, &secondary)
    }

    func updateFrame(_ frame: NSRect) {
        if primary.frame != frame {
            primary.setFrame(frame, display: true)
        }
        if secondary.frame != frame {
            secondary.setFrame(frame, display: true)
        }
    }

    func closeAll() {
        primary.close()
        secondary.close()
    }
}

final class BlurCoordinator {
    private enum TransitionKind {
        case none
        case switchWindow(newID: CGWindowID, primaryStartVisibility: Double)
        case fadeOut(startPrimaryVisibility: Double, startSecondaryVisibility: Double)
        case fadeIn(windowID: CGWindowID, startVisibility: Double)
    }

    private let settings: Settings
    private var pairs: [CGDirectDisplayID: ScreenOverlayPair] = [:]
    private var currentActiveWindowID: CGWindowID?
    private var pendingZOrderVerifyWindowID: CGWindowID?
    private var unorderableWindowID: CGWindowID?
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

        for pair in pairs.values {
            pair.closeAll()
        }
        pairs.removeAll()
    }

    func handleSettingsChanged() {
        if !settings.isEnabled {
            beginFadeOutIfNeeded()
            return
        }

        let snapshot = ActiveWindowDetector.snapshot()
        if let activeID = snapshot.activeWindowID {
            if currentActiveWindowID != activeID {
                unorderableWindowID = nil
                pendingZOrderVerifyWindowID = nil
                transitionToActiveWindow(activeID)
            } else if unorderableWindowID == activeID {
                return
            } else if case .none = activeTransition {
                let currentVis = pairs.values.first?.primary.currentVisibility ?? 0.0
                if currentVis < 0.999 {
                    beginFadeIn(to: activeID, startVisibility: Double(currentVis))
                } else {
                    applySteadyStateSettings()
                }
            } else {
                // Mid-transition: animation tick reads live settings directly.
                tickTransition()
            }
        } else {
            currentActiveWindowID = nil
            unorderableWindowID = nil
            pendingZOrderVerifyWindowID = nil
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

        mouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .leftMouseUp]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.evaluateActiveWindow()
            }
        }

        let poll = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            self?.evaluateActiveWindow()
        }
        RunLoop.main.add(poll, forMode: .common)
        pollTimer = poll
    }

    private func syncScreens() {
        var activeDisplayIDs = Set<CGDirectDisplayID>()

        for (index, screen) in NSScreen.screens.enumerated() {
            let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)
                .map { CGDirectDisplayID($0.uint32Value) } ?? CGDirectDisplayID(index + 1)
            activeDisplayIDs.insert(displayID)

            if let existing = pairs[displayID] {
                existing.updateFrame(screen.frame)
            } else {
                let pair = ScreenOverlayPair(
                    frame: screen.frame,
                    blurRadius: CGFloat(settings.blurRadius),
                    dimAlpha: CGFloat(settings.dimAlpha)
                )
                pairs[displayID] = pair
            }
        }

        let removedIDs = pairs.keys.filter { !activeDisplayIDs.contains($0) }
        for id in removedIDs {
            pairs[id]?.closeAll()
            pairs.removeValue(forKey: id)
        }
    }

    private func evaluateActiveWindow() {
        guard settings.isEnabled else {
            beginFadeOutIfNeeded()
            return
        }

        let snapshot = ActiveWindowDetector.snapshot()
        guard let activeID = snapshot.activeWindowID else {
            currentActiveWindowID = nil
            unorderableWindowID = nil
            pendingZOrderVerifyWindowID = nil
            beginFadeOutIfNeeded()
            return
        }

        if activeID != currentActiveWindowID {
            unorderableWindowID = nil
            pendingZOrderVerifyWindowID = nil
            transitionToActiveWindow(activeID)
            return
        }

        // Steady-state check: keep primary right below active window if WindowServer reordered windows.
        if case .none = activeTransition {
            if unorderableWindowID == activeID {
                return
            }
            ensureSteadyZOrder(activeWindowID: activeID, snapshot: snapshot)
        }
    }

    private func ensureSteadyZOrder(activeWindowID: CGWindowID, snapshot: WindowZOrderSnapshot) {
        let activeInt = Int(activeWindowID)
        guard let activeIdx = snapshot.orderedWindowNumbers.firstIndex(of: activeInt) else { return }

        let ownOverlayNumbers = Set(pairs.values.flatMap { [$0.primary.windowNumber, $0.secondary.windowNumber] })
        var hasOutOfOrderAbove = false
        var needsReorder = false

        for pair in pairs.values {
            let overlayNum = pair.primary.windowNumber
            if let overlayIdx = snapshot.orderedWindowNumbers.firstIndex(of: overlayNum) {
                let outOfOrderAbove = overlayIdx < activeIdx
                let intruderBetween = !outOfOrderAbove && snapshot.orderedWindowNumbers[(activeIdx + 1)..<overlayIdx]
                    .contains { !ownOverlayNumbers.contains($0) }
                if outOfOrderAbove {
                    hasOutOfOrderAbove = true
                    needsReorder = true
                } else if intruderBetween {
                    needsReorder = true
                }
            } else {
                needsReorder = true
            }
        }

        if hasOutOfOrderAbove && pendingZOrderVerifyWindowID == activeWindowID {
            // A previous RunLoop cycle already sent order(.below), and WindowServer left it above activeID.
            unorderableWindowID = activeWindowID
            pendingZOrderVerifyWindowID = nil
            finishTransitionToZero()
            return
        }

        if needsReorder {
            for pair in pairs.values {
                pair.primary.order(.below, relativeTo: activeInt)
            }
            pendingZOrderVerifyWindowID = activeWindowID
        } else {
            pendingZOrderVerifyWindowID = nil
            if let minVisibility = pairs.values.map({ Double($0.primary.currentVisibility) }).min(),
               minVisibility < 0.999 {
                beginFadeIn(to: activeWindowID, startVisibility: minVisibility)
            }
        }
    }

    @discardableResult
    private func hideIfOrderedAboveActiveWindow(
        activeWindowID: CGWindowID,
        orderedWindowNumbers: [Int]? = nil
    ) -> Bool {
        let numbers = orderedWindowNumbers ?? ActiveWindowDetector.orderedLayer0WindowNumbers()
        let activeInt = Int(activeWindowID)
        guard let activeIdx = numbers.firstIndex(of: activeInt) else { return false }

        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)
        var hidAny = false

        for pair in pairs.values {
            for overlay in [pair.primary, pair.secondary] where overlay.currentVisibility > 0.001 {
                if let overlayIdx = numbers.firstIndex(of: overlay.windowNumber), overlayIdx < activeIdx {
                    overlay.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
                    hidAny = true
                }
            }
        }

        return hidAny
    }

    private func transitionToActiveWindow(_ newID: CGWindowID) {
        let previousID = currentActiveWindowID
        currentActiveWindowID = newID

        // First active window or resuming from hidden state -> fade in primary smoothly.
        let maxCurrentVisibility = pairs.values.map {
            max(Double($0.primary.currentVisibility), Double($0.secondary.currentVisibility))
        }.max() ?? 0.0

        if previousID == nil || maxCurrentVisibility <= 0.01 {
            beginFadeIn(to: newID, startVisibility: maxCurrentVisibility)
            return
        }

        // If switching rapidly mid-transition where secondary already holds more blur than primary,
        // promote secondary to primary so existing background blur stays continuous without flashing.
        for pair in pairs.values {
            if pair.secondary.currentVisibility > pair.primary.currentVisibility {
                pair.swap()
            }
            pair.secondary.apply(
                blurRadius: CGFloat(settings.blurRadius),
                dimAlpha: CGFloat(settings.dimAlpha),
                visibility: 0.0
            )
            pair.secondary.order(.below, relativeTo: Int(newID))
        }

        let primaryStart = pairs.values.map { Double($0.primary.currentVisibility) }.max() ?? 1.0
        activeTransition = .switchWindow(newID: newID, primaryStartVisibility: primaryStart)
        startAnimationLoop()
    }

    private func beginFadeIn(to windowID: CGWindowID, startVisibility: Double) {
        for pair in pairs.values {
            pair.secondary.apply(
                blurRadius: CGFloat(settings.blurRadius),
                dimAlpha: CGFloat(settings.dimAlpha),
                visibility: 0.0
            )
            pair.primary.order(.below, relativeTo: Int(windowID))
        }
        activeTransition = .fadeIn(windowID: windowID, startVisibility: startVisibility)
        startAnimationLoop()
    }

    private func beginFadeOutIfNeeded() {
        let maxCurrent = pairs.values.map {
            max(Double($0.primary.currentVisibility), Double($0.secondary.currentVisibility))
        }.max() ?? 0.0

        guard maxCurrent > 0.001 else {
            if case .none = activeTransition { return }
            finishTransitionToZero()
            return
        }

        if case .fadeOut = activeTransition {
            return
        }

        let startPrimary = pairs.values.map { Double($0.primary.currentVisibility) }.max() ?? 0.0
        let startSecondary = pairs.values.map { Double($0.secondary.currentVisibility) }.max() ?? 0.0
        activeTransition = .fadeOut(
            startPrimaryVisibility: startPrimary,
            startSecondaryVisibility: startSecondary
        )
        startAnimationLoop()
    }

    private func applySteadyStateSettings() {
        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)
        for pair in pairs.values {
            pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: 1.0)
            pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
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

        case let .switchWindow(newID, primaryStartVisibility):
            if elapsed >= 0.016 && hideIfOrderedAboveActiveWindow(activeWindowID: newID) {
                unorderableWindowID = newID
                finishTransitionToZero()
                return
            }

            let (primaryFactor, secondaryFactor) = BlurTransitionMath.overlayVisibilities(progress: progress)
            let primaryVis = CGFloat(primaryStartVisibility * primaryFactor)
            let secondaryVis = CGFloat(secondaryFactor)

            for pair in pairs.values {
                // Re-assert z-order on every tick so late app window elevation never strands the overlay.
                pair.secondary.order(.below, relativeTo: Int(newID))
                pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: primaryVis)
                pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: secondaryVis)
            }

            if progress >= 1.0 {
                animationTimer?.invalidate()
                animationTimer = nil
                activeTransition = .none
                for pair in pairs.values {
                    pair.swap()
                    pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
                    pair.primary.order(.below, relativeTo: Int(newID))
                    pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: 1.0)
                }
                pendingZOrderVerifyWindowID = newID
            }

        case let .fadeIn(windowID, startVisibility):
            if elapsed >= 0.016 && hideIfOrderedAboveActiveWindow(activeWindowID: windowID) {
                unorderableWindowID = windowID
                finishTransitionToZero()
                return
            }

            let vis = CGFloat(BlurTransitionMath.fadeInVisibility(from: startVisibility, progress: progress))
            for pair in pairs.values {
                pair.primary.order(.below, relativeTo: Int(windowID))
                pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: vis)
                pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
            }
            if progress >= 1.0 {
                animationTimer?.invalidate()
                animationTimer = nil
                activeTransition = .none
                pendingZOrderVerifyWindowID = windowID
            }

        case let .fadeOut(startPrimary, startSecondary):
            let pVis = CGFloat(BlurTransitionMath.fadeOutVisibility(from: startPrimary, progress: progress))
            let sVis = CGFloat(BlurTransitionMath.fadeOutVisibility(from: startSecondary, progress: progress))
            for pair in pairs.values {
                pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: pVis)
                pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: sVis)
            }
            if progress >= 1.0 {
                finishTransitionToZero()
            }
        }
    }

    private func finishTransitionToZero() {
        animationTimer?.invalidate()
        animationTimer = nil
        activeTransition = .none
        let radius = CGFloat(settings.blurRadius)
        let dim = CGFloat(settings.dimAlpha)
        for pair in pairs.values {
            pair.primary.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
            pair.secondary.apply(blurRadius: radius, dimAlpha: dim, visibility: 0.0)
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
        check(start.primary == 1.0 && start.secondary == 0.0, "At t=0 primary=1.0 and secondary=0.0")

        let midOverlap = BlurTransitionMath.overlayVisibilities(progress: 0.35)
        check(midOverlap.primary == 1.0 && midOverlap.secondary > 0.72, "At t=0.35 primary remains 1.0 while secondary > 0.72")

        let end = BlurTransitionMath.overlayVisibilities(progress: 1.0)
        check(abs(end.primary - 0.0) < 1e-9 && abs(end.secondary - 1.0) < 1e-9, "At t=1 primary=0.0 and secondary=1.0")

        // 2. Verify PureBlurView strips fill/tone/Chameleon and customizes gaussianBlur.inputRadius
        let overlay = BlurOverlayWindow(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        overlay.orderBack(nil)
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.1))

        overlay.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 1.0)
        overlay.blurView.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        guard let backdrop = overlay.blurView.findBackdropLayer() else {
            fputs("SELF-TEST FAILED: CABackdropLayer 'backdrop' not found in PureBlurView\n", stderr)
            exit(1)
        }

        let appliedRadius = (backdrop.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
        let appliedSaturate = (backdrop.value(forKeyPath: "filters.colorSaturate.inputAmount") as? NSNumber)?.doubleValue
        check(appliedRadius == 36.0, "Expected backdrop gaussianBlur.inputRadius == 36.0, got \(String(describing: appliedRadius))")
        check(appliedSaturate == 1.0, "Expected backdrop colorSaturate.inputAmount == 1.0, got \(String(describing: appliedSaturate))")

        let suppressed = overlay.blurView.findSuppressedLayers()
        check(!suppressed.isEmpty, "Expected suppressed fill/tone/Chameleon layers to be present")
        for layer in suppressed {
            check(layer.isHidden && layer.opacity == 0.0, "Expected \(layer.name ?? "?") to be hidden with opacity 0")
        }

        overlay.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 0.5)
        let halfRadius = (backdrop.value(forKeyPath: "filters.gaussianBlur.inputRadius") as? NSNumber)?.doubleValue
        check(halfRadius == 18.0, "Expected half-visibility gaussianBlur.inputRadius == 18.0, got \(String(describing: halfRadius))")
        check(abs(overlay.alphaValue - 0.625) < 0.001, "Expected alphaValue == 0.625 at visibility 0.5")

        overlay.apply(blurRadius: 36.0, dimAlpha: 0.12, visibility: 0.0)
        check(overlay.alphaValue == 0.0, "Expected alphaValue == 0.0 at visibility 0.0")
        check(!overlay.collectionBehavior.contains(.fullScreenAuxiliary), "Overlay must not use .fullScreenAuxiliary")
        let fullScreenRect = NSRect(x: 0, y: 0, width: 3360, height: 1890)
        check(overlay.constrainFrameRect(fullScreenRect, to: NSScreen.main) == fullScreenRect, "Overlay constrainFrameRect must not clip frame below menu bar")
        overlay.close()

        // 3. Verify ActiveWindowDetector fullscreen & space-switch resolution rules
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
