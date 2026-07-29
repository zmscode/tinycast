import Foundation

/// Pinned folders, shown when the file grid opens at a bare `~` or `/` so browsing starts somewhere
/// useful instead of at the filesystem root. Mirrors `FavoritesStore`: an ordered list of keys in
/// bundle-scoped defaults, most-recent last.
///
/// Paths are stored home-relative (`~/Code`) rather than absolute, so a pin survives the home
/// directory being renamed and reads correctly in the UI.
@MainActor
final class FolderPinsStore: ObservableObject {
	private let defaults = UserDefaults.standard
	private let key = "pinnedFolders"
	private let home = FileManager.default.homeDirectoryForCurrentUser.path

	@Published private(set) var paths: [String]

	init() {
		paths = defaults.stringArray(forKey: key) ?? Self.defaultPins
	}

	/// Seeded rather than empty: an empty grid at `~` teaches nothing, and these four are where
	/// almost every browse starts. They are ordinary pins — unpinning one sticks.
	private static let defaultPins = ["~/Desktop", "~/Documents", "~/Downloads", "~/Applications"]

	/// Home-relative form, so `/Users/me/Code` and `~/Code` are the same pin.
	func key(for path: String) -> String {
		guard path.hasPrefix(home) else { return path }
		let tail = path.dropFirst(home.count)
		return tail.isEmpty ? "~" : "~" + tail
	}

	func isPinned(_ path: String) -> Bool { paths.contains(key(for: path)) }

	func toggle(_ path: String) {
		let k = key(for: path)
		if let index = paths.firstIndex(of: k) {
			paths.remove(at: index)
		} else {
			paths.append(k)
		}
		defaults.set(paths, forKey: key)
	}

	/// Pins as browsable entries, skipping any whose folder has since been deleted or renamed —
	/// a stale pin should quietly disappear rather than render a broken tile.
	func entries(fileManager: FileManager = .default) -> [FileEntry] {
		paths.compactMap { stored in
			let expanded = FileBrowser.expand(stored, home: home)
			var isDirectory: ObjCBool = false
			guard fileManager.fileExists(atPath: expanded, isDirectory: &isDirectory),
				isDirectory.boolValue
			else { return nil }
			let name = (expanded as NSString).lastPathComponent
			return FileEntry(name: name, path: expanded, isDirectory: true)
		}
	}
}
