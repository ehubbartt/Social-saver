import SwiftUI

/// Compact star display for summaries and review rows.
struct StarsView: View {
    let rating: Int
    var size: Font = .caption

    var body: some View {
        HStack(spacing: 1) {
            ForEach(1...5, id: \.self) { star in
                Image(systemName: star <= rating ? "star.fill" : "star")
                    .font(size)
                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
            }
        }
    }
}

/// Write or edit your review of a place: star rating, a worth-it verdict,
/// and an optional written take.
struct ReviewSheet: View {
    @Environment(\.dismiss) private var dismiss

    let place: Place
    let existing: PlaceReview?
    let onDone: () async -> Void

    @State private var rating: Int
    @State private var worthIt: Bool
    @State private var text: String
    @State private var isSaving = false
    @State private var errorMessage: String?

    private let repository = ReviewsRepository()

    init(place: Place, existing: PlaceReview?, onDone: @escaping () async -> Void) {
        self.place = place
        self.existing = existing
        self.onDone = onDone
        _rating = State(initialValue: existing?.rating ?? 0)
        _worthIt = State(initialValue: existing?.worthIt ?? true)
        _text = State(initialValue: existing?.body ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Rating") {
                    HStack(spacing: 8) {
                        ForEach(1...5, id: \.self) { star in
                            Button {
                                rating = star
                            } label: {
                                Image(systemName: star <= rating ? "star.fill" : "star")
                                    .font(.title2)
                                    .foregroundStyle(star <= rating ? Color.yellow : Color.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .frame(maxWidth: .infinity)
                }

                Section {
                    Picker("Verdict", selection: $worthIt) {
                        Text("👍 Worth it").tag(true)
                        Text("👎 Skip it").tag(false)
                    }
                    .pickerStyle(.segmented)
                }

                Section {
                    TextField("Was it worth the hype? Tips for going?", text: $text, axis: .vertical)
                        .lineLimit(3...8)
                } header: {
                    Text("Your take")
                } footer: {
                    Text("Reviews are visible to other users. Friends see them with your username in their feed.")
                }

                if existing != nil {
                    Section {
                        Button("Delete my review", role: .destructive) {
                            Task { await deleteReview() }
                        }
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await save() }
                    }
                    .disabled(rating == 0 || isSaving)
                }
            }
        }
    }

    private func save() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.upsertReview(
                placeId: place.id,
                rating: rating,
                worthIt: worthIt,
                body: trimmed.isEmpty ? nil : trimmed
            )
            await onDone()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func deleteReview() async {
        do {
            try await repository.deleteReview(placeId: place.id)
            await onDone()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
