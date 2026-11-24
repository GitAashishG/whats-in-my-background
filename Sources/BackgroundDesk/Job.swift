import Foundation

enum JobState: String, Sendable {
    case running = "Running"
    case idle = "Scheduled / idle"
    case unloaded = "Stopped"
    case archived = "Startup removed"
    case unavailable = "Unavailable"
}

struct ManagedJob: Identifiable, Sendable {
    let label: String
    let state: JobState
    let schedule: String
    let executable: String?   // Executable only, never arguments or environment.
    let pid: Int?
    let note: String?         // Safety conflict, missing file, externally disabled, etc.
    var id: String { label }
    var name: String {
        let tail = label.split(separator: ".").last.map(String.init) ?? label
        return tail.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ").capitalized
    }
}

enum JobAction: Sendable {
    case stop, load, archive, restore
}
