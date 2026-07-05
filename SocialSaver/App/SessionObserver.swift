import Foundation
import Observation
import Supabase

@Observable
final class SessionObserver {
    enum State {
        case loading
        case signedOut
        case signedIn
    }

    var state: State = .loading

    private var client: SupabaseClient { SupabaseClientProvider.shared }

    @MainActor
    func observe() async {
        for await (event, session) in client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed:
                state = session == nil ? .signedOut : .signedIn
            case .signedOut, .userDeleted:
                state = .signedOut
            default:
                break
            }
        }
    }

    func signIn(email: String, password: String) async throws {
        try await client.auth.signIn(email: email, password: password)
    }

    func signUp(email: String, password: String) async throws {
        try await client.auth.signUp(email: email, password: password)
    }

    func signOut() async throws {
        try await client.auth.signOut()
    }

    var email: String? {
        client.auth.currentSession?.user.email
    }
}
