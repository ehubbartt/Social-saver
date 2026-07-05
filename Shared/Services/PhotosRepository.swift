import Foundation
import Supabase

struct TripPhoto: Codable, Identifiable, Hashable {
    let id: UUID
    let ownerId: UUID
    let storagePath: String
    let placeId: UUID?
    let tripId: UUID?
    let takenAt: Date?
    let createdAt: Date

    enum CodingKeys: String, CodingKey {
        case id
        case ownerId = "owner_id"
        case storagePath = "storage_path"
        case placeId = "place_id"
        case tripId = "trip_id"
        case takenAt = "taken_at"
        case createdAt = "created_at"
    }
}

struct PhotosRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }
    private let bucket = "trip-photos"

    func photos(placeId: UUID) async throws -> [TripPhoto] {
        try await client
            .from("photos")
            .select()
            .eq("place_id", value: placeId)
            .order("taken_at", ascending: true)
            .execute()
            .value
    }

    func photos(tripId: UUID) async throws -> [TripPhoto] {
        try await client
            .from("photos")
            .select()
            .eq("trip_id", value: tripId)
            .order("taken_at", ascending: true)
            .execute()
            .value
    }

    /// Uploads a stripped JPEG and records the photo row. Returns the row.
    @discardableResult
    func upload(
        jpeg: Data,
        placeId: UUID?,
        tripId: UUID?,
        takenAt: Date?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> TripPhoto {
        guard let me = SupabaseClientProvider.currentUserId else { throw AuthError.sessionMissing }
        let path = "\(me.uuidString.lowercased())/\(UUID().uuidString.lowercased()).jpg"

        try await client.storage
            .from(bucket)
            .upload(path: path, file: jpeg, options: FileOptions(contentType: "image/jpeg"))

        struct NewPhoto: Encodable {
            let owner_id: UUID
            let storage_path: String
            let place_id: UUID?
            let trip_id: UUID?
            let taken_at: String?
            let latitude: Double?
            let longitude: Double?
        }
        return try await client.from("photos")
            .insert(NewPhoto(
                owner_id: me,
                storage_path: path,
                place_id: placeId,
                trip_id: tripId,
                taken_at: takenAt.map { ISO8601DateFormatter().string(from: $0) },
                latitude: latitude,
                longitude: longitude
            ))
            .select()
            .single()
            .execute()
            .value
    }

    func delete(_ photo: TripPhoto) async throws {
        try await client.from("photos").delete().eq("id", value: photo.id).execute()
        try? await client.storage.from(bucket).remove(paths: [photo.storagePath])
    }

    /// Batch-resolves signed download URLs for photos the caller may view.
    func signedURLs(for photoIds: [UUID]) async throws -> [UUID: URL] {
        guard !photoIds.isEmpty else { return [:] }
        struct Response: Codable { let urls: [String: String] }
        let response: Response = try await client.functions.invoke(
            "get-photo-url",
            options: FunctionInvokeOptions(body: ["photo_ids": photoIds.map(\.uuidString)])
        )
        var result: [UUID: URL] = [:]
        for (key, value) in response.urls {
            if let id = UUID(uuidString: key), let url = URL(string: value) {
                result[id] = url
            }
        }
        return result
    }
}
