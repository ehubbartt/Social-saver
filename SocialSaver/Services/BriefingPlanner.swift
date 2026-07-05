import Foundation
import MapKit
import UserNotifications

/// User-configurable briefing settings, shared between the settings screen
/// (@AppStorage) and the scheduler (UserDefaults reads).
enum BriefingSettings {
    static let enabledKey = "briefings.enabled"
    static let minutesFromMidnightKey = "briefings.minutesFromMidnight"
    static let prepMinutesKey = "briefings.prepMinutes"
    static let eveningPreviewKey = "briefings.eveningPreview"

    // Distinguish "never set" from a legitimate 0 (e.g. a midnight briefing).
    static var minutesFromMidnight: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: minutesFromMidnightKey) != nil else { return 450 } // 07:30
        return defaults.integer(forKey: minutesFromMidnightKey)
    }

    static var prepMinutes: Int {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: prepMinutesKey) != nil else { return 60 }
        return defaults.integer(forKey: prepMinutesKey)
    }
}

/// Everything known about one trip day, used by both the Today screen and
/// the notification text so they never disagree.
struct DayPlan {
    let trip: Trip
    let day: Int
    let date: Date
    let stops: [TripItem]
    let weather: DayWeather?
    /// Hotel → first timed stop travel time, when both are known.
    let travelTime: TimeInterval?

    var firstTimedStop: TripItem? {
        stops.first { $0.timeComponents != nil }
    }

    var firstStopArrival: Date? {
        guard let stop = firstTimedStop, let (hour, minute) = stop.timeComponents else { return nil }
        return Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: date)
    }

    /// Departure with a fixed 10-minute margin on top of travel time.
    var leaveBy: Date? {
        guard let arrival = firstStopArrival, let travelTime else { return nil }
        return arrival.addingTimeInterval(-travelTime - 600)
    }

    /// Leave-by minus prep time; without a known route, first stop minus prep.
    var wakeUp: Date? {
        let prep = TimeInterval(BriefingSettings.prepMinutes * 60)
        if let leaveBy { return leaveBy.addingTimeInterval(-prep) }
        guard let arrival = firstStopArrival else { return nil }
        return arrival.addingTimeInterval(-prep)
    }
}

enum BriefingPlanner {
    /// Timed stops first (by time), then unscheduled ones in itinerary order.
    static func sortedStops(_ items: [TripItem]) -> [TripItem] {
        items.sorted { a, b in
            switch (a.timeComponents, b.timeComponents) {
            case let (.some(x), .some(y)):
                return (x.hour, x.minute) < (y.hour, y.minute)
            case (.some, .none):
                return true
            case (.none, .some):
                return false
            case (.none, .none):
                return a.position < b.position
            }
        }
    }

    static func hotel(in items: [TripItem]) -> TripItem? {
        items.last { $0.kind == .hotel && $0.coordinate != nil }
    }

    /// Hotel → first timed stop travel time via MapKit; nil when unknown.
    static func travelTime(from hotel: TripItem?, to stop: TripItem?) async -> TimeInterval? {
        guard let hotelCoordinate = hotel?.coordinate, let stopCoordinate = stop?.coordinate else { return nil }
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(coordinate: hotelCoordinate))
        request.destination = MKMapItem(placemark: MKPlacemark(coordinate: stopCoordinate))
        let straightLine = CLLocation(latitude: hotelCoordinate.latitude, longitude: hotelCoordinate.longitude)
            .distance(from: CLLocation(latitude: stopCoordinate.latitude, longitude: stopCoordinate.longitude))
        request.transportType = straightLine < 2500 ? .walking : .automobile
        if let route = try? await MKDirections(request: request).calculate().routes.first {
            return route.expectedTravelTime
        }
        // Offline fallback: straight line at a conservative speed.
        return straightLine / (straightLine < 2500 ? 1.2 : 7.0)
    }

    static func notificationBody(for plan: DayPlan) -> String {
        var parts: [String] = []

        let names = plan.stops.prefix(4).map { stop in
            stop.timeDisplay.map { "\($0) \(stop.displayTitle)" } ?? stop.displayTitle
        }
        var lineup = names.joined(separator: " → ")
        if plan.stops.count > 4 { lineup += " …" }
        parts.append("\(plan.stops.count) stop\(plan.stops.count == 1 ? "" : "s"): \(lineup).")

        if let weather = plan.weather {
            var line = "\(Int(weather.tempMin.rounded()))–\(Int(weather.tempMax.rounded()))°C, \(weather.summary)"
            if let precip = weather.precipProbability, precip >= 30 {
                line += " (\(precip)% rain)"
            }
            line += " — \(weather.wearTip)."
            parts.append(line)
        }

        let time: (Date) -> String = { $0.formatted(date: .omitted, time: .shortened) }
        if let leave = plan.leaveBy, let wake = plan.wakeUp {
            parts.append("Wake by \(time(wake)), leave by \(time(leave)).")
        } else if let wake = plan.wakeUp {
            parts.append("Wake by \(time(wake)) for the first stop.")
        }

        return parts.joined(separator: " ")
    }
}

/// Schedules local notifications for upcoming trip days. Re-run after trip
/// edits or settings changes — it clears and rebuilds its own requests
/// (identifiers prefixed "briefing-").
@MainActor
final class BriefingScheduler {
    static let shared = BriefingScheduler()

    private let repository = TripsRepository()
    private let weatherService = WeatherService()
    private var isRefreshing = false
    private var lastRefresh: Date?

    /// `force` skips the throttle — used when settings change.
    func refresh(force: Bool = false) async {
        guard !isRefreshing else { return }
        // The sweep hits weather + directions APIs, so don't re-run it on
        // every Trips tab appearance.
        if !force, let lastRefresh, Date.now.timeIntervalSince(lastRefresh) < 900 { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefresh = .now
        }

        let center = UNUserNotificationCenter.current()
        let pending = await center.pendingNotificationRequests()
        let stale = pending.map(\.identifier).filter { $0.hasPrefix("briefing-") }
        center.removePendingNotificationRequests(withIdentifiers: stale)

        let defaults = UserDefaults.standard
        guard defaults.bool(forKey: BriefingSettings.enabledKey) else { return }
        guard (try? await center.requestAuthorization(options: [.alert, .sound])) == true else { return }

        let calendar = Calendar.current
        let today = calendar.startOfDay(for: .now)
        guard let horizon = calendar.date(byAdding: .day, value: 7, to: today) else { return }
        let briefingMinutes = BriefingSettings.minutesFromMidnight
        let eveningPreview = defaults.bool(forKey: BriefingSettings.eveningPreviewKey)

        guard let trips = try? await repository.fetchTrips() else { return }
        for trip in trips {
            guard let start = trip.startDateValue, let end = trip.endDateValue,
                  end >= today, start <= horizon else { continue }
            guard let items = try? await repository.fetchItems(tripId: trip.id), !items.isEmpty else { continue }

            // One forecast per trip, anchored on the first mapped stop.
            var forecast: [String: DayWeather] = [:]
            if let coordinate = items.compactMap(\.coordinate).first {
                forecast = (try? await weatherService.dailyForecast(
                    latitude: coordinate.latitude,
                    longitude: coordinate.longitude,
                    start: max(start, today),
                    end: end
                )) ?? [:]
            }
            let hotel = BriefingPlanner.hotel(in: items)

            for day in 1...trip.dayCount {
                guard let date = trip.date(forDay: day), date >= today, date <= horizon else { continue }
                let stops = BriefingPlanner.sortedStops(items.filter { $0.dayIndex == day })
                guard !stops.isEmpty else { continue }

                // Same stop the leave-by arrival uses; travelTime returns nil
                // if it has no coordinates and wake-up falls back cleanly.
                let travel = await BriefingPlanner.travelTime(
                    from: hotel,
                    to: stops.first { $0.timeComponents != nil }
                )
                let plan = DayPlan(
                    trip: trip,
                    day: day,
                    date: date,
                    stops: stops,
                    weather: forecast[Trip.dayFormatter.string(from: date)],
                    travelTime: travel
                )
                let body = BriefingPlanner.notificationBody(for: plan)
                let tripLabel = "\(trip.emoji ?? "🧳") Day \(day) in \(trip.destination)"

                if let fireDate = calendar.date(
                    bySettingHour: briefingMinutes / 60,
                    minute: briefingMinutes % 60,
                    second: 0,
                    of: date
                ), fireDate > .now {
                    await schedule(
                        center: center,
                        identifier: "briefing-\(trip.id)-\(day)-morning",
                        title: tripLabel,
                        body: body,
                        fireDate: fireDate
                    )
                }

                if eveningPreview,
                   let previousEvening = calendar.date(byAdding: .day, value: -1, to: date)
                       .flatMap({ calendar.date(bySettingHour: 21, minute: 0, second: 0, of: $0) }),
                   previousEvening > .now {
                    await schedule(
                        center: center,
                        identifier: "briefing-\(trip.id)-\(day)-evening",
                        title: "Tomorrow: \(tripLabel)",
                        body: body,
                        fireDate: previousEvening
                    )
                }
            }
        }
    }

    private func schedule(
        center: UNUserNotificationCenter,
        identifier: String,
        title: String,
        body: String,
        fireDate: Date
    ) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let components = Calendar.current.dateComponents(
            [.year, .month, .day, .hour, .minute],
            from: fireDate
        )
        let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        try? await center.add(UNNotificationRequest(identifier: identifier, content: content, trigger: trigger))
    }
}
