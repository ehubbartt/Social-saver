import SwiftUI

/// Browse more videos about a place: what other users have saved for the
/// same spot (anonymized public links) and, on demand, videos found on the
/// web. Any of them can be saved into your own library through the normal
/// ingest pipeline.
struct PlaceVideosView: View {
    @Environment(\.openURL) private var openURL

    let place: Place

    @State private var community: [CommunityVideo] = []
    @State private var communityLoaded = false
    @State private var web: [WebVideo] = []
    @State private var webSearched = false
    @State private var isSearchingWeb = false
    @State private var savedURLs: Set<String> = []
    @State private var savingURLs: Set<String> = []
    @State private var reviews: [PlaceReview] = []
    @State private var reviewsLoaded = false
    @State private var showingReviewSheet = false
    @State private var errorMessage: String?

    private let repository = SavesRepository()
    private let reviewsRepository = ReviewsRepository()

    private var myReview: PlaceReview? {
        guard let me = reviewsRepository.currentUserId else { return nil }
        return reviews.first { $0.userId == me }
    }

    var body: some View {
        List {
            Section {
                if !place.subtitle.isEmpty {
                    Text(place.subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Reviews") {
                if reviewsLoaded && !reviews.isEmpty {
                    reviewSummary
                }
                Button {
                    showingReviewSheet = true
                } label: {
                    Label(
                        myReview == nil ? "Write a review" : "Edit your review",
                        systemImage: myReview == nil ? "square.and.pencil" : "pencil"
                    )
                }
                if reviewsLoaded && reviews.isEmpty {
                    Text("Be the first to say whether it's worth it.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                ForEach(reviews) { review in
                    reviewRow(review)
                }
            }

            Section("Photos") {
                PhotoGallerySection(placeId: place.id)
            }

            Section("From the community") {
                if !communityLoaded {
                    ProgressView()
                } else if community.isEmpty {
                    Text("No one else has saved a video for this place yet.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(community) { video in
                        videoRow(
                            title: video.title ?? video.sourceUrl,
                            subtitle: video.sourcePlatform.capitalized,
                            thumbnailUrl: video.thumbnailUrl,
                            url: video.sourceUrl
                        )
                    }
                }
            }

            Section("From the web") {
                if !webSearched {
                    Button {
                        Task { await searchWeb() }
                    } label: {
                        Label(
                            isSearchingWeb ? "Searching…" : "Search the web for videos",
                            systemImage: "magnifyingglass"
                        )
                    }
                    .disabled(isSearchingWeb)
                } else if web.isEmpty {
                    Text("Nothing found on the web for this place.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(web) { video in
                        videoRow(
                            title: video.title,
                            subtitle: [video.platform.capitalized, video.description]
                                .compactMap { $0 }
                                .joined(separator: " · "),
                            thumbnailUrl: nil,
                            url: video.url
                        )
                    }
                }
            }

            if let errorMessage {
                Section {
                    Text(errorMessage).foregroundStyle(.red).font(.footnote)
                }
            }
        }
        .navigationTitle(place.name)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            async let communityTask = repository.communityVideos(placeId: place.id)
            async let reviewsTask = reviewsRepository.fetchReviews(placeId: place.id)
            community = (try? await communityTask) ?? []
            communityLoaded = true
            reviews = (try? await reviewsTask) ?? []
            reviewsLoaded = true
        }
        .sheet(isPresented: $showingReviewSheet) {
            ReviewSheet(place: place, existing: myReview) {
                reviews = (try? await reviewsRepository.fetchReviews(placeId: place.id)) ?? reviews
            }
        }
    }

    private var reviewSummary: some View {
        let count = reviews.count
        let average = Double(reviews.reduce(0) { $0 + $1.rating }) / Double(count)
        let worthCount = reviews.filter(\.worthIt).count
        return HStack(spacing: 8) {
            StarsView(rating: Int(average.rounded()), size: .subheadline)
            Text(String(format: "%.1f", average))
                .font(.subheadline.weight(.semibold))
            Text("· \(worthCount) of \(count) say it's worth it")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private func reviewRow(_ review: PlaceReview) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                StarsView(rating: review.rating)
                Image(systemName: review.worthIt ? "hand.thumbsup.fill" : "hand.thumbsdown.fill")
                    .font(.caption)
                    .foregroundStyle(review.worthIt ? Color.green : Color.orange)
                if review.userId == reviewsRepository.currentUserId {
                    Text("You")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor.opacity(0.15), in: Capsule())
                }
                Spacer()
                Text(review.createdAt.formatted(date: .abbreviated, time: .omitted))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let body = review.body, !body.isEmpty {
                Text(body)
                    .font(.subheadline)
            }
        }
        .padding(.vertical, 2)
    }

    private func videoRow(title: String, subtitle: String, thumbnailUrl: String?, url: String) -> some View {
        HStack(spacing: 10) {
            AsyncImage(url: thumbnailUrl.flatMap { URL(string: $0) }) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                ZStack {
                    Color(.secondarySystemBackground)
                    Image(systemName: "play.rectangle")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 48, height: 48)
            .clipShape(RoundedRectangle(cornerRadius: 8))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline)
                    .lineLimit(2)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            saveButton(url: url)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if let link = URL(string: url) { openURL(link) }
        }
    }

    @ViewBuilder
    private func saveButton(url: String) -> some View {
        if savedURLs.contains(url) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        } else if savingURLs.contains(url) {
            ProgressView().controlSize(.small)
        } else {
            Button {
                Task { await save(url: url) }
            } label: {
                Image(systemName: "square.and.arrow.down")
            }
            .buttonStyle(.borderless)
        }
    }

    /// Runs the discovered video through the normal ingest pipeline so it
    /// becomes a first-class save (classified, geocoded, filed into a list).
    private func save(url: String) async {
        savingURLs.insert(url)
        defer { savingURLs.remove(url) }
        do {
            try await repository.ingest(url: url)
            savedURLs.insert(url)
        } catch {
            errorMessage = "Couldn't save that video. Try again."
        }
    }

    private func searchWeb() async {
        isSearchingWeb = true
        errorMessage = nil
        defer { isSearchingWeb = false }
        do {
            web = try await repository.webVideos(for: place)
            webSearched = true
        } catch {
            errorMessage = "Web search failed. Try again."
        }
    }
}
