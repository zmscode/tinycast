import Foundation

/// One entry in a browsed directory.
struct FileEntry: Identifiable, Hashable, Sendable {
	let name: String
	let path: String
	let isDirectory: Bool

	var id: String { path }

	/// Grid caption: the icon already says "folder" and "which kind of file", so the slash and the
	/// extension are redundant chrome. `deletingPathExtension` leaves dotfiles alone (`.gitignore`
	/// stays whole) and strips only the last component (`archive.tar.gz` → `archive.tar`).
	var displayName: String {
		isDirectory ? name : (name as NSString).deletingPathExtension
	}
}

/// Resolves a typed path into a directory listing. Foundation-only and free of AppKit so
/// `Tools/file-test.swift` can compile the real source, matching the calculator and emoji engines.
///
/// The query is treated as "directory to list" plus an optional trailing filter fragment, so typing
/// `~/Code/tin` lists `~/Code` filtered to entries matching `tin` — the shell's tab-completion feel
/// rather than a separate search box.
enum FileBrowser {
	/// Prefixes that make a query a path rather than an app search. `~` alone is included so the grid appears as soon as the user commits to browsing.
	static func looksLikePath(_ query: String) -> Bool {
		let q = query.trimmingCharacters(in: .whitespaces)
		return q.hasPrefix("/") || q.hasPrefix("~") || q.hasPrefix("./") || q.hasPrefix("../")
	}

	/// Splits a query into the directory to list and the fragment filtering it.
	/// `~/Code/tin` → (`~/Code`, `tin`); `~/Code/` → (`~/Code`, ""). A path ending in a separator lists that directory whole.
	static func split(_ query: String) -> (directory: String, fragment: String) {
		let q = query.trimmingCharacters(in: .whitespaces)
		guard let slash = q.lastIndex(of: "/") else { return (q, "") }
		let directory = q[..<slash].isEmpty ? "/" : String(q[..<slash])
		return (directory, String(q[q.index(after: slash)...]))
	}

	/// Expands `~` against `home` — injected rather than read from the environment so the harness stays pure.
	static func expand(_ path: String, home: String) -> String {
		if path == "~" { return home }
		if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
		return path
	}

	/// Directory contents, folders first then files, each alphabetical. Hidden entries are included only when the fragment starts with a dot, so `.` reveals dotfiles the way a shell does.
	static func list(directory: String, fragment: String, home: String, fileManager: FileManager = .default)
		-> [FileEntry]
	{
		let expanded = expand(directory, home: home)
		guard
			let names = try? fileManager.contentsOfDirectory(atPath: expanded)
		else { return [] }

		let wantsHidden = fragment.hasPrefix(".")
		var entries: [FileEntry] = []
		for name in names {
			if name.hasPrefix("."), !wantsHidden { continue }
			let full = expanded.hasSuffix("/") ? expanded + name : expanded + "/" + name
			var isDir: ObjCBool = false
			guard fileManager.fileExists(atPath: full, isDirectory: &isDir) else { continue }
			entries.append(FileEntry(name: name, path: full, isDirectory: isDir.boolValue))
		}
		return entries.sorted {
			$0.isDirectory != $1.isDirectory
				? $0.isDirectory
				: $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
		}
	}

	/// Ranked entries for a query. An empty fragment keeps directory order; otherwise the shared fuzzy matcher ranks them, so the same camelCase and delimiter scoring the launcher uses applies here.
	static func entries(for query: String, home: String, fileManager: FileManager = .default)
		-> [FileEntry]
	{
		let (directory, fragment) = split(query)
		let all = list(directory: directory, fragment: fragment, home: home, fileManager: fileManager)
		guard !fragment.isEmpty, fragment != "." else { return all }

		return
			all
			.compactMap { entry -> (FileEntry, Int)? in
				guard let score = FuzzyMatch.score(query: fragment, candidate: entry.name) else {
					return nil
				}
				return (entry, score)
			}
			.sorted {
				if $0.1 != $1.1 { return $0.1 > $1.1 }
				// Matched region only, so length is the tiebreak — same rule as AppIndex.rank.
				if $0.0.name.count != $1.0.name.count { return $0.0.name.count < $1.0.name.count }
				return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
			}
			.map(\.0)
	}

	/// The query that browsing *into* `entry` should produce — a directory gains a trailing slash so the next listing starts inside it.
	static func descend(into entry: FileEntry, from query: String, home: String) -> String {
		let (directory, _) = split(query)
		let base = directory.hasSuffix("/") ? directory : directory + "/"
		return base + entry.name + (entry.isDirectory ? "/" : "")
	}

	/// One level up from the current query, or nil at the root.
	static func parent(of query: String) -> String? {
		let (directory, fragment) = split(query)
		// A trailing fragment is cleared first: `~/Code/tin` → `~/Code/`.
		if !fragment.isEmpty { return directory + "/" }
		guard directory != "/", directory != "~" else { return nil }
		let (up, _) = split(directory)
		return up.isEmpty ? "/" : up + "/"
	}
}
