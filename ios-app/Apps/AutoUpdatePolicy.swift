import Foundation

/// Pure decision logic for Mirsa's optional automatic self update.
/// Setting is OFF by default. State lives in UserDefaults so a relaunch
/// (the install replaces the app) can never loop on the same build.
struct AutoUpdatePolicy {
    static let enabledKey = "mirsa.autoUpdate.enabled"
    static let minCheckInterval: TimeInterval = 15 * 60
    static let maxAttemptsPerBuild = 3
    static let baseBackoff: TimeInterval = 15 * 60
    static let maxBackoff: TimeInterval = 6 * 3600
    /// An install that was started but never confirmed is considered in flight this long.
    static let pendingWindow: TimeInterval = 30 * 60

    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    var enabled: Bool {
        get { defaults.object(forKey: Self.enabledKey) as? Bool ?? false }
        nonmutating set { defaults.set(newValue, forKey: Self.enabledKey) }
    }
    private var lastCheck: Date? { defaults.object(forKey: "mirsa.autoUpdate.lastCheck") as? Date }
    private var nextRetry: Date? { defaults.object(forKey: "mirsa.autoUpdate.nextRetry") as? Date }
    private var attemptBuild: Int { defaults.integer(forKey: "mirsa.autoUpdate.attemptBuild") }
    private var attemptAt: Date? { defaults.object(forKey: "mirsa.autoUpdate.attemptAt") as? Date }
    private var attempts: Int { defaults.integer(forKey: "mirsa.autoUpdate.attempts") }

    /// Whether a passive feed check may run now. Never when OFF.
    func shouldCheck(now: Date = Date()) -> Bool {
        guard enabled else { return false }
        if let n = nextRetry, n > now { return false }
        if let l = lastCheck, now.timeIntervalSince(l) < Self.minCheckInterval { return false }
        return true
    }
    func recordCheck(now: Date = Date()) { defaults.set(now, forKey: "mirsa.autoUpdate.lastCheck") }

    /// Whether the given feed build should be installed automatically.
    func shouldInstall(build: Int, current: Int, now: Date = Date()) -> Bool {
        guard enabled, build > current else { return false }
        if attemptBuild == build {
            if let a = attemptAt, now.timeIntervalSince(a) < Self.pendingWindow { return false }
            if attempts >= Self.maxAttemptsPerBuild { return false }
            if let n = nextRetry, n > now { return false }
        }
        return true
    }
    func recordAttempt(build: Int, now: Date = Date()) {
        let n = attemptBuild == build ? attempts + 1 : 1
        defaults.set(build, forKey: "mirsa.autoUpdate.attemptBuild")
        defaults.set(n, forKey: "mirsa.autoUpdate.attempts")
        defaults.set(now, forKey: "mirsa.autoUpdate.attemptAt")
    }
    /// Failure (download, signing, install): bounded exponential backoff.
    func recordFailure(now: Date = Date()) {
        let n = max(attempts, 1)
        let delay = min(Self.baseBackoff * pow(2, Double(n - 1)), Self.maxBackoff)
        defaults.set(now.addingTimeInterval(delay), forKey: "mirsa.autoUpdate.nextRetry")
        defaults.removeObject(forKey: "mirsa.autoUpdate.attemptAt")
    }
    /// Turning the setting off clears all pending state.
    func reset() {
        for k in ["lastCheck", "nextRetry", "attemptBuild", "attemptAt", "attempts"] {
            defaults.removeObject(forKey: "mirsa.autoUpdate.\(k)")
        }
    }
}
