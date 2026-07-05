import SwiftUI
import MapKit

/// A single-day event: when it is, who's coming (with RSVP), and the stops
/// (places you're going, each linking out to its map/website).
struct EventDetailView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Environment(SavesStore.self) private var store

    let event: Event

    @State private var stops: [EventStop] = []
    @State private var guests: [EventGuest] = []
    @State private var myRSVP: RSVP?
    @State private var showingInvite = false
    @State private var showingAddStops = false
    @State private var addCustomTitle = ""
    @State private var showingAddCustom = false
    @State private var errorMessage: String?

    private let repository = EventsRepository()
    private var isOwner: Bool { repository.isOwner(event) }
    private var me: UUID? { SupabaseClientProvider.currentUserId }

    private var goingCount: Int { guests.filter { $0.status == .going }.count }

    /// Plain-text invite for sharing outside the app.
    private var shareText: String {
        var lines = ["\(event.emoji ?? "🎉") \(event.title)", event.whenText]
        if let note = event.note, !note.isEmpty { lines.append(note) }
        if !stops.isEmpty {
            lines.append("")
            lines.append("Plan:")
            for stop in stops {
                let time = stop.timeDisplay.map { "\($0) " } ?? ""
                lines.append("• \(time)\(stop.displayTitle)")
            }
        }
        return lines.joined(separator: "\n")
    }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 4) {
                    Text(event.whenText).font(.headline)
                    if let note = event.note, !note.isEmpty {
                        Text(note).font(.subheadline).foregroundStyle(.secondary)
                    }
                    Text("\(goingCount) going").font(.caption).foregroundStyle(.tint)
                }
            }

            if !isOwner {
                Section("Are you going?") {
                    Picker("RSVP", selection: Binding(
                        get: { myRSVP ?? .invited },
                        set: { newValue in Task { await setRSVP(newValue) } }
                    )) {
                        Text("Going").tag(RSVP.going)
                        Text("Maybe").tag(RSVP.maybe)
                        Text("Can't go").tag(RSVP.declined)
                    }
                    .pickerStyle(.segmented)
                }
            }

            Section {
                ForEach(stops) { stop in
                    stopRow(stop)
                }
                if stops.isEmpty {
                    Text(isOwner ? "Add the places you're going." : "No stops yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if isOwner {
                    Button {
                        showingAddStops = true
                    } label: {
                        Label("Add from saves", systemImage: "bookmark")
                    }
                    Button {
                        showingAddCustom = true
                    } label: {
                        Label("Add a custom stop", systemImage: "mappin")
                    }
                }
            } header: {
                Text("Plan")
            }

            Section("Guests") {
                HStack {
                    Image(systemName: "crown.fill").foregroundStyle(.yellow)
                    Text(isOwner ? "You (host)" : "Host")
                }
                ForEach(guests) { guest in
                    guestRow(guest)
                }
                if isOwner {
                    Button {
                        showingInvite = true
                    } label: {
                        Label("Invite friends", systemImage: "person.badge.plus")
                    }
                }
            }

            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red).font(.footnote) }
            }
        }
        .navigationTitle("\(event.emoji ?? "") \(event.title)".trimmingCharacters(in: .whitespaces))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                ShareLink(item: shareText) {
                    Image(systemName: "square.and.arrow.up")
                }
                if isOwner {
                    Menu {
                        Button(role: .destructive) {
                            Task {
                                try? await repository.deleteEvent(id: event.id)
                                dismiss()
                            }
                        } label: {
                            Label("Delete event", systemImage: "trash")
                        }
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                }
            }
        }
        .task { await load() }
        .refreshable { await load() }
        .sheet(isPresented: $showingInvite) {
            EventInviteSheet(event: event) { await load() }
        }
        .sheet(isPresented: $showingAddStops) {
            AddSavesToEventSheet(event: event) { await load() }
        }
        .alert("Custom stop", isPresented: $showingAddCustom) {
            TextField("Title (e.g. Meet at the fountain)", text: $addCustomTitle)
            Button("Add") {
                Task {
                    let t = addCustomTitle.trimmingCharacters(in: .whitespaces)
                    if !t.isEmpty {
                        try? await repository.addCustomStop(eventId: event.id, title: t, time: nil)
                        addCustomTitle = ""
                        await load()
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func stopRow(_ stop: EventStop) -> some View {
        HStack(spacing: 10) {
            if let time = stop.timeDisplay {
                Text(time).font(.caption.bold().monospacedDigit()).foregroundStyle(.tint)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(stop.displayTitle).font(.subheadline)
                if let place = stop.place {
                    Text(place.name).font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer()
            if let place = stop.place, place.latitude != nil {
                Button {
                    openInMaps(place)
                } label: {
                    Image(systemName: "map")
                }
                .buttonStyle(.borderless)
            }
            if let website = stop.place?.websiteURL {
                Button {
                    openURL(website)
                } label: {
                    Image(systemName: "globe")
                }
                .buttonStyle(.borderless)
            }
        }
        .swipeActions {
            if isOwner {
                Button(role: .destructive) {
                    Task {
                        try? await repository.removeStop(id: stop.id)
                        await load()
                    }
                } label: { Label("Remove", systemImage: "trash") }
            }
        }
    }

    private func guestRow(_ guest: EventGuest) -> some View {
        HStack {
            Text("@\(guest.profile?.username ?? "friend")")
            Spacer()
            Label(guest.status.label, systemImage: guest.status.systemImage)
                .font(.caption)
                .foregroundStyle(color(for: guest.status))
                .labelStyle(.titleAndIcon)
            if isOwner {
                Button {
                    Task {
                        try? await repository.removeGuest(eventId: event.id, userId: guest.userId)
                        await load()
                    }
                } label: {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            }
        }
    }

    private func color(for status: RSVP) -> Color {
        switch status {
        case .going: return .green
        case .maybe: return .orange
        case .declined: return .secondary
        case .invited: return .secondary
        }
    }

    private func openInMaps(_ place: Place) {
        let coordinate = CLLocationCoordinate2D(latitude: place.latitude ?? 0, longitude: place.longitude ?? 0)
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = place.name
        item.openInMaps()
    }

    private func load() async {
        stops = (try? await repository.stops(eventId: event.id)) ?? []
        guests = (try? await repository.guests(eventId: event.id)) ?? []
        myRSVP = guests.first { $0.userId == me }?.status
    }

    private func setRSVP(_ status: RSVP) async {
        myRSVP = status
        do {
            try await repository.setRSVP(eventId: event.id, status: status)
            await load()
        } catch {
            errorMessage = "Couldn't update your RSVP."
        }
    }
}

/// Invite accepted friends to an event.
struct EventInviteSheet: View {
    @Environment(\.dismiss) private var dismiss
    let event: Event
    let onInvited: () async -> Void

    @State private var friends: [FriendProfile] = []
    @State private var invited: Set<UUID> = []

    private let eventsRepository = EventsRepository()
    private let friendsRepository = FriendsRepository()

    var body: some View {
        NavigationStack {
            List(friends) { friend in
                Button {
                    Task { await invite(friend) }
                } label: {
                    HStack {
                        Text("@\(friend.username ?? "friend")")
                        Spacer()
                        if invited.contains(friend.id) {
                            Image(systemName: "checkmark").foregroundStyle(.green)
                        } else {
                            Image(systemName: "plus.circle").foregroundStyle(.tint)
                        }
                    }
                }
                .disabled(invited.contains(friend.id))
            }
            .overlay {
                if friends.isEmpty {
                    ContentUnavailableView("No friends yet", systemImage: "person.2",
                        description: Text("Add friends to invite them to events."))
                }
            }
            .navigationTitle("Invite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
            .task { await load() }
        }
    }

    private func load() async {
        guard let me = SupabaseClientProvider.currentUserId else { return }
        let friendships = (try? await friendsRepository.friendships()) ?? []
        friends = friendships.filter(\.isAccepted).compactMap { $0.otherProfile(than: me) }
        let guests = (try? await eventsRepository.guests(eventId: event.id)) ?? []
        invited = Set(guests.map(\.userId))
    }

    private func invite(_ friend: FriendProfile) async {
        do {
            try await eventsRepository.invite(eventId: event.id, userId: friend.id)
            invited.insert(friend.id)
            await onInvited()
        } catch {
            // ignore; likely already invited
        }
    }
}

/// Pick saves whose places become the event's stops.
struct AddSavesToEventSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(SavesStore.self) private var store

    let event: Event
    let onAdded: () async -> Void

    @State private var selection: Set<UUID> = []

    private let repository = EventsRepository()

    var body: some View {
        NavigationStack {
            List(store.saves) { save in
                Button {
                    if selection.contains(save.id) { selection.remove(save.id) } else { selection.insert(save.id) }
                } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(save.title ?? save.sourceUrl).lineLimit(1).foregroundStyle(.primary)
                            if let place = save.places.first {
                                Text(place.name).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        Spacer()
                        Image(systemName: selection.contains(save.id) ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(selection.contains(save.id) ? Color.accentColor : Color.secondary)
                    }
                }
            }
            .navigationTitle("Add to event")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selection.count)") {
                        Task {
                            try? await repository.addStops(eventId: event.id, saveIds: Array(selection))
                            await onAdded()
                            dismiss()
                        }
                    }
                    .disabled(selection.isEmpty)
                }
            }
            .task { await store.refresh() }
        }
    }
}
