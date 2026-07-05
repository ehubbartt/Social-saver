import Foundation

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

    var subtitle: String {
        [city, country].compactMap { $0 }.joined(separator: ", ")
    }
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
    let createdAt: Date
    let savePlaces: [SavePlaceJoin]?

    var places: [Place] { savePlaces?.map(\.place) ?? [] }

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
        case createdAt = "created_at"
        case savePlaces = "save_places"
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
