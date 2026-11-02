import Combine
import Foundation
import os.log
import Swinject
import UIKit

/// Ships new lines of Trio's and DanaKit's log files to our own server (t1d-monitor) after every
/// loop cycle. Off by default; the loop never waits for it; a failure here changes nothing in Trio.
/// Server contract: `docs/log-ingest-spec.md`.
struct LogShipperConfig: Equatable {
    var enabled = false
    var url = ""
    var token = ""
}

struct LogShipperStatus: Equatable {
    var lastAttempt: Date?
    var lastSuccess: Date?
    var lastSentBytes = 0
    var lastError: String?
    var backoffUntil: Date?
    var authFailed = false
}

protocol LogShipper: AnyObject {
    var config: LogShipperConfig { get }
    func save(_ config: LogShipperConfig)
    var status: CurrentValueSubject<LogShipperStatus, Never> { get }
    /// Manual "Send now" (ignores the interval and the backoff).
    func shipNow()
}

// MARK: - Wire format

struct LogShipmentPayload: Encodable {
    struct App: Encodable {
        let version: String
        let build: String
        let sha: String
    }

    struct Batch: Encodable {
        let stream: String
        let fileId: String
        let from: Int
        let to: Int
        let gapBefore: Bool
        let text: String

        enum CodingKeys: String, CodingKey {
            case stream
            case fileId = "file_id"
            case from
            case to
            case gapBefore = "gap_before"
            case text
        }
    }

    let v = 1
    let installId: String
    let app: App
    let sentAt: String
    let batches: [Batch]

    enum CodingKeys: String, CodingKey {
        case v
        case installId = "install_id"
        case app
        case sentAt = "sent_at"
        case batches
    }
}

enum LogShipmentCodec {
    static let contentEncoding = "deflate-raw"

    /// JSON, then raw DEFLATE (RFC 1951, what Apple's `.zlib` produces: no zlib header, no checksum).
    static func encode(_ payload: LogShipmentPayload) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let json = try encoder.encode(payload)
        return try (json as NSData).compressed(using: .zlib) as Data
    }

    static func decode(_ body: Data) throws -> Data {
        try (body as NSData).decompressed(using: .zlib) as Data
    }
}

struct LogShipmentAccepted: Decodable, Equatable {
    let stream: String
    let fileId: String
    let to: Int

    enum CodingKeys: String, CodingKey {
        case stream
        case fileId = "file_id"
        case to
    }
}

enum LogShipperOutcome: Equatable {
    case accepted([LogShipmentAccepted])
    case unauthorized
    case tooLarge
    case retryLater(after: TimeInterval?, message: String)
}

enum LogShipperResponse {
    private struct Body: Decodable {
        let accepted: [LogShipmentAccepted]
    }

    static func parse(status: Int, retryAfter: String?, body: Data) -> LogShipperOutcome {
        switch status {
        case 200 ... 299:
            if let decoded = try? JSONDecoder().decode(Body.self, from: body) {
                return .accepted(decoded.accepted)
            }
            return .retryLater(after: nil, message: "HTTP \(status): unreadable response")
        case 401,
             403:
            return .unauthorized
        case 413:
            return .tooLarge
        default:
            return .retryLater(after: retryAfterInterval(retryAfter), message: "HTTP \(status)")
        }
    }

    private static let httpDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter
    }()

    /// `Retry-After` as delay seconds or an HTTP date (RFC 9110); clamped to the backoff ceiling.
    static func retryAfterInterval(_ header: String?, now: Date = Date()) -> TimeInterval? {
        guard let value = header?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        let seconds: TimeInterval
        if let number = TimeInterval(value) {
            guard number.isFinite else { return nil } // "nan" / "inf" parse as numbers
            seconds = number
        } else if let date = httpDateFormatter.date(from: value) {
            seconds = date.timeIntervalSince(now)
        } else {
            return nil
        }
        return min(max(seconds, 0), BackoffPolicy.maximum)
    }
}

enum BackoffPolicy {
    static let initial: TimeInterval = 5 * 60
    static let maximum: TimeInterval = 60 * 60

    static func next(after previous: TimeInterval?) -> TimeInterval {
        guard let previous else { return initial }
        return min(maximum, max(initial, previous * 2))
    }
}

// MARK: - Service

final class BaseLogShipper: LogShipper, Injectable {
    enum Config {
        static let urlKey = "LogShipper.url"
        static let tokenKey = "LogShipper.token"
        static let enabledKey = "LogShipper.enabled"
        static let stateKey = "LogShipper.state"
        static let limitKey = "LogShipper.limit"
        static let installIdKey = "LogShipper.installId"
        /// Loop cycles are 5 min and the two triggers of one cycle coalesce while sleeping; this only
        /// stops a second shipment right after one (e.g. a glucose backfill after the loop end).
        static let minInterval: TimeInterval = 60
        /// After a loop ends: lets DanaKit's log writer (background queue) flush the cycle's last lines.
        static let settleDelay: TimeInterval = 10
        /// After a glucose store: delay + request must fit in the ~30 s of background time iOS
        /// grants. If a loop is running when it fires, it steps aside (the loop end ships).
        static let fallbackDelay: TimeInterval = 15
        /// A deferred request that could not start inside the background grant is dropped
        /// (the next trigger ships) rather than slept through with the process suspended.
        static let maxDelay: TimeInterval = 15
        static let requestTimeout: TimeInterval = 15
        static let defaultLimit = 1_048_576
        static let minimumLimit = 65536
    }

    @Injected() private var apsManager: APSManager!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var keychain: Keychain!
    @Injected() private var reachabilityManager: ReachabilityManager!

    private struct LogStream {
        let name: String
        let reader: LogTailReader
    }

    private typealias Shipment = (stream: String, batch: LogTailReader.Batch, next: LogTailReader.StreamState)

    let status = CurrentValueSubject<LogShipperStatus, Never>(LogShipperStatus())

    private let defaults = UserDefaults.standard
    private let log = OSLog(subsystem: Bundle.main.bundleIdentifier ?? "Trio", category: "LogShipper")
    private var streams: [LogStream] = []
    private var subscriptions = Set<AnyCancellable>()

    /// All scheduling state lives behind this one lock. One shipment exists at a time: it is
    /// `sleeping` (its delay, may be replaced by an earlier or a forced request) or shipping (never
    /// cancelled). `backoffUntil` / `authFailed` / `currentStatus` are the single source of what the
    /// UI sees; `publishStatus` copies them out.
    private let lock = NSLock()
    private var pendingShipment: Task<Void, Never>?
    private var pendingToken = UUID()
    private var pendingDue: Date = .distantPast
    private var sleeping = false
    /// A request that arrived while a shipment was running: runs right after it (nil = none;
    /// the value is its `force`). A loop end during a long shipment is deferred, never dropped.
    private var rerunRequested: Bool?
    private var lastAttempt: Date = .distantPast
    private var backoffInterval: TimeInterval?
    private var backoffUntil: Date?
    private var authFailed = false
    private var limit: Int
    /// Successful shipments since the last 413; the limit grows back only after a few in a row.
    private var successesSinceTooLarge = 0
    private var currentStatus = LogShipperStatus()

    init(resolver: Resolver) {
        let stored = UserDefaults.standard.integer(forKey: Config.limitKey)
        limit = stored >= Config.minimumLimit ? stored : Config.defaultLimit
        injectServices(resolver)

        let documents = SimpleLogReporter.getDocumentsDirectory()
        streams = [
            LogStream(name: "trio", reader: LogTailReader(
                currentURL: URL(fileURLWithPath: SimpleLogReporter.logFile),
                previousURL: URL(fileURLWithPath: SimpleLogReporter.logFilePrev)
            )),
            LogStream(name: "dana", reader: LogTailReader(
                currentURL: documents.appendingPathComponent("danakit/dana_log.txt"),
                previousURL: documents.appendingPathComponent("danakit/dana_log_prev.txt")
            ))
        ]

        // Regular trigger: the end of every loop cycle, success or failure.
        apsManager.isLooping
            .dropFirst()
            .removeDuplicates()
            .filter { !$0 }
            .sink { [weak self] _ in self?.requestShipment(force: false, delay: Config.settleDelay) }
            .store(in: &subscriptions)

        // Fallback: every glucose store, so shipping goes on while no loop starts (pump unreachable).
        glucoseStorage.updatePublisher
            .sink { [weak self] _ in self?.requestShipment(force: false, delay: Config.fallbackDelay) }
            .store(in: &subscriptions)
    }

    // MARK: - LogShipper

    var config: LogShipperConfig {
        LogShipperConfig(
            enabled: defaults.bool(forKey: Config.enabledKey),
            url: keychain.getValue(String.self, forKey: Config.urlKey) ?? "",
            token: keychain.getValue(String.self, forKey: Config.tokenKey) ?? ""
        )
    }

    func save(_ config: LogShipperConfig) {
        let wasEnabled = defaults.bool(forKey: Config.enabledKey)
        // Pasted values often carry a trailing newline; "Bearer abc\n" is a 401.
        keychain.setValue(config.url.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Config.urlKey)
        keychain.setValue(config.token.trimmingCharacters(in: .whitespacesAndNewlines), forKey: Config.tokenKey)
        defaults.set(config.enabled, forKey: Config.enabledKey)
        defaults.removeObject(forKey: Config.limitKey)
        lock.withLock {
            authFailed = false
            backoffUntil = nil
            backoffInterval = nil
            limit = Config.defaultLimit
            if !config.enabled {
                rerunRequested = nil
                if sleeping {
                    pendingShipment?.cancel()
                    pendingShipment = nil
                    sleeping = false
                    pendingToken = UUID()
                }
            }
        }
        publishStatus { $0.lastError = nil }
        if wasEnabled != config.enabled {
            debug(.service, "LogShipper \(config.enabled ? "enabled" : "disabled")")
        }
        if config.enabled {
            requestShipment(force: true, delay: 0)
        }
    }

    func shipNow() {
        requestShipment(force: true, delay: 0)
    }

    // MARK: - Scheduling

    /// `force` (Save / Send now) skips the interval, the backoff and the auth pause — never the
    /// enabled flag: nothing leaves the phone while "Send logs" is off. `rerun` is the request
    /// that waited for a running shipment: it skips the interval too (it was already deferred).
    private func requestShipment(force: Bool, delay: TimeInterval, rerun: Bool = false) {
        guard defaults.bool(forKey: Config.enabledKey) else { return }
        let now = Date()
        var delay = delay
        let scheduled: Bool = lock.withLock {
            if !force {
                if authFailed { return false }
                if let until = backoffUntil, until > now { return false }
                if !rerun {
                    // Too soon after the last shipment: defer to the end of the interval, as long
                    // as that still fits in the background grant.
                    delay = max(delay, lastAttempt.addingTimeInterval(Config.minInterval).timeIntervalSince(now))
                    if delay > Config.maxDelay { return false }
                }
            }
            let due = now.addingTimeInterval(delay)
            if pendingShipment != nil {
                // A shipment that is already running is never cancelled: the request runs after
                // it. A sleeping one is replaced only by an earlier (or a forced) request, so a
                // loop end wins over the fallback; one whose due time has passed was suspended
                // with the process and may be replaced too.
                if !sleeping {
                    rerunRequested = (rerunRequested ?? false) || force
                    return false
                }
                guard force || due < pendingDue || pendingDue < now else { return false }
                pendingShipment?.cancel()
            }
            let token = UUID()
            pendingToken = token
            pendingDue = due
            sleeping = true
            pendingShipment = Task { [weak self] in
                // Background time is taken BEFORE the delay: once the loop's own background task
                // ends, iOS suspends the process within seconds, and a shipment sleeping without
                // one would slip to the next BLE wake-up — i.e. into the next loop. Same shape as
                // APSManager.loop(): the expiration handler runs on the main thread.
                var taskID: UIBackgroundTaskIdentifier = .invalid
                taskID = await UIApplication.shared.beginBackgroundTask(withName: "LogShipper") {
                    if taskID != .invalid {
                        UIApplication.shared.endBackgroundTask(taskID)
                        taskID = .invalid
                    }
                }
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                if let self, self.startShipping(token) {
                    // A fallback that fires while a loop is running steps aside: the loop end
                    // ships the complete cycle (unless `force`).
                    if force || !self.apsManager.isLooping.value {
                        await self.performShipment(force: force)
                    } else {
                        os_log("Loop in progress, leaving the shipment to its end", log: self.log, type: .debug)
                    }
                    self.finishShipping(token)
                }
                if taskID != .invalid {
                    await UIApplication.shared.endBackgroundTask(taskID)
                    taskID = .invalid
                }
            }
            return true
        }
        if scheduled {
            os_log("Shipment scheduled in %.0f s (force: %{public}@)", log: log, type: .debug, delay, String(force))
        }
    }

    /// False when this task was replaced or cancelled while it slept.
    private func startShipping(_ token: UUID) -> Bool {
        lock.withLock {
            guard token == pendingToken, !Task.isCancelled else { return false }
            sleeping = false
            return true
        }
    }

    private func finishShipping(_ token: UUID) {
        let rerun: Bool? = lock.withLock {
            guard token == pendingToken else { return nil }
            pendingShipment = nil
            let rerun = rerunRequested
            rerunRequested = nil
            return rerun
        }
        if let force = rerun {
            requestShipment(force: force, delay: force ? 0 : Config.settleDelay, rerun: true)
        }
    }

    // MARK: - Shipping

    private func performShipment(force: Bool) async {
        guard force || reachabilityManager.isReachable else {
            os_log("No network, skipped", log: log, type: .debug)
            return
        }
        let config = self.config
        guard config.enabled else {
            return // disabled while this shipment slept: nothing to report
        }
        // https only: the body is the child's health data plus the token.
        guard let url = URL(string: config.url), url.scheme?.lowercased() == "https", url.host != nil,
              !config.token.isEmpty
        else {
            publishStatus { $0.lastError = "Not configured (needs an https:// URL and a token)" }
            return
        }

        let now = Date()
        lock.withLock { lastAttempt = now }
        publishStatus { $0.lastAttempt = now }

        var states = loadStates()
        let limit = lock.withLock { self.limit }
        var shipments: [Shipment] = []
        for stream in streams {
            let result = stream.reader.next(state: states[stream.name] ?? LogTailReader.StreamState(), limit: limit)
            if let batch = result.batch {
                shipments.append((stream: stream.name, batch: batch, next: result.stateAfterSuccess))
            } else {
                states[stream.name] = result.stateAfterSuccess
            }
        }
        saveStates(states)
        guard !shipments.isEmpty else {
            os_log("Nothing new", log: log, type: .debug)
            return
        }

        let payload = LogShipmentPayload(
            installId: installId,
            app: LogShipmentPayload.App(
                version: Bundle.main.releaseVersionNumber ?? "?",
                build: Bundle.main.buildVersionNumber ?? "?",
                sha: BuildDetails.shared.trioCommitSHA
            ),
            sentAt: TrioEventNote.isoFormatter.string(from: now),
            batches: shipments.map {
                LogShipmentPayload.Batch(
                    stream: $0.stream,
                    fileId: $0.batch.fileId,
                    from: $0.batch.from,
                    to: $0.batch.to,
                    gapBefore: $0.batch.gapBefore,
                    text: LogRedactor.redact(String(decoding: $0.batch.data, as: UTF8.self))
                )
            }
        )

        let body: Data
        do {
            body = try LogShipmentCodec.encode(payload)
        } catch {
            publishStatus { $0.lastError = "Encoding failed: \(error.localizedDescription)" }
            return
        }

        var request = URLRequest(url: url, timeoutInterval: Config.requestTimeout)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("Bearer \(config.token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(LogShipmentCodec.contentEncoding, forHTTPHeaderField: "Content-Encoding")
        request.setValue(LogShipmentCodec.contentEncoding, forHTTPHeaderField: "X-Trio-Log-Encoding")

        let outcome: LogShipperOutcome
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let http = response as? HTTPURLResponse
            outcome = LogShipperResponse.parse(
                status: http?.statusCode ?? 0,
                retryAfter: http?.value(forHTTPHeaderField: "Retry-After"),
                body: data
            )
        } catch {
            // Transport errors are mostly ours (iOS suspended the process mid-request, no route):
            // record them, but do not punish the server with a backoff — the next trigger retries.
            publishStatus { $0.lastError = error.localizedDescription }
            os_log("Request failed: %{public}@", log: log, type: .error, error.localizedDescription)
            return
        }

        apply(outcome, shipments: shipments, states: &states, sentBytes: body.count)
        saveStates(states)
    }

    private func apply(
        _ outcome: LogShipperOutcome,
        shipments: [Shipment],
        states: inout [String: LogTailReader.StreamState],
        sentBytes: Int
    ) {
        switch outcome {
        case let .accepted(items):
            var advanced = 0
            for item in items {
                guard let sent = shipments.first(where: { $0.stream == item.stream && $0.batch.fileId == item.fileId }),
                      let offset = sent.batch.lineAlignedOffset(upTo: item.to)
                else { continue }
                var next = sent.next
                next.offset = offset
                states[item.stream] = next
                advanced += 1
            }
            guard advanced > 0 else {
                // A 2xx that moves nothing would re-send the same bytes forever behind a green status.
                apply(.retryLater(after: nil, message: "HTTP 2xx accepted none of \(shipments.count) batch(es)"),
                      shipments: shipments, states: &states, sentBytes: sentBytes)
                return
            }
            let (leftBackoff, newLimit): (Bool, Int?) = lock.withLock {
                let had = backoffUntil != nil
                backoffUntil = nil
                backoffInterval = nil
                authFailed = false
                // Grow back after a 413, but only after three successes in a row — doubling on the
                // very next one would alternate 413 / success during a catch-up.
                successesSinceTooLarge += 1
                guard limit < Config.defaultLimit, successesSinceTooLarge >= 3 else { return (had, nil) }
                successesSinceTooLarge = 0
                limit = min(Config.defaultLimit, limit * 2)
                return (had, limit)
            }
            if let newLimit {
                defaults.set(newLimit, forKey: Config.limitKey)
            }
            if leftBackoff {
                debug(.service, "LogShipper: server reachable again")
            }
            publishStatus {
                $0.lastSuccess = Date()
                $0.lastSentBytes = sentBytes
                $0.lastError = nil
            }
            os_log("Shipped %d batch(es), %d bytes", log: log, type: .info, advanced, sentBytes)

        case .unauthorized:
            lock.withLock { authFailed = true }
            publishStatus { $0.lastError = "Server refused the token (401)" }
            debug(.service, "LogShipper: server refused the token; shipping paused until the settings change")

        case .tooLarge:
            let newLimit: Int = lock.withLock {
                limit = max(Config.minimumLimit, limit / 2)
                successesSinceTooLarge = 0
                return limit
            }
            defaults.set(newLimit, forKey: Config.limitKey)
            publishStatus { $0.lastError = "Shipment too large (413); limit now \(newLimit / 1024) KB" }
            debug(.service, "LogShipper: 413, limit lowered to \(newLimit) bytes")

        case let .retryLater(after, message):
            let (until, entered): (Date, Bool) = lock.withLock {
                let entered = backoffUntil == nil
                let interval = after ?? BackoffPolicy.next(after: backoffInterval)
                backoffInterval = interval
                let until = Date().addingTimeInterval(interval)
                backoffUntil = until
                return (until, entered)
            }
            publishStatus { $0.lastError = message }
            if entered {
                debug(.service, "LogShipper: \(message); backing off")
            }
            os_log("Failed: %{public}@, retry after %@", log: log, type: .error, message, until as NSDate)
        }
    }

    // MARK: - Persistence

    private var installId: String {
        if let id = defaults.string(forKey: Config.installIdKey) { return id }
        let id = UUID().uuidString.lowercased()
        defaults.set(id, forKey: Config.installIdKey)
        return id
    }

    /// One key per stream, so an unreadable state resets only that stream (from the start of the
    /// current file; the server's overlap rule absorbs the re-send).
    private func loadStates() -> [String: LogTailReader.StreamState] {
        var states: [String: LogTailReader.StreamState] = [:]
        for stream in streams {
            if let data = defaults.data(forKey: Config.stateKey + "." + stream.name),
               let state = try? JSONDecoder().decode(LogTailReader.StreamState.self, from: data)
            {
                states[stream.name] = state
            }
        }
        return states
    }

    private func saveStates(_ states: [String: LogTailReader.StreamState]) {
        for (name, state) in states {
            if let data = try? JSONEncoder().encode(state) {
                defaults.set(data, forKey: Config.stateKey + "." + name)
            }
        }
    }

    /// Mutates the status under `lock` (copying `backoffUntil` / `authFailed` from the scheduling
    /// state so the two never disagree) and sends it after the lock is released.
    private func publishStatus(_ change: (inout LogShipperStatus) -> Void) {
        let value: LogShipperStatus = lock.withLock {
            change(&currentStatus)
            currentStatus.backoffUntil = backoffUntil
            currentStatus.authFailed = authFailed
            return currentStatus
        }
        status.send(value)
    }
}
