import Foundation
import CoreLocation

enum AuthError: Error {
    case sessionMissing
}

enum ContentType: String, Codable, CaseIterable, Identifiable {
    case place
    case restaurant
    case recipe
    case activity
    case shopping
    case event
    case other

    var id: String { rawValue }

    var label: String {
        switch self {
        case .place: return "Places"
        case .restaurant: return "Food & Drink"
        case .recipe: return "Recipes"
        case .activity: return "Activities"
        case .shopping: return "Shopping"
        case .event: return "Events"
        case .other: return "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .place: return "mappin.and.ellipse"
        case .restaurant: return "fork.knife"
        case .recipe: return "book"
        case .activity: return "figure.hiking"
        case .shopping: return "bag"
        case .event: return "calendar"
        case .other: return "square.grid.2x2"
        }
    }
}

enum SaveStatus: String, Codable {
    case pending
    case processed
    case failed
}

struct Place: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
    let address: String?
    let city: String?
    let country: String?
    let latitude: Double?
    let longitude: Double?
    let website: String?
    let phone: String?

    // City/country are stored as '' rather than NULL (see 0004 migration),
    // so filter empties before joining.
    var subtitle: String {
        [city, country]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
            .joined(separator: ", ")
    }

    var websiteURL: URL? {
        website.flatMap { URL(string: $0) }
    }

    var phoneURL: URL? {
        guard let phone else { return nil }
        let digits = phone.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel:\(digits)")
    }
}

enum LinkKind: String, Codable {
    case app
    case product
    case booking
    case social
    case website
    case other

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = LinkKind(rawValue: raw) ?? .other
    }

    var systemImage: String {
        switch self {
        case .app: return "apps.iphone"
        case .product: return "tag"
        case .booking: return "calendar.badge.checkmark"
        case .social: return "at"
        case .website: return "globe"
        case .other: return "link"
        }
    }
}

struct SaveLink: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String
    let url: String
    let kind: LinkKind
    let note: String?
}

struct Recipe: Codable, Hashable {
    let ingredients: [String]
    let steps: [String]
}

struct Save: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let sourceUrl: String
    let sourcePlatform: String
    let title: String?
    let summary: String?
    let thumbnailUrl: String?
    let authorName: String?
    let contentType: ContentType
    let status: SaveStatus
    let recipe: Recipe?
    let note: String?
    let createdAt: Date
    let savePlaces: [SavePlaceJoin]?
    let saveLinks: [SaveLink]?

    var places: [Place] { savePlaces?.map(\.place) ?? [] }
    var links: [SaveLink] { saveLinks ?? [] }

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case sourceUrl = "source_url"
        case sourcePlatform = "source_platform"
        case title
        case summary
        case thumbnailUrl = "thumbnail_url"
        case authorName = "author_name"
        case contentType = "content_type"
        case status
        case recipe
        case note
        case createdAt = "created_at"
        case savePlaces = "save_places"
        case saveLinks = "save_links"
    }
}

struct SavePlaceJoin: Codable, Hashable {
    let place: Place
}

struct SavedList: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let name: String
    let emoji: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case emoji
        case createdAt = "created_at"
    }
}

struct ListItemJoin: Codable, Hashable {
    let save: Save
}

struct Trip: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let name: String
    let destination: String
    let emoji: String?
    // Postgres `date` columns arrive as "yyyy-MM-dd" strings; parsed lazily
    // rather than relying on the client's timestamp decoding strategy.
    let startDate: String?
    let endDate: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case name
        case destination
        case emoji
        case startDate = "start_date"
        case endDate = "end_date"
        case createdAt = "created_at"
    }

    static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter
    }()

    var startDateValue: Date? { startDate.flatMap { Self.dayFormatter.date(from: $0) } }
    var endDateValue: Date? { endDate.flatMap { Self.dayFormatter.date(from: $0) } }

    /// Number of itinerary days; defaults to 3 when no dates are set.
    var dayCount: Int {
        guard let start = startDateValue, let end = endDateValue else { return 3 }
        let days = Calendar.current.dateComponents([.day], from: start, to: end).day ?? 0
        return min(max(days + 1, 1), 14)
    }

    func date(forDay day: Int) -> Date? {
        guard let start = startDateValue else { return nil }
        return Calendar.current.date(byAdding: .day, value: day - 1, to: start)
    }

    var daysUntilStart: Int? {
        guard let start = startDateValue else { return nil }
        let days = Calendar.current.dateComponents(
            [.day],
            from: Calendar.current.startOfDay(for: .now),
            to: start
        ).day
        return days.flatMap { $0 >= 0 ? $0 : nil }
    }
}

enum TripItemKind: String, Codable {
    case save
    case flight
    case hotel
    case transport
    case custom

    init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        self = TripItemKind(rawValue: raw) ?? .custom
    }

    var systemImage: String {
        switch self {
        case .save: return "play.rectangle"
        case .flight: return "airplane"
        case .hotel: return "bed.double"
        case .transport: return "tram"
        case .custom: return "mappin"
        }
    }

    var label: String {
        switch self {
        case .save: return "Save"
        case .flight: return "Flight"
        case .hotel: return "Hotel"
        case .transport: return "Transport"
        case .custom: return "Stop"
        }
    }
}

struct TripItem: Codable, Identifiable, Hashable {
    let id: UUID
    let tripId: UUID
    let dayIndex: Int?
    let position: Int
    let note: String?
    let kind: TripItemKind
    let title: String?
    let detail: String?
    /// Postgres `time` as "HH:mm:ss".
    let startTime: String?
    let latitude: Double?
    let longitude: Double?
    let address: String?
    let save: Save?

    enum CodingKeys: String, CodingKey {
        case id
        case tripId = "trip_id"
        case dayIndex = "day_index"
        case position
        case note
        case kind
        case title
        case detail
        case startTime = "start_time"
        case latitude
        case longitude
        case address
        case save
    }

    var displayTitle: String {
        title ?? save?.title ?? save?.sourceUrl ?? "Stop"
    }

    var subtitle: String? {
        if let place = save?.places.first { return place.name }
        if let address, !address.isEmpty { return address }
        if let detail, !detail.isEmpty { return detail }
        return nil
    }

    /// Own location for custom entries, else the save's first mapped place.
    var coordinate: CLLocationCoordinate2D? {
        if let latitude, let longitude {
            return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
        }
        if let place = save?.places.first(where: { $0.latitude != nil && $0.longitude != nil }) {
            return CLLocationCoordinate2D(latitude: place.latitude ?? 0, longitude: place.longitude ?? 0)
        }
        return nil
    }

    var timeComponents: (hour: Int, minute: Int)? {
        guard let startTime else { return nil }
        let parts = startTime.split(separator: ":").compactMap { Int($0) }
        guard parts.count >= 2 else { return nil }
        return (parts[0], parts[1])
    }

    var timeDisplay: String? {
        guard let (hour, minute) = timeComponents else { return nil }
        return String(format: "%02d:%02d", hour, minute)
    }
}
