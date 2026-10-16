import Foundation
import Security

/// One row of the thread status panel: a thread that is still in motion.
struct ThreadStatusRow: Equatable, Sendable {
    enum Light: Sendable {
        /// A run is going.
        case working
        /// Stopped, but a subagent, monitor or other background task will wake it.
        case waiting
        /// Blocked on an approval or answer from you (or one of its subagents).
        /// Shown gray like waiting; kept apart to sort first and explain why.
        case needsYou
    }

    let id: String
    let title: String
    /// The project's name, when T3 sent it.
    let project: String?
    let light: Light
    /// Short status: "Working", "Waiting on subagent", "Needs approval".
    let detail: String
    /// What it waits on, such as the subagent's task, when T3 names it.
    let note: String?
    /// When the current work started, for the elapsed time.
    let since: Date?
}

/// Live thread state from the T3 Code server running on this Mac.
///
/// Uses the same `orchestration.subscribeShell` stream as the T3 sidebar: one
/// shell snapshot, then a message per thread change. It never reads
/// transcripts. Access is a read-only (`orchestration:read`) bearer session
/// issued by the T3 CLI and kept in the login keychain.
@MainActor
final class T3ThreadFeed {
    enum State: Equatable {
        case connecting
        case live([ThreadStatusRow])
        case offline(String)
        /// T3 revoked miced's session; waiting for the user to re-enable it.
        case revoked
    }

    var onChange: ((State) -> Void)?
    private(set) var state = State.connecting {
        didSet { if state != oldValue { onChange?(state) } }
    }

    private static let protocolVersion = 2
    private var threads: [String: ShellThread] = [:]
    private var projects: [String: String] = [:]
    private var runner: Task<Void, Never>?
    private var heardAt = Date()
    private let access = T3Access()

    func start() {
        guard runner == nil else { return }
        runner = Task { [weak self] in await self?.run() }
    }

    /// Issue a new session after T3 revoked the previous one.
    func reenableAccess() {
        guard state == .revoked else { return }
        access.requestReenable()
        state = .connecting
        start()
    }

    private func run() async {
        var delay: Double = 2
        var lastError = ""
        while !Task.isCancelled {
            do {
                try await connectOnce()
            } catch FeedError.revoked {
                // Stay stopped: retrying would only be refused again.
                threads = [:]
                state = .revoked
                runner = nil
                return
            } catch {
                // A connection that was live retries quickly; repeated failures back off.
                if case .live = state { delay = 2 }
                threads = [:]
                state = .offline((error as? FeedError)?.message ?? "T3 is not reachable")
                // Error descriptions can carry the socket URL, and with it the ticket.
                let summary = error is FeedError ? "\(error)" : "\((error as NSError).domain) \((error as NSError).code)"
                if summary != lastError {
                    lastError = summary
                    logLine("T3 feed: \(summary)")
                }
            }
            try? await Task.sleep(for: .seconds(delay))
            delay = min(delay * 2, 30)
        }
    }

    private func connectOnce() async throws {
        let origin = Self.serverOrigin()
        let descriptor: EnvironmentDescriptor = try await Self.getJSON(origin.appending(path: ".well-known/t3/environment"))
        guard descriptor.orchestrationProtocolVersion == Self.protocolVersion else {
            throw FeedError.unsupported(descriptor.orchestrationProtocolVersion)
        }

        let token = try await access.token(environmentId: descriptor.environmentId)
        var ticketRequest = URLRequest(url: origin.appending(path: "api/auth/websocket-ticket"))
        ticketRequest.httpMethod = "POST"
        ticketRequest.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (ticketData, ticketResponse) = try await URLSession.shared.data(for: ticketRequest)
        if (ticketResponse as? HTTPURLResponse)?.statusCode == 401 {
            throw access.rejected(token: token, environmentId: descriptor.environmentId)
        }
        guard (ticketResponse as? HTTPURLResponse)?.statusCode == 200 else { throw FeedError.badResponse }
        let ticket = try JSONDecoder().decode(WebSocketTicket.self, from: ticketData).ticket

        var socketURL = URLComponents(url: origin.appending(path: "ws"), resolvingAgainstBaseURL: false)!
        socketURL.scheme = socketURL.scheme == "https" ? "wss" : "ws"
        socketURL.queryItems = [
            URLQueryItem(name: "wsTicket", value: ticket),
            URLQueryItem(name: "orchestrationProtocol", value: String(Self.protocolVersion)),
        ]
        let socket = URLSession.shared.webSocketTask(with: socketURL.url!)
        // The first message is the whole shell (a few MB with long histories).
        socket.maximumMessageSize = 256 << 20
        socket.resume()
        defer { socket.cancel(with: .goingAway, reason: nil) }

        try await send(["_tag": "Request", "id": "1", "tag": "orchestration.subscribeShell",
                        "payload": [String: String](), "headers": [[String]]()], on: socket)

        // A silent socket (sleeping Mac, frozen server) must not keep stale dots.
        heardAt = Date()
        let heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self, !Task.isCancelled else { return }
                if Date().timeIntervalSince(self.heardAt) > 35 { socket.cancel(with: .goingAway, reason: nil); return }
                try? await self.send(["_tag": "Ping"], on: socket)
            }
        }
        defer { heartbeat.cancel() }

        while true {
            let data: Data
            switch try await socket.receive() {
            case .data(let bytes): data = bytes
            case .string(let text): data = Data(text.utf8)
            @unknown default: continue
            }
            heardAt = Date()
            let message = try await Task.detached { try JSONDecoder().decode(RpcMessage.self, from: data) }.value
            switch message.tag {
            case "Chunk":
                try await send(["_tag": "Ack", "requestId": message.requestId ?? "1"], on: socket)
                for item in message.values ?? [] { apply(item) }
                publish()
            case "Exit", "Defect", "ClientProtocolError":
                if message.isAuthorizationFailure {
                    throw access.rejected(token: token, environmentId: descriptor.environmentId)
                }
                throw FeedError.streamEnded
            default:
                break
            }
        }
    }

    private func send(_ object: [String: Any], on socket: URLSessionWebSocketTask) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func apply(_ item: ShellStreamItem) {
        switch item.kind {
        case "snapshot":
            projects = Dictionary((item.snapshot?.projects ?? []).map { ($0.id, $0.title) }, uniquingKeysWith: { $1 })
            // Repository-identity refreshes carry projects only, with no threads.
            guard item.resolvedRepositoryIdentityRoots == nil else { return }
            threads = Dictionary((item.snapshot?.threads ?? []).map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        case "project.updated":
            if let project = item.project { projects[project.id] = project.title }
        case "project.removed":
            if let id = item.projectId { projects[id] = nil }
        case "thread.updated":
            guard let thread = item.thread else { return }
            threads[thread.id] = item.location == "archive" ? nil : thread
        case "thread.removed":
            if let id = item.threadId { threads[id] = nil }
        default:
            break
        }
    }

    private func publish() {
        state = .live(Self.workRows(Array(threads.values), projects: projects))
    }

    /// Threads still in motion, as T3's sidebar sees them: those its Working
    /// section folds (a live run, or stopped with a subagent, monitor or
    /// background task that will wake it), plus those blocked on an approval
    /// or answer. Finished, idle, failed and stopped threads are left out,
    /// pinned or not, and so are threads holding only commands such as a dev
    /// server. Subagent rows are hidden, as in T3; their requests show on the
    /// visible thread above them. Needs-you first, then T3's Working order.
    static func workRows(_ all: [ShellThread], projects: [String: String]) -> [ThreadStatusRow] {
        let subagentRequests = pendingSubagentRequests(all)
        let rows: [(ShellThread, ThreadStatusRow)] = all.compactMap { thread in
            guard thread.lineage?.relationshipToParent != "subagent", thread.archivedAt == nil,
                  thread.deletedAt == nil, let state = thread.workState(subagentRequest: subagentRequests[thread.id])
            else { return nil }
            let name = thread.title.trimmingCharacters(in: .whitespacesAndNewlines)
            return (thread, ThreadStatusRow(
                id: thread.id, title: name.isEmpty ? "Untitled" : name,
                project: thread.projectId.flatMap { projects[$0] }, light: state.light,
                detail: state.detail, note: state.note, since: state.since
            ))
        }
        return rows.sorted { a, b in
            let (left, right) = (a.1.light == .needsYou, b.1.light == .needsYou)
            if left != right { return left }
            if a.0.sentAt != b.0.sentAt { return a.0.sentAt > b.0.sentAt }
            return a.0.id < b.0.id
        }.map(\.1)
    }

    /// T3's `pendingSubagentRequestsByThread`: every thread above a subagent
    /// whose live run waits on the user carries the request. Approval wins.
    private static func pendingSubagentRequests(_ all: [ShellThread]) -> [String: String] {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        var requests: [String: String] = [:]
        for child in all {
            guard let kind = child.pendingRuntimeRequest?.kind, kind != "auth_refresh",
                  child.lineage?.relationshipToParent == "subagent", child.creationSource != "provider",
                  child.hasActivityRunStatus ? child.activityRunStatus != nil
                      : ["preparing", "starting", "running", "waiting"].contains(child.status)
            else { continue }
            let request = kind == "user_input" ? "user_input" : "approval"
            var seen: Set<String> = [child.id]
            var current: ShellThread? = child
            while current?.lineage?.relationshipToParent == "subagent",
                  let parentId = current?.lineage?.parentThreadId, !seen.contains(parentId) {
                seen.insert(parentId)
                if requests[parentId] != "approval" { requests[parentId] = request }
                current = byId[parentId]
            }
        }
        return requests
    }

    /// The desktop app records where its server listens.
    private static func serverOrigin() -> URL {
        let runtime = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: ".t3/userdata/server-runtime.json")
        if let data = try? Data(contentsOf: runtime),
           let info = try? JSONDecoder().decode(ServerRuntime.self, from: data),
           let url = URL(string: "http://127.0.0.1:\(info.port)/") {
            return url
        }
        return URL(string: "http://127.0.0.1:3773/")!
    }

    private static func getJSON<T: Decodable>(_ url: URL) async throws -> T {
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw FeedError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
}

enum FeedError: Error, Equatable {
    case unsupported(Int)
    case unauthorized
    case expired
    case revoked
    case noAccess(String)
    case badResponse
    case streamEnded

    var message: String {
        switch self {
        case .unsupported(let version): "T3 protocol \(version) is not supported"
        case .unauthorized: "T3 access was refused"
        case .expired: "T3 access expired, renewing"
        case .revoked: "T3 access was revoked"
        case .noAccess(let reason): reason
        case .badResponse, .streamEnded: "T3 connection lost"
        }
    }
}

func logLine(_ message: String) {
    print("\(ISO8601DateFormatter().string(from: Date())) \(message)")
}

// MARK: - Status

extension ShellThread {
    struct WorkState: Equatable {
        let light: ThreadStatusRow.Light
        let detail: String
        let note: String?
        let since: Date?
    }

    /// Where T3's sidebar puts this thread, as far as the panel cares. Nil
    /// for anything that is not in motion: finished, idle, failed, stopped,
    /// never run, a plan waiting for review, or only a command left running.
    func workState(subagentRequest: String?) -> WorkState? {
        // Settlement is a visibility decision, independent of leftover task
        // records. A cancelled run can still carry old subagent summaries.
        guard self.settledOverride != "settled",
              !(self.settledOverride == nil && self.settledAt != nil) else { return nil }
        let hasLiveRun = hasActivityRunStatus
            ? self.activityRunStatus != nil
            : self.activeRunId != nil || ["preparing", "queued", "starting", "running", "waiting"].contains(self.status)
        if !hasLiveRun && ["failed", "interrupted", "cancelled", "rolled_back"].contains(self.status) {
            return nil
        }
        let request = self.pendingRuntimeRequest?.kind
        // T3 counts any request except an answer or an auth refresh as an approval.
        if (request != nil && request != "user_input" && request != "auth_refresh") || subagentRequest == "approval" {
            return WorkState(light: .needsYou, detail: request == nil ? "Subagent needs approval" : "Needs approval",
                             note: nil, since: nil)
        }
        if request == "user_input" || subagentRequest == "user_input" {
            return WorkState(light: .needsYou, detail: request == nil ? "Subagent has a question" : "Needs your answer",
                             note: nil, since: nil)
        }
        guard isWorking, let runtime = runtimeStatus else { return nil }
        if runtime == "idle" {
            let holding = holdingTasks
            // Shell status "idle" alone means the thread never ran. T3 would
            // fold a never-run thread with an open provider session too, but
            // it is not doing anything.
            if holding.isEmpty { return nil }
            let kinds = Set(holding.map(\.kind))
            let what = kinds.count > 1 ? "background work"
                : kinds.first == "subagent" ? (holding.count > 1 ? "\(holding.count) subagents" : "subagent")
                : kinds.first == "monitor" ? "monitor" : "background task"
            let note = holding.compactMap { $0.description?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .first { !$0.isEmpty }
            return WorkState(light: .waiting, detail: "Waiting on \(what)", note: note, since: nil)
        }
        let detail = runtime == "queued" ? "Queued" : runtime == "preparing" || runtime == "starting" ? "Starting" : "Working"
        let started = (self.activityRunStartedAt ?? self.latestRunStartedAt).flatMap(Self.date)
        return WorkState(light: .working, detail: detail, note: nil, since: started)
    }

    /// Background work that wakes the agent. Commands it left running, such
    /// as a dev server, do not hold the thread (T3's `backgroundWorkHoldsCompletion`).
    private var holdingTasks: [BackgroundTask] {
        (self.pendingBackgroundTasks ?? []).filter { ["subagent", "monitor", "background_task"].contains($0.kind) }
    }

    /// T3's `shellRuntime`: parked at idle while held by background work,
    /// unless the run failed; otherwise the activity run's status.
    var runtimeStatus: String? {
        let parkAtIdle = !holdingTasks.isEmpty && self.status != "failed"
        if self.latestRunId == nil && self.activeProviderThreadId == nil && !parkAtIdle { return nil }
        return parkAtIdle ? "idle" : (self.activityRunStatus ?? self.status)
    }

    /// T3's `isThreadWorking`: what the Working section folds. Requests are
    /// handled before this.
    private var isWorking: Bool {
        guard let runtime = runtimeStatus,
              ["preparing", "queued", "starting", "running", "waiting", "idle"].contains(runtime)
        else { return false }
        // A plan waiting for review is the user's turn, even with work lingering.
        let runSettled = self.latestRunId != nil
            && !["preparing", "queued", "starting", "running", "waiting"].contains(self.status == "idle" ? "completed" : self.status)
            && self.activeRunId != self.latestRunId
        return !(self.interactionMode == "plan" && self.hasActionableProposedPlan == true && runSettled)
    }

    /// T3's Working order: the last message the user sent, newest first.
    var sentAt: Date {
        let sent = (hasAuthoredStamp ? self.latestUserAuthoredMessageAt : self.latestRunRequestedAt).flatMap(Self.date)
        return max(Self.date(self.createdAt) ?? .distantPast, sent ?? .distantPast)
    }

    private static func date(_ text: String) -> Date? {
        ISO8601DateFormatter.withFractions.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

// MARK: - Wire types (only the fields the panel reads)

@dynamicMemberLookup
struct ShellThread: Decodable, Sendable {
    struct Lineage: Decodable, Sendable {
        let parentThreadId: String?
        let relationshipToParent: String?
    }
    struct Request: Decodable, Sendable { let kind: String }
    struct BackgroundTask: Decodable, Sendable {
        let kind: String
        let description: String?
    }

    struct Fields: Decodable, Sendable {
        let id: String
        let title: String
        let projectId: String?
        let creationSource: String?
        let status: String
        let interactionMode: String?
        let hasActionableProposedPlan: Bool?
        let latestRunId: String?
        let activeRunId: String?
        let activeProviderThreadId: String?
        let activityRunStatus: String?
        let activityRunStartedAt: String?
        let latestRunStartedAt: String?
        let latestRunRequestedAt: String?
        let latestUserAuthoredMessageAt: String?
        let pendingRuntimeRequest: Request?
        let pendingBackgroundTasks: [BackgroundTask]?
        let lineage: Lineage?
        let createdAt: String
        let archivedAt: String?
        let deletedAt: String?
        let settledOverride: String?
        let settledAt: String?
    }

    let fields: Fields
    /// Servers that predate the field omit it; T3 then falls back to the run time.
    let hasAuthoredStamp: Bool
    /// Servers that predate the field omit it; null means no activity run.
    let hasActivityRunStatus: Bool

    subscript<T>(dynamicMember path: KeyPath<Fields, T>) -> T { fields[keyPath: path] }

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        fields = try Fields(from: decoder)
        let keys = try decoder.container(keyedBy: Key.self)
        hasAuthoredStamp = keys.contains(Key(stringValue: "latestUserAuthoredMessageAt"))
        hasActivityRunStatus = keys.contains(Key(stringValue: "activityRunStatus"))
    }
}

private struct ShellStreamItem: Decodable, Sendable {
    struct Project: Decodable, Sendable {
        let id: String
        let title: String
    }
    struct Snapshot: Decodable, Sendable {
        let threads: [ShellThread]?
        let projects: [Project]?
    }
    let kind: String
    let snapshot: Snapshot?
    let resolvedRepositoryIdentityRoots: [String]?
    let location: String?
    let thread: ShellThread?
    let threadId: String?
    let project: Project?
    let projectId: String?
}

private struct RpcMessage: Decodable, Sendable {
    let tag: String
    let requestId: String?
    let values: [ShellStreamItem]?
    let isAuthorizationFailure: Bool

    private enum Keys: String, CodingKey { case _tag, requestId, values }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        tag = try container.decode(String.self, forKey: ._tag)
        if let text = try? container.decode(String.self, forKey: .requestId) { requestId = text }
        else { requestId = (try? container.decode(Int.self, forKey: .requestId)).map(String.init) }
        if tag == "Chunk" {
            // Skip kinds this build does not know instead of dropping the batch.
            var items: [ShellStreamItem] = []
            var list = try container.nestedUnkeyedContainer(forKey: .values)
            while !list.isAtEnd {
                if let item = try? list.decode(ShellStreamItem.self) { items.append(item) }
                else { _ = try? list.decode(Skip.self) }
            }
            values = items
        } else {
            values = nil
        }
        // Exits carry tagged errors; authorization failures name themselves.
        isAuthorizationFailure = tag == "Exit"
            && ((try? decoder.singleValueContainer().decode(AnyTags.self))?.tags.contains { $0.contains("Authorization") } ?? false)
    }

    private struct Skip: Decodable {}
}

/// Collects every `_tag` in a JSON tree.
private struct AnyTags: Decodable {
    var tags: [String] = []
    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    init(from decoder: Decoder) throws {
        if let object = try? decoder.container(keyedBy: Key.self) {
            for key in object.allKeys {
                if key.stringValue == "_tag", let tag = try? object.decode(String.self, forKey: key) { tags.append(tag) }
                else if let nested = try? object.decode(AnyTags.self, forKey: key) { tags += nested.tags }
            }
        } else if var array = try? decoder.unkeyedContainer() {
            while !array.isAtEnd {
                if let nested = try? array.decode(AnyTags.self) { tags += nested.tags } else { break }
            }
        }
    }
}

private struct EnvironmentDescriptor: Decodable {
    let environmentId: String
    let orchestrationProtocolVersion: Int
}

private struct ServerRuntime: Decodable { let port: Int }
private struct WebSocketTicket: Decodable { let ticket: String }

// MARK: - Access

/// A read-only T3 session, issued with the T3 CLI's supported
/// `t3 auth session issue` and kept in the login keychain. The token never
/// reaches logs or files.
///
/// Sessions are issued automatically only on first use and to renew one that
/// is about to expire. A session T3 rejects before it expires was revoked
/// there: it is marked rejected in the keychain (kept, not deleted) and no new
/// session is issued, across relaunches, until `requestReenable()`.
@MainActor
final class T3Access {
    private static let renewBefore: TimeInterval = 3 * 24 * 3600
    private static let retryIssueAfter: TimeInterval = 10 * 60

    struct Credential: Codable, Equatable {
        let token: String
        let sessionId: String
        let expiresAt: String
        /// Set when T3 refused the token before it expired.
        var rejectedAt: String?

        var expiry: Date? { ISO8601DateFormatter.withFractions.date(from: expiresAt) }
    }

    /// Where the credential is kept, per T3 environment id.
    struct Store: Sendable {
        var load: @Sendable (String) throws -> Data?
        var save: @Sendable (Data, String) throws -> Void
    }

    /// How sessions are issued and revoked.
    struct Sessions: Sendable {
        var issue: @Sendable () throws -> Data
        var revoke: @Sendable (String) -> Void
    }

    private let store: Store
    private let sessions: Sessions
    private let now: () -> Date
    private var lastIssueAt: Date?
    private var reenableRequested = false
    /// Rejected sessions, in case recording the rejection in the store failed.
    private var rejectedSessions: Set<String> = []

    init(store: Store = .keychain, sessions: Sessions = .cli, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.sessions = sessions
        self.now = now
    }

    func token(environmentId: String) async throws -> String {
        let stored = try load(environmentId)
        if let stored, isRejected(stored), !reenableRequested { throw FeedError.revoked }
        if let stored, !isRejected(stored), let expiry = stored.expiry,
           expiry.timeIntervalSince(now()) > Self.renewBefore {
            return stored.token
        }
        // Do not mint sessions in a loop when T3 keeps refusing them.
        if let lastIssueAt, now().timeIntervalSince(lastIssueAt) < Self.retryIssueAfter {
            if let stored, !isRejected(stored), let expiry = stored.expiry, expiry > now() { return stored.token }
            throw FeedError.noAccess("Waiting to request T3 access again")
        }
        lastIssueAt = now()
        let sessions = sessions
        let output = try await Task.detached { try sessions.issue() }.value
        guard var issued = try? JSONDecoder().decode(Credential.self, from: output) else {
            throw FeedError.noAccess("T3 did not issue access")
        }
        issued.rejectedAt = nil
        do {
            try save(issued, environmentId: environmentId)
        } catch {
            // Nothing will use the new session, so it must not stay active.
            Task.detached { sessions.revoke(issued.sessionId) }
            logLine("T3 feed: could not save new session to the keychain (\(error)); revoked it")
            throw error
        }
        reenableRequested = false
        logLine("T3 feed: issued read-only session \(issued.sessionId)")
        if let stored, stored.sessionId != issued.sessionId {
            Task.detached { sessions.revoke(stored.sessionId) }
        }
        return issued.token
    }

    /// T3 refused `token`. Returns the error the feed should show.
    func rejected(token: String, environmentId: String) -> FeedError {
        guard var stored = try? load(environmentId), stored.token == token else { return .unauthorized }
        if let expiry = stored.expiry, expiry <= now() { return .expired }
        rejectedSessions.insert(stored.sessionId)
        if stored.rejectedAt == nil {
            stored.rejectedAt = ISO8601DateFormatter.withFractions.string(from: now())
            do { try save(stored, environmentId: environmentId) } catch {
                logLine("T3 feed: could not record the revoked session (\(error))")
            }
            logLine("T3 feed: session \(stored.sessionId) was revoked in T3; not issuing a new one")
        }
        return .revoked
    }

    /// The user asked for access again after a revocation.
    func requestReenable() {
        reenableRequested = true
        lastIssueAt = nil
    }

    private func isRejected(_ credential: Credential) -> Bool {
        credential.rejectedAt != nil || rejectedSessions.contains(credential.sessionId)
    }

    private func load(_ environmentId: String) throws -> Credential? {
        guard let data = try store.load(environmentId) else { return nil }
        guard let credential = try? JSONDecoder().decode(Credential.self, from: data) else {
            throw FeedError.noAccess("Saved T3 access is unreadable")
        }
        return credential
    }

    private func save(_ credential: Credential, environmentId: String) throws {
        try store.save(try JSONEncoder().encode(credential), environmentId)
    }
}

extension T3Access.Store {
    private static let service = "com.codetorso.miced.t3-thread-status"

    private static func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The login keychain. Updates in place, so a failed write keeps the old item.
    static let keychain = T3Access.Store(
        load: { account in
            var query = query(account)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            if status == errSecItemNotFound { return nil }
            guard status == errSecSuccess, let data = result as? Data else {
                throw FeedError.noAccess("Keychain error \(status)")
            }
            return data
        },
        save: { data, account in
            var status = SecItemUpdate(query(account) as CFDictionary,
                                       [kSecValueData as String: data] as CFDictionary)
            if status == errSecItemNotFound {
                var item = query(account)
                item[kSecValueData as String] = data
                item[kSecAttrLabel as String] = "miced: T3 Code read-only thread status"
                item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
                status = SecItemAdd(item as CFDictionary, nil)
            }
            guard status == errSecSuccess else { throw FeedError.noAccess("Keychain error \(status)") }
        }
    )
}

extension T3Access.Sessions {
    private static let label = "miced thread status (read-only)"
    private static let lifetime = "30d"

    static let cli = T3Access.Sessions(
        issue: {
            try runCLI(["auth", "session", "issue", "--scope", "orchestration:read",
                        "--ttl", lifetime, "--label", label, "--json"])
        },
        revoke: { sessionId in _ = try? runCLI(["auth", "session", "revoke", sessionId]) }
    )

    private static func runCLI(_ arguments: [String]) throws -> Data {
        let cli = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".t3/bin/t3")
        guard FileManager.default.isExecutableFile(atPath: cli.path) else {
            throw FeedError.noAccess("T3 command line not found")
        }
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        let stdout = Pipe()
        process.standardOutput = stdout
        process.standardError = FileHandle.nullDevice
        try process.run()
        // The CLI talks to a local database; give up rather than hang the feed.
        DispatchQueue.global().asyncAfter(deadline: .now() + 60) { if process.isRunning { process.terminate() } }
        let data = stdout.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw FeedError.noAccess("T3 did not issue access") }
        return data
    }
}

extension ISO8601DateFormatter {
    nonisolated(unsafe) static let withFractions: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
