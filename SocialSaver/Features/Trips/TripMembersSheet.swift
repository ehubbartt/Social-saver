import SwiftUI

/// Manage who's on a trip: invite accepted friends, set viewer/editor, remove.
/// Members (non-owners) see a read-only roster and a Leave button.
struct TripMembersSheet: View {
    @Environment(\.dismiss) private var dismiss

    let trip: Trip
    let isOwner: Bool
    let onChanged: () async -> Void

    @State private var members: [TripMember] = []
    @State private var friends: [FriendProfile] = []
    @State private var errorMessage: String?

    private let tripsRepository = TripsRepository()
    private let friendsRepository = FriendsRepository()
    private var me: UUID? { SupabaseClientProvider.currentUserId }

    private var invitableFriends: [FriendProfile] {
        let memberIds = Set(members.map(\.userId))
        return friends.filter { !memberIds.contains($0.id) }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("On this trip") {
                    HStack {
                        Image(systemName: "crown.fill").foregroundStyle(.yellow)
                        Text(isOwner ? "You (organizer)" : "Organizer")
                    }
                    ForEach(members) { member in
                        memberRow(member)
                    }
                    if members.isEmpty {
                        Text("Just you so far.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }

                if isOwner {
                    Section {
                        if invitableFriends.isEmpty {
                            Text("Add friends first, or everyone's already invited.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        ForEach(invitableFriends) { friend in
                            Button {
                                Task { await invite(friend) }
                            } label: {
                                Label("@\(friend.username ?? "friend")", systemImage: "plus.circle")
                            }
                        }
                    } header: {
                        Text("Invite friends")
                    } footer: {
                        Text("Invited friends can see the trip. Make someone an editor to let them change the plan.")
                    }
                } else {
                    Section {
                        Button("Leave trip", role: .destructive) {
                            Task { await leave() }
                        }
                    }
                }

                if let errorMessage {
                    Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Members")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func memberRow(_ member: TripMember) -> some View {
        HStack {
            Text("@\(member.profile?.username ?? "friend")")
            Spacer()
            if isOwner {
                Menu {
                    Button {
                        Task { await setRole(member, role: "viewer") }
                    } label: {
                        Label("Viewer", systemImage: member.isEditor ? "" : "checkmark")
                    }
                    Button {
                        Task { await setRole(member, role: "editor") }
                    } label: {
                        Label("Editor", systemImage: member.isEditor ? "checkmark" : "")
                    }
                    Divider()
                    Button(role: .destructive) {
                        Task { await remove(member) }
                    } label: {
                        Label("Remove", systemImage: "person.badge.minus")
                    }
                } label: {
                    Text(member.isEditor ? "Editor" : "Viewer")
                        .font(.caption)
                        .foregroundStyle(.tint)
                }
            } else {
                Text(member.isEditor ? "Editor" : "Viewer")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func load() async {
        members = (try? await tripsRepository.members(tripId: trip.id)) ?? []
        if isOwner, let me {
            let friendships = (try? await friendsRepository.friendships()) ?? []
            friends = friendships
                .filter(\.isAccepted)
                .compactMap { $0.otherProfile(than: me) }
        }
    }

    private func invite(_ friend: FriendProfile) async {
        do {
            try await tripsRepository.addMember(tripId: trip.id, userId: friend.id, role: "viewer")
            await load()
            await onChanged()
        } catch {
            errorMessage = "Couldn't invite. They must be an accepted friend."
        }
    }

    private func setRole(_ member: TripMember, role: String) async {
        try? await tripsRepository.setMemberRole(tripId: trip.id, userId: member.userId, role: role)
        await load()
    }

    private func remove(_ member: TripMember) async {
        try? await tripsRepository.removeMember(tripId: trip.id, userId: member.userId)
        await load()
        await onChanged()
    }

    private func leave() async {
        try? await tripsRepository.leaveTrip(tripId: trip.id)
        await onChanged()
        dismiss()
    }
}
