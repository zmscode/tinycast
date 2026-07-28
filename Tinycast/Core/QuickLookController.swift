import AppKit
import QuickLookUI

/// Drives the shared `QLPreviewPanel` for the file grid.
///
/// `QLPreviewPanel` is a singleton that normally finds its controller by walking the responder
/// chain. That doesn't work here — the palette is a borderless `NSPanel` hosting SwiftUI, and its
/// first responder is the search field, which must never resign (see docs/palette.md). So this
/// object is set as the panel's controller explicitly instead, and `PaletteWindowController`
/// suppresses its own resign-key dismissal while the preview is up.
@MainActor
final class QuickLookController: NSObject, ObservableObject,
	@preconcurrency QLPreviewPanelDataSource, @preconcurrency QLPreviewPanelDelegate
{
	/// True while the preview is on screen, so the palette can render its own state accordingly.
	@Published private(set) var isPreviewing = false

	/// URLs currently previewable, in grid order, plus which one is showing. Kept in sync with the
	/// selection so arrowing the grid moves the preview without reopening the panel.
	private var urls: [URL] = []
	private var index = 0

	/// Show (or move) the preview. Calling it again while open just re-targets — Quick Look's own
	/// panel handles the crossfade, so this doubles as "follow the selection".
	func show(urls: [URL], index: Int) {
		guard !urls.isEmpty, urls.indices.contains(index) else { return }
		self.urls = urls
		self.index = index

		let panel = QLPreviewPanel.shared()!
		if panel.isVisible {
			panel.currentPreviewItemIndex = index
			panel.reloadData()
			return
		}
		panel.dataSource = self
		panel.delegate = self
		// The palette is `.floating`; the preview must sit above it or it opens behind the grid.
		panel.level = .floating + 1
		panel.makeKeyAndOrderFront(nil)
		panel.currentPreviewItemIndex = index
		isPreviewing = true
	}

	/// Follow the grid selection only when a preview is already open — space toggles it on, arrows keep it in step.
	func follow(urls: [URL], index: Int) {
		guard isPreviewing else { return }
		show(urls: urls, index: index)
	}

	func toggle(urls: [URL], index: Int) {
		isPreviewing ? close() : show(urls: urls, index: index)
	}

	func close() {
		guard QLPreviewPanel.sharedPreviewPanelExists(), QLPreviewPanel.shared().isVisible else {
			isPreviewing = false
			return
		}
		QLPreviewPanel.shared().orderOut(nil)
		isPreviewing = false
	}

	// MARK: - QLPreviewPanelDataSource

	func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { urls.count }

	func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
		urls.indices.contains(index) ? urls[index] as NSURL : nil
	}

	// MARK: - QLPreviewPanelDelegate

	/// Forward arrow keys back to the palette so the grid selection (and therefore the preview) can
	/// still be moved while the preview owns the keyboard — matching Finder's behavior.
	func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
		guard event.type == .keyDown else { return false }
		switch event.keyCode {
		case 123, 124, 125, 126:  // ←, →, ↓, ↑
			AppCore.shared.paletteKeyWindow?.sendEvent(event)
			return true
		default:
			return false
		}
	}

	func previewPanelDidClose(_ panel: QLPreviewPanel!) {
		isPreviewing = false
		// Hand the keyboard back to the palette rather than to whatever is behind it.
		AppCore.shared.paletteKeyWindow?.makeKeyAndOrderFront(nil)
	}
}
