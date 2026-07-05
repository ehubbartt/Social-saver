import SwiftUI
import MapKit

/// Adds a non-save itinerary entry: flight, hotel, or custom stop, with an
/// optional day, time, and searched location.
struct AddStopSheet: View {
    @Environment(\.dismiss) private var dismiss

    let trip: Trip
    let kind: TripItemKind
    let onAdded: () async -> Void

    @State private var title = ""
    @State private var detail = ""
    @State private var day: Int? = 1
    @State private var hasTime = false
    @State private var time = Date.now
    @State private var location: SelectedLocation?
    @State private var showingSearch = false
    @State private var isAdding = false
    @State private var errorMessage: String?

    private let repository = TripsRepository()

    struct SelectedLocation {
        let name: String
        let address: String?
        let latitude: Double
        let longitude: Double
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(titlePlaceholder, text: $title)
                    TextField(detailPlaceholder, text: $detail)
                }

                Section("When") {
                    Picker("Day", selection: $day) {
                        Text("Ideas").tag(Int?.none)
                        ForEach(1...trip.dayCount, id: \.self) { day in
                            Text("Day \(day)").tag(Int?.some(day))
                        }
                    }
                    Toggle("Set a time", isOn: $hasTime)
                    if hasTime {
                        DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                    }
                }

                Section("Where (optional)") {
                    if let location {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(location.name)
                            if let address = location.address {
                                Text(address).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Button("Remove location", role: .destructive) {
                            self.location = nil
                        }
                    }
                    Button {
                        showingSearch = true
                    } label: {
                        Label(location == nil ? "Add location" : "Change location", systemImage: "magnifyingglass")
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add \(kind.label.lowercased())")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        Task { await add() }
                    }
                    .disabled(isAdding || title.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .sheet(isPresented: $showingSearch) {
                PlaceSearchView { mapItem in
                    location = SelectedLocation(
                        name: mapItem.name ?? "Location",
                        address: mapItem.placemark.title,
                        latitude: mapItem.placemark.coordinate.latitude,
                        longitude: mapItem.placemark.coordinate.longitude
                    )
                }
            }
        }
    }

    private var titlePlaceholder: String {
        switch kind {
        case .flight: return "e.g. UA 837 to Tokyo"
        case .hotel: return "e.g. Park Hyatt check-in"
        case .transport: return "e.g. Narita Express to Shinjuku"
        default: return "e.g. Sunset picnic"
        }
    }

    private var detailPlaceholder: String {
        switch kind {
        case .flight: return "Confirmation #, terminal…"
        case .hotel: return "Confirmation #, notes…"
        default: return "Notes (optional)"
        }
    }

    private func add() async {
        isAdding = true
        defer { isAdding = false }
        do {
            let trimmedDetail = detail.trimmingCharacters(in: .whitespacesAndNewlines)
            try await repository.addCustomItem(
                tripId: trip.id,
                kind: kind,
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                detail: trimmedDetail.isEmpty ? nil : trimmedDetail,
                day: day,
                time: hasTime ? time : nil,
                latitude: location?.latitude,
                longitude: location?.longitude,
                address: location?.address
            )
            await onAdded()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Sets or clears the scheduled time on an existing itinerary item.
struct ItemTimeSheet: View {
    @Environment(\.dismiss) private var dismiss

    let item: TripItem
    let onDone: () async -> Void

    @State private var time: Date
    @State private var errorMessage: String?

    private let repository = TripsRepository()

    init(item: TripItem, onDone: @escaping () async -> Void) {
        self.item = item
        self.onDone = onDone
        var initial = Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: .now) ?? .now
        if let (hour, minute) = item.timeComponents {
            initial = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: .now) ?? initial
        }
        _time = State(initialValue: initial)
    }

    var body: some View {
        NavigationStack {
            Form {
                DatePicker("Time", selection: $time, displayedComponents: .hourAndMinute)
                if item.startTime != nil {
                    Button("Clear time", role: .destructive) {
                        Task { await set(nil) }
                    }
                }
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                }
            }
            .navigationTitle(item.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { await set(time) }
                    }
                }
            }
            .presentationDetents([.medium])
        }
    }

    private func set(_ value: Date?) async {
        do {
            try await repository.setTime(itemId: item.id, time: value)
            await onDone()
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
