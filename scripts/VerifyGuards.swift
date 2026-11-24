import Darwin
import Foundation

@main
struct VerifyGuards {
    struct Failure: LocalizedError { let message: String; var errorDescription: String? { message } }

    static func mustRefuse(_ reason: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw Failure(message: "Expected refusal: \(reason)")
    }

    static func main() {
        do { try verify() }
        catch {
            FileHandle.standardError.write(Data("Guard check failed: \(error.localizedDescription)\n".utf8))
            exit(EXIT_FAILURE)
        }
    }

    static func physicalPath(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw Failure(message: "Cannot resolve the home directory: \(String(cString: strerror(errno)))") }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    static func verify() throws {
        let fm = FileManager.default
        guard CommandLine.arguments.count == 2 else { throw Failure(message: "Use test-guards.sh") }
        // Foundation's resolvingSymlinksInPath can shorten /private/var back to /var.
        let home = URL(fileURLWithPath: try physicalPath(CommandLine.arguments[1]), isDirectory: true)
        guard home.path != (try physicalPath(fm.homeDirectoryForCurrentUser.path)),
              home.lastPathComponent == "home", home.deletingLastPathComponent().lastPathComponent.hasPrefix("backgrounddesk-guards.") else {
            throw Failure(message: "Use test-guards.sh with a disposable home.")
        }
        let live = home.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let archive = home.appendingPathComponent("Library/Application Support/WhatsInMyBackground/Removed Startup Items", isDirectory: true)
        for dir in [live, archive] { try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        let engine = AgentEngine(homeDirectory: home)
        let label = "local.backgrounddesk.guard-\(UUID().uuidString)"
        let file = live.appendingPathComponent(label + ".plist")
        let saved = archive.appendingPathComponent(file.lastPathComponent)
        let source = try PropertyListSerialization.data(fromPropertyList: ["Label": label, "Program": "/usr/bin/true"], format: .xml, options: 0)
        try source.write(to: file, options: .withoutOverwriting)
        try mustRefuse("untracked job") { try engine.perform(.archive, label: label) }
        guard fm.fileExists(atPath: file.path), !fm.fileExists(atPath: saved.path) else { throw Failure(message: "Untracked job moved") }
        guard let snapshot = try engine.snapshot(labels: [label]).first else { throw Failure(message: "Missing disposable job in snapshot") }
        guard snapshot.state == .unloaded else {
            throw Failure(message: "Expected stopped disposable job, found \(snapshot.state): \(snapshot.note ?? "no diagnostic note")")
        }
        let sentinel = Data("preexisting archive".utf8)
        try sentinel.write(to: saved, options: .withoutOverwriting)
        try mustRefuse("late archive collision") { try engine.perform(.archive, label: label) }
        guard try Data(contentsOf: saved) == sentinel, try Data(contentsOf: file) == source else { throw Failure(message: "Archive collision replaced data") }
        try fm.removeItem(at: saved)
        let target = home.appendingPathComponent("original.plist")
        try fm.moveItem(at: file, to: target)
        try fm.createSymbolicLink(at: file, withDestinationURL: target)
        try mustRefuse("symlink substituted after selection") { try engine.perform(.archive, label: label) }
        guard try fm.destinationOfSymbolicLink(atPath: file.path) == target.path, try Data(contentsOf: target) == source,
              !fm.fileExists(atPath: saved.path) else { throw Failure(message: "Symbolic-link target was changed") }
        print("Passed: untracked job, archive collision, and symlink substitution. No launchd job was loaded or stopped.")
    }
}
