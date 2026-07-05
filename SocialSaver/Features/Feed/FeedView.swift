import SwiftUI

/// What friends deliberately shared: recommended saves, friends-visible
/// lists, and their place reviews. Nothing appears here implicitly.
struct FeedView: View {
    enum Entry: Identifiable {
        case event(FeedEvent)
        case review(FriendReview, username: String?)

        var id: String {
            switch self {
            case .event(let event): return "event-\(event.id)"
            case .review(let review, _): return "review-\(review.id)"
            }
        }

        var date: Date {
            switch self {
            case .event(let event): return event.createdAt
            case .review(let review, _): return review.createdAt
            }
        }
    }

    @State private var entries: [Entry] = []
    @State private var friendCount = 0
    @State private var isLoading = true

    private let friendsRepository = FriendsRepository()
    private let feedRepository = FeedRepository()

    var body: some View {
        NavigationStack {
            List {
                ForEach(entries) { entry in
                    entryView(entry)
                }
            }
            .overlay {
                if !isLoading && entries.isEmpty {
                    if friendCount == 0 {
                        ContentUnavailableView(
                            "No friends yet",
                            systemImage: "person.2",
                            description: Text("Add friends to see the saves, lists, and reviews they choose to share.")
                        )
                    } else {
                        ContentUnavailableView(
                            "Nothing shared yet",
                            systemImage: "sparkles",
                            description: Text("When friends recommend a save, share a list, or review a place, it shows up here.")
                        )
                    }
                }
            }
            .navigationTitle("Friends")
            .toolbar {
                NavigationLink {
                    FriendsView()
                } label: {
                    Image(systemName: "person.badge.plus")
                }
            }
            .refreshable { await load() }
            .task { await load() }
            .overlay { if isLoading && entries.isEmpty { ProgressView() } }
        }
    }

    @ViewBuilder
    private func entryView(_ entry: Entry) -> some View {
        switch entry {
        case .event(let event):
            if event.kind == "recommended_save", let save = event.save {
                recommendedRow(event: event, save: save)
            } else if event.kind == "shared_list", let list = event.list {
                sharedListRow(event: event, list: list)
            }
        case .review(let review, let username):
            reviewRow(review, username: username)
        }
    }

    private func recommendedRow(event: FeedEvent, save: Save) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(name: event.actor?.username, verb: "recommends", date: event.createdAt)
            NavigationLink {
                SaveDetailView(save: save)
            } label: {
                SaveCardView(save: save)
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func sharedListRow(event: FeedEvent, list: SavedList) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(name: event.actor?.username, verb: "shared a list", date: event.createdAt)
            NavigationLink {
                ListDetailView(list: list)
            } label: {
                HStack {
                    Text(list.emoji ?? "📁").font(.title2)
                    Text(list.name).font(.headline)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .padding(10)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func reviewRow(_ review: FriendReview, username: String?) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            header(name: username, verb: "reviewed \(review.place.name)", date: review.createdAt)
            NavigationLink {
                PlaceVideosView(place: review.place)
            } label: {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        StarsView(rating: review.rating)
                        Image(systemName: review.worthIt ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                            .font(.caption)
                            .foregroundStyle(review.worthIt ? Color.green : Color.orange)
                        Text(review.worthIt ? "Worth it" : "Skip it")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(review.worthIt ? Color.green : Color.orange)
                    }
                    if let body = review.body, !body.isEmpty {
                        Text(body).font(.subheadline).lineLimit(3)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
        }
        .padding(.vertical, 4)
    }

    private func header(name: String?, verb: String, date: Date) -> some View {
        HStack {
            Image(systemName: "person.crop.circle")
                .foregroundStyle(.tint)
            Text("\(name.map { "@\($0)" } ?? "A friend") \(verb)")
                .font(.subheadline.weight(.medium))
            Spacer()
            Text(date.formatted(.relative(presentation: .named)))
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    private func load() async {
        defer { isLoading = false }
        guard let me = SupabaseClientProvider.currentUserId else { return }

        let friendships = (try? await friendsRepository.friendships()) ?? []
        let accepted = friendships.filter(\.isAccepted)
        friendCount = accepted.count

        var usernames: [UUID: String] = [:]
        var activeFriendIds: [UUID] = []
        for friendship in accepted {
            let otherId = friendship.otherId(than: me)
            let profile = friendship.otherProfile(than: me)
            if let username = profile?.username {
                usernames[otherId] = username
            }
            if profile?.sharingPaused != true {
                activeFriendIds.append(otherId)
            }
        }

        // RLS already excludes paused actors; the client filter drops own
        // events and is belt-and-suspenders on pause.
        let events = ((try? await feedRepository.events()) ?? [])
            .filter { $0.actorId != me && $0.actor?.sharingPaused != true }
        let reviews = (try? await feedRepository.friendReviews(friendIds: activeFriendIds)) ?? []

        entries = (
            events.map(Entry.event)
                + reviews.map { Entry.review($0, username: usernames[$0.userId]) }
        )
        .sorted { $0.date > $1.date }
    }
}
