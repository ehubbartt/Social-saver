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
}

struct PlanTripResponse: Codable {
    let planned: Int
    let summary: String
}
