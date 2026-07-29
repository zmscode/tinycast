import SwiftUI

/// A label with the characters the fuzzy matcher actually matched picked out.
///
/// The positions come from `FuzzyMatch.match`, so the highlight always agrees with the ranking —
/// there is no second, approximate "find the query in the string" pass to drift out of sync.
///
/// Deliberately computed per rendered row rather than threaded down from `rank`: only the dozen or
/// so realized rows ever ask, and `match` costs about 4× `score`, which is nothing at that scale but
/// would be real across the thousands of candidates a ranking sweep touches.
struct HighlightedText: View {
	let text: String
	/// The fragment that was actually matched — the whole query for the launcher, the trailing path
	/// fragment for the file grid.
	let query: String

	var body: some View {
		Text(attributed)
	}

	private var attributed: AttributedString {
		var result = AttributedString(text)
		let trimmed = query.trimmingCharacters(in: .whitespaces)
		guard !trimmed.isEmpty,
			let match = FuzzyMatch.match(query: trimmed, candidate: text)
		else { return result }

		// `positions` index the candidate's Character array, which is what AttributedString's
		// character view indexes too — so no UTF-8/UTF-16 offset conversion is needed.
		let characters = result.characters
		for position in match.positions {
			guard position >= 0, position < text.count else { continue }
			let start = characters.index(characters.startIndex, offsetBy: position)
			let end = characters.index(after: start)
			result[start..<end].foregroundColor = .white
			result[start..<end].font = Theme.Typography.rowTitle.weight(.bold)
		}
		return result
	}
}
