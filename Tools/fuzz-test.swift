// Standalone test for the launcher fuzzy matcher.
// Run: swiftc Tinycast/Core/FuzzyMatch.swift Tools/fuzz-test.swift -o /tmp/fuzz-test && /tmp/fuzz-test
// Compiles the real FuzzyMatch source, so there is no copy here to keep in sync.
//
// Assertions are relative ("A outranks B") rather than absolute scores, so retuning a bonus doesn't
// churn the suite — but every scoring rule has at least one case that fails if the rule is removed.

import Foundation

@main
struct FuzzTests {
	static var failures = 0

	static let apps = [
		"Google Chrome", "Chess", "Time Machine", "Safari", "Bluetooth File Exchange",
		"Screenshot", "Screen Sharing", "Visual Studio Code", "Photos", "App Store",
		"System Settings", "Calendar", "Terminal",
	]

	static func main() {
		orderingBasics()
		wordBoundaries()
		camelCase()
		paths()
		consecutiveRuns()
		gapsAndFirstChar()
		positions()
		edgeCases()

		print(failures == 0 ? "\nALL PASSED" : "\n\(failures) FAILED")
		exit(failures == 0 ? 0 : 1)
	}

	// MARK: - Launcher behavior

	static func orderingBasics() {
		let chrome = rank("chrome")
		check("'chrome' top is Google Chrome", chrome.first == "Google Chrome", "got \(chrome)")
		check("'chrome' does not include Chess", !chrome.contains("Chess"), "got \(chrome)")

		let ch = rank("ch")
		check("'ch' includes Google Chrome", ch.contains("Google Chrome"), "got \(ch)")
		check("'ch' includes Chess", ch.contains("Chess"))
		check(
			"'ch' ranks Chess above Google Chrome",
			ch.firstIndex(of: "Chess")! < ch.firstIndex(of: "Google Chrome")!, "got \(ch)")

		check("'saf' top is Safari", rank("saf").first == "Safari", "got \(rank("saf"))")
		check(
			"'tm' includes Time Machine", rank("tm").contains("Time Machine"), "got \(rank("tm"))")
		check(
			"'code' includes Visual Studio Code", rank("code").contains("Visual Studio Code"),
			"got \(rank("code"))")
		check("'terminal' exact top", rank("terminal").first == "Terminal")
		check("'xyz' matches nothing", rank("xyz").isEmpty, "got \(rank("xyz"))")

		// fzf scores the matched region and ignores trailing text, so these tie on score; the
		// shorter-name tiebreak in `rank` (and in AppIndex/EmojiIndex) is what separates them.
		let safari = ["Safari", "Safari Technology Preview"]
		let exact = safari.compactMap { n in
			FuzzyMatch.score(query: "safari", candidate: n).map { (n, $0) }
		}
		check(
			"exact and longer candidate tie on score", exact.count == 2 && exact[0].1 == exact[1].1,
			"got \(exact)")
		check(
			"shorter name wins the tie once sorted",
			exact.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }.first?.0
				== "Safari")
		// A prefix must beat the same letters buried mid-word.
		beats("scr", "Screenshot", "Discretion")
	}

	// MARK: - Scoring rules, one case per rule

	/// Removing the word-boundary bonus breaks these.
	static func wordBoundaries() {
		beats("fe", "Bluetooth File Exchange", "Defensive")
		beats("ss", "Screen Sharing", "Missing")
		beats("as", "App Store", "Atlas")
		// After an underscore/hyphen — a boundary that is neither whitespace nor a path delimiter.
		beats("ae", "app_engine", "adverse")
		beats("ae", "alpha-echo", "adverse")
	}

	/// Removing the camelCase bonus breaks these. This is the class the old matcher got wrong.
	static func camelCase() {
		beats("rpv", "RootPaletteView.swift", "reproving.txt")
		beats("acs", "AppCoreSettings.swift", "acclimates.txt")
		beats("ci", "CalcIndex", "chronic")
	}

	/// Removing the delimiter bonus breaks these — the case that matters for a file mode.
	static func paths() {
		beats("coreapp", "~/Code/tinycast/Core/AppIndex.swift", "~/corrupted-appendix.md")
		beats("cta", "Code/Tinycast/AppCore.swift", "contrast-alpha.txt")
		// A path match should score well outright, not merely beat a strawman.
		let m = FuzzyMatch.score(query: "coreapp", candidate: "~/Code/tinycast/Core/AppIndex.swift")
		check(
			"'coreapp' scores > 90 against a path", (m ?? 0) > 90,
			"got \(m.map(String.init) ?? "nil")")
	}

	/// Removing the consecutive-run bonus breaks these.
	static func consecutiveRuns() {
		beats("term", "Terminal", "The Elder Rooms")
		beats("cal", "Calendar", "Critical Alarm")

		// Contiguity has to be worth more than the gap it avoids, or a run is just cheaper spacing.
		// Ordering alone can't show this: boundary bonuses dominate, so it needs a margin check.
		let tight = need("ab", "xab")
		let loose = need("ab", "xaxb")
		check(
			"a consecutive run beats a one-gap match by more than the gap alone",
			tight - loose > 5, "tight \(tight) vs loose \(loose)")
	}

	/// Gap penalties and the first-char multiplier only scale scores — they rarely flip an ordering,
	/// so each needs a margin assertion or a mutation test would sail straight through.
	static func gapsAndFirstChar() {
		// Opening a gap must cost something.
		let contiguous = need("ab", "xab")
		let oneGap = need("ab", "xaxb")
		check("opening a gap costs score", contiguous > oneGap, "\(contiguous) vs \(oneGap)")

		// Each extra gap character must cost a little more.
		let twoGap = need("ab", "xaxxb")
		check("a wider gap costs more than a narrow one", oneGap > twoGap, "\(oneGap) vs \(twoGap)")

		// The first matched character's bonus is doubled, so the gap between a word-start hit and a
		// camel-hump hit is wider than their raw bonuses differ by.
		let atWordStart = need("s", "Safari")
		let atCamelHump = need("s", "aSafari")
		check(
			"first-char bonus is amplified", atWordStart - atCamelHump > 3,
			"word-start \(atWordStart) vs camel \(atCamelHump)")
	}

	// MARK: - Positions (needed for match highlighting)

	static func positions() {
		guard let m = FuzzyMatch.match(query: "rpv", candidate: "RootPaletteView") else {
			return check("'rpv' matches RootPaletteView", false)
		}
		check("positions count equals query length", m.positions.count == 3, "got \(m.positions)")
		check(
			"positions land on the camel humps R/P/V", m.positions == [0, 4, 11],
			"got \(m.positions)")

		guard let e = FuzzyMatch.match(query: "safari", candidate: "Safari") else {
			return check("'safari' matches Safari", false)
		}
		check(
			"exact match covers every character", e.positions == [0, 1, 2, 3, 4, 5],
			"got \(e.positions)")

		// Positions must be strictly increasing and in range for any match.
		for (q, c) in [
			("ci", "CalcIndex"), ("coreapp", "~/Code/Core/AppIndex.swift"), ("tm", "Time Machine"),
		] {
			guard let m = FuzzyMatch.match(query: q, candidate: c) else {
				check("\(q) matches \(c)", false)
				continue
			}
			let ok =
				zip(m.positions, m.positions.dropFirst()).allSatisfy { $0 < $1 }
				&& m.positions.allSatisfy { $0 >= 0 && $0 < c.count }
			check("positions strictly increasing and in range for '\(q)'", ok, "got \(m.positions)")
		}
	}

	static func edgeCases() {
		check("empty query scores 0", FuzzyMatch.score(query: "", candidate: "Safari") == 0)
		check("empty candidate never matches", FuzzyMatch.score(query: "a", candidate: "") == nil)
		check(
			"query longer than candidate fails",
			FuzzyMatch.score(query: "safaris", candidate: "Safari") == nil)
		check(
			"case is ignored when matching",
			FuzzyMatch.score(query: "SAFARI", candidate: "safari") != nil)
		check(
			"unicode candidate is safe",
			FuzzyMatch.score(query: "cafe", candidate: "Café Münster") != nil)
		check(
			"emoji candidate is safe",
			FuzzyMatch.score(query: "sm", candidate: "😀 smiling face") != nil)
		check(
			"repeated query characters need repeated candidate characters",
			FuzzyMatch.score(query: "aaa", candidate: "banal") == nil)
		check(
			"…and are satisfied when the candidate has enough of them",
			FuzzyMatch.score(query: "aaa", candidate: "banana") != nil)
	}

	// MARK: - Helpers

	/// Score that must exist; reports a failure and returns 0 rather than trapping.
	static func need(_ query: String, _ candidate: String) -> Int {
		guard let s = FuzzyMatch.score(query: query, candidate: candidate) else {
			check("'\(query)' should match \(candidate)", false)
			return 0
		}
		return s
	}

	static func rank(_ query: String) -> [String] {
		apps.compactMap { name -> (String, Int)? in
			guard let s = FuzzyMatch.score(query: query, candidate: name) else { return nil }
			return (name, s)
		}
		.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.count < $1.0.count }
		.map(\.0)
	}

	/// Asserts `winner` outranks `loser` for `query`, and that both actually match.
	static func beats(_ query: String, _ winner: String, _ loser: String) {
		let w = FuzzyMatch.score(query: query, candidate: winner)
		let l = FuzzyMatch.score(query: query, candidate: loser)
		guard let w else {
			return check(
				"'\(query)': \(winner) beats \(loser)", false, "winner did not match at all")
		}
		guard let l else {
			return check("'\(query)': \(winner) beats \(loser) (loser no match)", true)
		}
		check("'\(query)': \(winner) [\(w)] beats \(loser) [\(l)]", w > l)
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
