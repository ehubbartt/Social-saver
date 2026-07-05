import SwiftUI

struct TripsView: View {
    @State private var trips: [Trip] = []
    @State private var isLoading = false
    @State private var showingCreate = false

    private let repository = TripsRepository()

    /// Upcoming (soonest first), then undated, then past trips.
    private var sortedTrips: [Trip] {
        let today = Calendar.current.startOfDay(for: .now)
        return trips.sorted { a, b in
            switch (a.startDateValue, b.startDateValue) {
            case let (.some(dateA), .some(dateB)):
                let aPast = dateA < today
                let bPast = dateB < today
                if aPast != bPast { return bPast }
                return aPast ? dateA > dateB : dateA < dateB
            case (.some, .none): return true
            case (.none, .some): return false
            case (.none, .none): return a.createdAt > b.createdAt
            }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(sortedTrips) { trip in
                    NavigationLink {
                        TripDetailView(trip: trip)
                    } label: {
                        tripRow(trip)
                    }
                }
                .onDelete { indexSet in
                    Task { await delete(at: indexSet) }
                }
            }
            .overlay {
                if trips.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "airplane.departure",
                        description: Text("Create a trip and plan it from the videos you've saved.")
                    )
                }
            }
            .navigationTitle("Trips")
            .toolbar {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .sheet(isPresented: $showingCreate) {
                CreateTripSheet {
                    await refresh()
                }
            }
        }
    }

    private func tripRow(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            Text(trip.emoji ?? "🧳")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name)
                    .font(.headline)
                Text(trip.destination)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let days = trip.daysUntilStart {
                Text(days == 0 ? "Today!" : "in \(days)d")
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private func refresh() async {
        isLoading = trips.isEmpty
        defer { isLoading = false }
        trips = (try? await repository.fetchTrips()) ?? trips
    }

    private func delete(at indexSet: IndexSet) async {
        let ordered = sortedTrips
        for index in indexSet {
            try? await repository.deleteTrip(id: ordered[index].id)
        }
        await refresh()
    }
}

struct CreateTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onCreated: () async -> Void

    @State private var name = ""
    @State private var destination = ""
    @State private var emoji = ""
    @State private var hasDates = true
    @State private var startDate = Date.now
    @State private var endDate = Calendar.current.date(byAdding: .day, value: 4, to: .now) ?? .now
    @State private var isCreating = false
    @State private var errorMessage: String?

    private let repository = TripsRepository()

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Trip name (e.g. Spring in Tokyo)", text: $name)
                    TextField("Destination (e.g. Tokyo, Japan)", text: $destination)
                    TextField("Emoji (optional)", text: $emoji)
                }

                Section {
                    Toggle("I know the dates", isOn: $hasDates)
                    if hasDates {
                        DatePicker("Start", selection: $startDate, displayedComponents: .date)
                        DatePicker("End", selection: $endDate, in: startDate..., displayedComponents: .date)
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("New trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") {
                        Task { await create() }
                    }
                    .disabled(isCreating || name.isEmpty || destination.isEmpty)
                }
            }
        }
    }

    private func create() async {
        isCreating = true
        defer { isCreating = false }
        do {
            try await repository.createTrip(
                name: name,
                destination: destination,
                emoji: emoji.isEmpty ? nil : emoji,
                startDate: hasDates ? startDate : nil,
                endDate: hasDates ? endDate : nil
            )
            await onCreated()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
