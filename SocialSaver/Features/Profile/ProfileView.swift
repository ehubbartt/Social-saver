import SwiftUI

struct ProfileView: View {
    @Environment(SessionObserver.self) private var session
    @Environment(SavesStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section("Account") {
                    if let email = session.email {
                        LabeledContent("Email", value: email)
                    }
                    LabeledContent("Saves", value: "\(store.saves.count)")
                }

                Section {
                    Text("Share a video from TikTok or Instagram, tap the share button, and choose SocialSaver. The save is classified and mapped automatically.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } header: {
                    Text("How to save")
                }

                Section {
                    Button("Sign out", role: .destructive) {
                        Task { try? await session.signOut() }
                    }
                }
            }
            .navigationTitle("Profile")
        }
    }
}
