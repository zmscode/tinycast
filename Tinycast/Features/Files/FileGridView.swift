import SwiftUI

enum FileGrid {
	/// Wider tiles than the emoji grid — a filename needs room to read, a glyph doesn't.
	static let columns = 5
}

/// Icon-array browser for a typed path: five columns of file icons with captions, keyboard-driven
/// off the same flat `selection` index every other palette mode uses.
struct FileGridView: View {
	let entries: [FileEntry]
	let selection: Int
	/// The directory being listed. Row IDs are namespaced by it, so browsing elsewhere gives every
	/// row a new identity and the LazyVStack rebuilds at the top — no explicit scroll reset, which
	/// would fight the header's safe-area inset and jam the first row underneath it.
	let directoryKey: String
	/// The trailing path fragment being typed — what the caption highlights.
	let fragment: String
	let onSelect: (Int) -> Void
	let onActivate: () -> Void

	private var rows: [FileGridRow] {
		var rows: [FileGridRow] = []
		var offset = 0
		while offset < entries.count {
			let end = min(offset + FileGrid.columns, entries.count)
			rows.append(
				FileGridRow(
					id: "\(directoryKey)#\(offset)", start: offset,
					entries: Array(entries[offset..<end])))
			offset = end
		}
		return rows
	}

	var body: some View {
		let rows = rows
		return ScrollViewReader { proxy in
			ScrollView {
				LazyVStack(spacing: 0) {
					ForEach(rows) { row in
						FileGridRowView(
							row: row, selection: selection, fragment: fragment,
							onSelect: onSelect, onActivate: onActivate
						)
						.id(row.id)
					}
				}
				.padding(.horizontal, Theme.Spacing.md)
				.padding(.vertical, Theme.Spacing.xs)
				.hideNativeScrollers()
			}
			.edgeDissolve()
			.thinScrollbar()
			// Minimal scroll (nil anchor): an already-visible row never moves, so following the
			// selection can't pull content up under the floating header.
			.onChange(of: selection) {
				let row = selection / FileGrid.columns
				guard rows.indices.contains(row) else { return }
				proxy.scrollTo(rows[row].id, anchor: nil)
			}
		}
	}
}

private struct FileGridRow: Identifiable {
	let id: String
	let start: Int
	let entries: [FileEntry]
}

private struct FileGridRowView: View {
	let row: FileGridRow
	let selection: Int
	let fragment: String
	let onSelect: (Int) -> Void
	let onActivate: () -> Void

	var body: some View {
		HStack(spacing: 0) {
			ForEach(0..<FileGrid.columns, id: \.self) { column in
				if column < row.entries.count {
					let index = row.start + column
					FileCell(
						entry: row.entries[column], selected: index == selection,
						fragment: fragment)
						.contentShape(Rectangle())
						// Drag straight into Finder, a message, an upload field. The palette holds key
						// focus for the whole drag, so its resign-key dismissal never fires mid-drag.
						.draggable(URL(fileURLWithPath: row.entries[column].path)) {
							FileIconView(path: row.entries[column].path)
								.frame(width: Theme.Size.fileTileIcon, height: Theme.Size.fileTileIcon)
						}
						.onTapGesture { onSelect(index) }
						.simultaneousGesture(
							TapGesture(count: 2).onEnded {
								onSelect(index)
								onActivate()
							}
						)
				} else {
					// Empty trailing slots keep the last row's columns aligned with the rows above.
					Color.clear.frame(maxWidth: .infinity)
				}
			}
		}
	}
}

private struct FileCell: View {
	let entry: FileEntry
	let selected: Bool
	let fragment: String
	@State private var hovered = false

	private var fill: Color {
		if selected { return Theme.Colors.selection }
		if hovered { return Theme.Colors.rowHover }
		return .clear
	}

	var body: some View {
		VStack(spacing: Theme.Spacing.sm) {
			FileIconView(path: entry.path)
				.frame(width: Theme.Size.fileTileIcon, height: Theme.Size.fileTileIcon)
			// Matched against the caption, not `name`: highlighting an extension that isn't drawn
			// would put the emphasis on characters the user cannot see.
			HighlightedText(text: entry.displayName, query: fragment)
				.font(Theme.Typography.keyCap)
				.lineLimit(2)
				.multilineTextAlignment(.center)
				.truncationMode(.middle)
				.foregroundStyle(entry.isDirectory ? .primary : .secondary)
				.frame(height: 28, alignment: .top)
		}
		.padding(.vertical, Theme.Spacing.md)
		.padding(.horizontal, Theme.Spacing.xs)
		.frame(maxWidth: .infinity)
		.background(
			RoundedRectangle(cornerRadius: Theme.Radius.row, style: .continuous)
				.fill(fill)
		)
		.armedHover($hovered)
		.accessibilityElement(children: .ignore)
		.accessibilityLabel(
			entry.isDirectory
				? String(localized: "\(entry.name), folder") : String(localized: "\(entry.name), file"))
		.accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
	}
}

/// File icon that decodes off the main thread, mirroring `AppIconView` — a directory listing can
/// realize dozens of tiles at once and `NSWorkspace.icon(forFile:)` is not cheap.
struct FileIconView: View {
	let path: String
	@State private var image: NSImage?

	var body: some View {
		Group {
			if let image = image ?? IconCache.cached(forFile: path) {
				Image(nsImage: image).resizable().interpolation(.high)
			} else {
				RoundedRectangle(cornerRadius: Theme.Radius.thumbnail, style: .continuous)
					.fill(Theme.Colors.controlSurface)
			}
		}
		.task(id: path) {
			guard IconCache.cached(forFile: path) == nil else { return }
			image = await IconCache.loadAsync(forFile: path)
		}
	}
}
