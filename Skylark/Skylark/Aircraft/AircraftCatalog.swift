import Foundation

/// Every aircraft the game can fly: the ones built in, and any .json files the player put in the app's Aircraft folder
/// (Files › On My iPhone › Skylark › Aircraft). A file there with the id of a built-in one replaces it.
final class AircraftCatalog: ObservableObject {
    @Published private(set) var aircraft: [AircraftSpec] = []
    /// Files that could not be used, with the reason.
    @Published private(set) var problems: [String] = []
    /// Ids that came from the player's folder.
    @Published private(set) var custom: Set<String> = []

    static let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    static let userFolder = documents.appendingPathComponent("Aircraft", isDirectory: true)
    static let examplesFolder = documents.appendingPathComponent("Examples", isDirectory: true)

    init() {
        writeExamples()
        reload()
    }

    func reload() {
        var found: [AircraftSpec] = []
        var problems: [String] = []
        var custom: Set<String> = []

        let builtIn = (Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? [])
        for url in builtIn {
            if let spec = try? Self.read(url) { found.append(spec) }
        }
        found.sort { $0.name < $1.name }

        let files = (try? FileManager.default.contentsOfDirectory(at: Self.userFolder, includingPropertiesForKeys: nil)) ?? []
        for url in files.filter({ $0.pathExtension.lowercased() == "json" }).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            do {
                let spec = try Self.read(url)
                custom.insert(spec.id)
                if let index = found.firstIndex(where: { $0.id == spec.id }) {
                    found[index] = spec
                } else {
                    found.append(spec)
                }
            } catch {
                problems.append("\(url.lastPathComponent): \(Self.explain(error))")
            }
        }
        self.aircraft = found
        self.problems = problems
        self.custom = custom
    }

    static func read(_ url: URL) throws -> AircraftSpec {
        let spec = try JSONDecoder().decode(AircraftSpec.self, from: Data(contentsOf: url))
        try spec.validate()
        return spec
    }

    private static func explain(_ error: Error) -> String {
        guard let decoding = error as? DecodingError else { return error.localizedDescription }
        func place(_ context: DecodingError.Context) -> String {
            let path = context.codingPath.map { $0.intValue.map { "item \($0 + 1)" } ?? "\"\($0.stringValue)\"" }.joined(separator: " › ")
            return path.isEmpty ? "" : " in \(path)"
        }
        switch decoding {
        case .keyNotFound(let key, let context): return "\"\(key.stringValue)\" is missing\(place(context))"
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "a value is the wrong kind\(place(context)) (a number where text belongs, or the other way round)"
        case .dataCorrupted(let context): return "this is not valid JSON\(place(context)); look for a missing comma, quote or bracket"
        @unknown default: return "this file could not be read"
        }
    }

    /// Keeps a copy of the built-in aircraft and the guide where the player can find them, as starting points.
    private func writeExamples() {
        let manager = FileManager.default
        try? manager.createDirectory(at: Self.userFolder, withIntermediateDirectories: true)
        try? manager.createDirectory(at: Self.examplesFolder, withIntermediateDirectories: true)
        var sources = Bundle.main.urls(forResourcesWithExtension: "json", subdirectory: nil) ?? []
        if let guide = Bundle.main.url(forResource: "How to make aircraft", withExtension: "txt") { sources.append(guide) }
        for source in sources {
            let copy = Self.examplesFolder.appendingPathComponent(source.lastPathComponent)
            try? manager.removeItem(at: copy)
            try? manager.copyItem(at: source, to: copy)
        }
    }
}
