import SwiftUI
import Photos
import UIKit
import CoreLocation

/// Suggests camera-roll photos taken at a planned place during the trip, and
/// uploads the ones the user picks. Nothing leaves the device until "Add".
struct PhotoSuggestionsSheet: View {
    @Environment(\.dismiss) private var dismiss

    let place: Place
    let tripId: UUID?
    let start: Date
    let end: Date
    let onDone: () async -> Void

    @State private var access: PhotoMatchService.AccessLevel?
    @State private var matches: [PhotoMatch] = []
    @State private var thumbnails: [String: UIImage] = [:]
    @State private var selected: Set<String> = []
    @State private var isLoading = true
    @State private var isUploading = false
    @State private var errorMessage: String?

    private let service = PhotoMatchService()
    private let repository = PhotosRepository()

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            Group {
                switch access {
                case .denied:
                    ContentUnavailableView(
                        "Photo access off",
                        systemImage: "photo.on.rectangle",
                        description: Text("Enable photo access in Settings to add photos from your trip.")
                    )
                case .some:
                    content
                case nil:
                    ProgressView()
                }
            }
            .navigationTitle("Photos at \(place.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add \(selected.count)") {
                        Task { await attach() }
                    }
                    .disabled(selected.isEmpty || isUploading)
                }
            }
            .task { await load() }
        }
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("Finding your photos…")
        } else if matches.isEmpty {
            ContentUnavailableView(
                "No photos found here",
                systemImage: "mappin.slash",
                description: Text("No photos in your library were taken near \(place.name) during the trip.")
            )
        } else {
            ScrollView {
                if access == .limited {
                    Text("You've allowed limited photo access, so only your selected photos are searched.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                }
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(matches) { match in
                        thumbnailCell(match)
                    }
                }
                .padding(4)
            }
            .overlay {
                if isUploading {
                    VStack(spacing: 8) {
                        ProgressView()
                        Text("Adding photos…").font(.footnote)
                    }
                    .padding(20)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                }
            }
            .safeAreaInset(edge: .bottom) {
                if let errorMessage {
                    Text(errorMessage).font(.footnote).foregroundStyle(.red).padding(8)
                }
            }
        }
    }

    private func thumbnailCell(_ match: PhotoMatch) -> some View {
        let isSelected = selected.contains(match.id)
        return ZStack(alignment: .topTrailing) {
            if let image = thumbnails[match.id] {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1, contentMode: .fill)
            } else {
                Color(.secondarySystemBackground).aspectRatio(1, contentMode: .fill)
            }
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? Color.accentColor : Color.white)
                .padding(4)
                .shadow(radius: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .onTapGesture {
            if isSelected { selected.remove(match.id) } else { selected.insert(match.id) }
        }
        .task {
            if thumbnails[match.id] == nil {
                thumbnails[match.id] = await service.thumbnail(for: match.asset)
            }
        }
    }

    private func load() async {
        let level = await service.requestAccess()
        access = level
        guard level != .denied else { isLoading = false; return }
        guard let coordinate = place.coordinate else {
            isLoading = false
            return
        }
        matches = service.matches(near: coordinate, start: start, end: end)
        isLoading = false
    }

    private func attach() async {
        isUploading = true
        errorMessage = nil
        defer { isUploading = false }
        let chosen = matches.filter { selected.contains($0.id) }
        for match in chosen {
            guard let jpeg = await service.strippedJPEG(for: match.asset) else { continue }
            do {
                try await repository.upload(
                    jpeg: jpeg,
                    placeId: place.id,
                    tripId: tripId,
                    takenAt: match.takenAt,
                    latitude: match.coordinate?.latitude,
                    longitude: match.coordinate?.longitude
                )
            } catch {
                errorMessage = "Some photos couldn't be added."
            }
        }
        await onDone()
        dismiss()
    }
}

private extension Place {
    var coordinate: CLLocationCoordinate2D? {
        guard let latitude, let longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }
}
