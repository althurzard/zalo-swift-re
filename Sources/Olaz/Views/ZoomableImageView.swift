import SwiftUI
import AppKit
@preconcurrency import VisionKit

/// What the zoom buttons and the percent label of a `ZoomableImageView` read and drive.
///
/// The `NSScrollView` owns the real magnification (pinch, wheel, double-click all end up there); this mirrors it for SwiftUI
/// (updated one runloop turn later so it never mutates observed state in the middle of a view update).
@MainActor
@Observable
final class ZoomController {
    /// 1 = one image pixel per point.
    private(set) var magnification: CGFloat = 1
    /// The image is at its "fit" size (and stays fitted when the window is resized).
    private(set) var isFitted = true
    /// An image is on screen; the buttons are disabled until then.
    private(set) var hasContent = false

    @ObservationIgnored fileprivate weak var scrollView: ZoomScrollView?
    var currentImage: NSImage? { scrollView?.currentImage }

    var percent: Int { Int((magnification * 100).rounded()) }

    func zoomIn() { scrollView?.zoom(by: 1.25) }
    func zoomOut() { scrollView?.zoom(by: 1 / 1.25) }
    func fit() { scrollView?.zoomToFit() }
    func actualSize() { scrollView?.zoom(to: 1) }
    /// Fitted -> 100%, anything else -> fitted.
    func toggleActualSize() { isFitted ? actualSize() : fit() }

    fileprivate func apply(magnification: CGFloat, isFitted: Bool, hasContent: Bool) {
        if abs(self.magnification - magnification) > 0.0005 { self.magnification = magnification }
        if self.isFitted != isFitted { self.isFitted = isFitted }
        if self.hasContent != hasContent { self.hasContent = hasContent }
    }
}

/// A still image in a magnifying scroll view: pinch, ⌥/⌘-scroll at the pointer, double-click, drag to pan, and the
/// `ZoomController` buttons. It starts fitted (filling the view, small images included) and stays fitted across window
/// resizes and full screen until the user zooms.
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    let zoom: ZoomController
    var ocrEnabled: Bool = false
    var ocrAnalysis: ImageAnalysis? = nil

    func makeNSView(context: Context) -> ZoomScrollView {
        let view = ZoomScrollView(frame: .zero)
        view.attach(zoom)
        view.setImage(image)
        view.setOCR(enabled: ocrEnabled, analysis: ocrAnalysis)
        return view
    }

    func updateNSView(_ view: ZoomScrollView, context: Context) {
        view.attach(zoom)
        view.setImage(image)
        view.setOCR(enabled: ocrEnabled, analysis: ocrAnalysis)
    }

    static func dismantleNSView(_ view: ZoomScrollView, coordinator: ()) {
        view.teardown()
    }
}

/// Keeps the document centered while it is smaller than the viewport (a fitted photo, a zoomed-out one).
private final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let document = documentView else { return rect }
        let frame = document.frame
        if rect.width > frame.width { rect.origin.x = frame.minX - (rect.width - frame.width) / 2 }
        if rect.height > frame.height { rect.origin.y = frame.minY - (rect.height - frame.height) / 2 }
        return rect
    }
}

/// The scroll view's document: hands every mouse event to the scroll view, which does the panning and double-click zoom.
private final class ZoomImageView: NSImageView {
    override func mouseDown(with event: NSEvent) { enclosingScrollView?.mouseDown(with: event) }
    override func mouseDragged(with event: NSEvent) { enclosingScrollView?.mouseDragged(with: event) }
    override func mouseUp(with event: NSEvent) { enclosingScrollView?.mouseUp(with: event) }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class ZoomScrollView: NSScrollView {
    private let imageView = ZoomImageView()
    private var ocrOverlay: ImageAnalysisOverlayView?
    private weak var controller: ZoomController?
    private var observers: [NSObjectProtocol] = []
    private var syncPending = false
    /// Fitted until the user zooms: resizes (and full screen) re-fit while this is set.
    private var followsFit = true
    /// The viewport size the current fit was computed for: layout only re-fits when it really changes.
    private var fittedViewport = NSSize.zero
    private var pan: (mouse: NSPoint, origin: NSPoint)?

    var currentImage: NSImage? { imageView.image }
    var isOCROverlayAttached: Bool { ocrOverlay != nil }

    override init(frame: NSRect) {
        super.init(frame: frame)
        configure()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func configure() {
        let clip = CenteringClipView()
        clip.drawsBackground = false
        contentView = clip
        drawsBackground = false
        borderType = .noBorder
        // The viewer window's content runs under its transparent titlebar; the image must not be pushed down by it.
        automaticallyAdjustsContentInsets = false
        contentInsets = NSEdgeInsetsZero
        hasHorizontalScroller = true
        hasVerticalScroller = true
        autohidesScrollers = true
        scrollerStyle = .overlay
        scrollerKnobStyle = .light
        usesPredominantAxisScrolling = false
        allowsMagnification = true
        imageView.imageScaling = .scaleAxesIndependently
        imageView.imageAlignment = .alignCenter
        imageView.isEditable = false
        documentView = imageView
        clip.postsBoundsChangedNotifications = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSView.boundsDidChangeNotification, object: clip, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleSync() }
        })
        // Synchronous (no queue): a pinch changes the magnification at once, and a layout pass in between must not re-fit it.
        observers.append(center.addObserver(forName: NSScrollView.willStartLiveMagnifyNotification, object: self, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated { self?.followsFit = false }
        })
        observers.append(center.addObserver(forName: NSScrollView.didEndLiveMagnifyNotification, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.liveMagnifyEnded() }
        })
    }

    func attach(_ controller: ZoomController) {
        guard self.controller !== controller else { return }
        self.controller?.scrollView = nil
        self.controller = controller
        controller.scrollView = self
        scheduleSync()
    }

    func teardown() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        removeOCROverlay()
        imageView.image = nil
        if let controller {
            self.controller = nil
            Task { @MainActor in
                if controller.scrollView === self { controller.scrollView = nil }
                controller.apply(magnification: 1, isFitted: true, hasContent: false)
            }
        }
    }

    func setImage(_ image: NSImage) {
        guard imageView.image !== image else { return }
        imageView.image = image
        imageView.frame = NSRect(origin: .zero, size: image.size)
        ocrOverlay?.frame = imageView.bounds
        ocrOverlay?.analysis = nil
        ocrOverlay?.setContentsRectNeedsUpdate()
        followsFit = true
        updateLimits()
        applyFit()
        scheduleSync()
    }

    /// Attaches `ImageAnalysisOverlayView` only while OCR mode is ON; removes it completely when OFF so
    /// normal `ZoomImageView` pan, drag, and double-click zoom work identically.
    func setOCR(enabled: Bool, analysis: ImageAnalysis?) {
        guard enabled, imageView.image != nil else {
            removeOCROverlay()
            return
        }
        let overlay: ImageAnalysisOverlayView
        if let existing = ocrOverlay {
            overlay = existing
        } else {
            let created = ImageAnalysisOverlayView(frame: imageView.bounds)
            created.autoresizingMask = [.width, .height]
            created.preferredInteractionTypes = [.textSelection, .dataDetectors]
            created.isSupplementaryInterfaceHidden = true
            created.trackingImageView = imageView
            imageView.addSubview(created)
            ocrOverlay = created
            overlay = created
            window?.invalidateCursorRects(for: self)
        }
        if overlay.frame != imageView.bounds {
            overlay.frame = imageView.bounds
        }
        if overlay.analysis !== analysis {
            overlay.analysis = analysis
        }
        overlay.setContentsRectNeedsUpdate()
    }

    private func removeOCROverlay() {
        guard let ocrOverlay else { return }
        ocrOverlay.resetSelection()
        ocrOverlay.analysis = nil
        ocrOverlay.trackingImageView = nil
        ocrOverlay.removeFromSuperview()
        self.ocrOverlay = nil
        window?.invalidateCursorRects(for: self)
    }

    // MARK: Fit

    /// Magnification at which the whole image fills the viewport (small images are scaled up to it).
    private var fitScale: CGFloat {
        let size = imageView.frame.size
        guard size.width > 0, size.height > 0, bounds.width > 0, bounds.height > 0 else { return 1 }
        return min(bounds.width / size.width, bounds.height / size.height)
    }

    var isFitted: Bool {
        let fit = fitScale
        return abs(magnification - fit) <= max(fit * 0.002, 0.0001)
    }

    /// Never smaller than the fit (a small image may go down to 100%), up to at least 8x.
    private func updateLimits() {
        let fit = fitScale
        minMagnification = min(fit, 1)
        maxMagnification = max(8, fit * 4)
    }

    private func applyFit() {
        let fit = fitScale
        if abs(magnification - fit) > 0.000001 { magnification = fit }
        fittedViewport = bounds.size
        recenter()
    }

    /// Puts a document smaller than the viewport back in the middle (the clip view does the constraining).
    private func recenter() {
        let clip = contentView
        let target = clip.constrainBoundsRect(NSRect(origin: clip.bounds.origin, size: clip.bounds.size))
        clip.scroll(to: target.origin)
        reflectScrolledClipView(clip)
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        guard changed, imageView.image != nil else { return }
        updateLimits()
        if followsFit {
            applyFit()
        } else if magnification < minMagnification {
            magnification = minMagnification
        }
        scheduleSync()
    }

    /// Safety net for size changes that do not go through `setFrameSize`.
    override func layout() {
        super.layout()
        guard followsFit, imageView.image != nil, bounds.size != fittedViewport, abs(magnification - fitScale) > 0.0001 else { return }
        updateLimits()
        applyFit()
        scheduleSync()
    }

    // MARK: Zoom

    func zoom(by factor: CGFloat) { zoom(to: magnification * factor) }

    func zoomToFit() { zoom(to: fitScale, refit: true) }

    /// Animated zoom about the middle of what is on screen (buttons, shortcuts) or about `documentPoint` (double-click).
    func zoom(to target: CGFloat, at documentPoint: NSPoint? = nil, refit: Bool = false) {
        guard imageView.image != nil else { return }
        let clamped = min(max(target, minMagnification), maxMagnification)
        let center = documentPoint ?? NSPoint(x: contentView.bounds.midX, y: contentView.bounds.midY)
        followsFit = false
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.allowsImplicitAnimation = true
            animator().setMagnification(clamped, centeredAt: center)
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                if refit {
                    self.followsFit = true
                    self.applyFit()
                }
                self.scheduleSync()
            }
        }
    }

    /// Zoom that keeps the image point under the pointer where it is (⌥/⌘-scroll).
    func zoom(to target: CGFloat, anchoredAt windowPoint: NSPoint) {
        let clamped = min(max(target, minMagnification), maxMagnification)
        guard abs(clamped - magnification) > 0.000001 else { return }
        followsFit = false
        let clip = contentView
        let anchor = clip.convert(windowPoint, from: nil)
        let origin = clip.bounds.origin
        let ratio = magnification / clamped
        magnification = clamped
        clip.scroll(to: NSPoint(x: anchor.x - (anchor.x - origin.x) * ratio, y: anchor.y - (anchor.y - origin.y) * ratio))
        reflectScrolledClipView(clip)
    }

    /// Pinch ended: a gesture that stops near the fit snaps to it (and so keeps following window resizes).
    private func liveMagnifyEnded() {
        let fit = fitScale
        if isFitted {
            followsFit = true
        } else if abs(magnification - fit) < fit * 0.03 {
            zoomToFit()
        } else {
            followsFit = false
        }
        scheduleSync()
    }

    /// Two-finger double tap: the same fit <-> zoom toggle as a double click. (The system's version zooms to a "smart" rect and
    /// would leave `followsFit` set, so the next window resize would snap the zoom back.)
    override func smartMagnify(with event: NSEvent) {
        guard imageView.image != nil else { return super.smartMagnify(with: event) }
        toggleZoom(at: contentView.convert(event.locationInWindow, from: nil))
    }

    /// Fitted -> in (about `point`), anything else -> fitted (which follows the window again).
    private func toggleZoom(at point: NSPoint) {
        if isFitted {
            zoom(to: max(fitScale * 2, 1), at: point)
        } else {
            zoomToFit()
        }
    }

    override func scrollWheel(with event: NSEvent) {
        guard imageView.image != nil, !event.modifierFlags.isDisjoint(with: [.option, .command]) else {
            super.scrollWheel(with: event)
            return
        }
        let precise = event.hasPreciseScrollingDeltas
        let delta = precise ? (event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX)
                            : (event.deltaY != 0 ? event.deltaY : event.deltaX)
        guard delta != 0 else { return }
        zoom(to: magnification * exp(delta * (precise ? 0.01 : 0.1)), anchoredAt: event.locationInWindow)
    }

    // MARK: Mouse

    /// The image is bigger than the viewport, so dragging moves it.
    private var canPan: Bool {
        let size = imageView.frame.size
        return size.width * magnification > bounds.width + 0.5 || size.height * magnification > bounds.height + 0.5
    }

    override func mouseDown(with event: NSEvent) {
        guard imageView.image != nil else { return super.mouseDown(with: event) }
        if event.clickCount == 2 {
            toggleZoom(at: contentView.convert(event.locationInWindow, from: nil))
            return
        }
        guard canPan else { return }
        pan = (event.locationInWindow, contentView.bounds.origin)
        NSCursor.closedHand.push()
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pan else { return }
        let dx = (event.locationInWindow.x - pan.mouse.x) / magnification
        let dy = (event.locationInWindow.y - pan.mouse.y) / magnification
        contentView.scroll(to: NSPoint(x: pan.origin.x - dx, y: pan.origin.y - dy))
        reflectScrolledClipView(contentView)
    }

    override func mouseUp(with event: NSEvent) {
        guard pan != nil else { return }
        pan = nil
        NSCursor.pop()
    }

    override func resetCursorRects() {
        if !isOCROverlayAttached && canPan { addCursorRect(bounds, cursor: .openHand) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: Mirror

    private func scheduleSync() {
        guard !syncPending else { return }
        syncPending = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            syncPending = false
            controller?.apply(magnification: magnification, isFitted: isFitted, hasContent: imageView.image != nil)
            window?.invalidateCursorRects(for: self)
        }
    }
}

// MARK: - Controls

/// Round glass icon button of the viewer's bars: a help tag and a VoiceOver label in one string.
struct ViewerIconButton: View {
    let symbol: String
    let label: String
    var help: String?
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 20, height: 20)
                .contentTransition(.symbolEffect(.replace))
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .help(help ?? label)
        .accessibilityLabel(label)
    }
}

/// Zoom out, percent (click = fit), zoom in, fit / 100% toggle. The shortcuts exist only in the media viewer window.
struct ZoomControls: View {
    let zoom: ZoomController
    var showsShortcuts = true

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                ViewerIconButton(symbol: "minus.magnifyingglass", label: "Thu nhỏ", help: help("Thu nhỏ", "⌘−")) { zoom.zoomOut() }
                Button { zoom.fit() } label: {
                    Text("\(zoom.percent)%")
                        .font(.system(size: 12, weight: .medium).monospacedDigit())
                        .frame(minWidth: 38)
                }
                .buttonStyle(.glass)
                .help(help("Vừa khung", "⌘9"))
                .accessibilityLabel("Mức thu phóng")
                .accessibilityValue("\(zoom.percent) phần trăm")
                .accessibilityHint("Nhấn để vừa khung")
                ViewerIconButton(symbol: "plus.magnifyingglass", label: "Phóng to", help: help("Phóng to", "⌘+")) { zoom.zoomIn() }
                if zoom.isFitted {
                    ViewerIconButton(symbol: "1.magnifyingglass", label: "Kích thước thật", help: help("Kích thước thật", "⌘0")) { zoom.actualSize() }
                } else {
                    ViewerIconButton(symbol: "arrow.up.left.and.down.right.magnifyingglass", label: "Vừa khung", help: help("Vừa khung", "⌘9")) { zoom.fit() }
                }
            }
        }
        .disabled(!zoom.hasContent)
    }

    private func help(_ title: String, _ shortcut: String) -> String {
        showsShortcuts ? "\(title) (\(shortcut))" : title
    }
}
