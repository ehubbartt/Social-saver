import SwiftUI
import MapKit

struct SaveDetailView: View {
    @Environment(SavesStore.self) private var store
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL

    @State private var save: Save
    @State private var lists: [SavedList] = []
    @State private var confirmation: String?
    @State private var showingEdit = false
    @State private var placeForVideos: Place?

    private let listsRepository = ListsRepository()
    private let savesRepository = SavesRepository()

    init(save: Save) {
        _save = State(initialValue: save)
    }

    var body: some View {
        List {
            Section {
                header
            }
            .listRowInsets(EdgeInsets())
            .listRowBackground(Color.clear)

            if let summary = save.summary, !summary.isEmpty {
                Section("Summary") {
                    Text(summary)
                }
            }

            if let note = save.note, !note.isEmpty {
                Section("My note") {
                    Label(note, systemImage: "note.text")
                }
            }

            if let recipe = save.recipe {
                if !recipe.ingredients.isEmpty {
                    Section("Ingredients") {
                        ForEach(recipe.ingredients, id: \.self) { ingredient in
                            Label(ingredient, systemImage: "circle.fill")
                                .labelStyle(IngredientLabelStyle())
                        }
                    }
                }
                if !recipe.steps.isEmpty {
                    Section("Steps") {
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { index, step in
                            HStack(alignment: .top, spacing: 10) {
                                Text("\(index + 1)")
                                    .font(.caption.bold())
                                    .frame(width: 22, height: 22)
                                    .background(Color.accentColor.opacity(0.15), in: Circle())
                                Text(step)
                            }
                        }
                    }
                }
            }

            if !save.places.isEmpty {
                Section("Places") {
                    ForEach(save.places) { place in
                        placeRow(place)
                    }
                }
            }

            if !save.links.isEmpty {
                Section("Mentioned") {
                    ForEach(save.links) { link in
                        linkRow(link)
                    }
                }
            }

            Section {
                Button {
                    if let url = URL(string: save.sourceUrl) { openURL(url) }
                } label: {
                    Label("Open on \(save.sourcePlatform.capitalized)", systemImage: "play.rectangle")
                }
            }
        }
        .navigationTitle(save.title ?? "Save")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        showingEdit = true
                    } label: {
                        Label("Edit", systemImage: "pencil")
                    }
                    addToListMenu
                    Divider()
                    Button(role: .destructive) {
                        Task {
                            await store.delete(save)
                            dismiss()
                        }
                    } label: {
                        Label("Delete save", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .task {
            lists = (try? await listsRepository.fetchLists()) ?? []
        }
        .sheet(item: $placeForVideos) { place in
            NavigationStack {
                PlaceVideosView(place: place)
            }
        }
        .sheet(isPresented: $showingEdit, onDismiss: {
            // Place edits apply immediately inside the sheet, so refresh even
            // when the user cancels instead of tapping Save.
            Task { await reload() }
        }) {
            EditSaveView(save: save) {
                await reload()
            }
        }
        .overlay(alignment: .bottom) {
            if let confirmation {
                Text(confirmation)
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .task(id: confirmation) {
                        try? await Task.sleep(for: .seconds(2))
                        self.confirmation = nil
                    }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            AsyncImage(url: save.thumbnailUrl.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground).frame(height: 200)
            }
            .frame(maxHeight: 260)
            .clipped()

            HStack {
                Label(save.contentType.label, systemImage: save.contentType.systemImage)
                if let author = save.authorName {
                    Text("by \(author)")
                }
                Spacer()
                if save.status == .pending {
                    Label("Processing", systemImage: "clock")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.bottom, 8)
        }
    }

    private func placeRow(_ place: Place) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(place.name).font(.headline)
            if !place.subtitle.isEmpty {
                Text(place.subtitle).font(.subheadline).foregroundStyle(.secondary)
            }
            if let lat = place.latitude, let lon = place.longitude {
                let coordinate = CLLocationCoordinate2D(latitude: lat, longitude: lon)
                Map(initialPosition: .region(MKCoordinateRegion(
                    center: coordinate,
                    span: MKCoordinateSpan(latitudeDelta: 0.02, longitudeDelta: 0.02)
                ))) {
                    Marker(place.name, coordinate: coordinate)
                }
                .frame(height: 140)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .allowsHitTesting(false)
            }
            contactButtons(for: place)
        }
        .padding(.vertical, 4)
    }

    private func contactButtons(for place: Place) -> some View {
        HStack(spacing: 12) {
            if let website = place.websiteURL {
                Button {
                    openURL(website)
                } label: {
                    Label("Website", systemImage: "globe")
                }
            }
            if let phone = place.phoneURL {
                Button {
                    openURL(phone)
                } label: {
                    Label("Call", systemImage: "phone")
                }
            }
            Button {
                placeForVideos = place
            } label: {
                Label("Reviews & videos", systemImage: "play.square.stack")
            }
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .font(.footnote)
    }

    private func linkRow(_ link: SaveLink) -> some View {
        Button {
            if let url = URL(string: link.url) { openURL(url) }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: link.kind.systemImage)
                    .frame(width: 26)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(link.title)
                        .foregroundStyle(.primary)
                    if let note = link.note, !note.isEmpty {
                        Text(note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                Image(systemName: "arrow.up.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func reload() async {
        if let fresh = try? await savesRepository.fetchSave(id: save.id) {
            save = fresh
        }
        await store.refresh()
    }

    private struct IngredientLabelStyle: LabelStyle {
        func makeBody(configuration: Configuration) -> some View {
            HStack(alignment: .top, spacing: 10) {
                configuration.icon
                    .font(.system(size: 6))
                    .foregroundStyle(.secondary)
                    .padding(.top, 7)
                configuration.title
            }
        }
    }

    @ViewBuilder
    private var addToListMenu: some View {
        Menu {
            ForEach(lists) { list in
                Button {
                    Task {
                        try? await listsRepository.addSave(save.id, to: list.id)
                        confirmation = "Added to \(list.name)"
                    }
                } label: {
                    Text("\(list.emoji ?? "📁") \(list.name)")
                }
            }
        } label: {
            Label("Add to list", systemImage: "plus.rectangle.on.folder")
        }
    }
}
