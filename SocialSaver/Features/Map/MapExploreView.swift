import SwiftUI
import MapKit

struct MapExploreView: View {
    @Environment(SavesStore.self) private var store
    @State private var position: MapCameraPosition = .automatic
    @State private var selectedPin: PlacePin?

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                ForEach(store.placePins) { pin in
                    Annotation(pin.place.name, coordinate: pin.coordinate) {
                        Button {
                            selectedPin = pin
                        } label: {
                            Image(systemName: pin.saves.first?.contentType.systemImage ?? "mappin")
                                .font(.callout)
                                .padding(8)
                                .background(.thinMaterial, in: Circle())
                        }
                    }
                }
            }
            .navigationTitle("Map")
            .navigationBarTitleDisplayMode(.inline)
            .task { await store.refresh() }
            .sheet(item: $selectedPin) { pin in
                PlaceSheetView(pin: pin)
                    .presentationDetents([.medium])
            }
        }
    }
}

private extension PlacePin {
    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: place.latitude ?? 0, longitude: place.longitude ?? 0)
    }
}

struct PlaceSheetView: View {
    let pin: PlacePin

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !pin.place.subtitle.isEmpty {
                        Text(pin.place.subtitle).foregroundStyle(.secondary)
                    }
                    Button {
                        openInMaps()
                    } label: {
                        Label("Open in Maps", systemImage: "arrow.triangle.turn.up.right.circle")
                    }
                    if let website = pin.place.websiteURL {
                        Link(destination: website) {
                            Label("Website", systemImage: "globe")
                        }
                    }
                    if let phone = pin.place.phoneURL {
                        Link(destination: phone) {
                            Label("Call", systemImage: "phone")
                        }
                    }
                }
                Section("Saved from") {
                    ForEach(pin.saves) { save in
                        NavigationLink {
                            SaveDetailView(save: save)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(save.title ?? save.sourceUrl).lineLimit(1)
                                Text(save.sourcePlatform.capitalized)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
            .navigationTitle(pin.place.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func openInMaps() {
        let coordinate = CLLocationCoordinate2D(
            latitude: pin.place.latitude ?? 0,
            longitude: pin.place.longitude ?? 0
        )
        let item = MKMapItem(placemark: MKPlacemark(coordinate: coordinate))
        item.name = pin.place.name
        item.openInMaps()
    }
}
