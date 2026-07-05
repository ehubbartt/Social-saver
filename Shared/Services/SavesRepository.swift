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

    func deleteList(id: UUID) async throws {
        try await client.from("lists").delete().eq("id", value: id).execute()
    }
}
