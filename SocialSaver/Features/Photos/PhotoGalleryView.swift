import SwiftUI

/// Displays photos for a place: loads the rows visible to the caller, resolves
/// signed URLs in one batch, and shows a horizontal strip. Reused on the place
/// hub and the trip.
struct PhotoGallerySection: View {
    let placeId: UUID

    @State private var photos: [TripPhoto] = []
    @State private var urls: [UUID: URL] = [:]
    @State private var loaded = false
    @State private var fullscreen: URL?

    private let repository = PhotosRepository()

    var body: some View {
        Group {
            if !photos.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(photos) { photo in
                            photoThumb(photo)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else if loaded {
                Text("No photos yet — add yours from a trip that visits here.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
            }
        }
        .task { await load() }
        .fullScreenCover(item: $fullscreen) { url in
            PhotoViewer(url: url) { fullscreen = nil }
        }
    }

    private func photoThumb(_ photo: TripPhoto) -> some View {
        Button {
            fullscreen = urls[photo.id]
        } label: {
            AsyncImage(url: urls[photo.id]) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Color(.secondarySystemBackground)
            }
            .frame(width: 110, height: 110)
            .clipShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .disabled(urls[photo.id] == nil)
    }

    private func load() async {
        photos = (try? await repository.photos(placeId: placeId)) ?? []
        loaded = true
        urls = (try? await repository.signedURLs(for: photos.map(\.id))) ?? [:]
    }
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}

struct PhotoViewer: View {
    let url: URL
    let onClose: () -> Void

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            AsyncImage(url: url) { image in
                image.resizable().aspectRatio(contentMode: .fit)
            } placeholder: {
                ProgressView().tint(.white)
            }
        }
        .overlay(alignment: .topTrailing) {
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title)
                    .foregroundStyle(.white)
                    .padding()
            }
        }
    }
}
