import Foundation
import Observation

@Observable
final class SavesStore {
    var saves: [Save] = []
    var isLoading = false
    var errorMessage: String?

    private let repository = SavesRepository()

    @MainActor
    func refresh() async {
        isLoading = saves.isEmpty
        defer { isLoading = false }
        do {
            saves = try await repository.fetchSaves()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @MainActor
    func delete(_ save: Save) async {
        do {
            try await repository.delete(id: save.id)
            saves.removeAll { $0.id == save.id }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Pins for the map tab: every geocoded place across all saves, with the
    /// saves that reference it grouped together.
    var placePins: [PlacePin] {
        var byPlace: [UUID: PlacePin] = [:]
        for save in saves {
            for place in save.places where place.latitude != nil && place.longitude != nil {
                byPlace[place.id, default: PlacePin(place: place, saves: [])].saves.append(save)
            }
        }
        return Array(byPlace.values)
    }
}

struct PlacePin: Identifiable {
    let place: Place
    var saves: [Save]
    var id: UUID { place.id }
}
