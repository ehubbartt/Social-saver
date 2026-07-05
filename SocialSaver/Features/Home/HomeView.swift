import SwiftUI

struct HomeView: View {
    @Environment(SavesStore.self) private var store
    @State private var filter: ContentType?
    @State private var searchText = ""
    @State private var showingAsk = false
    @State private var showingLists = false
    @State private var isSelecting = false
    @State private var selection: Set<UUID> = []
    @State private var lists: [SavedList] = []

    private let listsRepository = ListsRepository()

    private var filteredSaves: [Save] {
        var result = store.saves
        if let filter {
            result = result.filter { $0.contentType == filter }
        }
        let query = searchText.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            result = result.filter { save in
                (save.title?.localizedCaseInsensitiveContains(query) ?? false)
                    || (save.summary?.localizedCaseInsensitiveContains(query) ?? false)
                    || (save.note?.localizedCaseInsensitiveContains(query) ?? false)
                    || save.places.contains { place in
                        place.name.localizedCaseInsensitiveContains(query)
                            || place.subtitle.localizedCaseInsensitiveContains(query)
                    }
            }
        }
        return result
    }

    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                categoryChips
                if filteredSaves.isEmpty && !store.isLoading {
                    emptyState
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(filteredSaves) { save in
                            if isSelecting {
                                Button {
                                    toggleSelection(save.id)
                                } label: {
                                    SaveCardView(save: save)
                                        .overlay(alignment: .topTrailing) {
                                            Image(systemName: selection.contains(save.id)
                                                ? "checkmark.circle.fill"
                                                : "circle")
                                                .font(.title3)
                                                .foregroundStyle(selection.contains(save.id)
                                                    ? Color.accentColor
                                                    : Color.secondary)
                                                .padding(6)
                                        }
                                }
                                .buttonStyle(.plain)
                            } else {
                                NavigationLink(value: save) {
                                    SaveCardView(save: save)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Saves")
            .searchable(text: $searchText, prompt: "Search saves and places")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(isSelecting ? "Done" : "Select") {
                        isSelecting.toggle()
                        selection.removeAll()
                    }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    // Lists moved off the tab bar to make room for Friends.
                    Button {
                        showingLists = true
                    } label: {
                        Image(systemName: "folder")
                    }
                    Button {
                        showingAsk = true
                    } label: {
                        Image(systemName: "sparkles")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                if isSelecting && !selection.isEmpty {
                    bulkActionBar
                }
            }
            .task(id: isSelecting) {
                if isSelecting {
                    lists = (try? await listsRepository.fetchLists()) ?? []
                }
            }
            .sheet(isPresented: $showingAsk) {
                AskView()
            }
            .sheet(isPresented: $showingLists) {
                ListsView()
            }
            .navigationDestination(for: Save.self) { save in
                SaveDetailView(save: save)
            }
            .refreshable { await store.refresh() }
            .task {
                await store.refresh()
                await store.pollWhileProcessing()
            }
            .overlay { if store.isLoading { ProgressView() } }
        }
    }

    private var categoryChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip(label: "All", systemImage: "square.stack", isSelected: filter == nil) {
                    filter = nil
                }
                ForEach(ContentType.allCases) { type in
                    chip(label: type.label, systemImage: type.systemImage, isSelected: filter == type) {
                        filter = filter == type ? nil : type
                    }
                }
            }
            .padding(.horizontal)
        }
        .padding(.vertical, 8)
    }

    private func chip(label: String, systemImage: String, isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(label, systemImage: systemImage)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.secondarySystemBackground))
                .foregroundStyle(isSelected ? .white : .primary)
                .clipShape(Capsule())
        }
    }

    private var bulkActionBar: some View {
        HStack {
            Menu {
                ForEach(lists) { list in
                    Button("\(list.emoji ?? "📁") \(list.name)") {
                        Task { await bulkAdd(to: list) }
                    }
                }
            } label: {
                Label("Add \(selection.count) to list", systemImage: "plus.rectangle.on.folder")
            }
            .disabled(lists.isEmpty)
            Spacer()
            Button(role: .destructive) {
                Task { await bulkDelete() }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .padding()
        .background(.bar)
    }

    private func toggleSelection(_ id: UUID) {
        if selection.contains(id) {
            selection.remove(id)
        } else {
            selection.insert(id)
        }
    }

    private func bulkAdd(to list: SavedList) async {
        for id in selection {
            try? await listsRepository.addSave(id, to: list.id)
        }
        isSelecting = false
        selection.removeAll()
    }

    private func bulkDelete() async {
        let toDelete = store.saves.filter { selection.contains($0.id) }
        for save in toDelete {
            await store.delete(save)
        }
        isSelecting = false
        selection.removeAll()
    }

    private var emptyState: some View {
        ContentUnavailableView(
            "Nothing saved yet",
            systemImage: "square.and.arrow.down",
            description: Text("Share a video from TikTok or Instagram and pick SocialSaver in the share sheet.")
        )
        .padding(.top, 80)
    }
}

struct SaveCardView: View {
    let save: Save

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            thumbnail
            Text(save.title ?? save.sourceUrl)
                .font(.subheadline.weight(.medium))
                .lineLimit(2)
            HStack(spacing: 4) {
                Image(systemName: save.contentType.systemImage)
                Text(save.contentType.label)
                if save.status == .pending {
                    Spacer()
                    ProgressView().controlSize(.mini)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 14))
    }

    private var thumbnail: some View {
        AsyncImage(url: save.thumbnailUrl.flatMap { URL(string: $0) }) { image in
            image.resizable().aspectRatio(contentMode: .fill)
        } placeholder: {
            ZStack {
                Color(.tertiarySystemBackground)
                Image(systemName: save.contentType.systemImage)
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(height: 150)
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}
