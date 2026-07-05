import Foundation
import Supabase

struct ReviewsRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    var currentUserId: UUID? {
        client.auth.currentSession?.user.id
    }

    func fetchReviews(placeId: UUID) async throws -> [PlaceReview] {
        try await client
            .from("place_reviews")
            .select()
            .eq("place_id", value: placeId)
            .order("created_at", ascending: false)
            .limit(50)
            .execute()
            .value
    }

    func upsertReview(placeId: UUID, rating: Int, worthIt: Bool, body: String?) async throws {
        guard let userId = currentUserId else { throw AuthError.sessionMissing }
        struct Payload: Encodable {
            let place_id: UUID
            let user_id: UUID
            let rating: Int
            let worth_it: Bool
            let body: String?
        }
        try await client
            .from("place_reviews")
            .upsert(
                Payload(place_id: placeId, user_id: userId, rating: rating, worth_it: worthIt, body: body),
                onConflict: "place_id,user_id"
            )
            .execute()
    }

    /// Deletes the caller's own review — RLS confines the delete to it.
    func deleteReview(placeId: UUID) async throws {
        try await client
            .from("place_reviews")
            .delete()
            .eq("place_id", value: placeId)
            .execute()
    }
}
