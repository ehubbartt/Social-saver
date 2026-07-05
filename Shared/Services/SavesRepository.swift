import Foundation
import Supabase

struct SavesRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    private static let saveColumns = "*, save_places(place:places(*)), save_links(*)"

    func fetchSaves() async throws -> [Save] {
        try await client
            .from("saves")
            .select(Self.saveColumns)
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchSave(id: UUID) async throws -> Save {
        try await client
            .from("saves")
            .select(Self.saveColumns)
            .eq("id", value: id)
            .single()
            .execute()
            .value
    }

    func delete(id: UUID) async throws {
        try await client.from("saves").delete().eq("id", value: id).execute()
    }

    /// Manual corrections: the AI pipeline can get titles, summaries, and
    /// categories wrong, so everything it writes is user-editable.
    func update(id: UUID, title: String?, summary: String?, note: String?, contentType: ContentType) async throws {
        struct Payload: Encodable {
            let title: String?
            let summary: String?
            let note: String?
            let content_type: String
        }
        try await client.from("saves")
            .update(Payload(title: title, summary: summary, note: note, content_type: contentType.rawValue))
            .eq("id", value: id)
            .execute()
    }

    func removePlace(_ placeId: UUID, from saveId: UUID) async throws {
        try await client.from("save_places")
            .delete()
            .eq("save_id", value: saveId)
            .eq("place_id", value: placeId)
            .execute()
    }

    /// Links a manually chosen place to a save, optionally replacing a wrong
    /// one. A new canonical place row is upserted rather than mutating the
    /// old row, since place rows are shared across saves.
    @discardableResult
    func setPlace(
        on saveId: UUID,
        replacing oldPlaceId: UUID?,
        name: String,
        address: String?,
        city: String?,
        country: String?,
        latitude: Double?,
        longitude: Double?
    ) async throws -> Place {
        struct NewPlace: Encodable {
            let name: String
            let address: String?
            let city: String
            let country: String
            let latitude: Double?
            let longitude: Double?
        }
        let place: Place = try await client.from("places")
            .upsert(
                NewPlace(
                    name: name,
                    address: address,
                    city: city ?? "",
                    country: country ?? "",
                    latitude: latitude,
                    longitude: longitude
                ),
                onConflict: "name,city,country"
            )
            .select()
            .single()
            .execute()
            .value

        if let oldPlaceId {
            try await removePlace(oldPlaceId, from: saveId)
        }

        struct Link: Encodable {
            let save_id: UUID
            let place_id: UUID
        }
        try await client.from("save_places")
            .upsert(Link(save_id: saveId, place_id: place.id))
            .execute()
        return place
    }

    /// Conversational recommendations over the user's own saves.
    func ask(question: String) async throws -> AskResponse {
        try await client.functions.invoke(
            "ask-saves",
            options: FunctionInvokeOptions(body: ["question": question])
        )
    }

    /// Kicks off the ingest pipeline: the edge function creates the row,
    /// resolves the link's metadata, classifies it, extracts places, geocodes
    /// them, and files the save into the best-matching list.
    func ingest(url: String) async throws {
        try await client.functions.invoke(
            "process-save",
            options: FunctionInvokeOptions(body: ["url": url])
        )
    }
}

struct ListsRepository {
    private var client: SupabaseClient { SupabaseClientProvider.shared }

    func fetchLists() async throws -> [SavedList] {
        try await client
            .from("lists")
            .select()
            .order("created_at", ascending: false)
            .execute()
            .value
    }

    func fetchItems(listId: UUID) async throws -> [Save] {
        let joins: [ListItemJoin] = try await client
            .from("list_items")
            .select("save:saves(*, save_places(place:places(*)), save_links(*))")
            .eq("list_id", value: listId)
            .execute()
            .value
        return joins.map(\.save)
    }

    func createList(name: String, emoji: String?) async throws {
        struct NewList: Encodable {
            let name: String
            let emoji: String?
            let user_id: UUID
        }
        guard let userId = SupabaseClientProvider.shared.auth.currentSession?.user.id else {
            throw AuthError.sessionMissing
        }
        try await client.from("lists")
            .insert(NewList(name: name, emoji: emoji, user_id: userId))
            .execute()
    }

    func addSave(_ saveId: UUID, to listId: UUID) async throws {
        struct NewItem: Encodable {
            let list_id: UUID
            let save_id: UUID
        }
        try await client.from("list_items")
            .upsert(NewItem(list_id: listId, save_id: saveId))
            .execute()
    }

    func removeSave(_ saveId: UUID, from listId: UUID) async throws {
        try await client.from("list_items")
            .delete()
            .eq("list_id", value: listId)
            .eq("save_id", value: saveId)
            .execute()
    }

    func deleteList(id: UUID) async throws {
        try await client.from("lists").delete().eq("id", value: id).execute()
    }
}

struct AskResponse: Codable {
    let answer: String
    let saveIds: [UUID]

    enum CodingKeys: String, CodingKey {
        case answer
        case saveIds = "save_ids"
    }
}
