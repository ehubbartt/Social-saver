import Foundation
import Supabase

struct FriendProfile: Codable, Identifiable, Hashable {
    let id: UUID
    let username: String?
    let sharingPaused: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case sharingPaused = "sharing_paused"
    }
}

struct MyProfile: Codable {
    let id: UUID
    let username: String?
    let sharingPaused: Bool

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case sharingPaused = "sharing_paused"
    }
}

struct Friendship: Codable, Identifiable, Hashable {
    let id: UUID
    let requester: UUID
    let addressee: UUID
    let status: String
    let createdAt: Date
    let requesterProfile: FriendProfile?
    let addresseeProfile: FriendProfile?

    enum CodingKeys: String, CodingKey {
        case id
        case requester
        case addressee
        case status
        case createdAt = "created_at"
        case requesterProfile = "requester_profile"
        case addresseeProfile = "addressee_profile"
    }

    var isAccepted: Bool { status == "accepted" }

    func otherId(than me: UUID) -> UUID {
        requester == me ? addressee : requester
    }

    func otherProfile(than me: UUID) -> FriendProfile? {
        requester == me ? addresseeProfile : requesterProfile
    }
}

struct FriendsRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    private static let columns =
        "*, requester_profile:profiles!requester(id, username, sharing_paused), addressee_profile:profiles!addressee(id, username, sharing_paused)"

    func myProfile() async throws -> MyProfile {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        return try await client
            .from("profiles")
            .select("id, username, sharing_paused")
            .eq("id", value: me)
            .single()
            .execute()
            .value
    }

    func claimUsername(_ username: String) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        try await client.from("profiles")
            .update(["username": username])
            .eq("id", value: me)
            .execute()
    }

    func setSharingPaused(_ paused: Bool) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        try await client.from("profiles")
            .update(["sharing_paused": paused])
            .eq("id", value: me)
            .execute()
    }

    /// Exact-match discovery only; no browse or substring search by design.
    func lookup(username: String) async throws -> FriendProfile? {
        let results: [FriendProfile] = try await client
            .rpc("lookup_username", params: ["p_username": username])
            .execute()
            .value
        return results.first
    }

    func friendships() async throws -> [Friendship] {
        try await client
            .from("friendships")
            .select(Self.columns)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func sendRequest(to userId: UUID) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        struct NewFriendship: Encodable {
            let requester: UUID
            let addressee: UUID
        }
        try await client.from("friendships")
            .insert(NewFriendship(requester: me, addressee: userId))
            .execute()
    }

    func accept(_ friendshipId: UUID) async throws {
        try await client.from("friendships")
            .update([
                "status": AnyJSON.string("accepted"),
                "responded_at": AnyJSON.string(ISO8601DateFormatter().string(from: .now)),
            ])
            .eq("id", value: friendshipId)
            .execute()
    }

    /// Cancels a pending request, declines one, or unfriends.
    func remove(_ friendshipId: UUID) async throws {
        try await client.from("friendships")
            .delete()
            .eq("id", value: friendshipId)
            .execute()
    }
}

// MARK: - Feed

struct FeedEvent: Codable, Identifiable, Hashable {
    let id: UUID
    let actorId: UUID
    let kind: String // "recommended_save" | "shared_list"
    let createdAt: Date
    let actor: FriendProfile?
    let save: Save?
    let list: SavedList?

    enum CodingKeys: String, CodingKey {
        case id
        case actorId = "actor_id"
        case kind
        case createdAt = "created_at"
        case actor
        case save
        case list
    }
}

struct FriendReview: Codable, Identifiable, Hashable {
    let id: UUID
    let userId: UUID
    let rating: Int
    let worthIt: Bool
    let body: String?
    let createdAt: Date
    let place: Place

    enum CodingKeys: String, CodingKey {
        case id
        case userId = "user_id"
        case rating
        case worthIt = "worth_it"
        case body
        case createdAt = "created_at"
        case place
    }
}

struct FeedRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    private static let eventColumns =
        "*, actor:profiles(id, username, sharing_paused), save:saves(*, save_places(place:places(*)), save_links(*)), list:lists(*)"

    func events(limit: Int = 60) async throws -> [FeedEvent] {
        try await client
            .from("feed_events")
            .select(Self.eventColumns)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }

    func myEvents() async throws -> [FeedEvent] {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        return try await client
            .from("feed_events")
            .select(Self.eventColumns)
            .eq("actor_id", value: me)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func isRecommended(saveId: UUID) async throws -> Bool {
        guard let me = SupabaseClientProvider.currentUserId else { return false }
        let rows: [FeedEvent] = try await client
            .from("feed_events")
            .select("id, actor_id, kind, created_at")
            .eq("actor_id", value: me)
            .eq("save_id", value: saveId)
            .execute()
            .value
        return !rows.isEmpty
    }

    func recommend(saveId: UUID) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        struct NewEvent: Encodable {
            let actor_id: UUID
            let kind: String
            let save_id: UUID
        }
        try await client.from("feed_events")
            .insert(NewEvent(actor_id: me, kind: "recommended_save", save_id: saveId))
            .execute()
    }

    func unrecommend(saveId: UUID) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { return }
        try await client.from("feed_events")
            .delete()
            .eq("actor_id", value: me)
            .eq("save_id", value: saveId)
            .execute()
    }

    func deleteEvent(id: UUID) async throws {
        try await client.from("feed_events").delete().eq("id", value: id).execute()
    }

    /// Flipping a list to friends-visible publishes it; back to private
    /// retracts the feed event so publish state stays coherent.
    func setListVisibility(list: SavedList, friendsVisible: Bool) async throws {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        try await client.from("lists")
            .update(["visibility": friendsVisible ? "friends" : "private"])
            .eq("id", value: list.id)
            .execute()

        if friendsVisible {
            let existing: [FeedEvent] = try await client
                .from("feed_events")
                .select("id, actor_id, kind, created_at")
                .eq("actor_id", value: me)
                .eq("list_id", value: list.id)
                .execute()
                .value
            if existing.isEmpty {
                struct NewEvent: Encodable {
                    let actor_id: UUID
                    let kind: String
                    let list_id: UUID
                }
                try await client.from("feed_events")
                    .insert(NewEvent(actor_id: me, kind: "shared_list", list_id: list.id))
                    .execute()
            }
        } else {
            try await client.from("feed_events")
                .delete()
                .eq("actor_id", value: me)
                .eq("list_id", value: list.id)
                .execute()
        }
    }

    func friendReviews(friendIds: [UUID], limit: Int = 30) async throws -> [FriendReview] {
        guard !friendIds.isEmpty else { return [] }
        return try await client
            .from("place_reviews")
            .select("id, user_id, rating, worth_it, body, created_at, place:places(*)")
            .in("user_id", values: friendIds)
            .order("created_at", ascending: false)
            .limit(limit)
            .execute()
            .value
    }
}
