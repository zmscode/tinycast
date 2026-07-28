import AppKit

/// Directory listings for the palette's file grid, memoized per query.
///
/// One-entry memo like `AppIndex.matchCache`: every keystroke re-renders the grid, and a listing is
/// disk I/O, so a repeated render for the same query must not re-hit the filesystem.
@MainActor
final class FileStore: ObservableObject {
	let home = FileManager.default.homeDirectoryForCurrentUser.path

	private var cache: (query: String, entries: [FileEntry])?

	func entries(for query: String) -> [FileEntry] {
		if let cache, cache.query == query { return cache.entries }
		let entries = FileBrowser.entries(for: query, home: home)
		cache = (query, entries)
		return entries
	}

	/// Dropped when the palette closes so a directory changed behind our back is re-read on reopen.
	func invalidate() {
		cache = nil
	}
}

/// Actions menu for a file-grid entry, mirroring `AppActionsMenu`.
@MainActor
enum FileActionsMenu {
	static func content(entry: FileEntry, core: AppCore) -> PopoverMenuContent {
		PopoverMenuContent(
			header: entry.name,
			items: [
				PopoverMenuItem(
					title: entry.isDirectory
						? String(localized: "Open Folder") : String(localized: "Open"),
					systemImage: entry.isDirectory ? "folder" : "arrow.up.forward.app",
					shortcut: "↵"
				) {
					core.openFile(entry)
				},
				PopoverMenuItem(
					title: String(localized: "Quick Look"), systemImage: "eye", shortcut: "Space"
				) {
					core.quickLookFromMenu(entry)
				},
				PopoverMenuItem(title: String(localized: "Show in Finder"), systemImage: "folder") {
					core.revealFile(entry)
				},
				PopoverMenuItem(
					title: String(localized: "Copy Path"), systemImage: "doc.on.doc", shortcut: "⌘↵"
				) {
					core.copyFilePath(entry)
				},
			]
		)
	}
}
