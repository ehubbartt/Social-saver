import SwiftUI

@main
struct SocialSaverApp: App {
    @State private var session = SessionObserver()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(session)
        }
    }
}

struct RootView: View {
    @Environment(SessionObserver.self) private var session

    var body: some View {
        Group {
            switch session.state {
            case .loading:
                ProgressView()
            case .signedOut:
                SignInView()
            case .signedIn:
                MainTabView()
            }
        }
        .task { await session.observe() }
    }
}
