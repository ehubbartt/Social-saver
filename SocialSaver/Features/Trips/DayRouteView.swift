import SwiftUI
import MapKit

enum TransportMode: String, CaseIterable, Identifiable {
    case walk
    case drive

    var id: String { rawValue }

    var label: String {
        switch self {
        case .walk: return "Walk"
        case .drive: return "Drive"
        }
    }

    var systemImage: String {
        switch self {
        case .walk: return "figure.walk"
        case .drive: return "car"
        }
    }

    var transportType: MKDirectionsTransportType {
        switch self {
        case .walk: return .walking
        case .drive: return .automobile
        }
    }

    /// Fallback speed (m/s) when directions are unavailable.
    var fallbackSpeed: Double {
        switch self {
        case .walk: return 1.3
        case .drive: return 9.0
        }
    }
}

struct RouteLeg: Identifiable {
    let id = UUID()
    let index: Int
    let from: String
    let to: String
    let distance: CLLocationDistance
    let travelTime: TimeInterval
    let polyline: MKPolyline
    let isEstimate: Bool
    /// Scheduled arrival at the destination stop, when it has a time set.
    let arriveBy: Date?

    var leaveBy: Date? {
        arriveBy?.addingTimeInterval(-travelTime)
    }

    var distanceText: String {
        distance < 1000
            ? "\(Int(distance.rounded())) m"
            : String(format: "%.1f km", distance / 1000)
    }

    var durationText: String {
        let minutes = max(1, Int((travelTime / 60).rounded()))
        if minutes < 60 { return "\(minutes) min" }
        return "\(minutes / 60) h \(minutes % 60) min"
    }
}

/// A day's stops in order, connected by real routes, with distance, travel
/// time, and "leave by" per leg.
struct DayRouteView: View {
    @Environment(\.dismiss) private var dismiss

    let trip: Trip
    let day: Int
    let items: [TripItem]

    @State private var mode: TransportMode = .walk
    @State private var legs: [RouteLeg] = []
    @State private var isRouting = false

    private var stops: [TripItem] {
        items.filter { $0.coordinate != nil }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                routeMap
                legsList
            }
            .navigationTitle(dayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task(id: mode) { await computeRoutes() }
        }
    }

    private var dayTitle: String {
        if let date = trip.date(forDay: day) {
            return "Day \(day) · \(date.formatted(.dateTime.month(.abbreviated).day()))"
        }
        return "Day \(day) route"
    }

    private var routeMap: some View {
        Map {
            ForEach(legs) { leg in
                MapPolyline(leg.polyline)
                    .stroke(
                        Color.accentColor,
                        style: StrokeStyle(
                            lineWidth: 4,
                            lineCap: .round,
                            dash: leg.isEstimate ? [6, 6] : []
                        )
                    )
            }
            ForEach(Array(stops.enumerated()), id: \.element.id) { index, stop in
                if let coordinate = stop.coordinate {
                    Annotation(stop.displayTitle, coordinate: coordinate) {
                        Text("\(index + 1)")
                            .font(.caption.bold())
                            .foregroundStyle(.white)
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.accentColor))
                            .overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
            }
        }
    }

    private var legsList: some View {
        List {
            Section {
                Picker("Transport", selection: $mode) {
                    ForEach(TransportMode.allCases) { mode in
                        Label(mode.label, systemImage: mode.systemImage).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }

            Section("Route") {
                if stops.count < 2 {
                    Text("Add at least two stops with locations to see the route.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else if isRouting {
                    ProgressView("Calculating routes…")
                } else {
                    ForEach(legs) { leg in
                        legRow(leg)
                    }
                }
            }
        }
        .frame(maxHeight: 340)
    }

    private func legRow(_ leg: RouteLeg) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text("\(leg.index + 1) → \(leg.index + 2)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                Text("\(leg.distanceText) · \(leg.durationText)\(leg.isEstimate ? " (est.)" : "")")
                    .font(.subheadline)
            }
            Text("\(leg.from) → \(leg.to)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let leaveBy = leg.leaveBy, let arriveBy = leg.arriveBy {
                Label(
                    "Leave by \(leaveBy.formatted(date: .omitted, time: .shortened)) to arrive \(arriveBy.formatted(date: .omitted, time: .shortened))",
                    systemImage: "clock.badge.exclamationmark"
                )
                .font(.caption.weight(.medium))
                .foregroundStyle(.tint)
            }
        }
        .padding(.vertical, 2)
    }

    private func computeRoutes() async {
        let stops = self.stops
        guard stops.count >= 2 else {
            legs = []
            return
        }
        isRouting = true
        defer { isRouting = false }

        var newLegs: [RouteLeg] = []
        for index in 0..<(stops.count - 1) {
            let from = stops[index]
            let to = stops[index + 1]
            guard let fromCoordinate = from.coordinate, let toCoordinate = to.coordinate else { continue }

            let arriveBy = arrivalDate(for: to)
            let request = MKDirections.Request()
            request.source = MKMapItem(placemark: MKPlacemark(coordinate: fromCoordinate))
            request.destination = MKMapItem(placemark: MKPlacemark(coordinate: toCoordinate))
            request.transportType = mode.transportType

            if let route = try? await MKDirections(request: request).calculate().routes.first {
                newLegs.append(RouteLeg(
                    index: index,
                    from: from.displayTitle,
                    to: to.displayTitle,
                    distance: route.distance,
                    travelTime: route.expectedTravelTime,
                    polyline: route.polyline,
                    isEstimate: false,
                    arriveBy: arriveBy
                ))
            } else {
                // Directions unavailable (offline, or no route) — fall back to
                // a straight line and a speed-based estimate.
                let fromLocation = CLLocation(latitude: fromCoordinate.latitude, longitude: fromCoordinate.longitude)
                let toLocation = CLLocation(latitude: toCoordinate.latitude, longitude: toCoordinate.longitude)
                let distance = fromLocation.distance(from: toLocation)
                var coordinates = [fromCoordinate, toCoordinate]
                newLegs.append(RouteLeg(
                    index: index,
                    from: from.displayTitle,
                    to: to.displayTitle,
                    distance: distance,
                    travelTime: distance / mode.fallbackSpeed,
                    polyline: MKPolyline(coordinates: &coordinates, count: 2),
                    isEstimate: true,
                    arriveBy: arriveBy
                ))
            }
        }
        legs = newLegs
    }

    private func arrivalDate(for item: TripItem) -> Date? {
        guard let (hour, minute) = item.timeComponents else { return nil }
        let base = trip.date(forDay: day) ?? Calendar.current.startOfDay(for: .now)
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base)
    }
}
