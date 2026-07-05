import SwiftUI
import MapKit

/// The day at a glance for an active trip: weather and what to wear, when to
/// wake up and leave, and the day's timeline.
struct TodayView: View {
    let trip: Trip
    let day: Int

    @State private var plan: DayPlan?
    @State private var isLoading = true
    @State private var showingRoute = false

    private let repository = TripsRepository()
    private let weatherService = WeatherService()

    var body: some View {
        List {
            if let plan {
                if let weather = plan.weather {
                    weatherSection(weather)
                }
                if plan.wakeUp != nil || plan.leaveBy != nil {
                    scheduleSection(plan)
                }
                timelineSection(plan)
            } else if !isLoading {
                ContentUnavailableView(
                    "Nothing planned today",
                    systemImage: "sun.max",
                    description: Text("Add stops to Day \(day) or ask the trip assistant to plan it.")
                )
            }
        }
        .navigationTitle(dayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if plan?.stops.contains(where: { $0.coordinate != nil }) == true {
                Button {
                    showingRoute = true
                } label: {
                    Image(systemName: "point.topleft.down.to.point.bottomright.curvepath")
                }
            }
        }
        .overlay { if isLoading { ProgressView() } }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingRoute) {
            DayRouteView(trip: trip, day: day, items: plan?.stops ?? [])
        }
    }

    private var dayTitle: String {
        "Day \(day) · \(trip.destination)"
    }

    private func weatherSection(_ weather: DayWeather) -> some View {
        Section("Weather") {
            HStack(spacing: 14) {
                Image(systemName: weather.symbol)
                    .font(.system(size: 34))
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(Int(weather.tempMin.rounded()))° – \(Int(weather.tempMax.rounded()))°C · \(weather.summary.capitalized)")
                        .font(.headline)
                    if let precip = weather.precipProbability, precip >= 20 {
                        Text("\(precip)% chance of rain")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Text("Wear \(weather.wearTip).")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
        }
    }

    private func scheduleSection(_ plan: DayPlan) -> some View {
        Section("Your morning") {
            if let wake = plan.wakeUp {
                Label {
                    Text("Wake up by **\(wake.formatted(date: .omitted, time: .shortened))**")
                } icon: {
                    Image(systemName: "alarm")
                }
            }
            if let leave = plan.leaveBy, let arrival = plan.firstStopArrival, let first = plan.firstTimedStop {
                Label {
                    Text("Leave by **\(leave.formatted(date: .omitted, time: .shortened))** to reach \(first.displayTitle) at \(arrival.formatted(date: .omitted, time: .shortened))")
                } icon: {
                    Image(systemName: "figure.walk.departure")
                }
            } else if let first = plan.firstTimedStop, let arrival = plan.firstStopArrival {
                Label {
                    Text("First stop: \(first.displayTitle) at \(arrival.formatted(date: .omitted, time: .shortened))")
                } icon: {
                    Image(systemName: "clock")
                }
            }
        }
        .font(.subheadline)
    }

    private func timelineSection(_ plan: DayPlan) -> some View {
        Section("Today's plan") {
            ForEach(plan.stops) { stop in
                HStack(alignment: .top, spacing: 10) {
                    Text(stop.timeDisplay ?? "–")
                        .font(.caption.bold().monospacedDigit())
                        .foregroundStyle(.tint)
                        .frame(width: 44, alignment: .leading)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Image(systemName: stop.kind == .save
                                ? (stop.save?.contentType.systemImage ?? "mappin")
                                : stop.kind.systemImage)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(stop.displayTitle)
                                .font(.subheadline)
                                .lineLimit(2)
                        }
                        if let subtitle = stop.subtitle {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        if let note = stop.note, !note.isEmpty {
                            Text(note)
                                .font(.caption2)
                                .foregroundStyle(.tint)
                        }
                    }
                }
            }
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let date = trip.date(forDay: day) else { return }
        let items = (try? await repository.fetchItems(tripId: trip.id)) ?? []
        let stops = BriefingPlanner.sortedStops(items.filter { $0.dayIndex == day })
        guard !stops.isEmpty else {
            plan = nil
            return
        }

        var weather: DayWeather?
        if let coordinate = (stops.compactMap(\.coordinate).first ?? items.compactMap(\.coordinate).first) {
            let forecast = (try? await weatherService.dailyForecast(
                latitude: coordinate.latitude,
                longitude: coordinate.longitude,
                start: date,
                end: date
            )) ?? [:]
            weather = forecast[Trip.dayFormatter.string(from: date)]
        }

        let travel = await BriefingPlanner.travelTime(
            from: BriefingPlanner.hotel(in: items),
            to: stops.first { $0.timeComponents != nil }
        )
        plan = DayPlan(trip: trip, day: day, date: date, stops: stops, weather: weather, travelTime: travel)
    }
}
