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
            let after = retryAfter.flatMap { TimeInterval($0.trimmingCharacters(in: .whitespaces)) }
                .map { min(max($0, 0), BackoffPolicy.maximum) }
            return .retryLater(after: after, message: "HTTP \(status)")
        }
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
        /// After a glucose store: long enough for the loop that normally follows the reading to end
        /// and replace this with the earlier loop-end shipment; ships anyway when no loop runs.
        static let fallbackDelay: TimeInterval = 90
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
    /// A forced request (Save / Send now) that arrived while a shipment was running: runs right after it.
    private var rerunRequested = false
    private var lastAttempt: Date = .distantPast
    private var backoffInterval: TimeInterval?
    private var backoffUntil: Date?
    private var authFailed = false
    private var limit: Int
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
        keychain.setValue(config.url, forKey: Config.urlKey)
        keychain.setValue(config.token, forKey: Config.tokenKey)
        defaults.set(config.enabled, forKey: Config.enabledKey)
        defaults.removeObject(forKey: Config.limitKey)
        lock.withLock {
            authFailed = false
            backoffUntil = nil
            backoffInterval = nil
            limit = Config.defaultLimit
            if !config.enabled, sleeping {
                pendingShipment?.cancel()
                pendingShipment = nil
                sleeping = false
                pendingToken = UUID()
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

    private func requestShipment(force: Bool, delay: TimeInterval) {
        guard force || defaults.bool(forKey: Config.enabledKey) else { return }
        let now = Date()
        let due = now.addingTimeInterval(delay)
        let scheduled: Bool = lock.withLock {
            if !force {
                if authFailed { return false }
                if let until = backoffUntil, until > now { return false }
                if now.timeIntervalSince(lastAttempt) < Config.minInterval { return false }
            }
            if pendingShipment != nil {
                // A shipment that is already running is never cancelled (a forced request runs
                // after it). A sleeping one is replaced only by an earlier (or a forced) request,
                // so a loop end wins over the fallback.
                if !sleeping {
                    if force { rerunRequested = true }
                    return false
                }
                guard force || due < pendingDue else { return false }
                pendingShipment?.cancel()
            }
            let token = UUID()
            pendingToken = token
            pendingDue = due
            sleeping = true
            pendingShipment = Task { [weak self] in
                if delay > 0 {
                    try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
                guard let self, self.startShipping(token) else { return }
                await self.ship(force: force)
                self.finishShipping(token)
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
        let rerun: Bool = lock.withLock {
            guard token == pendingToken else { return false }
            pendingShipment = nil
            let rerun = rerunRequested
            rerunRequested = false
            return rerun
        }
        if rerun {
            requestShipment(force: true, delay: 0)
        }
    }

    // MARK: - Shipping

    private func ship(force: Bool) async {
        // Same shape as APSManager.loop(): the handler runs on the main thread.
        var taskID: UIBackgroundTaskIdentifier = .invalid
        taskID = await UIApplication.shared.beginBackgroundTask(withName: "LogShipper") {
            if taskID != .invalid {
                UIApplication.shared.endBackgroundTask(taskID)
                taskID = .invalid
            }
        }

        await performShipment(force: force)

        if taskID != .invalid {
            await UIApplication.shared.endBackgroundTask(taskID)
            taskID = .invalid
        }
    }

    private func performShipment(force: Bool) async {
        guard force || reachabilityManager.isReachable else {
            os_log("No network, skipped", log: log, type: .debug)
            return
        }
        let config = self.config
        if !force, !config.enabled {
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
                version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?",
                build: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?",
                sha: BuildDetails.shared.trioCommitSHA
            ),
            sentAt: ISO8601DateFormatter().string(from: now),
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
            outcome = .retryLater(after: nil, message: error.localizedDescription)
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
                      item.to > sent.batch.from
                else { continue }
                var next = sent.next
                next.offset = min(item.to, sent.batch.to)
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
                // Grow back after a 413 (one doubling per success, up to the default).
                let grown = min(Config.defaultLimit, limit * 2)
                let changed = grown != limit
                limit = grown
                return (had, changed ? grown : nil)
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

    private func loadStates() -> [String: LogTailReader.StreamState] {
        guard let data = defaults.data(forKey: Config.stateKey),
              let states = try? JSONDecoder().decode([String: LogTailReader.StreamState].self, from: data)
        else { return [:] }
        return states
    }

    private func saveStates(_ states: [String: LogTailReader.StreamState]) {
        if let data = try? JSONEncoder().encode(states) {
            defaults.set(data, forKey: Config.stateKey)
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
