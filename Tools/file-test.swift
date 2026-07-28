// Standalone test for the file-grid path logic.
// Run: swiftc Tinycast/Core/FuzzyMatch.swift Tinycast/Core/FileBrowser.swift Tools/file-test.swift \
//          -o /tmp/file-test && /tmp/file-test
// Compiles the real sources; FileBrowser stays Foundation-only so this works.

import Foundation

@main
struct FileTests {
	static var failures = 0
	static let home = "/Users/tester"

	static func main() {
		detection()
		splitting()
		expansion()
		navigation()
		captions()
		spaceRule()
		listing()

		print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
		exit(failures == 0 ? 0 : 1)
	}

	/// Only a path-shaped query should hijack the launcher; ordinary app searches must not.
	static func detection() {
		for q in ["/", "/Applications", "~", "~/Code", "./x", "../x"] {
			check("'\(q)' reads as a path", FileBrowser.looksLikePath(q))
		}
		for q in ["safari", "1+1", "", "a/b", "Visual Studio Code"] {
			check("'\(q)' is not a path", !FileBrowser.looksLikePath(q))
		}
	}

	static func splitting() {
		expectSplit("~/Code/tin", "~/Code", "tin")
		expectSplit("~/Code/", "~/Code", "")
		expectSplit("/Applications/Saf", "/Applications", "Saf")
		expectSplit("/", "/", "")
		// A bare root fragment keeps "/" as the directory rather than collapsing to empty.
		expectSplit("/App", "/", "App")
		expectSplit("~", "~", "")
	}

	static func expansion() {
		check("bare ~ expands to home", FileBrowser.expand("~", home: home) == home)
		check(
			"~/x expands under home",
			FileBrowser.expand("~/Code", home: home) == "/Users/tester/Code")
		check(
			"absolute path is untouched",
			FileBrowser.expand("/Applications", home: home) == "/Applications")
		// A path merely *containing* a tilde must not be rewritten.
		check(
			"embedded tilde is untouched",
			FileBrowser.expand("/tmp/a~b", home: home) == "/tmp/a~b")
	}

	static func navigation() {
		let dir = FileEntry(name: "Core", path: "/x/Core", isDirectory: true)
		let file = FileEntry(name: "a.swift", path: "/x/a.swift", isDirectory: false)
		check(
			"descending into a folder appends a trailing slash",
			FileBrowser.descend(into: dir, from: "~/Code/Co", home: home) == "~/Code/Core/")
		check(
			"descending onto a file does not",
			FileBrowser.descend(into: file, from: "~/Code/a", home: home) == "~/Code/a.swift")

		check("a fragment is cleared first", FileBrowser.parent(of: "~/Code/tin") == "~/Code/")
		check("then one level is dropped", FileBrowser.parent(of: "~/Code/") == "~/")
		check("root has no parent", FileBrowser.parent(of: "/") == nil)
		check("bare home has no parent", FileBrowser.parent(of: "~") == nil)
	}

	/// Captions drop the folder slash and the file extension — the icon conveys both.
	static func captions() {
		func caption(_ name: String, dir: Bool) -> String {
			FileEntry(name: name, path: "/x/" + name, isDirectory: dir).displayName
		}
		check("a folder shows no trailing slash", caption("Core", dir: true) == "Core")
		check("a file drops its extension", caption("AppCore.swift", dir: false) == "AppCore")
		check("an extensionless file is unchanged", caption("Makefile", dir: false) == "Makefile")
		// A dotfile's leading dot is its name, not an extension.
		check("a dotfile keeps its name", caption(".gitignore", dir: false) == ".gitignore")
		check("a dotted dotfile drops only the last part", caption(".hidden.txt", dir: false) == ".hidden")
		check("only the last extension goes", caption("archive.tar.gz", dir: false) == "archive.tar")
		// A folder that looks like it has an extension keeps its whole name.
		check("a folder with a dot keeps it", caption("Tinycast.xcodeproj", dir: true) == "Tinycast.xcodeproj")
	}

	/// Regression: Space previews only when no filter fragment is being typed.
	///
	/// The first cut guarded on `hasSuffix("/") || !query.isEmpty`, which is a tautology for any
	/// path-shaped query — so the space bar could never type a character, and typing a directory
	/// containing a space silently opened Quick Look instead.
	static func spaceRule() {
		func previewsOnSpace(_ query: String) -> Bool {
			FileBrowser.split(query).fragment.isEmpty
		}
		for q in ["/Applications/", "~/Code/", "/", "~"] {
			check("space previews at '\(q)' (no fragment)", previewsOnSpace(q))
		}
		for q in ["/Applications/Visual", "/Applications/Visual Studio", "~/Code/tin", "/App"] {
			check("space types at '\(q)' (fragment in play)", !previewsOnSpace(q))
		}
	}

	/// Listing against a real temp tree — the one part that must touch a filesystem.
	static func listing() {
		let fm = FileManager.default
		let root = URL(fileURLWithPath: NSTemporaryDirectory())
			.appendingPathComponent("tinycast-file-test-\(UUID().uuidString)")
		defer { try? fm.removeItem(at: root) }
		try? fm.createDirectory(
			at: root.appendingPathComponent("zebra"), withIntermediateDirectories: true)
		try? fm.createDirectory(
			at: root.appendingPathComponent("alpha"), withIntermediateDirectories: true)
		for name in ["beta.swift", "Calc.swift", ".hidden"] {
			try? Data().write(to: root.appendingPathComponent(name))
		}

		let all = FileBrowser.entries(for: root.path + "/", home: home)
		let names = all.map(\.name)
		check("hidden entries are excluded by default", !names.contains(".hidden"), "got \(names)")
		check(
			"folders sort before files",
			names.prefix(2).sorted() == ["alpha", "zebra"], "got \(names)")
		check(
			"files follow, alphabetically",
			Array(names.dropFirst(2)) == ["beta.swift", "Calc.swift"], "got \(names)")

		let dotted = FileBrowser.entries(for: root.path + "/.", home: home).map(\.name)
		check("a dot fragment reveals hidden entries", dotted.contains(".hidden"), "got \(dotted)")

		// The shared fuzzy matcher ranks the fragment, so an exact prefix wins.
		let filtered = FileBrowser.entries(for: root.path + "/Calc", home: home).map(\.name)
		check("fragment filters and ranks", filtered.first == "Calc.swift", "got \(filtered)")

		let missing = FileBrowser.entries(for: "/no/such/place/", home: home)
		check("a missing directory yields nothing", missing.isEmpty)
	}

	// MARK: - Helpers

	static func expectSplit(_ query: String, _ directory: String, _ fragment: String) {
		let got = FileBrowser.split(query)
		check(
			"split('\(query)') → (\(directory), '\(fragment)')",
			got.directory == directory && got.fragment == fragment,
			"got (\(got.directory), '\(got.fragment)')")
	}

	static func check(_ desc: String, _ cond: Bool, _ detail: String = "") {
		if cond {
			print("PASS  \(desc)")
		} else {
			print("FAIL  \(desc)  \(detail)")
			failures += 1
		}
	}
}
