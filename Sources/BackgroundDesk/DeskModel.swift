import SwiftUI

// launchctl and filesystem access run off the main actor. Serialize mutations and reads.
private actor JobWorker {
    private let engine = AgentEngine()
    func snapshot(_ labels: [String]) throws -> [ManagedJob] { try engine.snapshot(labels: labels) }
    func candidates() throws -> [String] { try engine.candidates() }
    func act(_ action: JobAction, _ label: String) throws { try engine.perform(action, label: label) }
}

@MainActor
final class DeskModel: ObservableObject {
    @Published private(set) var jobs: [ManagedJob] = []
    @Published private(set) var candidates: [String] = []
    @Published private(set) var busy = false
    @Published var errorMessage: String?

    private let worker = JobWorker()
    private let defaults = UserDefaults.standard
    private var labels: [String]
    private var refreshTask: Task<Void, Never>?

    init() {
        labels = Array(Set(UserDefaults.standard.stringArray(forKey: "trackedLabels") ?? [])).sorted()
    }

    func refresh() {
        guard !busy else { return }
        refreshTask?.cancel()
        let current = labels
        refreshTask = Task {
            do {
                let snapshot = try await worker.snapshot(current)
                if !Task.isCancelled { jobs = snapshot }
            } catch {
                if !Task.isCancelled { errorMessage = error.localizedDescription }
            }
        }
    }

    func loadCandidates() {
        guard !busy else { return }
        candidates = []
        busy = true
        Task {
            defer { busy = false }
            do { candidates = try await worker.candidates().filter { !labels.contains($0) }.sorted() }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func track(_ additions: [String]) {
        guard !busy else { return }
        let chosen = Set(additions).intersection(candidates)
        guard !chosen.isEmpty else { return }
        persist(Array(Set(labels).union(chosen)).sorted())
        candidates.removeAll { chosen.contains($0) }
        refresh()
    }

    func untrack(_ label: String) {
        guard !busy, labels.contains(label) else { return }
        if jobs.first(where: { $0.label == label })?.state == .archived {
            errorMessage = "Restore this job’s startup file before removing it from your list."
            return
        }
        persist(labels.filter { $0 != label })
        jobs.removeAll { $0.label == label }
        refresh()
    }

    func perform(_ action: JobAction, on job: ManagedJob) {
        guard !busy, labels.contains(job.label) else { return }
        refreshTask?.cancel()
        busy = true
        Task {
            do { try await worker.act(action, job.label) }
            catch { errorMessage = error.localizedDescription }
            busy = false
            refresh()
        }
    }

    private func persist(_ updated: [String]) {
        labels = updated
        defaults.set(updated, forKey: "trackedLabels")
    }
}
