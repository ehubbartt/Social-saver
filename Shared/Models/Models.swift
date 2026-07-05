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
