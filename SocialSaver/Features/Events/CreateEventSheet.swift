import SwiftUI

struct CreateEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () async -> Void

    @State private var title = ""
    @State private var emoji = ""
    @State private var date = Date.now
    @State private var hasTime = true
    @State private var time = Date.now
    @State private var note = ""
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let repository = EventsRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What's happening? (e.g. Saturday food crawl)", text: $title)
                    TextField("Emoji (optional)", text: $emoji)
                }
                Section {
                    DatePicker("Date", selection: $date, displayedComponents: .date)
                    Toggle("Set a start time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Start", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }
                Section("Note") {
                    TextField("Details for your guests (optional)", text: $note, axis: .vertical)
                        .lineLimit(2...5)
                }
                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red) }
                }
            }
            .navigationTitle("New event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(isCreating || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            let trimmedNote = note.trimmingCharacters(in: .whitespacesAndNewlines)
            _ = try await repository.createEvent(
                title: title.trimmingCharacters(in: .whitespaces),
                emoji: emoji.isEmpty ? nil : emoji,
                date: date,
                time: hasTime ? time : nil,
                note: trimmedNote.isEmpty ? nil : trimmedNote
            )
            await onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
