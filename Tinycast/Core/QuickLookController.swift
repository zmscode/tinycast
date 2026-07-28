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
	/// Derived from the panel, never cached. A cached flag goes stale the moment the panel is closed
	/// by any route we don't own (its close button, Esc, ⌘W) — and a stale `true` makes every
	/// selection change re-open the preview, since `follow` treats it as "already showing".
	var isPreviewing: Bool {
		QLPreviewPanel.sharedPreviewPanelExists() && QLPreviewPanel.shared().isVisible
	}

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
		guard isPreviewing else { return }
		QLPreviewPanel.shared().orderOut(nil)
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

	/// `QLPreviewPanelDelegate` refines `NSWindowDelegate`, so this is the genuine close callback —
	/// there is no `previewPanelDidClose`. Hand the keyboard back to the palette rather than letting
	/// it fall through to whatever is behind it.
	func windowWillClose(_ notification: Notification) {
		AppCore.shared.paletteKeyWindow?.makeKeyAndOrderFront(nil)
	}
}
