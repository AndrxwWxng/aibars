import Foundation

/// One assistant turn as Claude Code wrote it down.
///
/// This is the whole of what a rollout log says about what a turn cost. The
/// four token counts are kept apart rather than summed because they are priced
/// apart — a cache read is an order of magnitude cheaper than the same tokens
/// read fresh — and a scanner that added them up would have decided the pricing
/// question on the caller's behalf.
public struct ClaudeCodeTurn: Equatable {
    /// When the turn was written, from the row's own ISO 8601 stamp. A turn
    /// without one is dropped rather than stamped with the time it was read:
    /// every use of this is a window, and a made-up time lands in the wrong one.
    public let at: Date
    /// `message.model`, verbatim — "claude-opus-5", not a tidied display name.
    /// Tidying is a presentation decision and belongs where the presenting is.
    public let model: String
    public let inputTokens: Int
    public let cacheCreationTokens: Int
    public let cacheReadTokens: Int
    public let outputTokens: Int
    /// `message.id`, and the dedupe key. Subagent and forked sessions copy the
    /// parent's turn history into their own log, so a scan that counts rows
    /// counts some of them twice; a scan that counts distinct message ids does
    /// not. `requestId` looks like it would serve as well and does not — a
    /// synthetic row has none, and one request can be written more than once.
    public let messageID: String
    /// The session the row was written in, from the row itself rather than the
    /// file name. Empty when the row does not say, which the caller can fall
    /// back to attributing by file.
    public let sessionID: String
    /// Whether this turn belongs to a subagent rather than the main thread.
    /// Carried, not filtered: a subagent's tokens are spent against the same
    /// quota, but a per-session view usually wants them separated out.
    public let isSidechain: Bool

    public init(
        at: Date,
        model: String,
        inputTokens: Int,
        cacheCreationTokens: Int,
        cacheReadTokens: Int,
        outputTokens: Int,
        messageID: String,
        sessionID: String,
        isSidechain: Bool
    ) {
        self.at = at
        self.model = model
        self.inputTokens = inputTokens
        self.cacheCreationTokens = cacheCreationTokens
        self.cacheReadTokens = cacheReadTokens
        self.outputTokens = outputTokens
        self.messageID = messageID
        self.sessionID = sessionID
        self.isSidechain = isSidechain
    }
}

/// Reads Claude Code's own rollout logs off disk.
///
/// Claude Code keeps one JSONL file per session under
/// `<config>/projects/<slugified-cwd>/<sessionUUID>.jsonl`, appending one JSON
/// object per line as the session runs. Assistant rows carry `message.usage`,
/// which is the only place on the machine that says what the local agent has
/// actually spent — the web endpoints know nothing about it.
///
/// Everything here is pure file and JSON work: no UI, no main actor, no
/// singletons, so the parsing can be tested against a fixture on any thread.
/// Deciding which turns to count, how to price them and what to show is the
/// caller's; this decides only what the file says.
public enum ClaudeCodeScanner {
    /// How much is read at a time. Large enough that a first pass over a
    /// long-lived session is a handful of reads, small enough that scanning a
    /// directory of them never holds a whole log in memory.
    private static let chunkSize = 1 << 18

    /// How far a run with no newline in it is allowed to buffer.
    ///
    /// A line is one JSON object and a large tool result makes a large one, so
    /// this is generous. Past it the scan stops and returns the offset it had
    /// reached, which does not advance over the unterminated run: nothing is
    /// skipped, the scanner just declines to grow without bound for a file that
    /// turns out not to be JSONL at all.
    private static let maximumLine = 16 << 20

    // MARK: - Where the logs are

    /// The directory the session logs live under.
    ///
    /// `CLAUDE_CONFIG_DIR` moves Claude Code's whole configuration, logs
    /// included, and someone running two accounts is exactly the person who has
    /// set it. Both arguments are passed in rather than read here so this stays
    /// a function of its inputs and a test can point it at a fixture tree.
    public static func defaultRoot(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let configured = environment["CLAUDE_CONFIG_DIR"]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .flatMap { $0.isEmpty ? nil : directory($0, home: home) }
        let root = configured ?? home.appendingPathComponent(".claude", isDirectory: true)
        return root.appendingPathComponent("projects", isDirectory: true)
    }

    /// An environment value as a directory, or nothing.
    ///
    /// The value reaches us the way the user typed it into a shell profile, so
    /// a leading `~` is a real possibility and is expanded against the home we
    /// were given rather than the process's own. A relative path is refused
    /// outright: it would be relative to a working directory nobody agreed on,
    /// and the honest answer to that is to fall back to the default root.
    private static func directory(_ path: String, home: URL) -> URL? {
        if path == "~" { return home }
        if path.hasPrefix("~/") {
            return home.appendingPathComponent(String(path.dropFirst(2)), isDirectory: true)
        }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    // MARK: - One line

    /// One log line as a turn, or nil for every line that is not one.
    ///
    /// Most lines are not: a session file is mostly user rows, attachments,
    /// mode changes and file-history snapshots. Anything that is not an
    /// assistant row carrying a usage block returns nil rather than throwing,
    /// because a line this does not recognise is the normal case and not an
    /// error — and because a newer Claude Code writing a row shape we have not
    /// seen must cost the caller the row, not the file.
    public static func turn(from line: Data) -> ClaudeCodeTurn? {
        guard !line.isEmpty,
              let object = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
              object["type"] as? String == "assistant",
              let message = object["message"] as? [String: Any],
              let usage = message["usage"] as? [String: Any],
              let messageID = message["id"] as? String, !messageID.isEmpty,
              let model = message["model"] as? String,
              // "<synthetic>" is Claude Code rendering an API error as an
              // assistant turn. It reached no model, always reports zero
              // tokens, and letting it through would put a model nobody ran
              // into a per-model breakdown.
              model != "<synthetic>",
              let stamp = object["timestamp"] as? String,
              let at = ProviderDate.parse(stamp)
        else { return nil }

        return ClaudeCodeTurn(
            at: at,
            model: model,
            inputTokens: tokens(usage["input_tokens"]),
            cacheCreationTokens: tokens(usage["cache_creation_input_tokens"]),
            cacheReadTokens: tokens(usage["cache_read_input_tokens"]),
            outputTokens: tokens(usage["output_tokens"]),
            messageID: messageID,
            sessionID: object["sessionId"] as? String ?? "",
            // Absent on some older rows, and absent means the main thread.
            isSidechain: object["isSidechain"] as? Bool ?? false
        )
    }

    /// A token count, or zero.
    ///
    /// Zero rather than nil throughout: a usage block that omits a field spent
    /// nothing on it, and an optional here would push that same decision onto
    /// every caller.
    private static func tokens(_ value: Any?) -> Int {
        // JSON `true` bridges to NSNumber and would coerce to 1.
        if let boxed = value as? NSNumber, CFGetTypeID(boxed) == CFBooleanGetTypeID() { return 0 }
        guard let raw = ProviderNumber.coerce(value), raw.isFinite, raw > 0 else { return 0 }
        // Refused rather than clamped, and `Int(_: Double)` would trap outright.
        // A figure outside `Int` is not a token count, and saturating it at
        // `Int.max` would put 4.6e18 into the caller's running total — where the
        // sum, not this, is what overflows.
        return Int(exactly: raw.rounded()) ?? 0
    }

    // MARK: - One file

    /// Reads `file` from `offset` and returns the turns found and where to
    /// resume.
    ///
    /// A session file is appended to while the session runs, so the last line
    /// of a read is regularly half written. The returned offset is the byte
    /// after the last newline consumed, never the end of the read: the partial
    /// line is left in the file for the next pass, which is what makes calling
    /// this repeatedly on a live log safe.
    ///
    /// Errors from opening and reading are passed through rather than swallowed
    /// — a directory sweep wants to skip the one file it cannot read, and it
    /// can only do that if it is told.
    public static func scan(file: URL, from offset: UInt64) throws -> (turns: [ClaudeCodeTurn], offset: UInt64) {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }

        // Asked of the open descriptor rather than the file manager, so the
        // size is the one belonging to the bytes about to be read.
        let size = try handle.seekToEnd()
        // A file shorter than where the last pass stopped is not the file that
        // pass read: the session was rotated or rewritten under us. Resuming at
        // the old offset would read nothing for ever, so start over instead.
        let start = offset > size ? 0 : offset
        guard start < size else { return ([], start) }
        try handle.seek(toOffset: start)

        var turns: [ClaudeCodeTurn] = []
        var consumed = start
        // Whatever followed the last newline seen, waiting for the rest of its
        // line. Always rebuilt by `subdata`, so its `startIndex` is zero.
        var buffer = Data()

        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            buffer.append(chunk)

            // Found through the raw buffer: the byte-at-a-time `Data` subscript
            // pays for a copy-on-write check per byte, and a first pass over a
            // year of sessions is tens of millions of them.
            let breaks: [Int] = buffer.withUnsafeBytes { raw in
                var found: [Int] = []
                for (index, byte) in raw.enumerated() where byte == 0x0A { found.append(index) }
                return found
            }

            var lineStart = 0
            for end in breaks {
                let line = buffer.subdata(in: lineStart..<end)
                if let turn = turn(from: line) { turns.append(turn) }
                lineStart = end + 1
            }

            consumed += UInt64(lineStart)
            buffer = lineStart == 0 ? buffer : buffer.subdata(in: lineStart..<buffer.count)
            guard buffer.count <= maximumLine else { break }
        }

        return (turns, consumed)
    }
}
