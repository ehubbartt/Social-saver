import SwiftUI

struct MainTabView: View {
    @State private var store = SavesStore()

    var body: some View {
        TabView {
            HomeView()
                .tabItem { Label("Saves", systemImage: "square.grid.2x2") }
            MapExploreView()
                .tabItem { Label("Map", systemImage: "map") }
            TripsView()
                .tabItem { Label("Trips", systemImage: "airplane") }
            FeedView()
                .tabItem { Label("Friends", systemImage: "person.2") }
            ProfileView()
                .tabItem { Label("Profile", systemImage: "person.circle") }
        }
        .environment(store)
    }
}
