import SwiftUI
import ProxyLightCore

// Sheets for choosing which mappings take part in an export or import.
// Both follow the MappingEditorView layout: headline title, grouped Form,
// bottom bar with Cancel on the left of the default action.

private let transferSheetWidth: CGFloat = 480
private let transferSheetMaxHeight: CGFloat = 520

// From/to pair rendered the same way as the main mappings list.
private struct MappingSummary: View {
	let mapping: Mapping

	var body: some View {
		VStack(alignment: .leading, spacing: 1) {
			Text(mapping.from)
				.lineLimit(1)
				.truncationMode(.middle)
			Text(mapping.to)
				.font(.caption)
				.foregroundStyle(.secondary)
				.lineLimit(1)
				.truncationMode(.middle)
		}
	}
}

// Pick which of the current mappings get written to the export file.
// Everything starts selected; confirming hands the selection to onExport.
struct ExportSelectionView: View {
	let mappings: [Mapping]
	let onExport: ([Mapping]) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var selectedIDs: Set<Mapping.ID>

	init(mappings: [Mapping], onExport: @escaping ([Mapping]) -> Void) {
		self.mappings = mappings
		self.onExport = onExport
		_selectedIDs = State(initialValue: Set(mappings.map(\.id)))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Export Mappings")
				.font(.headline)
				.padding([.top, .horizontal], 20)

			Form {
				Section {
					ForEach(mappings) { mapping in
						Toggle(isOn: selectionBinding(mapping.id)) {
							MappingSummary(mapping: mapping)
						}
					}
				} footer: {
					Text("\(selectedIDs.count) of \(mappings.count) selected — only the selected mappings are written to the export file.")
						.font(.caption)
						.foregroundStyle(.secondary)
				}
			}
			.formStyle(.grouped)

			Divider()

			HStack {
				Button(allSelected ? "Deselect All" : "Select All") {
					selectedIDs = allSelected ? [] : Set(mappings.map(\.id))
				}
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Export…") {
					let selected = mappings.filter { selectedIDs.contains($0.id) }
					dismiss()
					onExport(selected)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(selectedIDs.isEmpty)
			}
			.padding(20)
		}
		.frame(width: transferSheetWidth)
		.frame(maxHeight: transferSheetMaxHeight)
	}

	private var allSelected: Bool { selectedIDs.count == mappings.count }

	private func selectionBinding(_ id: Mapping.ID) -> Binding<Bool> {
		Binding(
			get: { selectedIDs.contains(id) },
			set: { included in
				if included { selectedIDs.insert(id) } else { selectedIDs.remove(id) }
			}
		)
	}
}

// Pick which of an import file's mappings to keep. New mappings start
// selected; a mapping that collides with an existing one (same local URL or
// same live-site URL) starts unselected and is labelled with what it would
// overwrite, so overwriting is always an explicit opt-in. Exact duplicates
// are disabled — importing them would change nothing.
struct ImportSelectionView: View {
	let onImport: ([Mapping]) -> Void
	@Environment(\.dismiss) private var dismiss
	@State private var selectedOffsets: Set<Int>
	// Rows are keyed by position, not mapping id: ids come from the file and
	// aren't trusted to be unique.
	private let rows: [(mapping: Mapping, disposition: MappingIO.ImportDisposition)]

	init(imported: [Mapping], existing: [Mapping], onImport: @escaping ([Mapping]) -> Void) {
		self.onImport = onImport
		let classified = imported.map { ($0, MappingIO.classify($0, against: existing)) }
		rows = classified
		_selectedOffsets = State(initialValue: Set(classified.indices.filter { classified[$0].1 == .new }))
	}

	var body: some View {
		VStack(alignment: .leading, spacing: 0) {
			Text("Import Mappings")
				.font(.headline)
				.padding([.top, .horizontal], 20)

			Form {
				Section {
					ForEach(rows.indices, id: \.self) { index in
						row(at: index)
					}
				} footer: {
					summaryFooter
				}
			}
			.formStyle(.grouped)

			Divider()

			HStack {
				Spacer()
				Button("Cancel", role: .cancel) { dismiss() }
					.keyboardShortcut(.cancelAction)
				Button("Import") {
					let accepted = selectedOffsets.sorted().map { rows[$0].mapping }
					dismiss()
					onImport(accepted)
				}
				.keyboardShortcut(.defaultAction)
				.disabled(selectedOffsets.isEmpty)
			}
			.padding(20)
		}
		.frame(width: transferSheetWidth)
		.frame(maxHeight: transferSheetMaxHeight)
	}

	@ViewBuilder
	private func row(at index: Int) -> some View {
		let entry = rows[index]
		VStack(alignment: .leading, spacing: 3) {
			Toggle(isOn: selectionBinding(index)) {
				MappingSummary(mapping: entry.mapping)
			}
			.disabled(entry.disposition == .duplicate)
			switch entry.disposition {
			case .new:
				EmptyView()
			case .duplicate:
				Text("Identical mapping already present — nothing to import.")
					.font(.caption)
					.foregroundStyle(.secondary)
			case .conflict(let matches):
				ForEach(matches) { match in
					Label("Overwrites \(match.from) → \(match.to)", systemImage: "exclamationmark.triangle.fill")
						.font(.caption)
						.foregroundStyle(.orange)
						.lineLimit(1)
						.truncationMode(.middle)
				}
			}
		}
	}

	private var summaryFooter: some View {
		let selected = selectedOffsets.map { rows[$0] }
		let adds = selected.filter { $0.disposition == .new }.count
		// Duplicates can't be selected, so everything else is an overwrite.
		let overwrites = selected.count - adds
		return Text("Importing \(adds) new mapping(s)" + (overwrites > 0 ? ", overwriting \(overwrites) existing." : "."))
			.font(.caption)
			.foregroundStyle(overwrites > 0 ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
	}

	private func selectionBinding(_ index: Int) -> Binding<Bool> {
		Binding(
			get: { selectedOffsets.contains(index) },
			set: { included in
				if included { selectedOffsets.insert(index) } else { selectedOffsets.remove(index) }
			}
		)
	}
}
