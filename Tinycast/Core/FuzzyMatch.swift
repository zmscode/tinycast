import Foundation

// Foundation-only and pure so `Tools/fuzz-test.swift` can compile this exact source; keep AppKit out.
//
// Scoring is a port of fzf's FuzzyMatchV2 (github.com/junegunn/fzf, MIT © Junegunn Choi): an
// affine-gap alignment that picks the *best* placement of the query rather than the first one, with
// bonuses for word boundaries, camelCase humps and path separators. Two properties a left-to-right
// subsequence walk can't give:
//
//   - "rpv" prefers RootPaletteView over reproving — camel humps beat an earlier, denser run.
//   - "coreapp" scores well against …/Core/AppIndex.swift — `/` reads as a word boundary.
//
// Bonuses read the ORIGINAL case; only the equality test is case-folded. Lower-casing the text first
// would erase the camelCase signal that does most of the work.
enum FuzzyMatch {
	// fzf's constants (algo.go). The ratios matter more than the magnitudes: a boundary is worth
	// half a match, opening a gap costs about a fifth of one.
	private static let scoreMatch = 16
	private static let scoreGapStart = -3
	private static let scoreGapExtension = -1
	private static let bonusBoundary = scoreMatch / 2
	private static let bonusNonWord = scoreMatch / 2
	private static let bonusCamel123 = bonusBoundary + scoreGapExtension
	private static let bonusConsecutive = -(scoreGapStart + scoreGapExtension)
	private static let bonusFirstCharMultiplier = 2
	private static let bonusBoundaryWhite = bonusBoundary + 2
	private static let bonusBoundaryDelimiter = bonusBoundary + 1

	/// A scored match plus the candidate offsets that matched, so a row can highlight them. Offsets index the candidate's `Character` array.
	struct Match: Equatable {
		let score: Int
		let positions: [Int]
	}

	/// Ordered so `> .nonWord` means "a real word character", matching fzf's boundary test.
	private enum CharClass: Int {
		case white = 0
		case nonWord
		case delimiter
		case lower
		case upper
		case letter
		case number
	}

	/// Relevance score (higher is better), or nil when the query doesn't match.
	///
	/// Skips the backtrace matrix, which ranking never reads — that allocation is most of the cost
	/// when sweeping thousands of candidates on every keystroke, so don't route this through `match`.
	static func score(query: String, candidate: String) -> Int? {
		align(query: query, candidate: candidate, tracking: false)?.score
	}

	/// Full match with positions, for highlighting. An empty query matches everything at score 0 — callers read that as "no filtering".
	static func match(query: String, candidate: String) -> Match? {
		align(query: query, candidate: candidate, tracking: true)
	}

	private static func align(query: String, candidate: String, tracking: Bool) -> Match? {
		let pattern = Array(query)
		guard !pattern.isEmpty else { return Match(score: 0, positions: []) }
		let text = Array(candidate)
		guard !text.isEmpty else { return nil }

		let loweredPattern = pattern.map(folded)
		let loweredText = text.map(folded)

		// Bound the work to the region that can hold a match: first occurrence of the query's first
		// character through the greedy end. Everything outside is dead cells.
		guard let first = loweredText.firstIndex(of: loweredPattern[0]) else { return nil }
		var pidx = 0
		var last = 0
		for (i, c) in loweredText.enumerated() where pidx < loweredPattern.count {
			if c == loweredPattern[pidx] {
				last = i
				pidx += 1
			}
		}
		guard pidx == loweredPattern.count else { return nil }

		let width = last - first + 1
		let rows = pattern.count

		// Boundary bonus per text position, taken from the class transition into it. Only the match
		// region is scored, but the walk starts at 0 so position `first` sees its true predecessor.
		var bonuses = [Int](repeating: 0, count: last + 1)
		var previous = CharClass.white
		for i in 0...last {
			let current = charClass(text[i])
			bonuses[i] = bonusFor(previous: previous, current: current)
			previous = current
		}

		let none = Int.min / 4  // sentinel: no alignment ends at this cell

		// `best[j]`: score of an alignment through the current row whose last matched character sits
		// at column j. `runs[j]`: the consecutive-match streak ending there, for the run bonus.
		var best = [Int](repeating: none, count: width)
		var runs = [Int](repeating: 0, count: width)
		var next = [Int](repeating: none, count: width)
		var nextRuns = [Int](repeating: 0, count: width)
		// Flat rows × width, and only when the caller wants positions back.
		var parents = tracking ? [Int](repeating: -1, count: rows * width) : []

		for row in 0..<rows {
			for j in 0..<width {
				next[j] = none
				nextRuns[j] = 0
			}
			// Affine gap carried left to right: open a gap after the previous row's match, or extend
			// the one already open. `gapFrom` remembers the column it started from, for backtrace.
			var gap = none
			var gapFrom = -1

			for j in 0..<width {
				let col = first + j

				if row > 0, j >= 2 {
					let opened = best[j - 2]
					let openScore = opened == none ? none : opened + scoreGapStart
					let extended = gap == none ? none : gap + scoreGapExtension
					if openScore >= extended {
						gap = openScore
						gapFrom = j - 2
					} else {
						gap = extended
					}
				}

				guard loweredPattern[row] == loweredText[col] else { continue }

				// Row 0 may start anywhere — no leading-gap penalty, same as fzf.
				var from = -1
				var carried = 0
				let base: Int
				if row == 0 {
					base = 0
				} else {
					let diagonal = j >= 1 ? best[j - 1] : none
					if diagonal != none && diagonal >= gap {
						base = diagonal
						from = j - 1
						carried = runs[j - 1]
					} else if gap != none {
						base = gap
						from = gapFrom
					} else {
						continue
					}
				}

				var bonus = bonuses[col]
				var run = carried + 1
				if run > 1 {
					// fzf: a boundary start outranks a long run; otherwise the run keeps the better of
					// its opening bonus and the flat consecutive bonus.
					let runStart = bonuses[col - run + 1]
					if bonus >= bonusBoundary && bonus > runStart {
						run = 1
					} else {
						bonus = max(bonus, max(runStart, bonusConsecutive))
					}
				}
				if row == 0 { bonus *= bonusFirstCharMultiplier }

				next[j] = base + scoreMatch + bonus
				nextRuns[j] = run
				if tracking { parents[row * width + j] = from }
			}

			swap(&best, &next)
			swap(&runs, &nextRuns)
		}

		var end = -1
		for j in 0..<width where best[j] != none && (end == -1 || best[j] > best[end]) { end = j }
		guard end >= 0 else { return nil }

		guard tracking else { return Match(score: best[end], positions: []) }
		var positions = [Int](repeating: 0, count: rows)
		var column = end
		for row in stride(from: rows - 1, through: 0, by: -1) {
			positions[row] = first + column
			if row > 0 { column = parents[row * width + column] }
		}
		return Match(score: best[end], positions: positions)
	}

	// ASCII fast paths matter here: this runs over every candidate on every keystroke, and
	// `Character.lowercased()` allocates a String per call — enough to cost tens of milliseconds
	// across an emoji-sized index. Non-ASCII falls through to the correct Unicode-aware path.
	private static func folded(_ c: Character) -> Character {
		guard let ascii = c.asciiValue else { return c.lowercased().first ?? c }
		guard ascii >= 65, ascii <= 90 else { return c }
		return Character(UnicodeScalar(ascii + 32))
	}

	private static func charClass(_ c: Character) -> CharClass {
		guard let ascii = c.asciiValue else {
			if c.isNumber { return .number }
			if c.isLetter { return c.isUppercase ? .upper : (c.isLowercase ? .lower : .letter) }
			return .nonWord
		}
		switch ascii {
		case 32, 9, 10, 13: return .white
		case 48...57: return .number
		case 65...90: return .upper
		case 97...122: return .lower
		// fzf's default delimiter set — this is what makes a path segment read as a word start.
		case 47, 44, 58, 59, 124: return .delimiter
		default: return .nonWord
		}
	}

	private static func bonusFor(previous: CharClass, current: CharClass) -> Int {
		if current.rawValue > CharClass.nonWord.rawValue {
			switch previous {
			case .white: return bonusBoundaryWhite
			case .delimiter: return bonusBoundaryDelimiter
			case .nonWord: return bonusBoundary
			default: break
			}
		}
		if previous == .lower && current == .upper { return bonusCamel123 }
		if previous != .number && current == .number { return bonusCamel123 }
		switch current {
		case .nonWord, .delimiter: return bonusNonWord
		case .white: return bonusBoundaryWhite
		default: return 0
		}
	}
}
