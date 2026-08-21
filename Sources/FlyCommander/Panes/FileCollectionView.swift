import AppKit

final class FileCollectionView: NSCollectionView {
    weak var paneView: PaneView?

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
