import AppKit

extension NSWindow {
    /// How much of the content view sits under the title bar. Zero for an ordinary window; the
    /// title bar's height for one styled `.fullSizeContentView`, which is what every window here
    /// is. A page that wants 678 pt of room *below* the bar needs a window that much taller.
    var titleBarOverlap: CGFloat {
        max(0, contentRect(forFrameRect: frame).height - contentLayoutRect.height)
    }

    /// Give the page `height` points below the title bar, keeping the title bar where it is.
    /// `setContentSize` alone anchors the bottom-left corner, so a window that grows walks up
    /// the screen and one that shrinks drops away from the pointer that just collapsed a group.
    /// Kept on its screen.
    func setContentHeight(_ height: CGFloat, animate: Bool) {
        let content = contentRect(forFrameRect: frame)
        let total = height + titleBarOverlap
        guard height > 0, abs(content.height - total) > 0.5 else { return }
        var target = frameRect(forContentRect: NSRect(x: content.minX, y: content.maxY - total,
                                                       width: content.width, height: total))
        target = constrainFrameRect(target, to: screen ?? NSScreen.main)
        setFrame(target, display: true, animate: animate)
    }
}
