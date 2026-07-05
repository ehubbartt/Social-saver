import SwiftUI

struct ListsView: View {
    @State private var lists: [SavedList] = []
    @State private var isLoading = false
    @State private var showingCreate = false
    @State private var newName = ""
    @State private var newEmoji = ""

    private let repository = ListsRepository()

    var body: some View {
        NavigationStack {
            List {
                ForEach(lists) { list in
                    NavigationLink {
                        ListDetailView(list: list)
                    } label: {
                        HStack {
                            Text(list.emoji ?? "📁")
                            Text(list.name)
                        }
                    }
                }
                .onDelete { indexSet in
                    Task { await delete(at: indexSet) }
                }
            }
            .overlay {
                if lists.isEmpty && !isLoading {
                    ContentUnavailableView(
                        "No lists yet",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Lists are created automatically when you save videos, or make your own.")
                    )
                }
            }
            .navigationTitle("Lists")
            .toolbar {
                Button {
                    showingCreate = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            .refreshable { await refresh() }
            .task { await refresh() }
            .alert("New list", isPresented: $showingCreate) {
                TextField("Name", text: $newName)
                TextField("Emoji (optional)", text: $newEmoji)
                Button("Create") {
                    Task {
                        try? await repository.createList(
                            name: newName,
                            emoji: newEmoji.isEmpty ? nil : newEmoji
                        )
                        newName = ""
                        newEmoji = ""
                        await refresh()
                    }
                }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    private func refresh() async {
        isLoading = lists.isEmpty
        defer { isLoading = false }
        lists = (try? await repository.fetchLists()) ?? lists
    }

    private func delete(at indexSet: IndexSet) async {
        for index in indexSet {
            try? await repository.deleteList(id: lists[index].id)
        }
        await refresh()
    }
}

struct ListDetailView: View {
    let list: SavedList
    @State private var saves: [Save] = []

    private let repository = ListsRepository()
    private let columns = [GridItem(.adaptive(minimum: 160), spacing: 12)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(saves) { save in
                    NavigationLink(value: save) {
                        SaveCardView(save: save)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("\(list.emoji ?? "") \(list.name)")
        .navigationDestination(for: Save.self) { save in
            SaveDetailView(save: save)
        }
        .overlay {
            if saves.isEmpty {
                ContentUnavailableView("Empty list", systemImage: "tray")
            }
        }
        .task {
            saves = (try? await repository.fetchItems(listId: list.id)) ?? []
        }
    }
}
