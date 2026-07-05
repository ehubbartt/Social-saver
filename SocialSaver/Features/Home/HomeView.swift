import SwiftUI

struct HomeView: View {
    @Environment(SavesStore.self) private var store
    @State private var filter: ContentType?

    private var filteredSaves: [Save] {
        guard let filter else { return store.saves }
        return store.saves.filter { $0.contentType == filter }
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
                            NavigationLink(value: save) {
                                SaveCardView(save: save)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal)
                }
            }
            .navigationTitle("Saves")
            .navigationDestination(for: Save.self) { save in
                SaveDetailView(save: save)
            }
            .refreshable { await store.refresh() }
            .task { await store.refresh() }
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
        AsyncImage(url: save.thumbnailUrl.flatMap(URL.init)) { image in
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
