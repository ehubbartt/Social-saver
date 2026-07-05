import SwiftUI

/// Everything you've published to friends, in one place, each removable —
/// plus the global pause switch. This is the answer to "what can my friends
/// see right now?"
struct ActivityView: View {
    @State private var events: [FeedEvent] = []
    @State private var sharingPaused = false
    @State private var isLoaded = false

    private let feedRepository = FeedRepository()
    private let friendsRepository = FriendsRepository()

    var body: some View {
        List {
            Section {
                Toggle("Pause sharing", isOn: $sharingPaused)
                    .onChange(of: sharingPaused) {
                        Task { try? await friendsRepository.setSharingPaused(sharingPaused) }
                    }
            } footer: {
                Text("While paused, friends see nothing of yours in their feed — existing items included.")
            }

            Section {
                if isLoaded && events.isEmpty {
                    Text("You haven't shared anything. Recommend a save or make a list visible to friends and it shows up here.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(events) { event in
                    eventRow(event)
                        .swipeActions {
                            Button("Remove", role: .destructive) {
                                Task { await retract(event) }
                            }
                        }
                }
            } header: {
                Text("Shared with friends")
            } footer: {
                Text("Your place reviews are visible too — manage those from each place's Reviews section.")
            }
        }
        .navigationTitle("Your activity")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .refreshable { await load() }
    }

    private func eventRow(_ event: FeedEvent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: event.kind == "recommended_save" ? "hand.thumbsup" : "folder.badge.person.crop")
                .foregroundStyle(.tint)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.kind == "recommended_save"
                    ? (event.save?.title ?? "Recommended save")
                    : "\(event.list?.emoji ?? "📁") \(event.list?.name ?? "Shared list")")
                    .font(.subheadline)
                    .lineLimit(1)
                Text(event.kind == "recommended_save" ? "Recommended" : "List visible to friends")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Text(event.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func retract(_ event: FeedEvent) async {
        if event.kind == "shared_list", let list = event.list {
            // Keep publish state coherent: retracting a shared list also
            // makes the list private again.
            try? await feedRepository.setListVisibility(list: list, friendsVisible: false)
        } else {
            try? await feedRepository.deleteEvent(id: event.id)
        }
        await load()
    }

    private func load() async {
        events = (try? await feedRepository.myEvents()) ?? events
        sharingPaused = (try? await friendsRepository.myProfile())?.sharingPaused ?? sharingPaused
        isLoaded = true
    }
}
