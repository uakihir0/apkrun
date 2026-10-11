import AppKit
import IOSurface
import QuartzCore

/// Shows one IOSurface as the contents of a plain layer (display-and-windowing.md §5.3, #023).
///
/// The view never draws with the CPU. Setting the contents is zero-copy: Core Animation reads the surface, and the
/// consumer's `displayed` callback runs once Core Animation has committed the new contents.
@MainActor
public final class IOSurfaceLayerView: NSView {
    private let contentLayer = CALayer()
    private let contentSize: CGSize

    /// Creates a view whose content is `contentSize` points, shown at `contentScale` pixels per point.
    public init(frame: NSRect, contentSize: CGSize, contentScale: CGFloat) {
        self.contentSize = contentSize
        super.init(frame: frame)
        wantsLayer = true
        contentLayer.bounds = CGRect(origin: .zero, size: contentSize)
        contentLayer.contentsScale = contentScale
        contentLayer.contentsGravity = .resize
        contentLayer.isOpaque = true
        layer?.addSublayer(contentLayer)
    }

    /// Not supported: the view is created in code.
    @available(*, unavailable)
    public required init?(coder: NSCoder) {
        fatalError("IOSurfaceLayerView is created in code.")
    }

    /// Keeps the content aspect-fit when the window is resized (display-and-windowing.md §7.1).
    public override func layout() {
        super.layout()
        contentLayer.frame = DisplayGeometry.aspectFit(contentSize: contentSize, in: bounds.size)
    }

    /// Shows `surface`. `displayed` runs on the main thread after Core Animation commits the contents.
    public func show(_ surface: IOSurface, displayed: @escaping @Sendable () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        CATransaction.setCompletionBlock(displayed)
        contentLayer.contents = surface
        CATransaction.commit()
    }
}
