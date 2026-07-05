import SwiftUI
import MapKit

struct TripDetailView: View {
    @Environment(SavesStore.self) private var store

    let trip: Trip
    @State private var items: [TripItem] = []
    @State private var isLoading = false
    @State private var isPlanning = false
    @State private var planSummary: String?
    @State private var showingAddSaves = false
    @State private var showingMap = false
    @State private var errorMessage: String?

    private let repository = TripsRepository()

    private var ideas: [TripItem] { items.filter { $0.dayIndex == nil } }

    private func items(forDay day: Int) -> [TripItem] {
        items.filter { $0.dayIndex == day }
    }

    var body: some View {
        List {
            headerSection

            if let planSummary {
                Section {
                    Label(planSummary, systemImage: "sparkles")
                        .font(.footnote)
                }
            }

            ForEach(1...trip.dayCount, id: \.self) { day in
                Section(dayTitle(day)) {
                    let dayItems = items(forDay: day)
                    if dayItems.isEmpty {
                        Text("Nothing planned")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                    }
                    ForEach(dayItems) { item in
                        itemRow(item)
                    }
                }
            }

            Section("Ideas") {
                if ideas.isEmpty {
                    Text("Saves added to the trip but not scheduled land here.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                }
                ForEach(ideas) { item in
                    itemRow(item)
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle("\(trip.emoji ?? "") \(trip.name)".trimmingCharacters(in: .whitespaces))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    showingMap = true
                } label: {
                    Image(systemName: "map")
                }
                .disabled(pins.isEmpty)
                Menu {
                    Button {
                        showingAddSaves = true
                    } label: {
                        Label("Add saves", systemImage: "plus")
                    }
                    Button {
                        Task { await autoPlan() }
                    } label: {
                        Label("Auto-plan from my saves", systemImage: "wand.and.stars")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .overlay {
            if isPlanning {
                VStack(spacing: 12) {
                    ProgressView()
                    Text("Planning your days…")
                        .font(.footnote)
                }
                .padding(24)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 16))
            }
        }
        .refreshable { await refresh() }
        .task {
            await refresh()
            await store.refresh()
        }
        .sheet(isPresented: $showingAddSaves) {
            AddSavesToTripSheet(trip: trip, existingSaveIds: Set(items.map(\.save.id))) {
                await refresh()
            }
        }
        .sheet(isPresented: $showingMap) {
            TripMapView(trip: trip, pins: pins)
        }
    }

    private var headerSection: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                Text(trip.destination)
                    .font(.headline)
                if let start = trip.startDateValue, let end = trip.endDateValue {
                    Text("\(start.formatted(date: .abbreviated, time: .omitted)) – \(end.formatted(date: .abbreviated, time: .omitted))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let days = trip.daysUntilStart, days > 0 {
                    Text("Starts in \(days) day\(days == 1 ? "" : "s")")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
        }
    }

    private func dayTitle(_ day: Int) -> String {
        if let date = trip.date(forDay: day) {
            return "Day \(day) · \(date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day()))"
        }
        return "Day \(day)"
    }

    private func itemRow(_ item: TripItem) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: item.save.thumbnailUrl.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: item.save.contentType.systemImage)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(item.save.title ?? item.save.sourceUrl)
                    .font(.subheadline)
                    .lineLimit(1)
                if let place = item.save.places.first {
                    Text(place.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                if let note = item.note, !note.isEmpty {
                    Text(note)
                        .font(.caption2)
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                }
            }

            Spacer()

            Menu {
                ForEach(1...trip.dayCount, id: \.self) { day in
                    Button("Day \(day)") {
                        Task { await move(item, toDay: day) }
                    }
                }
                Button("Ideas") {
                    Task { await move(item, toDay: nil) }
                }
                Divider()
                Button(role: .destructive) {
                    Task { await remove(item) }
                } label: {
                    Label("Remove from trip", systemImage: "trash")
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
        }
        .background {
            NavigationLink("") {
                SaveDetailView(save: item.save)
            }
            .opacity(0)
        }
    }

    private var pins: [PlacePin] {
        var byPlace: [UUID: PlacePin] = [:]
        for item in items {
            for place in item.save.places where place.latitude != nil && place.longitude != nil {
                byPlace[place.id, default: PlacePin(place: place, saves: [])].saves.append(item.save)
            }
        }
        return Array(byPlace.values)
    }

    private func refresh() async {
        isLoading = items.isEmpty
        defer { isLoading = false }
        items = (try? await repository.fetchItems(tripId: trip.id)) ?? items
    }

    private func autoPlan() async {
        isPlanning = true
        errorMessage = nil
        defer { isPlanning = false }
        do {
            let response = try await repository.autoPlan(tripId: trip.id)
            planSummary = response.summary
            await refresh()
        } catch {
            errorMessage = "Couldn't plan the trip. Try again."
        }
    }

    private func move(_ item: TripItem, toDay day: Int?) async {
        do {
            try await repository.setDay(itemId: item.id, day: day)
            await refresh()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func remove(_ item: TripItem) async {
        do {
            try await repository.removeItem(id: item.id)
            items.removeAll { $0.id == item.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Picker for adding saved videos to a trip, with destination-relevant saves
/// sorted to the top.
struct AddSavesToTripSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SavesStore.self) private var store

    let trip: Trip
    let existingSaveIds: Set<UUID>
    let onAdded: () async -> Void

    @State private var selection: Set<UUID> = []
    @State private var isAdding = false

    private let repository = TripsRepository()

    private var candidates: [Save] {
        let available = store.saves.filter { !existingSaveIds.contains($0.id) }
        let destinationToken = trip.destination
            .components(separatedBy: ",")[0]
            .trimmingCharacters(in: .whitespaces)
            .lowercased()
        guard !destinationToken.isEmpty else { return available }
        return available.sorted { relevance($0, token: destinationToken) > relevance($1, token: destinationToken) }
    }

    private func relevance(_ save: Save, token: String) -> Int {
        let inPlaces = save.places.contains {
            $0.name.lowercased().contains(token)
                || ($0.city ?? "").lowercased().contains(token)
                || ($0.country ?? "").lowercased().contains(token)
        }
        if inPlaces { return 2 }
        let inText = (save.title?.lowercased().contains(token) ?? false)
            || (save.summary?.lowercased().contains(token) ?? false)
        return inText ? 1 : 0
    }

    var body: some View {
        NavigationStack {
            List(candidates) { save in
                Button {
                    if selection.contains(save.id) {
                        selection.remove(save.id)
                    } else {
                        selection.insert(save.id)
                    }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(save.title ?? save.sourceUrl)
                                .lineLimit(1)
                                .foregroundStyle(.primary)
                            if let place = save.places.first {
                                Text([place.name, place.subtitle].filter { !$0.isEmpty }.joined(separator: " · "))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(save.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(save.id) ? Color.accentColor : Color.secondary)
                    }
                }
            }
            .overlay {
                if candidates.isEmpty {
                    ContentUnavailableView("All saves are already in this trip", systemImage: "checkmark")
                }
            }
            .navigationTitle("Add to trip")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selection.count)") {
                        Task { await add() }
                    }
                    .disabled(selection.isEmpty || isAdding)
                }
            }
            .task { await store.refresh() }
        }
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        try? await repository.addSaves(Array(selection), to: trip.id)
        await onAdded()
        dismiss()
    }
}

struct TripMapView: View {
    @Environment(\.dismiss) private var dismiss
    let trip: Trip
    let pins: [PlacePin]

    var body: some View {
        NavigationStack {
            Map {
                ForEach(pins) { pin in
                    Marker(
                        pin.place.name,
                        coordinate: CLLocationCoordinate2D(
                            latitude: pin.place.latitude ?? 0,
                            longitude: pin.place.longitude ?? 0
                        )
                    )
                }
            }
            .navigationTitle(trip.destination)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
