import XCTest
@testable import aibarsCore

/// What a rollout log says, and nothing beyond it.
///
/// The scanner is the one place in the app that reads a file the user's own
/// tools wrote and we do not control the shape of, so most of this is about
/// what it refuses: a row it does not recognise, a count that is not a number,
/// a line that was still being written when we read it. Deciding what the turns
/// are worth belongs to `ClaudeCodeIndex` and is tested there.
final class ClaudeCodeScannerTests: XCTestCase {

    // MARK: - Harness

    /// A scratch tree per test, torn down afterwards, so no test can read a
    /// transcript belonging to the machine this runs on.
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-scanner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A home that exists only here. `defaultRoot` never touches the file
    /// system, so this does not have to be a real directory — only a stable one.
    private let home = URL(fileURLWithPath: "/Users/tester", isDirectory: true)

    private let usage: [String: Any] = [
        "input_tokens": 4,
        "cache_creation_input_tokens": 1_200,
        "cache_read_input_tokens": 34_567,
        "output_tokens": 210
    ]

    /// A row shaped the way Claude Code writes one, with the one part a test
    /// cares about substituted in.
    ///
    /// Serialised rather than hand-written so every fixture makes the same
    /// round trip the real thing does: JSON `true` and JSON `1.0` only bridge
    /// to the types the parser guards against once they have been through
    /// `JSONSerialization`.
    private func row(
        type: String = "assistant",
        id: Any? = "msg_01AAA",
        model: Any? = "claude-opus-5",
        usage: [String: Any]? = nil,
        timestamp: Any? = "2026-08-10T12:00:00.000Z",
        sessionID: Any? = "8f1c3d2e-0000-4a1b-9c3d-2e0f1a2b3c4d",
        isSidechain: Any? = false
    ) throws -> Data {
        var message: [String: Any] = [
            "type": "message",
            "role": "assistant",
            "content": [["type": "text", "text": "ok"]],
            "stop_reason": "end_turn"
        ]
        message["id"] = id
        message["model"] = model
        message["usage"] = usage ?? self.usage

        var object: [String: Any] = [
            "type": type,
            "parentUuid": "1c0b7c5a-1111-4bbb-8ccc-2d3e4f5a6b7c",
            "userType": "external",
            "cwd": "/Users/tester/git/aibars",
            "version": "2.0.14",
            "gitBranch": "main",
            "requestId": "req_011XYZ",
            "uuid": "9d8c7b6a-2222-4ccc-9ddd-3e4f5a6b7c8d",
            "message": message
        ]
        object["timestamp"] = timestamp
        object["sessionId"] = sessionID
        object["isSidechain"] = isSidechain
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// A row with the usage block removed outright, rather than emptied.
    private func rowWithoutUsage() throws -> Data {
        let full = try row()
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: full) as? [String: Any]
        )
        var message = try XCTUnwrap(object["message"] as? [String: Any])
        message.removeValue(forKey: "usage")
        object["message"] = message
        return try JSONSerialization.data(withJSONObject: object)
    }

    /// Writes `lines` as JSONL and returns the file. `terminated` is the whole
    /// question for a live log: a session being written to right now ends
    /// mid-line, and one that has finished ends with a newline.
    @discardableResult
    private func write(_ lines: [Data], terminated: Bool = true, named name: String = "session.jsonl") throws -> URL {
        var file = Data()
        for (index, line) in lines.enumerated() {
            file.append(line)
            if terminated || index < lines.count - 1 { file.append(0x0A) }
        }
        let url = directory.appendingPathComponent(name)
        try file.write(to: url)
        return url
    }

    private func date(
        year: Int, month: Int, day: Int, hour: Int, minute: Int = 0, second: Int = 0
    ) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar(identifier: .gregorian)
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        components.second = second
        return try XCTUnwrap(components.date)
    }

    // MARK: - One line

    /// The headline case, written out the way the file has it rather than
    /// assembled, so this test also fails if the parser starts reading fields
    /// off some other path.
    func testAssistantRowParsesEveryField() throws {
        let line = Data(#"""
        {"parentUuid":"1c0b7c5a-1111-4bbb-8ccc-2d3e4f5a6b7c","isSidechain":false,"userType":"external","cwd":"/Users/tester/git/aibars","sessionId":"8f1c3d2e-0000-4a1b-9c3d-2e0f1a2b3c4d","version":"2.0.14","gitBranch":"main","type":"assistant","message":{"id":"msg_01ABCdef","type":"message","role":"assistant","model":"claude-opus-5","content":[{"type":"text","text":"ok"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":4,"cache_creation_input_tokens":1200,"cache_read_input_tokens":34567,"output_tokens":210,"service_tier":"standard"}},"requestId":"req_011XYZ","uuid":"9d8c7b6a-2222-4ccc-9ddd-3e4f5a6b7c8d","timestamp":"2026-08-10T12:00:00.000Z"}
        """#.utf8)

        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: line))
        XCTAssertEqual(turn.at, try date(year: 2026, month: 8, day: 10, hour: 12))
        XCTAssertEqual(turn.model, "claude-opus-5", "the model id is carried verbatim, not tidied")
        XCTAssertEqual(turn.inputTokens, 4)
        // The two the rest of the industry drops. They are the bulk of a coding
        // session and they are priced apart from everything else.
        XCTAssertEqual(turn.cacheCreationTokens, 1_200)
        XCTAssertEqual(turn.cacheReadTokens, 34_567)
        XCTAssertEqual(turn.outputTokens, 210)
        XCTAssertEqual(turn.messageID, "msg_01ABCdef")
        XCTAssertEqual(turn.sessionID, "8f1c3d2e-0000-4a1b-9c3d-2e0f1a2b3c4d")
        XCTAssertFalse(turn.isSidechain)
    }

    /// A timestamp without a fractional part is the older writer's, and the
    /// file may hold both shapes at once.
    func testTimestampWithoutFractionalSecondsStillParses() throws {
        let turn = try XCTUnwrap(
            ClaudeCodeScanner.turn(from: try row(timestamp: "2026-08-10T12:00:00Z"))
        )
        XCTAssertEqual(turn.at, try date(year: 2026, month: 8, day: 10, hour: 12))
    }

    /// Carried rather than filtered: the caller separates subagent spend out,
    /// so the scanner has to say which it was.
    func testSidechainRowIsCarriedRatherThanDropped() throws {
        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: try row(isSidechain: true)))
        XCTAssertTrue(turn.isSidechain)
    }

    /// Both fields are absent on older rows, and absent has a meaning in each
    /// case: attribute by file, and the main thread.
    func testAbsentSessionAndSidechainTakeTheirDefaults() throws {
        let turn = try XCTUnwrap(
            ClaudeCodeScanner.turn(from: try row(sessionID: nil, isSidechain: nil))
        )
        XCTAssertEqual(turn.sessionID, "")
        XCTAssertFalse(turn.isSidechain)
    }

    /// Most of a session file is these. None of them is an error.
    func testRowsThatAreNotAssistantTurnsReturnNil() throws {
        for type in ["user", "mode", "last-prompt", "summary", "file-history-snapshot", "system"] {
            XCTAssertNil(
                ClaudeCodeScanner.turn(from: try row(type: type)),
                "a \(type) row is not a turn"
            )
        }
    }

    /// A row with no usage block is a row that says nothing about cost. Reading
    /// it as a turn of zeros would put a turn nobody paid for into the count.
    func testAssistantRowWithoutUsageReturnsNil() throws {
        XCTAssertNil(ClaudeCodeScanner.turn(from: try rowWithoutUsage()))
    }

    /// "<synthetic>" is an API error rendered as an assistant turn. It reached
    /// no model, so it must not appear in a per-model breakdown.
    func testSyntheticModelReturnsNil() throws {
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(model: "<synthetic>")))
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(model: nil)))
    }

    /// The message id is the dedupe key, so a row without a usable one cannot
    /// be counted safely at all.
    func testRowWithoutAUsableMessageIDReturnsNil() throws {
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(id: nil)))
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(id: "")))
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(id: 42)))
    }

    /// Every use of a turn is a window, so a turn with no time it belongs to is
    /// dropped rather than stamped with the time it was read.
    func testRowWithoutAReadableTimestampReturnsNil() throws {
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(timestamp: nil)))
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(timestamp: "yesterday")))
        XCTAssertNil(ClaudeCodeScanner.turn(from: try row(timestamp: "")))
    }

    /// One bad line must cost the caller that line and nothing else, which
    /// means it cannot throw.
    func testMalformedLinesReturnNilWithoutThrowing() throws {
        let full = try row()
        let truncated = full.prefix(full.count / 2)
        for line in [
            Data(),
            Data("not json at all".utf8),
            Data(truncated),
            Data(#"{"type":"assistant","message":{"#.utf8),
            // Valid JSON, wrong root: an array and a bare string are both
            // things a half-written or hand-edited file can hold.
            Data(#"["type","assistant"]"#.utf8),
            Data(#""assistant""#.utf8),
            Data([0xFF, 0xFE, 0x00, 0x01])
        ] {
            XCTAssertNil(ClaudeCodeScanner.turn(from: line))
        }
    }

    /// Some writers quote their numbers. `ProviderNumber` tolerates that
    /// everywhere else in this codebase and it has to here too.
    func testStringTokenCountsAreCoerced() throws {
        let line = try row(usage: [
            "input_tokens": "4",
            "cache_creation_input_tokens": "1200",
            "cache_read_input_tokens": "34567",
            "output_tokens": "210"
        ])
        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: line))
        XCTAssertEqual(turn.inputTokens, 4)
        XCTAssertEqual(turn.cacheCreationTokens, 1_200)
        XCTAssertEqual(turn.cacheReadTokens, 34_567)
        XCTAssertEqual(turn.outputTokens, 210)
    }

    /// A usage block that omits a field spent nothing on it. The row is still a
    /// turn: it reached a model and it has a time.
    func testMissingTokenFieldsCountAsZero() throws {
        let line = try row(usage: ["output_tokens": 210])
        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: line))
        XCTAssertEqual(turn.inputTokens, 0)
        XCTAssertEqual(turn.cacheCreationTokens, 0)
        XCTAssertEqual(turn.cacheReadTokens, 0)
        XCTAssertEqual(turn.outputTokens, 210)
    }

    /// An empty usage block is a turn of zeros, not a dropped row: the block is
    /// there, it just claims nothing.
    func testEmptyUsageBlockIsATurnOfZeros() throws {
        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: try row(usage: [:])))
        XCTAssertEqual(turn.inputTokens, 0)
        XCTAssertEqual(turn.outputTokens, 0)
        XCTAssertEqual(turn.messageID, "msg_01AAA")
    }

    /// Everything a token count can be and still not be one. Each of these
    /// would otherwise reach the caller's running total, where the sum is what
    /// breaks rather than this.
    func testCountsThatAreNotTokenCountsAreZero() throws {
        let cases: [(String, Any)] = [
            ("zero", 0),
            ("negative", -5),
            ("negative fraction", -0.4),
            ("not a number", "many"),
            ("nan", "nan"),
            ("infinity", "inf"),
            ("past Int", 1e30),
            ("boolean true", true),
            ("null", NSNull()),
            ("an object", ["value": 12]),
            ("an array", [12])
        ]
        for (name, value) in cases {
            let turn = try XCTUnwrap(
                ClaudeCodeScanner.turn(from: try row(usage: ["input_tokens": value])),
                "\(name) should cost the field, not the row"
            )
            XCTAssertEqual(turn.inputTokens, 0, "\(name) reached the count")
        }
    }

    /// Tokens are whole things. A writer that reports a fraction gets rounded
    /// rather than truncated or refused.
    func testFractionalTokenCountRoundsToTheNearestWhole() throws {
        let line = try row(usage: ["input_tokens": 12.6, "output_tokens": 0.4])
        let turn = try XCTUnwrap(ClaudeCodeScanner.turn(from: line))
        XCTAssertEqual(turn.inputTokens, 13)
        // Rounds to zero, which is what a sub-token count is worth.
        XCTAssertEqual(turn.outputTokens, 0)
    }

    // MARK: - Where the logs are

    func testDefaultRootFallsBackToHomeClaude() {
        XCTAssertEqual(
            ClaudeCodeScanner.defaultRoot(environment: [:], home: home).path,
            "/Users/tester/.claude/projects"
        )
    }

    /// Someone running two accounts is exactly the person who has set this.
    func testDefaultRootHonoursConfigDir() {
        XCTAssertEqual(
            ClaudeCodeScanner.defaultRoot(
                environment: ["CLAUDE_CONFIG_DIR": "/opt/claude-work"],
                home: home
            ).path,
            "/opt/claude-work/projects"
        )
    }

    /// The value arrives the way it was typed into a shell profile, so a
    /// leading `~` and stray whitespace are both ordinary.
    func testDefaultRootExpandsTildeAndTrimsWhitespace() {
        let cases = [
            "~": "/Users/tester/projects",
            "~/alt": "/Users/tester/alt/projects",
            "~/alt/deeper": "/Users/tester/alt/deeper/projects",
            "  /opt/claude-work  ": "/opt/claude-work/projects",
            "\t~/alt\n": "/Users/tester/alt/projects"
        ]
        for (value, expected) in cases {
            XCTAssertEqual(
                ClaudeCodeScanner.defaultRoot(
                    environment: ["CLAUDE_CONFIG_DIR": value],
                    home: home
                ).path,
                expected,
                "CLAUDE_CONFIG_DIR=\(value)"
            )
        }
    }

    /// A relative path is relative to a working directory nobody agreed on, and
    /// blank is not an answer. Both fall back rather than guess.
    func testDefaultRootRefusesConfigDirItCannotResolve() {
        for value in ["", "   ", "\n", "relative/dir", "./claude", "../claude"] {
            XCTAssertEqual(
                ClaudeCodeScanner.defaultRoot(
                    environment: ["CLAUDE_CONFIG_DIR": value],
                    home: home
                ).path,
                "/Users/tester/.claude/projects",
                "CLAUDE_CONFIG_DIR=\(value) should not have been resolved"
            )
        }
    }

    // MARK: - One file

    func testScanFromZeroReadsEveryTurnAndReportsTheFileLength() throws {
        let lines = [
            try row(id: "msg_1"),
            try row(type: "user"),
            try row(id: "msg_2"),
            try row(id: "msg_3")
        ]
        let file = try write(lines)

        let result = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_1", "msg_2", "msg_3"])
        // Every line was terminated, so nothing is held back.
        let size = try XCTUnwrap(
            FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int
        )
        XCTAssertEqual(result.offset, UInt64(size))
    }

    /// The whole point of the offset: a second pass over a live log reads only
    /// what was appended since the first.
    func testScanFromAMidFileOffsetReturnsOnlyTheTurnsAfterIt() throws {
        let first = try row(id: "msg_1")
        let second = try row(id: "msg_2")
        let file = try write([first, second])

        let resume = UInt64(first.count + 1)
        let result = try ClaudeCodeScanner.scan(file: file, from: resume)
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_2"])
        XCTAssertEqual(result.offset, UInt64(first.count + second.count + 2))
    }

    /// The case that makes repeated scanning of a running session safe. The
    /// last line is half written, so it is neither parsed nor consumed, and the
    /// next pass — after the writer finished it — returns it exactly once.
    func testPartialLastLineIsLeftForTheNextPass() throws {
        let complete = try row(id: "msg_1")
        let partial = try row(id: "msg_2")
        let cut = partial.prefix(partial.count / 2)

        let file = directory.appendingPathComponent("live.jsonl")
        var contents = complete
        contents.append(0x0A)
        contents.append(contentsOf: cut)
        try contents.write(to: file)

        let first = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertEqual(first.turns.map(\.messageID), ["msg_1"])
        XCTAssertEqual(
            first.offset,
            UInt64(complete.count + 1),
            "the offset must stop at the byte after the last newline, or the partial line is lost"
        )

        // The writer finishes the line.
        var finished = contents
        finished.append(contentsOf: partial.suffix(partial.count - cut.count))
        finished.append(0x0A)
        try finished.write(to: file)

        let second = try ClaudeCodeScanner.scan(file: file, from: first.offset)
        XCTAssertEqual(second.turns.map(\.messageID), ["msg_2"], "the line was lost or read twice")
        XCTAssertEqual(second.offset, UInt64(finished.count))
    }

    /// A sweep wants to skip the one file it cannot read, and it can only do
    /// that if it is told. Reporting nothing would read as an idle day.
    func testScanOfAMissingFileThrows() {
        let missing = directory.appendingPathComponent("gone.jsonl")
        XCTAssertThrowsError(try ClaudeCodeScanner.scan(file: missing, from: 0))
    }

    func testEmptyFileYieldsNothingAndStaysAtZero() throws {
        let file = try write([])
        let result = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertTrue(result.turns.isEmpty)
        XCTAssertEqual(result.offset, 0)
    }

    func testScanFromTheEndOfTheFileReadsNothing() throws {
        let line = try row()
        let file = try write([line])
        let end = UInt64(line.count + 1)

        let result = try ClaudeCodeScanner.scan(file: file, from: end)
        XCTAssertTrue(result.turns.isEmpty)
        XCTAssertEqual(result.offset, end, "the watermark must not move backwards")
    }

    /// A file shorter than the offset is not the file that offset came from:
    /// the session was rotated or rewritten. Resuming would read nothing for
    /// ever, so the scan starts over.
    func testAnOffsetPastTheEndOfTheFileStartsOver() throws {
        let line = try row(id: "msg_fresh")
        let file = try write([line])

        let result = try ClaudeCodeScanner.scan(file: file, from: 9_000_000)
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_fresh"])
        XCTAssertEqual(result.offset, UInt64(line.count + 1))
    }

    /// One unreadable line costs its own turn and nothing around it.
    func testOneBadLineDoesNotCostTheRestOfTheFile() throws {
        let file = try write([
            try row(id: "msg_1"),
            Data("{ this was never valid json".utf8),
            Data(),
            Data("   ".utf8),
            try row(id: "msg_2")
        ])

        let result = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_1", "msg_2"])
    }

    /// An offset that does not land on a line boundary can only come from a
    /// watermark that no longer matches the file. The bytes to the next newline
    /// are not a line, so they are dropped — and the scan resynchronises rather
    /// than throwing or reading rubbish.
    func testResumingInsideALineDropsOnlyThatLine() throws {
        let first = try row(id: "msg_1")
        let second = try row(id: "msg_2")
        let file = try write([first, second])

        let result = try ClaudeCodeScanner.scan(file: file, from: UInt64(first.count / 2))
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_2"])
        XCTAssertEqual(result.offset, UInt64(first.count + second.count + 2))
    }

    /// The reason the scan buffers at all. A tool result runs to hundreds of
    /// kilobytes, so lines routinely straddle a read, and a scanner that parsed
    /// each chunk on its own would lose every one of them.
    func testLinesSpanningSeveralReadsAreStillParsed() throws {
        // Comfortably past the 256 KB chunk, three times over, so at least two
        // lines are split and one read holds no newline at all.
        let padding = String(repeating: "a", count: 300_000)
        let lines = try (1...3).map { index in
            try row(id: "msg_\(index)", usage: [
                "input_tokens": 4,
                "output_tokens": 210,
                "padding": padding
            ])
        }
        let file = try write(lines)

        let result = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertEqual(result.turns.map(\.messageID), ["msg_1", "msg_2", "msg_3"])
        XCTAssertEqual(result.turns.map(\.outputTokens), [210, 210, 210])
        XCTAssertEqual(result.offset, UInt64(lines.reduce(0) { $0 + $1.count + 1 }))
    }

    /// Duplicates are the index's problem, not this one: a subagent log copies
    /// its parent's rows, and the scanner's job is to report what the file says.
    func testRepeatedMessageIDsAreReportedRatherThanDeduplicated() throws {
        let file = try write([try row(id: "msg_dup"), try row(id: "msg_dup")])
        let result = try ClaudeCodeScanner.scan(file: file, from: 0)
        XCTAssertEqual(result.turns.count, 2)
    }
}
