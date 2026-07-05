import SwiftUI

/// Friend management: find people by exact username, handle requests, and
/// see who you're connected with.
struct FriendsView: View {
    @State private var friendships: [Friendship] = []
    @State private var myUsername: String?
    @State private var searchText = ""
    @State private var searchResult: FriendProfile?
    @State private var searchMessage: String?
    @State private var isSearching = false

    private let repository = FriendsRepository()
    private var me: UUID? { SupabaseClientProvider.currentUserId }

    private var incoming: [Friendship] {
        friendships.filter { $0.status == "pending" && $0.addressee == me }
    }

    private var outgoing: [Friendship] {
        friendships.filter { $0.status == "pending" && $0.requester == me }
    }

    private var accepted: [Friendship] {
        friendships.filter(\.isAccepted)
    }

    var body: some View {
        List {
            if myUsername == nil {
                Section {
                    Label("Claim a username in Profile so friends can find you.", systemImage: "at")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                HStack {
                    TextField("Find by exact username", text: $searchText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Search") {
                        Task { await search() }
                    }
                    .disabled(searchText.trimmingCharacters(in: .whitespaces).isEmpty || isSearching)
                }
                if let searchResult {
                    HStack {
                        Text("@\(searchResult.username ?? "")")
                        Spacer()
                        Button("Add") {
                            Task { await sendRequest(to: searchResult.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
                }
                if let searchMessage {
                    Text(searchMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Add a friend")
            } footer: {
                Text("Search matches exact usernames only.")
            }

            if !incoming.isEmpty {
                Section("Requests") {
                    ForEach(incoming) { friendship in
                        HStack {
                            Text("@\(friendship.requesterProfile?.username ?? "someone")")
                            Spacer()
                            Button("Accept") {
                                Task { await accept(friendship) }
                            }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.small)
                            Button("Decline", role: .destructive) {
                                Task { await remove(friendship) }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        }
                    }
                }
            }

            if !outgoing.isEmpty {
                Section("Sent") {
                    ForEach(outgoing) { friendship in
                        HStack {
                            Text("@\(friendship.addresseeProfile?.username ?? "someone")")
                            Spacer()
                            Button("Cancel") {
                                Task { await remove(friendship) }
                            }
                            .font(.footnote)
                        }
                    }
                }
            }

            Section("Friends (\(accepted.count))") {
                if accepted.isEmpty {
                    Text("No friends yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(accepted) { friendship in
                    Text("@\(me.flatMap { friendship.otherProfile(than: $0)?.username } ?? "friend")")
                        .swipeActions {
                            Button("Unfriend", role: .destructive) {
                                Task { await remove(friendship) }
                            }
                        }
                }
            }
        }
        .navigationTitle("Friends")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        friendships = (try? await repository.friendships()) ?? friendships
        myUsername = (try? await repository.myProfile())?.username
    }

    private func search() async {
        isSearching = true
        defer { isSearching = false }
        searchResult = nil
        searchMessage = nil
        let query = searchText.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
        do {
            if let result = try await repository.lookup(username: query) {
                if result.id == me {
                    searchMessage = "That's you!"
                } else {
                    searchResult = result
                }
            } else {
                searchMessage = "No one with that exact username."
            }
        } catch {
            searchMessage = "Search failed. Try again."
        }
    }

    private func sendRequest(to userId: UUID) async {
        do {
            try await repository.sendRequest(to: userId)
            searchResult = nil
            searchMessage = "Request sent!"
            await load()
        } catch {
            searchMessage = "Couldn't send — maybe you're already connected."
        }
    }

    private func accept(_ friendship: Friendship) async {
        try? await repository.accept(friendship.id)
        await load()
    }

    private func remove(_ friendship: Friendship) async {
        try? await repository.remove(friendship.id)
        await load()
    }
}
