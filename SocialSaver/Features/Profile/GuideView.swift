import SwiftUI

/// Per-platform saving instructions, mirroring the import guides Albo ships —
/// teaching the share-sheet habit is the whole onboarding.
struct GuideView: View {
    var body: some View {
        List {
            Section("TikTok") {
                step(1, "Find a video you want to keep")
                step(2, "Tap the Share arrow")
                step(3, "Scroll the app row and tap SocialSaver")
            }

            Section("Instagram") {
                step(1, "Open a Reel or post")
                step(2, "Tap the paper-plane Share icon")
                step(3, "Tap “Share to…”, then SocialSaver")
            }

            Section("Safari & other apps") {
                step(1, "Open the page or video")
                step(2, "Tap Share, then SocialSaver")
            }

            Section {
                Text("If SocialSaver isn't in the share sheet yet, scroll to the end of the app row, tap More, and enable it. You can drag it to the front so it's always one tap away.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Don't see SocialSaver?")
            }

            Section("What happens next") {
                Label("The save is classified into a category", systemImage: "sparkles")
                Label("Places are extracted and pinned on your map", systemImage: "mappin.and.ellipse")
                Label("Websites, phone numbers, and links are found", systemImage: "link")
                Label("It's filed into the best-matching list", systemImage: "folder")
                Label("Anything the AI got wrong is editable", systemImage: "pencil")
            }
            .font(.subheadline)

            Section("Migrating your old saves") {
                Text("Already have videos saved inside TikTok or Instagram? Open your favorites/saved tab there and share each one to SocialSaver — the pipeline organizes them as they arrive.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("How to save")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func step(_ number: Int, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Text("\(number)")
                .font(.caption.bold())
                .frame(width: 22, height: 22)
                .background(Color.accentColor.opacity(0.15), in: Circle())
            Text(text)
        }
    }
}
