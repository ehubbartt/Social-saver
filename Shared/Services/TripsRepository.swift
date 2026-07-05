import Foundation
import Supabase

struct TripsRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    func fetchTrips() async throws -> [Trip] {
        try await client
            .from("trips")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func createTrip(
        name: String,
        destination: String,
        emoji: String?,
        startDate: Date?,
        endDate: Date?
    ) async throws {
        guard let userId = client.auth.currentSession?.user.id else {
            throw AuthError.sessionMissing
        }
        struct NewTrip: Encodable {
            let user_id: UUID
            let name: String
            let destination: String
            let emoji: String?
            let start_date: String?
            let end_date: String?
        }
        try await client.from("trips")
            .insert(NewTrip(
                user_id: userId,
                name: name,
                destination: destination,
                emoji: emoji,
                start_date: startDate.map { Trip.dayFormatter.string(from: $0) },
                end_date: endDate.map { Trip.dayFormatter.string(from: $0) }
            ))
            .execute()
    }

    func deleteTrip(id: UUID) async throws {
        try await client.from("trips").delete().eq("id", value: id).execute()
    }

    func fetchItems(tripId: UUID) async throws -> [TripItem] {
        try await client
            .from("trip_items")
            .select("*, save:saves(*, save_places(place:places(*)), save_links(*))")
            .eq("trip_id", value: tripId)
            .order("day_index", ascending: true)
            .order("position", ascending: true)
            .order("created_at", ascending: true)
            .execute()
            .value
    }

    func addSaves(_ saveIds: [UUID], to tripId: UUID) async throws {
        struct NewItem: Encodable {
            let trip_id: UUID
            let save_id: UUID
        }
        guard !saveIds.isEmpty else { return }
        try await client.from("trip_items")
            .upsert(
                saveIds.map { NewItem(trip_id: tripId, save_id: $0) },
                onConflict: "trip_id,save_id"
            )
            .execute()
    }

    /// Moves an item to a day; nil sends it back to the Ideas bucket.
    func setDay(itemId: UUID, day: Int?) async throws {
        let value: AnyJSON = day.map { AnyJSON.integer($0) } ?? .null
        try await client.from("trip_items")
            .update(["day_index": value])
            .eq("id", value: itemId)
            .execute()
    }

    /// Drag-and-drop support: place an item on a day at a specific position.
    func setPlacement(itemId: UUID, day: Int?, position: Int) async throws {
        let dayValue: AnyJSON = day.map { AnyJSON.integer($0) } ?? .null
        try await client.from("trip_items")
            .update(["day_index": dayValue, "position": AnyJSON.integer(position)])
            .eq("id", value: itemId)
            .execute()
    }

    static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    func setTime(itemId: UUID, time: Date?) async throws {
        let value: AnyJSON = time.map { AnyJSON.string(Self.timeFormatter.string(from: $0)) } ?? .null
        try await client.from("trip_items")
            .update(["start_time": value])
            .eq("id", value: itemId)
            .execute()
    }

    /// Standalone itinerary entries: flights, hotels, transport, custom stops.
    func addCustomItem(
        tripId: UUID,
        kind: TripItemKind,
        title: String,
        detail: String?,
        day: Int?,
        time: Date?,
        latitude: Double?,
        longitude: Double?,
        address: String?
    ) async throws {
        struct NewItem: Encodable {
            let trip_id: UUID
            let kind: String
            let title: String
            let detail: String?
            let day_index: Int?
            let start_time: String?
            let latitude: Double?
            let longitude: Double?
            let address: String?
        }
        try await client.from("trip_items")
            .insert(NewItem(
                trip_id: tripId,
                kind: kind.rawValue,
                title: title,
                detail: detail,
                day_index: day,
                start_time: time.map { Self.timeFormatter.string(from: $0) },
                latitude: latitude,
                longitude: longitude,
                address: address
            ))
            .execute()
    }

    func removeItem(id: UUID) async throws {
        try await client.from("trip_items").delete().eq("id", value: id).execute()
    }

    /// Asks the backend to draft the itinerary from the user's saved videos.
    func autoPlan(tripId: UUID) async throws -> PlanTripResponse {
        try await client.functions.invoke(
            "plan-trip",
            options: FunctionInvokeOptions(body: ["trip_id": tripId.uuidString])
        )
    }

    /// One turn of the trip agent conversation. The full transcript is sent
    /// each time; the server is stateless.
    func chat(tripId: UUID, messages: [TripChatTurn]) async throws -> TripChatResponse {
        struct Body: Encodable {
            let trip_id: String
            let messages: [TripChatTurn]
        }
        return try await client.functions.invoke(
            "trip-agent",
            options: FunctionInvokeOptions(body: Body(trip_id: tripId.uuidString, messages: messages))
        )
    }
}

struct TripChatTurn: Codable {
    let role: String
    let content: String
}

struct TripChatResponse: Codable {
    let reply: String
    let changed: Bool
}

struct PlanTripResponse: Codable {
    let planned: Int
    let summary: String
}

struct TripMember: Codable, Identifiable, Hashable {
    let userId: UUID
    let role: String
    let profile: FriendProfile?

    var id: UUID { userId }
    var isEditor: Bool { role == "editor" }

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case role
        case profile
    }
}

extension TripsRepository {
    /// Trips grow member access via RLS, so distinguish mine from shared.
    func isOwner(_ trip: Trip) -> Bool {
        trip.userId == SupabaseClientProvider.currentUserId
    }

    func members(tripId: UUID) async throws -> [TripMember] {
        try await client
            .from("trip_members")
            .select("user_id, role, profile:profiles(id, username, sharing_paused)")
            .eq("trip_id", value: tripId)
            .execute()
            .value
    }

    func addMember(tripId: UUID, userId: UUID, role: String) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        struct NewMember: Encodable {
            let trip_id: UUID
            let user_id: UUID
            let role: String
            let invited_by: UUID
        }
        try await client.from("trip_members")
            .upsert(NewMember(trip_id: tripId, user_id: userId, role: role, invited_by: me), onConflict: "trip_id,user_id")
            .execute()
    }

    func setMemberRole(tripId: UUID, userId: UUID, role: String) async throws {
        try await client.from("trip_members")
            .update(["role": role])
            .eq("trip_id", value: tripId)
            .eq("user_id", value: userId)
            .execute()
    }

    func removeMember(tripId: UUID, userId: UUID) async throws {
        try await client.from("trip_members")
            .delete()
            .eq("trip_id", value: tripId)
            .eq("user_id", value: userId)
            .execute()
    }

    func leaveTrip(tripId: UUID) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        try await removeMember(tripId: tripId, userId: me)
    }
}
