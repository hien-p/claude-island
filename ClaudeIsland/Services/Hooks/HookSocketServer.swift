//
//  HookSocketServer.swift
//  ClaudeIsland
//
//  Unix domain socket server for real-time hook events
//  Supports request/response for permission decisions
//

import Foundation
import os.log

/// Logger for hook socket server
private let logger = Logger(subsystem: "com.claudeisland", category: "Hooks")

/// Configuration for socket server
enum SocketConfig {
    /// Timeout for reading client data (in seconds)
    static let clientReadTimeout: TimeInterval = 5.0

    /// Maximum concurrent connections
    static let maxConcurrentConnections = 10

    /// Tool ID cache TTL (in seconds) - entries older than this are cleaned up
    static let cacheEntryTTL: TimeInterval = 60.0

    /// Cache cleanup interval (in seconds)
    static let cacheCleanupInterval: TimeInterval = 30.0
}

/// Event received from Claude Code hooks
struct HookEvent: Codable, Sendable {
    let sessionId: String
    let cwd: String
    let event: String
    let status: String
    let pid: Int?
    let tty: String?
    let tool: String?
    let toolInput: [String: AnyCodable]?
    let toolUseId: String?
    let notificationType: String?
    let message: String?

    enum CodingKeys: String, CodingKey {
        case sessionId = "session_id"
        case cwd, event, status, pid, tty, tool
        case toolInput = "tool_input"
        case toolUseId = "tool_use_id"
        case notificationType = "notification_type"
        case message
    }

    /// Create a copy with updated toolUseId
    init(sessionId: String, cwd: String, event: String, status: String, pid: Int?, tty: String?, tool: String?, toolInput: [String: AnyCodable]?, toolUseId: String?, notificationType: String?, message: String?) {
        self.sessionId = sessionId
        self.cwd = cwd
        self.event = event
        self.status = status
        self.pid = pid
        self.tty = tty
        self.tool = tool
        self.toolInput = toolInput
        self.toolUseId = toolUseId
        self.notificationType = notificationType
        self.message = message
    }

    var sessionPhase: SessionPhase {
        if event == "PreCompact" {
            return .compacting
        }

        switch status {
        case "waiting_for_approval":
            // Note: Full PermissionContext is constructed by SessionStore, not here
            // This is just for quick phase checks
            return .waitingForApproval(PermissionContext(
                toolUseId: toolUseId ?? "",
                toolName: tool ?? "unknown",
                toolInput: toolInput,
                receivedAt: Date()
            ))
        case "waiting_for_input":
            return .waitingForInput
        case "running_tool", "processing", "starting":
            return .processing
        case "compacting":
            return .compacting
        default:
            return .idle
        }
    }

    /// Whether this event expects a response (permission request)
    nonisolated var expectsResponse: Bool {
        event == "PermissionRequest" && status == "waiting_for_approval"
    }
}

/// Response to send back to the hook
struct HookResponse: Codable {
    let decision: String // "allow", "deny", or "ask"
    let reason: String?
}

/// Pending permission request waiting for user decision
struct PendingPermission: Sendable {
    let sessionId: String
    let toolUseId: String
    let clientSocket: Int32
    let event: HookEvent
    let receivedAt: Date
}

/// Cached tool ID with timestamp for TTL-based cleanup
struct CachedToolId {
    let toolUseId: String
    let cachedAt: Date
}

/// Callback for hook events
typealias HookEventHandler = @Sendable (HookEvent) -> Void

/// Callback for permission response failures (socket died)
typealias PermissionFailureHandler = @Sendable (_ sessionId: String, _ toolUseId: String) -> Void

/// Unix domain socket server that receives events from Claude Code hooks
/// Uses GCD DispatchSource for non-blocking I/O
class HookSocketServer {
    static let shared = HookSocketServer()
    static let socketPath = "/tmp/claude-island.sock"

    private var serverSocket: Int32 = -1
    private var acceptSource: DispatchSourceRead?
    private var eventHandler: HookEventHandler?
    private var permissionFailureHandler: PermissionFailureHandler?
    private let queue = DispatchQueue(label: "com.claudeisland.socket", qos: .userInitiated)

    /// Pending permission requests indexed by toolUseId
    private var pendingPermissions: [String: PendingPermission] = [:]
    private let permissionsLock = NSLock()

    /// Cache tool_use_id from PreToolUse to correlate with PermissionRequest
    /// Key: "sessionId:toolName:serializedInput" -> Queue of CachedToolIds (FIFO)
    /// PermissionRequest events don't include tool_use_id, so we cache from PreToolUse
    private var toolUseIdCache: [String: [CachedToolId]] = [:]
    private let cacheLock = NSLock()

    /// Timer for periodic cache cleanup
    private var cacheCleanupTimer: DispatchSourceTimer?

    /// Active connection count for rate limiting
    private var activeConnections: Int = 0
    private let connectionsLock = NSLock()

    private init() {}

    /// Start the socket server
    func start(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler? = nil) {
        queue.async { [weak self] in
            self?.startServer(onEvent: onEvent, onPermissionFailure: onPermissionFailure)
        }
    }

    private func startServer(onEvent: @escaping HookEventHandler, onPermissionFailure: PermissionFailureHandler?) {
        guard serverSocket < 0 else { return }

        eventHandler = onEvent
        permissionFailureHandler = onPermissionFailure

        unlink(Self.socketPath)

        serverSocket = socket(AF_UNIX, SOCK_STREAM, 0)
        guard serverSocket >= 0 else {
            logger.error("Failed to create socket: \(errno)")
            return
        }

        let flags = fcntl(serverSocket, F_GETFL)
        _ = fcntl(serverSocket, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        Self.socketPath.withCString { ptr in
            withUnsafeMutablePointer(to: &addr.sun_path) { pathPtr in
                let pathBufferPtr = UnsafeMutableRawPointer(pathPtr)
                    .assumingMemoryBound(to: CChar.self)
                strcpy(pathBufferPtr, ptr)
            }
        }

        let bindResult = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                bind(serverSocket, sockaddrPtr, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }

        guard bindResult == 0 else {
            logger.error("Failed to bind socket: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        // Security fix: Use restrictive permissions (owner-only access)
        // instead of world-writable 0o777 to prevent unauthorized socket access
        chmod(Self.socketPath, 0o700)

        guard listen(serverSocket, 10) == 0 else {
            logger.error("Failed to listen: \(errno)")
            close(serverSocket)
            serverSocket = -1
            return
        }

        logger.info("Listening on \(Self.socketPath, privacy: .public)")

        acceptSource = DispatchSource.makeReadSource(fileDescriptor: serverSocket, queue: queue)
        acceptSource?.setEventHandler { [weak self] in
            self?.acceptConnection()
        }
        acceptSource?.setCancelHandler { [weak self] in
            if let fd = self?.serverSocket, fd >= 0 {
                close(fd)
                self?.serverSocket = -1
            }
        }
        acceptSource?.resume()

        // Start periodic cache cleanup
        startCacheCleanupTimer()
    }

    /// Stop the socket server
    func stop() {
        acceptSource?.cancel()
        acceptSource = nil
        unlink(Self.socketPath)

        // Stop cache cleanup timer
        cacheCleanupTimer?.cancel()
        cacheCleanupTimer = nil

        permissionsLock.lock()
        for (_, pending) in pendingPermissions {
            close(pending.clientSocket)
        }
        pendingPermissions.removeAll()
        permissionsLock.unlock()

        // Clear cache
        cacheLock.lock()
        toolUseIdCache.removeAll()
        cacheLock.unlock()
    }

    /// Respond to a pending permission request by toolUseId
    func respondToPermission(toolUseId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponse(toolUseId: toolUseId, decision: decision, reason: reason)
        }
    }

    /// Respond to permission by sessionId (finds the most recent pending for that session)
    func respondToPermissionBySession(sessionId: String, decision: String, reason: String? = nil) {
        queue.async { [weak self] in
            self?.sendPermissionResponseBySession(sessionId: sessionId, decision: decision, reason: reason)
        }
    }

    /// Cancel all pending permissions for a session (when Claude stops waiting)
    func cancelPendingPermissions(sessionId: String) {
        queue.async { [weak self] in
            self?.cleanupPendingPermissions(sessionId: sessionId)
        }
    }

    /// Check if there's a pending permission request for a session
    func hasPendingPermission(sessionId: String) -> Bool {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        return pendingPermissions.values.contains { $0.sessionId == sessionId }
    }

    /// Get the pending permission details for a session (if any)
    func getPendingPermission(sessionId: String) -> (toolName: String?, toolId: String?, toolInput: [String: AnyCodable]?)? {
        permissionsLock.lock()
        defer { permissionsLock.unlock() }
        guard let pending = pendingPermissions.values.first(where: { $0.sessionId == sessionId }) else {
            return nil
        }
        return (pending.event.tool, pending.toolUseId, pending.event.toolInput)
    }

    /// Cancel a specific pending permission by toolUseId (when tool completes via terminal approval)
    func cancelPendingPermission(toolUseId: String) {
        queue.async { [weak self] in
            self?.cleanupSpecificPermission(toolUseId: toolUseId)
        }
    }

    private func cleanupSpecificPermission(toolUseId: String) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            return
        }
        permissionsLock.unlock()

        logger.debug("Tool completed externally, closing socket for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
        close(pending.clientSocket)
    }

    private func cleanupPendingPermissions(sessionId: String) {
        permissionsLock.lock()
        let matching = pendingPermissions.filter { $0.value.sessionId == sessionId }
        for (toolUseId, pending) in matching {
            logger.debug("Cleaning up stale permission for \(sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")
            close(pending.clientSocket)
            pendingPermissions.removeValue(forKey: toolUseId)
        }
        permissionsLock.unlock()
    }

    // MARK: - Tool Use ID Cache

    /// Encoder with sorted keys for deterministic cache keys
    private static let sortedEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        return encoder
    }()

    /// Generate cache key from event properties
    private func cacheKey(sessionId: String, toolName: String?, toolInput: [String: AnyCodable]?) -> String {
        let inputStr: String
        if let input = toolInput,
           let data = try? Self.sortedEncoder.encode(input),
           let str = String(data: data, encoding: .utf8) {
            inputStr = str
        } else {
            inputStr = "{}"
        }
        return "\(sessionId):\(toolName ?? "unknown"):\(inputStr)"
    }

    /// Cache tool_use_id from PreToolUse event (FIFO queue per key) with timestamp
    private func cacheToolUseId(event: HookEvent) {
        guard let toolUseId = event.toolUseId else { return }

        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)
        let cached = CachedToolId(toolUseId: toolUseId, cachedAt: Date())

        cacheLock.lock()
        if toolUseIdCache[key] == nil {
            toolUseIdCache[key] = []
        }
        toolUseIdCache[key]?.append(cached)
        cacheLock.unlock()

        logger.debug("Cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(toolUseId.prefix(12), privacy: .public)")
    }

    /// Pop and return cached tool_use_id for PermissionRequest (FIFO)
    private func popCachedToolUseId(event: HookEvent) -> String? {
        let key = cacheKey(sessionId: event.sessionId, toolName: event.tool, toolInput: event.toolInput)

        cacheLock.lock()
        defer { cacheLock.unlock() }

        guard var queue = toolUseIdCache[key], !queue.isEmpty else {
            return nil
        }

        let cached = queue.removeFirst()

        if queue.isEmpty {
            toolUseIdCache.removeValue(forKey: key)
        } else {
            toolUseIdCache[key] = queue
        }

        logger.debug("Retrieved cached tool_use_id for \(event.sessionId.prefix(8), privacy: .public) tool:\(event.tool ?? "?", privacy: .public) id:\(cached.toolUseId.prefix(12), privacy: .public)")
        return cached.toolUseId
    }

    /// Clean up cache entries for a session (on session end)
    private func cleanupCache(sessionId: String) {
        cacheLock.lock()
        let keysToRemove = toolUseIdCache.keys.filter { $0.hasPrefix("\(sessionId):") }
        for key in keysToRemove {
            toolUseIdCache.removeValue(forKey: key)
        }
        cacheLock.unlock()

        if !keysToRemove.isEmpty {
            logger.debug("Cleaned up \(keysToRemove.count) cache entries for session \(sessionId.prefix(8), privacy: .public)")
        }
    }

    /// Start periodic timer to clean up stale cache entries
    private func startCacheCleanupTimer() {
        cacheCleanupTimer = DispatchSource.makeTimerSource(queue: queue)
        cacheCleanupTimer?.schedule(
            deadline: .now() + SocketConfig.cacheCleanupInterval,
            repeating: SocketConfig.cacheCleanupInterval
        )
        cacheCleanupTimer?.setEventHandler { [weak self] in
            self?.cleanupStaleCacheEntries()
        }
        cacheCleanupTimer?.resume()
        logger.debug("Cache cleanup timer started (interval: \(SocketConfig.cacheCleanupInterval)s)")
    }

    /// Remove cache entries older than TTL
    private func cleanupStaleCacheEntries() {
        let now = Date()
        var removedCount = 0

        cacheLock.lock()

        for (key, queue) in toolUseIdCache {
            // Filter out stale entries
            let freshEntries = queue.filter { entry in
                now.timeIntervalSince(entry.cachedAt) < SocketConfig.cacheEntryTTL
            }

            if freshEntries.isEmpty {
                toolUseIdCache.removeValue(forKey: key)
                removedCount += queue.count
            } else if freshEntries.count < queue.count {
                toolUseIdCache[key] = freshEntries
                removedCount += queue.count - freshEntries.count
            }
        }

        let cacheSize = toolUseIdCache.values.reduce(0) { $0 + $1.count }
        cacheLock.unlock()

        if removedCount > 0 {
            logger.debug("Cache cleanup: removed \(removedCount) stale entries, \(cacheSize) remaining")
        }
    }

    // MARK: - Rate Limiting

    /// Increment active connections (returns false if at limit)
    private func tryIncrementConnections() -> Bool {
        connectionsLock.lock()
        defer { connectionsLock.unlock() }

        if activeConnections >= SocketConfig.maxConcurrentConnections {
            logger.warning("Rate limit reached: \(self.activeConnections) active connections")
            return false
        }

        activeConnections += 1
        return true
    }

    /// Decrement active connections
    private func decrementConnections() {
        connectionsLock.lock()
        activeConnections = max(0, activeConnections - 1)
        connectionsLock.unlock()
    }

    // MARK: - Private

    private func acceptConnection() {
        let clientSocket = accept(serverSocket, nil, nil)
        guard clientSocket >= 0 else { return }

        // Rate limiting check
        guard tryIncrementConnections() else {
            logger.warning("Rejecting connection due to rate limit")
            close(clientSocket)
            return
        }

        var nosigpipe: Int32 = 1
        setsockopt(clientSocket, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))

        handleClient(clientSocket)
    }

    private func handleClient(_ clientSocket: Int32) {
        let flags = fcntl(clientSocket, F_GETFL)
        _ = fcntl(clientSocket, F_SETFL, flags | O_NONBLOCK)

        var allData = Data()
        var buffer = [UInt8](repeating: 0, count: 131072)
        var pollFd = pollfd(fd: clientSocket, events: Int16(POLLIN), revents: 0)

        let startTime = Date()
        let timeoutSeconds = SocketConfig.clientReadTimeout

        while Date().timeIntervalSince(startTime) < timeoutSeconds {
            let pollResult = poll(&pollFd, 1, 50)

            if pollResult > 0 && (pollFd.revents & Int16(POLLIN)) != 0 {
                let bytesRead = read(clientSocket, &buffer, buffer.count)

                if bytesRead > 0 {
                    allData.append(contentsOf: buffer[0..<bytesRead])
                } else if bytesRead == 0 {
                    break
                } else if errno != EAGAIN && errno != EWOULDBLOCK {
                    break
                }
            } else if pollResult == 0 {
                if !allData.isEmpty {
                    break
                }
            } else {
                break
            }
        }

        // Check for timeout
        if Date().timeIntervalSince(startTime) >= timeoutSeconds && allData.isEmpty {
            logger.warning("Client read timeout after \(timeoutSeconds)s")
        }

        guard !allData.isEmpty else {
            close(clientSocket)
            decrementConnections()
            return
        }

        let data = allData

        guard let event = try? JSONDecoder().decode(HookEvent.self, from: data) else {
            logger.warning("Failed to parse event: \(String(data: data, encoding: .utf8) ?? "?", privacy: .public)")
            close(clientSocket)
            decrementConnections()
            return
        }

        logger.debug("Received: \(event.event, privacy: .public) for \(event.sessionId.prefix(8), privacy: .public)")

        if event.event == "PreToolUse" {
            cacheToolUseId(event: event)
        }

        if event.event == "SessionEnd" {
            cleanupCache(sessionId: event.sessionId)
        }

        if event.expectsResponse {
            let toolUseId: String
            if let eventToolUseId = event.toolUseId {
                toolUseId = eventToolUseId
            } else if let cachedToolUseId = popCachedToolUseId(event: event) {
                toolUseId = cachedToolUseId
            } else {
                logger.warning("Permission request missing tool_use_id for \(event.sessionId.prefix(8), privacy: .public) - no cache hit")
                close(clientSocket)
                decrementConnections()
                eventHandler?(event)
                return
            }

            logger.debug("Permission request - keeping socket open for \(event.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public)")

            let updatedEvent = HookEvent(
                sessionId: event.sessionId,
                cwd: event.cwd,
                event: event.event,
                status: event.status,
                pid: event.pid,
                tty: event.tty,
                tool: event.tool,
                toolInput: event.toolInput,
                toolUseId: toolUseId,  // Use resolved toolUseId
                notificationType: event.notificationType,
                message: event.message
            )

            let pending = PendingPermission(
                sessionId: event.sessionId,
                toolUseId: toolUseId,
                clientSocket: clientSocket,
                event: updatedEvent,
                receivedAt: Date()
            )
            permissionsLock.lock()
            pendingPermissions[toolUseId] = pending
            permissionsLock.unlock()

            // Note: Don't decrement connections here - socket stays open for response
            eventHandler?(updatedEvent)
            return
        } else {
            close(clientSocket)
            decrementConnections()
        }

        eventHandler?(event)
    }

    private func sendPermissionResponse(toolUseId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        guard let pending = pendingPermissions.removeValue(forKey: toolUseId) else {
            permissionsLock.unlock()
            logger.debug("No pending permission for toolUseId: \(toolUseId.prefix(12), privacy: .public)")
            return
        }
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            decrementConnections()
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(pending.sessionId.prefix(8), privacy: .public) tool:\(toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
            }
        }

        close(pending.clientSocket)
        decrementConnections()
    }

    private func sendPermissionResponseBySession(sessionId: String, decision: String, reason: String?) {
        permissionsLock.lock()
        let matchingPending = pendingPermissions.values
            .filter { $0.sessionId == sessionId }
            .sorted { $0.receivedAt > $1.receivedAt }
            .first

        guard let pending = matchingPending else {
            permissionsLock.unlock()
            logger.debug("No pending permission for session: \(sessionId.prefix(8), privacy: .public)")
            return
        }

        pendingPermissions.removeValue(forKey: pending.toolUseId)
        permissionsLock.unlock()

        let response = HookResponse(decision: decision, reason: reason)
        guard let data = try? JSONEncoder().encode(response) else {
            close(pending.clientSocket)
            decrementConnections()
            permissionFailureHandler?(sessionId, pending.toolUseId)
            return
        }

        let age = Date().timeIntervalSince(pending.receivedAt)
        logger.info("Sending response: \(decision, privacy: .public) for \(sessionId.prefix(8), privacy: .public) tool:\(pending.toolUseId.prefix(12), privacy: .public) (age: \(String(format: "%.1f", age), privacy: .public)s)")

        var writeSuccess = false
        data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else {
                logger.error("Failed to get data buffer address")
                return
            }
            let result = write(pending.clientSocket, baseAddress, data.count)
            if result < 0 {
                logger.error("Write failed with errno: \(errno)")
            } else {
                logger.debug("Write succeeded: \(result) bytes")
                writeSuccess = true
            }
        }

        close(pending.clientSocket)
        decrementConnections()

        if !writeSuccess {
            permissionFailureHandler?(sessionId, pending.toolUseId)
        }
    }
}

// MARK: - AnyCodable for tool_input

/// Type-erasing codable wrapper for heterogeneous values
/// Used to decode JSON objects with mixed value types
struct AnyCodable: Codable, @unchecked Sendable {
    /// The underlying value (nonisolated(unsafe) because Any is not Sendable)
    nonisolated(unsafe) let value: Any

    /// Initialize with any value
    init(_ value: Any) {
        self.value = value
    }

    /// Decode from JSON
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()

        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map { $0.value }
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues { $0.value }
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Cannot decode value")
        }
    }

    /// Encode to JSON
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()

        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            throw EncodingError.invalidValue(value, EncodingError.Context(codingPath: [], debugDescription: "Cannot encode value"))
        }
    }
}
