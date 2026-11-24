import Darwin
import Foundation

// The owner serializes calls. Listing available files never grants permission to act on them.
struct AgentEngine {
    private final class Watchlist { var labels = Set<String>() }
    private let watchlist = Watchlist()

    private let homeDirectory: URL?
    init(homeDirectory: URL? = nil) { self.homeDirectory = homeDirectory }
    private var domain: String { "gui/\(getuid())" }

    static func isValidLabel(_ label: String) -> Bool {
        func alphanumeric(_ byte: UInt8) -> Bool {
            (65...90).contains(byte) || (97...122).contains(byte) || (48...57).contains(byte)
        }
        let bytes = label.utf8
        guard let first = bytes.first, alphanumeric(first), bytes.count <= 249 else { return false }
        return !label.contains("..") && bytes.allSatisfy { alphanumeric($0) || $0 == 46 || $0 == 45 || $0 == 95 }
    }

    func snapshot(labels: [String]) throws -> [ManagedJob] {
        watchlist.labels.removeAll(keepingCapacity: true)
        guard labels.allSatisfy(Self.isValidLabel) else { throw Fault("The watchlist contains an invalid label.") }
        watchlist.labels.formUnion(labels)
        guard !labels.isEmpty else { return [] }
        do {
            let folders = try Folders(homeDirectory)
            let overrides = try disabledOverrides()
            return labels.map { label in
                do { return try inspect(label, in: folders, overrides: overrides).job }
                catch { return unavailable(label, error) }
            }
        } catch {
            return labels.map { unavailable($0, error) }
        }
    }

    func candidates() throws -> [String] {
        let folders = try Folders(homeDirectory)
        guard let live = folders.live else { return [] }
        let names: [String]
        do { names = try FileManager.default.contentsOfDirectory(atPath: live.path) }
        catch { throw Fault("Cannot read your LaunchAgents folder.") }
        let overrides = try disabledOverrides()
        return names.compactMap { name -> String? in
            guard name.hasSuffix(".plist") else { return nil }
            let label = String(name.dropLast(6))
            guard Self.isValidLabel(label), let entry = try? inspect(label, in: folders, overrides: overrides),
                  entry.job.state != .archived else { return nil }
            return label
        }.sorted()
    }

    func perform(_ action: JobAction, label: String) throws {
        guard Self.isValidLabel(label), watchlist.labels.contains(label) else {
            throw Fault("Only items on your watchlist can be changed.")
        }
        let folders = try Folders(homeDirectory)
        let entry = try inspect(label, in: folders, overrides: disabledOverrides())
        let file = entry.file
        switch action {
        case .stop:
            guard entry.loaded else { throw Fault("This item is not loaded.") }
            try bootout(file, from: file.folder)
        case .load:
            guard entry.job.state == .unloaded else { throw Fault("Only a stopped, installed item can be loaded.") }
            try bootstrap(file, in: file.folder)
        case .archive:
            guard entry.job.state != .archived else { throw Fault("This startup item has already been removed.") }
            guard let destination = try Folders(homeDirectory, createArchive: true).archive else { throw Fault("Cannot open the archive folder.") }
            try file.prepareMove(from: file.folder, to: destination)
            if entry.loaded { try bootout(file, from: file.folder) }
            do {
                guard try service(label) == nil else { throw Fault("A service still has this label loaded. Refresh before trying again.") }
                try file.move(from: file.folder, to: destination)
            } catch {
                guard entry.loaded else { throw error }
                do { try bootstrap(file, in: file.folder) }
                catch { throw Fault("Could not archive the startup file or reload the original service. Refresh to see its current state.") }
                throw Fault("Could not archive the startup file. The original service was loaded again.")
            }
        case .restore:
            guard entry.job.state == .archived else { throw Fault("Only a removed startup item can be restored.") }
            guard let destination = try Folders(homeDirectory, createLive: true).live else { throw Fault("Cannot open your LaunchAgents folder.") }
            guard try service(label) == nil else { throw Fault("Another service has claimed this label.") }
            try file.move(from: file.folder, to: destination)
            do { try bootstrap(file, in: destination) }
            catch {
                do {
                    guard try service(label) == nil else { throw Fault("A service has claimed this label.") }
                    try file.move(from: destination, to: file.folder)
                } catch {
                    throw Fault("The startup file was restored, but loading or returning it to the archive could not be confirmed. Refresh to check its state.")
                }
                throw Fault("The service could not be loaded. Its startup file is back in the archive.")
            }
        }
    }

    private struct Fault: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    private func unavailable(_ label: String, _ error: Error) -> ManagedJob {
        ManagedJob(label: label, state: .unavailable, schedule: "Unknown", executable: nil, pid: nil,
                   note: (error as? Fault)?.errorDescription ?? "Could not safely inspect this item.")
    }

    private struct Entry {
        let file: JobFile
        let job: ManagedJob
        var loaded: Bool { job.state == .running || job.state == .idle }
    }

    private func inspect(_ label: String, in folders: Folders, overrides: [String: Bool]) throws -> Entry {
        let live = try folders.live.flatMap { try JobFile.read(label, from: $0) }
        let archived = try folders.archive.flatMap { try JobFile.read(label, from: $0) }
        guard live == nil || archived == nil else { throw Fault("A startup file and an archived file both have this label. Neither will be changed.") }
        guard let file = live ?? archived else { throw Fault("The startup file is missing from LaunchAgents and the archive.") }
        let service = try self.service(label)
        if let service {
            guard live != nil else { throw Fault("This startup file is archived, but a service with the same label is still loaded.") }
            guard service.path == file.path(in: file.folder) else { throw Fault("A service from a different location has this label.") }
        }
        try requireEnabled(file, overrides: overrides)
        let state: JobState = service?.state ?? (live == nil ? .archived : .unloaded)
        return Entry(file: file, job: ManagedJob(label: label, state: state, schedule: file.schedule,
                                                  executable: file.executable, pid: service?.pid, note: nil))
    }

    private func requireEnabled(_ file: JobFile, overrides: [String: Bool]) throws {
        if overrides[file.label] ?? file.disabled {
            throw Fault("Startup is disabled outside this app. Its setting will not be changed.")
        }
    }

    private func bootout(_ file: JobFile, from folder: Folder) throws {
        try requireEnabled(file, overrides: disabledOverrides())
        try file.verify(in: folder)
        guard try service(file.label)?.path == file.path(in: folder) else {
            throw Fault("The loaded service changed. Nothing was stopped.")
        }
        // Target a verified label, not a PID, domain alone, or label re-read by launchctl from a file.
        try change(["bootout", "\(domain)/\(file.label)"], failure: "Could not stop the service")
    }

    private func bootstrap(_ file: JobFile, in folder: Folder) throws {
        try requireEnabled(file, overrides: disabledOverrides())
        guard try service(file.label) == nil else { throw Fault("A service already has this label loaded.") }
        try file.verify(in: folder)
        try change(["bootstrap", domain, file.path(in: folder)], failure: "Could not load the service")
    }

    private func change(_ arguments: [String], failure: String) throws {
        let (status, _) = try launchctl(arguments, capture: false)
        guard status == 0 else { throw Fault("\(failure) (launchctl code \(status)).") }
    }

    private struct Service {
        let path: String
        let state: JobState
        let pid: Int?
    }

    private func service(_ label: String) throws -> Service? {
        let target = "\(domain)/\(label)"
        let (status, text) = try launchctl(["print", target])
        if status == 113 { return nil } // launchctl's service-not-found result, not a general lookup failure.
        guard status == 0 else { throw Fault("Cannot inspect this service (launchctl code \(status)).") }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let unreadable = Fault("Cannot verify the service details reported by launchd.")
        guard lines.first == Substring("\(target) = {") else { throw unreadable }
        // Only accept origin and state in launchctl's header, before arguments or environment values.
        let header = lines.dropFirst().prefix { !$0.isEmpty && !$0.hasSuffix(" = {") && !$0.hasPrefix("\tprogram = ") }
        func value(_ field: String) -> String? {
            let prefix = "\t\(field) = "
            let matches = header.filter { $0.hasPrefix(prefix) }
            guard matches.count == 1 else { return nil }
            return String(matches[0].dropFirst(prefix.count))
        }
        guard let path = value("path"), path.hasPrefix("/"), let statusText = value("state") else { throw unreadable }
        let state: JobState
        switch statusText {
        case "running": state = .running
        case "not running", "waiting", "spawn scheduled", "exited": state = .idle
        default: throw Fault("The service is changing state or launchd reported an unfamiliar state. Refresh before making changes.")
        }
        // A PID is informational only. Never take action against it.
        let prefix = "\tpid = "
        let pids = lines.filter { $0.hasPrefix(prefix) }
        let pid = pids.count == 1 ? Int(pids[0].dropFirst(prefix.count)) : nil
        return Service(path: path, state: state, pid: state == .running && (pid ?? 0) > 0 ? pid : nil)
    }

    private func disabledOverrides() throws -> [String: Bool] {
        let (status, text) = try launchctl(["print-disabled", domain])
        guard status == 0 else { throw Fault("Cannot read startup settings for this login (launchctl code \(status)).") }
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let unknown = Fault("Cannot verify which services launchd has disabled.")
        guard lines.first == "disabled services = {", lines.last == "}" else { throw unknown }
        var result = [String: Bool]()
        for line in lines.dropFirst().dropLast() {
            guard line.hasPrefix("\""), let separator = line.range(of: "\" => ", options: .backwards),
                  separator.lowerBound > line.startIndex else { throw unknown }
            let label = String(line[line.index(after: line.startIndex)..<separator.lowerBound])
            let disabled: Bool
            switch line[separator.upperBound...] {
            case "disabled", "true": disabled = true
            case "enabled", "false": disabled = false
            default: throw unknown
            }
            guard result.updateValue(disabled, forKey: label) == nil else { throw unknown }
        }
        return result
    }

    // stderr can contain arguments and environment values. Never show, persist, or merge it into stdout.
    private func launchctl(_ arguments: [String], capture: Bool = true) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.environment = ["LC_ALL": "C", "PATH": "/usr/bin:/bin"]
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let pipe = capture ? Pipe() : nil
        if let pipe { process.standardOutput = pipe } else { process.standardOutput = FileHandle.nullDevice }
        do { try process.run() } catch { throw Fault("Cannot start launchctl.") }
        var bytes = Data()
        var tooLarge = false
        if let reader = pipe?.fileHandleForReading {
            do {
                while let chunk = try reader.read(upToCount: 65_536), !chunk.isEmpty {
                    if !tooLarge && bytes.count + chunk.count <= 2_097_152 { bytes.append(chunk) }
                    else { tooLarge = true } // Drain the pipe even when the response is not usable.
                }
            } catch {
                try? reader.close()
                if process.isRunning { process.terminate() }
                process.waitUntilExit()
                throw Fault("Cannot read launchctl's response.")
            }
        }
        process.waitUntilExit()
        guard process.terminationReason == .exit else { throw Fault("launchctl was interrupted.") }
        guard !tooLarge else { throw Fault("The launchctl response is too large to inspect safely.") }
        guard let text = String(data: bytes, encoding: .utf8) else { throw Fault("Cannot read launchctl's response.") }
        return (process.terminationStatus, text)
    }

    private struct Folders {
        let live: Folder?
        let archive: Folder?

        private static func accountHome() throws -> String {
            // Use the login account record, not an inherited HOME or a Foundation sandbox override.
            var record = passwd()
            var result: UnsafeMutablePointer<passwd>?
            var buffer = [CChar](repeating: 0, count: max(16_384, sysconf(_SC_GETPW_R_SIZE_MAX)))
            return try buffer.withUnsafeMutableBufferPointer { bytes in
                guard getpwuid_r(getuid(), &record, bytes.baseAddress!, bytes.count, &result) == 0, result != nil,
                      let directory = record.pw_dir, let path = String(validatingUTF8: directory) else {
                    throw Fault("Cannot identify your login account's home folder.")
                }
                return path
            }
        }

        init(_ directory: URL?, createLive: Bool = false, createArchive: Bool = false) throws {
            guard getuid() != 0, getuid() == geteuid(), getgid() == getegid() else { throw Fault("Run this app as your regular login user.") }
            let home = try Folder(home: directory?.path ?? Self.accountHome())
            guard let library = try home.child("Library") else { throw Fault("Your Library folder is missing.") }
            live = try library.child("LaunchAgents", create: createLive)
            let support = try library.child("Application Support", create: createArchive)
            let app = try support?.child("WhatsInMyBackground", create: createArchive)
            archive = try app?.child("Removed Startup Items", create: createArchive)
        }
    }

    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW_ANY | O_CLOEXEC
    private static let lockedFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND)

    // Mode bits can look private while an extended ACL still grants someone write access.
    // Don't try to resolve users or group membership. Refuse any extra write grant, even to the owner.
    private static func checkACL(_ fd: Int32) throws {
        let unreadable = Fault("Cannot verify the access permissions on a startup file or folder.")
        guard let acl = acl_get_fd_np(fd, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return } // No extended ACL on this open inode.
            throw unreadable
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let writes = UInt64(ACL_WRITE_DATA.rawValue | ACL_APPEND_DATA.rawValue | ACL_DELETE.rawValue |
                            ACL_DELETE_CHILD.rawValue | ACL_WRITE_ATTRIBUTES.rawValue | ACL_WRITE_EXTATTRIBUTES.rawValue |
                            ACL_WRITE_SECURITY.rawValue | ACL_CHANGE_OWNER.rawValue)
        var index: Int32 = 0
        var entry: acl_entry_t?
        while acl_get_entry(acl, index, &entry) == 0 {
            guard let entry else { throw unreadable }
            var tag = ACL_UNDEFINED_TAG
            var mask: acl_permset_mask_t = 0
            guard acl_get_tag_type(entry, &tag) == 0, acl_get_permset_mask_np(entry, &mask) == 0 else { throw unreadable }
            if tag == ACL_EXTENDED_ALLOW && mask & writes != 0 {
                throw Fault("An access rule grants extra write permissions to a startup file or folder. It will not be managed.")
            }
            index += 1
        }
        guard errno == EINVAL else { throw unreadable } // Darwin returns EINVAL after the last entry.
    }

    private struct Folder {
        let path: String
        let handle: FileHandle
        let info: stat
        var fd: Int32 { handle.fileDescriptor }

        init(home: String) throws {
            guard home.hasPrefix("/"), home != "/" else { throw Fault("Cannot identify your home folder.") }
            try self.init(path: home, fd: open(home, AgentEngine.directoryFlags))
        }

        private init(path: String, fd: Int32) throws {
            guard fd >= 0 else { throw Fault("Cannot safely open a required folder. Check for symlinks or insufficient permissions.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, Self.safe(info) else { throw Fault("A required folder is not private to your account. Check its ownership and write permissions.") }
            try AgentEngine.checkACL(fd)
            self.path = path
            self.handle = handle
            self.info = info
        }

        private static func safe(_ info: stat) -> Bool {
            info.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) && info.st_uid == getuid() && info.st_mode & 0o022 == 0
        }

        func child(_ name: String, create: Bool = false) throws -> Folder? {
            var child = openat(fd, name, AgentEngine.directoryFlags)
            if child < 0 && errno == ENOENT {
                guard create else { return nil }
                guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else { throw Fault("Cannot create the required startup folder.") }
                child = openat(fd, name, AgentEngine.directoryFlags)
            }
            return try Folder(path: path + "/" + name, fd: child)
        }

        func verify(writable: Bool = false) throws {
            let current = open(path, AgentEngine.directoryFlags)
            guard current >= 0 else { throw Fault("A required folder changed or cannot be opened safely.") }
            defer { close(current) }
            var now = stat()
            guard fstat(current, &now) == 0, Self.safe(now), info.st_dev == now.st_dev, info.st_ino == now.st_ino else {
                throw Fault("A required folder changed. Refresh before making changes.")
            }
            try AgentEngine.checkACL(current)
            if writable, now.st_flags & AgentEngine.lockedFlags != 0 || faccessat(current, ".", W_OK | X_OK, 0) != 0 {
                throw Fault("A startup folder is locked or not writable. No file was moved.")
            }
        }
    }

    private struct JobFile {
        let label: String
        let folder: Folder
        let handle: FileHandle // Keep the checked inode alive through the operation.
        let info: stat
        let executable: String?
        let schedule: String
        let disabled: Bool
        var name: String { label + ".plist" }
        func path(in folder: Folder) -> String { folder.path + "/" + name }

        static func read(_ label: String, from folder: Folder) throws -> JobFile? {
            let name = label + ".plist"
            var found = stat()
            if fstatat(folder.fd, name, &found, AT_SYMLINK_NOFOLLOW) != 0 {
                if errno == ENOENT { return nil }
                throw Fault("Cannot inspect the startup file.")
            }
            try check(found)
            let fd = openat(folder.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw Fault("Cannot safely open the startup file.") }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_dev == found.st_dev, info.st_ino == found.st_ino else { throw Fault("The startup file changed during inspection.") }
            try check(info)
            guard info.st_size > 0, info.st_size <= 1_048_576 else { throw Fault("The startup file is empty or too large to inspect safely.") }
            let plist: [String: Any]
            do {
                guard let bytes = try handle.read(upToCount: Int(info.st_size) + 1), bytes.count == Int(info.st_size),
                      let dictionary = try PropertyListSerialization.propertyList(from: bytes, options: [], format: nil) as? [String: Any] else {
                    throw Fault("Cannot read this startup file as a property list.")
                }
                plist = dictionary
            } catch { throw Fault("Cannot read this startup file as a property list.") }
            guard plist["Label"] as? String == label else { throw Fault("The label inside the startup file does not match its filename.") }
            let program = (plist["Program"] as? String) ?? ((plist["ProgramArguments"] as? [Any])?.first as? String)
            guard let program, !program.isEmpty else { throw Fault("This file does not specify a standalone LaunchAgent executable.") }
            let entry = JobFile(label: label, folder: folder, handle: handle, info: info,
                                executable: safeExecutable(program), schedule: AgentEngine.schedule(plist),
                                disabled: plist["Disabled"] as? Bool ?? false)
            try entry.verify(in: folder)
            return entry
        }

        private static func check(_ info: stat) throws {
            guard info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), info.st_nlink == 1 else { throw Fault("The startup file must be a regular file, not a symlink or hard link.") }
            guard info.st_uid == getuid(), info.st_mode & 0o7022 == 0 else { throw Fault("The startup file has unsafe permissions or a different owner.") }
        }

        private static func safeExecutable(_ path: String) -> String? {
            guard path.hasPrefix("/"), path.utf8.count < Int(MAXPATHLEN), path.rangeOfCharacter(from: .controlCharacters) == nil,
                  path.rangeOfCharacter(from: .newlines) == nil, FileManager.default.isExecutableFile(atPath: path) else { return nil }
            var metadata = stat()
            guard stat(path, &metadata) == 0, metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG) else { return nil }
            return path
        }

        func verify(in folder: Folder) throws {
            try folder.verify()
            var now = stat()
            guard fstatat(folder.fd, name, &now, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_dev == now.st_dev, info.st_ino == now.st_ino, info.st_size == now.st_size,
                  info.st_mtimespec.tv_sec == now.st_mtimespec.tv_sec, info.st_mtimespec.tv_nsec == now.st_mtimespec.tv_nsec else {
                throw Fault("The startup file changed. Refresh before making changes.")
            }
            try Self.check(now)
            try AgentEngine.checkACL(handle.fileDescriptor)
            // A case-insensitive volume may open a different spelling of the requested name.
            var diskPath = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            let identified = diskPath.withUnsafeMutableBytes { fcntl(handle.fileDescriptor, F_GETPATH, $0.baseAddress!) }
            guard identified == 0, String(cString: diskPath).split(separator: "/").last == Substring(name) else {
                throw Fault("The startup filename does not exactly match the service label.")
            }
        }

        func prepareMove(from source: Folder, to destination: Folder) throws {
            try verify(in: source)
            try source.verify(writable: true)
            try destination.verify(writable: true)
            var current = stat()
            guard fstat(handle.fileDescriptor, &current) == 0, current.st_flags & AgentEngine.lockedFlags == 0 else { throw Fault("The startup file is locked and cannot be moved.") }
            guard source.info.st_dev == destination.info.st_dev else { throw Fault("LaunchAgents and the archive must be on the same volume. No file was moved.") }
            var existing = stat()
            guard fstatat(destination.fd, name, &existing, AT_SYMLINK_NOFOLLOW) < 0, errno == ENOENT else { throw Fault("The destination already exists or cannot be checked. Nothing will be overwritten.") }
        }

        func move(from source: Folder, to destination: Folder) throws {
            try prepareMove(from: source, to: destination)
            // Unlike FileManager.moveItem, this cannot copy/delete across volumes or overwrite a late arrival.
            guard renameatx_np(source.fd, name, destination.fd, name, UInt32(RENAME_EXCL)) == 0 else { throw Fault("Could not move the startup file. No destination file was overwritten.") }
        }
    }

    private static func schedule(_ plist: [String: Any]) -> String {
        var triggers: [String] = []
        if let interval = plist["StartInterval"] as? Int, interval > 0 {
            let (amount, unit): (Int, String)
            if interval % 86_400 == 0 { (amount, unit) = (interval / 86_400, "day") }
            else if interval % 3_600 == 0 { (amount, unit) = (interval / 3_600, "hour") }
            else if interval % 60 == 0 { (amount, unit) = (interval / 60, "minute") }
            else { (amount, unit) = (interval, "second") }
            triggers.append(amount == 1 ? "Every \(unit)" : "Every \(amount) \(unit)s")
        }
        if let value = plist["StartCalendarInterval"] {
            if let rule = value as? [String: Int] { triggers.append(calendar(rule)) }
            else if let rules = value as? [[String: Int]], rules.count == 1 { triggers.append(calendar(rules[0])) }
            else if let rules = value as? [[String: Int]], !rules.isEmpty { triggers.append("\(rules.count) calendar schedules") }
            else { triggers.append("Calendar schedule") }
        }
        if plist["KeepAlive"] as? Bool == true { triggers.append("Kept running") }
        else if let conditions = plist["KeepAlive"] as? [String: Any], !conditions.isEmpty { triggers.append("Kept running when needed") }
        else if plist["RunAtLoad"] as? Bool == true { triggers.append("At login or load") }
        return triggers.isEmpty ? "On demand" : triggers.joined(separator: " · ")
    }

    private static func calendar(_ rule: [String: Int]) -> String {
        guard rule.keys.allSatisfy({ ["Month", "Day", "Weekday", "Hour", "Minute"].contains($0) }) else { return "Calendar schedule" }
        let month = rule["Month"], day = rule["Day"], weekday = rule["Weekday"], hour = rule["Hour"], minute = rule["Minute"]
        guard month.map({ (1...12).contains($0) }) ?? true, day.map({ (1...31).contains($0) }) ?? true,
              weekday.map({ (0...7).contains($0) }) ?? true, hour.map({ (0...23).contains($0) }) ?? true,
              minute.map({ (0...59).contains($0) }) ?? true else { return "Calendar schedule" }
        let monthName = month.map { Calendar(identifier: .gregorian).monthSymbols[$0 - 1] }
        let dayName = day.map { n in monthName.map { "\($0) \(n)" } ?? "Day \(n) of each month" }
        let days = ["Sundays", "Mondays", "Tuesdays", "Wednesdays", "Thursdays", "Fridays", "Saturdays"]
        let weekdayName = weekday.map { days[$0 % 7] + (monthName.map { " in \($0)" } ?? "") }
        // launchd treats Day and Weekday as alternatives, not an intersection.
        let date: String?
        if let dayName, let weekdayName { date = dayName + " or " + weekdayName }
        else { date = dayName ?? weekdayName ?? monthName.map { "Daily in \($0)" } }
        if let hour, let minute { return (date ?? "Daily") + String(format: " at %02d:%02d", hour, minute) }
        let frequency: String
        if let minute { frequency = String(format: "Hourly at :%02d", minute) }
        else if let hour { frequency = String(format: "Every minute from %02d:00 to %02d:59", hour, hour) }
        else { frequency = "Every minute" }
        return date.map { $0 + ": " + frequency.lowercased() } ?? frequency
    }
}
