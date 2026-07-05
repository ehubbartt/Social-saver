import SwiftUI

struct TripsView: View {
    enum Mode: String, CaseIterable { case trips = "Trips", events = "Events" }

    @State private var trips: [Trip] = []
    @State private var events: [Event] = []
    @State private var mode: Mode = .trips
    @State private var isLoading = false
    @State private var showingCreate = false
    @State private var showingCreateEvent = false

    private let repository = TripsRepository()
    private let eventsRepository = EventsRepository()

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

    /// The trip happening right now, with today's 1-based day number.
    private var activeTripDay: (trip: Trip, day: Int)? {
        let today = Calendar.current.startOfDay(for: .now)
        for trip in trips {
            guard let start = trip.startDateValue, let end = trip.endDateValue,
                  today >= start, today <= end else { continue }
            let day = (Calendar.current.dateComponents([.day], from: start, to: today).day ?? 0) + 1
            return (trip, min(day, trip.dayCount))
        }
        return nil
    }

    private var upcomingEvents: [Event] {
        events.sorted { ($0.dateValue ?? .distantFuture) < ($1.dateValue ?? .distantFuture) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("View", selection: $mode) {
                        ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if mode == .events {
                    eventsContent
                } else {
                    tripsContent
                }
            }
            .overlay {
                if mode == .events && events.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No events yet",
                        systemImage: "calendar.badge.plus",
                        description: Text("Plan a single day out and invite friends to it.")
                    )
                } else if mode == .trips && trips.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No trips yet",
                        systemImage: "airplane.departure",
                        description: Text("Create a trip and plan it from the videos you've saved.")
                    )
                }
            }
            .navigationTitle(mode.rawValue)
            .toolbar {
                Button {
                    if mode == .events { showingCreateEvent = true } else { showingCreate = true }
                } label: {
                    Image(systemName: "plus")
                }
            }
            .refreshable { await refresh() }
            .task {
                await refresh()
                await BriefingScheduler.shared.refresh()
            }
            .sheet(isPresented: $showingCreate) {
                CreateTripSheet { await refresh() }
            }
            .sheet(isPresented: $showingCreateEvent) {
                CreateEventSheet { await refresh() }
            }
        }
    }

    @ViewBuilder
    private var eventsContent: some View {
        ForEach(upcomingEvents) { event in
            NavigationLink {
                EventDetailView(event: event)
            } label: {
                eventRow(event)
            }
        }
    }

    private func eventRow(_ event: Event) -> some View {
        HStack(spacing: 12) {
            Text(event.emoji ?? "🎉").font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(.headline)
                HStack(spacing: 4) {
                    Text(event.whenText)
                    if event.ownerId != SupabaseClientProvider.currentUserId {
                        Image(systemName: "person.2.fill").foregroundStyle(.tint)
                    }
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var tripsContent: some View {
        Group {
                if let active = activeTripDay {
                    Section {
                        NavigationLink {
                            TodayView(trip: active.trip, day: active.day)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "sun.max.fill")
                                    .font(.title2)
                                    .foregroundStyle(.yellow)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Today · Day \(active.day) in \(active.trip.destination)")
                                        .font(.headline)
                                    Text("Plan, weather, and when to leave")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
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
    }

    private func tripRow(_ trip: Trip) -> some View {
        HStack(spacing: 12) {
            Text(trip.emoji ?? "🧳")
                .font(.title2)
            VStack(alignment: .leading, spacing: 2) {
                Text(trip.name)
                    .font(.headline)
                HStack(spacing: 4) {
                    Text(trip.destination)
                    if trip.userId != SupabaseClientProvider.currentUserId {
                        Label("Shared", systemImage: "person.2.fill")
                            .labelStyle(.iconOnly)
                            .foregroundStyle(.tint)
                    }
                }
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
        isLoading = trips.isEmpty && events.isEmpty
        defer { isLoading = false }
        trips = (try? await repository.fetchTrips()) ?? trips
        events = (try? await eventsRepository.events()) ?? events
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
