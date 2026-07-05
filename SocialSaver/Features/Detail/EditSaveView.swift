import SwiftUI
import MapKit

/// Manual corrections for everything the AI pipeline wrote: title, summary,
/// category, and the places attached to a save. Place edits go through Apple
/// Maps search so the user picks the exact right pin instead of typing
/// coordinates.
struct EditSaveView: View {
    @Environment(\.dismiss) private var dismiss

    let save: Save
    let onSaved: () async -> Void

    @State private var title: String
    @State private var summary: String
    @State private var note: String
    @State private var contentType: ContentType
    @State private var places: [Place]
    @State private var placeToReplace: Place?
    @State private var showingPlaceSearch = false
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let repository = SavesRepository()

    init(save: Save, onSaved: @escaping () async -> Void) {
        self.save = save
        self.onSaved = onSaved
        _title = State(initialValue: save.title ?? "")
        _summary = State(initialValue: save.summary ?? "")
        _note = State(initialValue: save.note ?? "")
        _contentType = State(initialValue: save.contentType)
        _places = State(initialValue: save.places)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title, axis: .vertical)
                }

                Section("Category") {
                    Picker("Category", selection: $contentType) {
                        ForEach(ContentType.allCases) { type in
                            Label(type.label, systemImage: type.systemImage).tag(type)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Summary") {
                    TextField("Summary", text: $summary, axis: .vertical)
                        .lineLimit(3...8)
                }

                Section("My note") {
                    TextField("e.g. Mia recommended this — book ahead", text: $note, axis: .vertical)
                        .lineLimit(2...6)
                }

                Section {
                    ForEach(places) { place in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(place.name)
                                if !place.subtitle.isEmpty {
                                    Text(place.subtitle)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Menu {
                                Button {
                                    placeToReplace = place
                                    showingPlaceSearch = true
                                } label: {
                                    Label("Replace…", systemImage: "arrow.triangle.2.circlepath")
                                }
                                Button(role: .destructive) {
                                    Task { await remove(place) }
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "ellipsis.circle")
                            }
                        }
                    }
                    Button {
                        placeToReplace = nil
                        showingPlaceSearch = true
                    } label: {
                        Label("Add place", systemImage: "plus")
                    }
                } header: {
                    Text("Places")
                } footer: {
                    Text("Place changes apply immediately; other edits apply when you tap Save.")
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Edit save")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await commit() }
                    }
                    .disabled(isSaving)
                }
            }
            .sheet(isPresented: $showingPlaceSearch) {
                PlaceSearchView { mapItem in
                    Task { await apply(mapItem, replacing: placeToReplace) }
                }
            }
        }
    }

    private func commit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.update(
                id: save.id,
                title: trimmedTitle.isEmpty ? nil : trimmedTitle,
                summary: trimmedSummary.isEmpty ? nil : trimmedSummary,
                contentType: contentType
            )
            try await repository.setNote(saveId: save.id, note: trimmedNote.isEmpty ? nil : trimmedNote)
            await onSaved()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ place: Place) async {
        do {
            try await repository.removePlace(place.id, from: save.id)
            places.removeAll { $0.id == place.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func apply(_ mapItem: MKMapItem, replacing old: Place?) async {
        do {
            let placemark = mapItem.placemark
            let newPlace = try await repository.setPlace(
                on: save.id,
                replacing: old?.id,
                name: mapItem.name ?? placemark.name ?? "Unknown place",
                address: placemark.title,
                city: placemark.locality,
                country: placemark.country,
                latitude: placemark.coordinate.latitude,
                longitude: placemark.coordinate.longitude
            )
            if let old, let index = places.firstIndex(of: old) {
                places[index] = newPlace
            } else {
                places.append(newPlace)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Apple Maps search so corrected locations come with accurate coordinates
/// and addresses instead of free-typed text.
struct PlaceSearchView: View {
    @Environment(\.dismiss) private var dismiss
    let onSelect: (MKMapItem) -> Void

    @State private var query = ""
    @State private var results: [MKMapItem] = []
    @State private var isSearching = false

    var body: some View {
        NavigationStack {
            List(Array(results.enumerated()), id: \.offset) { _, item in
                Button {
                    onSelect(item)
                    dismiss()
                } label: {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Unknown")
                            .foregroundStyle(.primary)
                        if let address = item.placemark.title {
                            Text(address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .overlay {
                if results.isEmpty {
                    ContentUnavailableView(
                        query.isEmpty ? "Search for a place" : (isSearching ? "Searching…" : "No results"),
                        systemImage: "magnifyingglass"
                    )
                }
            }
            .searchable(text: $query, prompt: "Restaurant, landmark, address…")
            .task(id: query) {
                await search()
            }
            .navigationTitle("Find place")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func search() async {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 3 else {
            results = []
            return
        }
        // Debounce keystrokes before hitting MapKit.
        try? await Task.sleep(for: .milliseconds(350))
        guard !Task.isCancelled else { return }

        isSearching = true
        defer { isSearching = false }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = trimmed
        let search = MKLocalSearch(request: request)
        if let response = try? await search.start() {
            results = response.mapItems
        }
    }
}
