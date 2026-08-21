import AppKit

final class FileCollectionView: NSCollectionView {
    weak var paneView: PaneView?

    override func layout() {
        // Keep row width in sync with our OWN width: the vertical scroller
        // appearing shrinks the document view without re-running the
        // enclosing pane's layout, which left a stale, too-wide row width.
        // The flow layout reserves ~17.5pt for the scroller, so the row must
        // be narrower than bounds.width by that margin to avoid the
        // "item width must be less than" warning and right-edge clipping.
        let target = NSSize(width: max(320, bounds.width - 20), height: 22)
        if let fl = collectionViewLayout as? NSCollectionViewFlowLayout, fl.itemSize != target {
            fl.itemSize = target
        }
        super.layout()
    }

    override func mouseDown(with event: NSEvent) {
        guard let pane = paneView else { super.mouseDown(with: event); return }
        let local = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: local) {
            pane.handleClick(indexPath: indexPath,
                              control: event.modifierFlags.contains(.control),
                              doubleClick: event.clickCount >= 2)
        }
    }
}
