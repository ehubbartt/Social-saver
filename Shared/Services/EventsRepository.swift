import Foundation
import Supabase

enum RSVP: String, Codable, CaseIterable {
    case invited
    case going
    case maybe
    case declined

    var label: String {
        switch self {
        case .invited: return "Invited"
        case .going: return "Going"
        case .maybe: return "Maybe"
        case .declined: return "Can't go"
        }
    }

    var systemImage: String {
        switch self {
        case .invited: return "envelope"
        case .going: return "checkmark.circle.fill"
        case .maybe: return "questionmark.circle.fill"
        case .declined: return "xmark.circle.fill"
        }
    }
}

struct Event: Codable, Identifiable, Hashable {
    let id: UUID
    let ownerId: UUID
    let title: String
    let emoji: String?
    let eventDate: String
    let startTime: String?
    let note: String?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case title
        case emoji
        case eventDate = "event_date"
        case startTime = "start_time"
        case note
        case createdAt = "created_at"
    }

    var dateValue: Date? { Trip.dayFormatter.date(from: eventDate) }

    var timeDisplay: String? {
        guard let startTime else { return nil }
        return String(startTime.prefix(5))
    }

    var whenText: String {
        let day = dateValue?.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()) ?? eventDate
        if let time = timeDisplay { return "\(day) · \(time)" }
        return day
    }
}

struct EventStop: Codable, Identifiable, Hashable {
    let id: UUID
    let title: String?
    let startTime: String?
    let position: Int
    let save: Save?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case startTime = "start_time"
        case position
        case save
    }

    var displayTitle: String { title ?? save?.title ?? save?.sourceUrl ?? "Stop" }
    var place: Place? { save?.places.first }
    var timeDisplay: String? { startTime.map { String($0.prefix(5)) } }
}

struct EventGuest: Codable, Identifiable, Hashable {
    let userId: UUID
    let status: RSVP
    let profile: FriendProfile?

    var id: UUID { userId }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case status
        case profile
    }
}

struct EventsRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    func isOwner(_ event: Event) -> Bool {
        event.ownerId == SupabaseClientProvider.currentUserId
    }

    func events() async throws -> [Event] {
        try await client
            .from("events")
            .select()
            .order("event_date", ascending: true)
            .execute()
            .value
    }

    func createEvent(title: String, emoji: String?, date: Date, time: Date?, note: String?) async throws -> Event {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        struct NewEvent: Encodable {
            let owner_id: UUID
            let title: String
            let emoji: String?
            let event_date: String
            let start_time: String?
            let note: String?
        }
        return try await client.from("events")
            .insert(NewEvent(
                owner_id: me,
                title: title,
                emoji: emoji,
                event_date: Trip.dayFormatter.string(from: date),
                start_time: time.map { TripsRepository.timeFormatter.string(from: $0) },
                note: note
            ))
            .select()
            .single()
            .execute()
            .value
    }

    func deleteEvent(id: UUID) async throws {
        try await client.from("events").delete().eq("id", value: id).execute()
    }

    func stops(eventId: UUID) async throws -> [EventStop] {
        try await client
            .from("event_stops")
            .select("*, save:saves(*, save_places(place:places(*)), save_links(*))")
            .eq("event_id", value: eventId)
            .order("position", ascending: true)
            .order("start_time", ascending: true)
            .execute()
            .value
    }

    func addStops(eventId: UUID, saveIds: [UUID]) async throws {
        guard !saveIds.isEmpty else { return }
        struct NewStop: Encodable {
            let event_id: UUID
            let save_id: UUID
        }
        try await client.from("event_stops")
            .insert(saveIds.map { NewStop(event_id: eventId, save_id: $0) })
            .execute()
    }

    func addCustomStop(eventId: UUID, title: String, time: Date?) async throws {
        struct NewStop: Encodable {
            let event_id: UUID
            let title: String
            let start_time: String?
        }
        try await client.from("event_stops")
            .insert(NewStop(
                event_id: eventId,
                title: title,
                start_time: time.map { TripsRepository.timeFormatter.string(from: $0) }
            ))
            .execute()
    }

    func removeStop(id: UUID) async throws {
        try await client.from("event_stops").delete().eq("id", value: id).execute()
    }

    func guests(eventId: UUID) async throws -> [EventGuest] {
        try await client
            .from("event_guests")
            .select("user_id, status, profile:profiles(id, username, sharing_paused)")
            .eq("event_id", value: eventId)
            .execute()
            .value
    }

    func invite(eventId: UUID, userId: UUID) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        struct NewGuest: Encodable {
            let event_id: UUID
            let user_id: UUID
            let invited_by: UUID
        }
        try await client.from("event_guests")
            .upsert(NewGuest(event_id: eventId, user_id: userId, invited_by: me), onConflict: "event_id,user_id")
            .execute()
    }

    func setRSVP(eventId: UUID, status: RSVP) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        try await client.from("event_guests")
            .update(["status": status.rawValue])
            .eq("event_id", value: eventId)
            .eq("user_id", value: me)
            .execute()
    }

    func removeGuest(eventId: UUID, userId: UUID) async throws {
        try await client.from("event_guests")
            .delete()
            .eq("event_id", value: eventId)
            .eq("user_id", value: userId)
            .execute()
    }
}
