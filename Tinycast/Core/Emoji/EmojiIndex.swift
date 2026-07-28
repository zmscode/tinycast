import Foundation

/// Owns the parsed emoji/symbol catalog: category sections precomputed once at load, search memoized one query deep (the `AppIndex` pattern).
@MainActor
final class EmojiIndex: ObservableObject {
	@Published private(set) var entries: [EmojiEntry] = []
	@Published private(set) var categorySections: [(category: EmojiCategory, entries: [EmojiEntry])] = []

	private var byGlyph: [String: EmojiEntry] = [:]
	private var searchCache: (query: String, result: [EmojiEntry])?

	var isLoaded: Bool { !entries.isEmpty }

	func load() async {
		let parsed = await Task.detached(priority: .utility) { EmojiCatalog.parse(EmojiData.raw) }.value
		entries = parsed
		var grouped: [EmojiCategory: [EmojiEntry]] = [:]
		for entry in parsed { grouped[entry.category, default: []].append(entry) }
		categorySections = EmojiCategory.allCases.compactMap { category in
			grouped[category].map { (category, $0) }
		}
		byGlyph = Dictionary(parsed.map { ($0.glyph, $0) }, uniquingKeysWith: { first, _ in first })
		searchCache = nil
	}

	func entry(for glyph: String) -> EmojiEntry? { byGlyph[glyph] }

	/// Ranked fuzzy matches over names and keywords; empty query returns nothing (the grid shows sections instead).
	func search(_ query: String, limit: Int = 320) -> [EmojiEntry] {
		let q = query.trimmingCharacters(in: .whitespaces)
		guard !q.isEmpty else { return [] }
		if let searchCache, searchCache.query == q { return searchCache.result }

		// A keyword hit is penalized so an equal-quality name match always outranks it. Sized against
		// FuzzyMatch's scale (a matched character is worth 16), not the old tiered one where this was
		// 500 out of ~70,000 — at that magnitude every keyword hit would now sort below every name hit.
		let keywordPenalty = 8
		var scored: [(entry: EmojiEntry, score: Int, order: Int)] = []
		for (order, entry) in entries.enumerated() {
			let nameScore = FuzzyMatch.score(query: q, candidate: entry.name)
			var best = nameScore
			if !entry.keywords.isEmpty,
				let keywordScore = FuzzyMatch.score(query: q, candidate: entry.keywords)
			{
				best = max(best ?? Int.min, keywordScore - keywordPenalty)
			}
			if let best { scored.append((entry, best, order)) }
		}
		// Shorter name wins a tie: fzf scores the matched region only, so "grin" and "grinning cat
		// with smiling eyes" tie on score alone.
		let result = scored
			.sorted {
				if $0.score != $1.score { return $0.score > $1.score }
				if $0.entry.name.count != $1.entry.name.count {
					return $0.entry.name.count < $1.entry.name.count
				}
				return $0.order < $1.order
			}
			.prefix(limit)
			.map(\.entry)
		searchCache = (q, result)
		return result
	}
}
