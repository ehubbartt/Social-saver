import SwiftUI

struct ProfileView: View {
    @Environment(SessionObserver.self) private var session
    @Environment(SavesStore.self) private var store

    @State private var username: String?
    @State private var usernameDraft = ""
    @State private var usernameMessage: String?

    private let friendsRepository = FriendsRepository()

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
                    if let username {
                        LabeledContent("Username", value: "@\(username)")
                    } else {
                        HStack {
                            TextField("Pick a username", text: $usernameDraft)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Claim") {
                                Task { await claimUsername() }
                            }
                            .disabled(usernameDraft.trimmingCharacters(in: .whitespaces).count < 3)
                        }
                        if let usernameMessage {
                            Text(usernameMessage).font(.footnote).foregroundStyle(.red)
                        }
                    }
                    NavigationLink {
                        ActivityView()
                    } label: {
                        Label("Your activity & sharing", systemImage: "person.2.badge.gearshape")
                    }
                } header: {
                    Text("Friends & sharing")
                } footer: {
                    if username == nil {
                        Text("A username lets friends find you. Nothing is shared until you choose to share it.")
                    }
                }

                Section {
                    NavigationLink {
                        NotificationSettingsView()
                    } label: {
                        Label("Daily briefings", systemImage: "bell.badge")
                    }
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
            .task {
                username = (try? await friendsRepository.myProfile())?.username
            }
        }
    }

    private func claimUsername() async {
        let candidate = usernameDraft
            .trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "@", with: "")
            .lowercased()
        guard candidate.count >= 3, candidate.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }) else {
            usernameMessage = "3+ characters; letters, numbers, and _ only."
            return
        }
        do {
            try await friendsRepository.claimUsername(candidate)
            username = candidate
            usernameMessage = nil
        } catch {
            usernameMessage = "That username is taken."
        }
    }
}
