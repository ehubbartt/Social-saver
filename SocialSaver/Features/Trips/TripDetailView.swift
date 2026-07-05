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
    @State private var addStopKind: TripItemKind?
    @State private var timeEditItem: TripItem?
    @State private var routeDay: DayRef?
    @State private var showingMap = false
    @State private var showingChat = false
    @State private var showingMembers = false
    @State private var canEdit = true
    @State private var photoItem: TripItem?
    @State private var errorMessage: String?

    /// Photo matching window: the trip's dates (padded to whole days), or a
    /// broad fallback when the trip is undated.
    private var photoWindow: (start: Date, end: Date) {
        let calendar = Calendar.current
        if let start = trip.startDateValue, let end = trip.endDateValue {
            let dayEnd = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: end)) ?? end
            return (calendar.startOfDay(for: start), dayEnd)
        }
        let now = Date.now
        let twoYearsAgo = calendar.date(byAdding: .year, value: -2, to: now) ?? now
        return (twoYearsAgo, now)
    }

    private let repository = TripsRepository()

    private var isOwner: Bool { repository.isOwner(trip) }

    struct DayRef: Identifiable {
        let day: Int
        var id: Int { day }
    }

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
                Section {
                    let dayItems = items(forDay: day)
                    if dayItems.isEmpty {
                        Text("Nothing planned — drag stops here")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .dropDestination(for: String.self) { ids, _ in
                                handleDrop(ids, toDay: day, before: nil)
                            }
                    }
                    ForEach(dayItems) { item in
                        itemRow(item)
                            .draggable(item.id.uuidString)
                            .dropDestination(for: String.self) { ids, _ in
                                handleDrop(ids, toDay: day, before: item)
                            }
                    }
                    if !dayItems.isEmpty {
                        dropTail(day: day)
                    }
                } header: {
                    dayHeader(day)
                }
            }

            Section {
                if ideas.isEmpty {
                    Text("Saves added to the trip but not scheduled land here.")
                        .font(.footnote)
                        .foregroundStyle(.tertiary)
                        .dropDestination(for: String.self) { ids, _ in
                            handleDrop(ids, toDay: nil, before: nil)
                        }
                }
                ForEach(ideas) { item in
                    itemRow(item)
                        .draggable(item.id.uuidString)
                        .dropDestination(for: String.self) { ids, _ in
                            handleDrop(ids, toDay: nil, before: item)
                        }
                }
            } header: {
                Text("Ideas")
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
                    showingMembers = true
                } label: {
                    Image(systemName: "person.2")
                }
                Button {
                    showingChat = true
                } label: {
                    Image(systemName: "bubble.left.and.text.bubble.right")
                }
                Button {
                    showingMap = true
                } label: {
                    Image(systemName: "map")
                }
                .disabled(pins.isEmpty)
                if canEdit {
                Menu {
                    Button {
                        showingAddSaves = true
                    } label: {
                        Label("Add saves", systemImage: "bookmark")
                    }
                    Button {
                        addStopKind = .flight
                    } label: {
                        Label("Add flight", systemImage: "airplane")
                    }
                    Button {
                        addStopKind = .hotel
                    } label: {
                        Label("Add hotel", systemImage: "bed.double")
                    }
                    Button {
                        addStopKind = .custom
                    } label: {
                        Label("Add custom stop", systemImage: "mappin")
                    }
                    Divider()
                    Button {
                        Task { await autoPlan() }
                    } label: {
                        Label("Auto-plan from my saves", systemImage: "wand.and.stars")
                    }
                } label: {
                    Image(systemName: "plus")
                }
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
            await resolveEditRights()
        }
        .sheet(isPresented: $showingMembers) {
            TripMembersSheet(trip: trip, isOwner: isOwner) {
                await resolveEditRights()
            }
        }
        .sheet(item: $photoItem) { item in
            if let place = item.mappedPlace {
                PhotoSuggestionsSheet(
                    place: place,
                    tripId: trip.id,
                    start: photoWindow.start,
                    end: photoWindow.end
                ) {
                    await refresh()
                }
            }
        }
        .sheet(isPresented: $showingAddSaves) {
            AddSavesToTripSheet(trip: trip, existingSaveIds: Set(items.compactMap(\.save?.id))) {
                await refresh()
            }
        }
        .sheet(item: $addStopKind) { kind in
            AddStopSheet(trip: trip, kind: kind) {
                await refresh()
            }
        }
        .sheet(item: $timeEditItem) { item in
            ItemTimeSheet(item: item) {
                await refresh()
            }
        }
        .sheet(item: $routeDay) { ref in
            DayRouteView(trip: trip, day: ref.day, items: items(forDay: ref.day))
        }
        .sheet(isPresented: $showingMap) {
            TripMapView(trip: trip, pins: pins)
        }
        .sheet(isPresented: $showingChat) {
            TripChatView(trip: trip) {
                await refresh()
            }
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
                Text("Tip: press and hold any stop to drag it onto a day.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func dayHeader(_ day: Int) -> some View {
        HStack {
            Text(dayTitle(day))
            Spacer()
            if items(forDay: day).contains(where: { $0.coordinate != nil }) {
                Button {
                    routeDay = DayRef(day: day)
                } label: {
                    Label("Route", systemImage: "point.topleft.down.to.point.bottomright.curvepath")
                        .font(.caption)
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

    /// Invisible drop target so items can be dropped at the end of a day.
    private func dropTail(day: Int?) -> some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: 6)
            .listRowSeparator(.hidden)
            .dropDestination(for: String.self) { ids, _ in
                handleDrop(ids, toDay: day, before: nil)
            }
    }

    private func itemRow(_ item: TripItem) -> some View {
        HStack(spacing: 10) {
            if let save = item.save {
                AsyncImage(url: save.thumbnailUrl.flatMap { URL(string: $0) }) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    ZStack {
                        Color(.secondarySystemBackground)
                        Image(systemName: save.contentType.systemImage)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 48, height: 48)
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.accentColor.opacity(0.12))
                    Image(systemName: item.kind.systemImage)
                        .foregroundStyle(.tint)
                }
                .frame(width: 48, height: 48)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    if let time = item.timeDisplay {
                        Text(time)
                            .font(.caption.bold())
                            .foregroundStyle(.tint)
                    }
                    Text(item.displayTitle)
                        .font(.subheadline)
                        .lineLimit(1)
                }
                if let subtitle = item.subtitle {
                    Text(subtitle)
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

            if canEdit {
                Menu {
                    Button {
                        timeEditItem = item
                    } label: {
                        Label(item.startTime == nil ? "Set time…" : "Change time…", systemImage: "clock")
                    }
                    Divider()
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
        }
        .background {
            if let save = item.save {
                NavigationLink("") {
                    SaveDetailView(save: save)
                }
                .opacity(0)
            }
        }
        .contextMenu {
            // Any member can add their own photos of a mapped place — that's
            // not editing the plan, so it isn't gated by canEdit.
            if item.mappedPlace != nil {
                Button {
                    photoItem = item
                } label: {
                    Label("Add your photos here", systemImage: "photo.badge.plus")
                }
            }
        }
    }

    private var pins: [PlacePin] {
        var byPlace: [UUID: PlacePin] = [:]
        for item in items {
            guard let save = item.save else { continue }
            for place in save.places where place.latitude != nil && place.longitude != nil {
                byPlace[place.id, default: PlacePin(place: place, saves: [])].saves.append(save)
            }
        }
        return Array(byPlace.values)
    }

    // MARK: - Drag & drop

    private func resolveEditRights() async {
        if isOwner {
            canEdit = true
            return
        }
        let members = (try? await repository.members(tripId: trip.id)) ?? []
        let me = SupabaseClientProvider.currentUserId
        canEdit = members.first { $0.userId == me }?.isEditor ?? false
    }

    private func handleDrop(_ ids: [String], toDay day: Int?, before target: TripItem?) -> Bool {
        guard canEdit else { return false }
        guard let idString = ids.first,
              let uuid = UUID(uuidString: idString),
              let dragged = items.first(where: { $0.id == uuid })
        else { return false }
        guard dragged.id != target?.id else { return true }

        Task {
            var dayItems = items.filter { $0.dayIndex == day && $0.id != dragged.id }
            let insertIndex = target.flatMap { t in dayItems.firstIndex(where: { $0.id == t.id }) }
                ?? dayItems.count
            dayItems.insert(dragged, at: insertIndex)
            // Renumber the whole target day so ordering stays stable.
            for (index, item) in dayItems.enumerated() {
                try? await repository.setPlacement(itemId: item.id, day: day, position: index * 10)
            }
            await refresh()
        }
        return true
    }

    // MARK: - Data

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

extension TripItemKind: Identifiable {
    var id: String { rawValue }
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
