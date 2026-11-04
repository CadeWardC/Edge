import Foundation

/// Saved trails and recorded hikes, kept as JSON in Application Support.
@MainActor
final class Library: ObservableObject {
    static let shared = Library()

    @Published private(set) var trails: [Trail] = []
    @Published private(set) var activities: [Activity] = []

    private let trailsURL = Files.support.appendingPathComponent("saved-trails.json")
    private let activitiesURL = Files.support.appendingPathComponent("activities.json")

    init() {
        trails = Files.load([Trail].self, from: trailsURL) ?? []
        activities = Files.load([Activity].self, from: activitiesURL) ?? []
    }

    // MARK: Trails

    func isSaved(_ id: String) -> Bool { trails.contains { $0.id == id } }

    func toggleSaved(_ trail: Trail) {
        if isSaved(trail.id) { removeTrail(id: trail.id) } else { save(trail) }
    }

    func save(_ trail: Trail) {
        let t = Profiles.shared.withProfile(trail)
        if let i = trails.firstIndex(where: { $0.id == t.id }) {
            trails[i] = t
        } else {
            trails.insert(t, at: 0)
        }
        persistTrails()
    }

    func removeTrail(id: String) {
        trails.removeAll { $0.id == id }
        persistTrails()
    }

    func removeTrails(at offsets: IndexSet) {
        trails.remove(atOffsets: offsets)
        persistTrails()
    }

    func updateProfile(_ p: ElevationProfile, for id: String) {
        guard let i = trails.firstIndex(where: { $0.id == id }), trails[i].profile == nil else { return }
        trails[i].profile = p
        persistTrails()
    }

    func renameTrail(id: String, to name: String) {
        guard let i = trails.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        trails[i].name = name
        persistTrails()
    }

    // MARK: Activities

    func add(_ a: Activity) {
        activities.insert(a, at: 0)
        persistActivities()
    }

    func deleteActivity(id: UUID) {
        activities.removeAll { $0.id == id }
        persistActivities()
    }

    func deleteActivities(at offsets: IndexSet) {
        activities.remove(atOffsets: offsets)
        persistActivities()
    }

    func renameActivity(id: UUID, to name: String) {
        guard let i = activities.firstIndex(where: { $0.id == id }), !name.isEmpty else { return }
        activities[i].name = name
        persistActivities()
    }

    private func persistTrails() { Files.save(trails, to: trailsURL) }
    private func persistActivities() { Files.save(activities, to: activitiesURL) }
}
