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
                    NavigationLink {
                        GuideView()
                    } label: {
                        Label("How to save", systemImage: "questionmark.circle")
                    }
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
