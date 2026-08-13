import XCTest
@testable import aibarsCore

/// The incremental index over Claude Code's transcripts.
///
/// Everything here is driven by a fixture tree and a `now` the test supplies,
/// so nothing depends on the machine's real clock, its real `~/.claude`, or on
/// waiting out a five-hour window. Two things are being pinned down: what the
/// windows add up to, and what the sweep is allowed to touch — the second
/// matters as much as the first, because the whole point of the watermarks is
/// that a refresh does not reread a gigabyte.
final class ClaudeCodeIndexTests: XCTestCase {

    // MARK: - Harness

    /// Noon, on a day chosen for being unremarkable — 2027-01-15, no daylight
    /// saving shift in the zones this is likely to run in. Every fixture is
    /// placed as an offset from here, all of them under twelve hours, so every
    /// turn lands on the same local day whatever zone the test machine is in.
    private let now = Calendar.current
        .startOfDay(for: Date(timeIntervalSince1970: 1_800_000_000))
        .addingTimeInterval(12 * 60 * 60)

    /// A modification date old enough that the sweep treats the file's last
    /// turn as finished rather than holding it back. Five minutes is the
    /// settle delay; ten is comfortably past it.
    private var settled: Date { now.addingTimeInterval(-10 * 60) }

    /// The key the index writes its state under. Hard-coded rather than reached
    /// for: it is private on purpose, and a test that reads it is asserting on
    /// the stored shape, which is not what any of these are about.
    private let stateKey = "aibars.claudeCode.index"

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("claude-code-index-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    /// A scratch domain per test, torn down afterwards, so one test's index is
    /// never another's launch state and nothing here touches the user's own
    /// settings.
    private func scratchDefaults(_ label: String = #function) throws -> UserDefaults {
        // Stable, not a UUID. `TestDomain` in `TestIsolation.swift` has the
        // measurement: `removePersistentDomain` empties a domain and does not
        // delete its file, so a fresh name per run left a plist behind every time.
        let name = TestDomain.stable("\(TestDomain.prefix).claude-code-index.\(label)")
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return try XCTUnwrap(UserDefaults(suiteName: name))
    }

    private func makeIndex(
        store: UserDefaults,
        lookback: TimeInterval = 30 * 24 * 60 * 60
    ) -> ClaudeCodeIndex {
        ClaudeCodeIndex(root: root, store: store, lookback: lookback)
    }

    /// A time of day today. Offsets are given in local clock terms because the
    /// block boundary snaps to the top of the local hour.
    private func today(_ hour: Int, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar.current.startOfDay(for: now)
            .addingTimeInterval(TimeInterval(hour * 3600 + minute * 60 + second))
    }

    // MARK: - Fixtures

    /// One assistant row, written the way Claude Code writes it.
    private func assistantLine(
        id: String,
        at: Date,
        model: String = "claude-opus-5",
        input: Int = 100,
        output: Int = 10,
        cacheCreation: Int = 0,
        cacheRead: Int = 0
    ) -> String {
        """
        {"type":"assistant","sessionId":"s1","isSidechain":false,\
        "timestamp":"\(ProviderDate.iso8601.string(from: at))",\
        "message":{"id":"\(id)","model":"\(model)","usage":{\
        "input_tokens":\(input),"output_tokens":\(output),\
        "cache_creation_input_tokens":\(cacheCreation),\
        "cache_read_input_tokens":\(cacheRead)}}}
        """
    }

    @discardableResult
    private func writeRaw(_ name: String, _ text: String, modified: Date? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(text.utf8).write(to: url)
        try touch(url, modified ?? settled)
        return url
    }

    @discardableResult
    private func write(_ name: String, _ lines: [String], modified: Date? = nil) throws -> URL {
        try writeRaw(name, lines.joined(separator: "\n") + "\n", modified: modified)
    }

    /// Appends by rewriting the file with the old bytes in front of the new
    /// ones. From the index's side that is indistinguishable from a real
    /// append — same prefix, larger size, later mtime — and it saves juggling
    /// a file handle whose close would otherwise fight the mtime being set.
    private func appendRaw(_ name: String, _ text: String, modified: Date? = nil) throws {
        let url = root.appendingPathComponent(name)
        let existing = try Data(contentsOf: url)
        try (existing + Data(text.utf8)).write(to: url)
        try touch(url, modified ?? settled)
    }

    private func append(_ name: String, _ lines: [String], modified: Date? = nil) throws {
        try appendRaw(name, lines.joined(separator: "\n") + "\n", modified: modified)
    }

    private func touch(_ url: URL, _ date: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: date],
            ofItemAtPath: url.path
        )
    }

    private func indexed(
        _ at: Date,
        model: String = "claude-opus-5",
        id: String = "m1"
    ) -> IndexedTurn {
        IndexedTurn(ClaudeCodeTurn(
            at: at,
            model: model,
            inputTokens: 0,
            cacheCreationTokens: 0,
            cacheReadTokens: 0,
            outputTokens: 0,
            messageID: id,
            sessionID: "s1",
            isSidechain: false
        ))
    }

    // MARK: - The first sweep

    func testTheFirstRefreshReadsEveryTranscriptUnderTheRoot() throws {
        try write("projects/one/a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-3 * 3600), input: 100, output: 10),
            assistantLine(id: "a2", at: now.addingTimeInterval(-2 * 3600), input: 200, output: 20),
        ])
        try write("projects/two/b.jsonl", [
            assistantLine(id: "b1", at: now.addingTimeInterval(-90 * 60), input: 1, output: 2,
                          cacheCreation: 3, cacheRead: 4),
            assistantLine(id: "b2", at: now.addingTimeInterval(-60 * 60), input: 5, output: 6),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 4)
        XCTAssertEqual(totals.month.inputTokens, 306)
        XCTAssertEqual(totals.month.outputTokens, 38)
        XCTAssertEqual(totals.month.cacheCreationTokens, 3)
        XCTAssertEqual(totals.month.cacheReadTokens, 4)
        XCTAssertEqual(totals.today, totals.month, "every fixture turn is on today's date")
        XCTAssertEqual(totals.week, totals.month)
        XCTAssertEqual(totals.lastTurnAt, now.addingTimeInterval(-60 * 60))
    }

    func testAppendingToATranscriptAddsOnlyTheNewTurns() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-3 * 3600), input: 100),
        ])
        let index = makeIndex(store: try scratchDefaults())

        XCTAssertEqual(try index.refresh(now: now).month.turns, 1)

        try append("a.jsonl", [
            assistantLine(id: "a2", at: now.addingTimeInterval(-2 * 3600), input: 100),
        ])
        let second = try index.refresh(now: now)

        // Two, not three: the bytes read on the first pass are not read again.
        XCTAssertEqual(second.month.turns, 2)
        XCTAssertEqual(second.month.inputTokens, 200)
    }

    func testAnUnchangedTranscriptIsNotOpenedOnTheNextRefresh() throws {
        let url = try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-3 * 3600)),
        ])
        let store = try scratchDefaults()
        let index = makeIndex(store: store)
        let first = try index.refresh(now: now)

        // Two independent proofs, because either alone is weak. The mode change
        // shows the sweep never needs the file's contents; clearing the stored
        // state shows nothing was written, and a sweep that had reopened the
        // file would have rewritten its watermark and persisted again.
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        addTeardownBlock {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644],
                ofItemAtPath: url.path
            )
        }
        try XCTSkipIf(
            FileManager.default.isReadableFile(atPath: url.path),
            "this user can read a mode 000 file, so the fixture proves nothing"
        )
        store.removeObject(forKey: stateKey)

        let second = try index.refresh(now: now)
        XCTAssertEqual(second, first)
        XCTAssertNil(
            store.data(forKey: stateKey),
            "the second sweep changed state, which it could not have without opening the file"
        )
    }

    func testAMessageWrittenTwiceInOneFileCountsOnceAtItsFinalFigures() throws {
        // Claude Code rewrites an assistant row as it streams, each line
        // repeating the message id with a larger output count than the last.
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-2 * 3600), input: 900, output: 6),
            assistantLine(id: "a1", at: now.addingTimeInterval(-2 * 3600), input: 900, output: 17_000),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1)
        XCTAssertEqual(totals.month.outputTokens, 17_000, "the last line supersedes the ones before it")
        XCTAssertEqual(totals.month.inputTokens, 900)
    }

    func testATurnCaughtMidStreamTakesItsLaterFigureOnTheNextRefresh() throws {
        // The file was written a moment ago, so its last turn is held back
        // rather than summed — but it still has to be reported, because a
        // window that ignores the turn happening right now is wrong.
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-60), output: 6),
        ], modified: now.addingTimeInterval(-30))
        let index = makeIndex(store: try scratchDefaults())

        let first = try index.refresh(now: now)
        XCTAssertEqual(first.month.turns, 1)
        XCTAssertEqual(first.month.outputTokens, 6)

        try append("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-60), output: 17_000),
        ], modified: now.addingTimeInterval(-10))
        let second = try index.refresh(now: now)

        XCTAssertEqual(second.month.turns, 1, "the held-back turn was replaced, not added to")
        XCTAssertEqual(second.month.outputTokens, 17_000)
    }

    // MARK: - What the sweep declines to open

    func testATranscriptOlderThanTheLookbackIsLeftAlone() throws {
        let old = now.addingTimeInterval(-40 * 24 * 3600)
        try write("stale.jsonl", [assistantLine(id: "s1", at: old)], modified: old)
        try write("fresh.jsonl", [assistantLine(id: "f1", at: now.addingTimeInterval(-3600))])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1)
        XCTAssertEqual(totals.lastTurnAt, now.addingTimeInterval(-3600))
    }

    func testTranscriptsEitherSideOfTheLookbackBoundary() throws {
        let lookback: TimeInterval = 3600
        let cutoff = now.addingTimeInterval(-lookback)

        // A second inside the cutoff on both counts.
        try write("inside.jsonl", [
            assistantLine(id: "i1", at: cutoff.addingTimeInterval(1), input: 7),
        ], modified: cutoff.addingTimeInterval(1))
        // A second outside it: never opened, whatever it contains.
        try write("outside.jsonl", [
            assistantLine(id: "o1", at: cutoff.addingTimeInterval(-1), input: 9),
        ], modified: cutoff.addingTimeInterval(-1))
        // Opened, because its mtime is inside — but the turn itself is exactly
        // on the cutoff, which the window includes, and one second before it,
        // which it does not.
        try write("straddling.jsonl", [
            assistantLine(id: "e1", at: cutoff, input: 100),
            assistantLine(id: "e2", at: cutoff.addingTimeInterval(-1), input: 1_000),
        ])

        let totals = try makeIndex(store: try scratchDefaults(), lookback: lookback).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 2)
        XCTAssertEqual(totals.month.inputTokens, 107)
    }

    func testATurnDatedAfterNowIsRefusedRatherThanCounted() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-600), input: 5),
            assistantLine(id: "a2", at: now.addingTimeInterval(600), input: 5_000),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1, "a turn in the future is a clock problem, not usage")
        XCTAssertEqual(totals.month.inputTokens, 5)
    }

    func testFilesThatAreNotTranscriptsAreIgnored() throws {
        try write("notes.json", [assistantLine(id: "x1", at: now.addingTimeInterval(-3600))])
        try write("a.jsonl.tmp", [assistantLine(id: "x2", at: now.addingTimeInterval(-3600))])
        try write(".hidden.jsonl", [assistantLine(id: "x3", at: now.addingTimeInterval(-3600))])
        try write("deep/er/still/real.jsonl", [
            assistantLine(id: "r1", at: now.addingTimeInterval(-3600)),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1, "only the nested .jsonl is a transcript")
    }

    // MARK: - Files that change underneath the watermark

    func testATruncatedTranscriptIsRescannedRatherThanSkippedForEver() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-4 * 3600), input: 100),
            assistantLine(id: "a2", at: now.addingTimeInterval(-3 * 3600), input: 100),
        ])
        let index = makeIndex(store: try scratchDefaults())
        XCTAssertEqual(try index.refresh(now: now).month.turns, 2)

        // The session was rotated: same path, shorter file, so the watermark is
        // now past the end of it.
        try write("a.jsonl", [
            assistantLine(id: "a3", at: now.addingTimeInterval(-2 * 3600), input: 7),
        ])
        let second = try index.refresh(now: now)

        // Three, because the two already summed are not unmade by the rotation:
        // the work happened whether or not the file survived it.
        XCTAssertEqual(second.month.turns, 3)
        XCTAssertEqual(second.month.inputTokens, 207)
    }

    func testATranscriptReplacedAtTheSameSizeAddsNothingAndStaysReadable() throws {
        let first = assistantLine(id: "aaa1", at: now.addingTimeInterval(-3 * 3600), input: 100)
        let replacement = assistantLine(id: "bbb2", at: now.addingTimeInterval(-3 * 3600), input: 100)
        XCTAssertEqual(
            first.utf8.count, replacement.utf8.count,
            "the fixture is not actually the same size, so this asserts nothing"
        )

        try write("a.jsonl", [first])
        let index = makeIndex(store: try scratchDefaults())
        XCTAssertEqual(try index.refresh(now: now).month.turns, 1)

        try write("a.jsonl", [replacement], modified: now.addingTimeInterval(-9 * 60))
        let second = try index.refresh(now: now)

        // The later mtime does bring the file back into the sweep, but the
        // watermark is already at its end and nothing was appended past it, so
        // there is nothing to read. Transcripts are appended to, never rewritten
        // in place, so what matters here is that the count does not drift and
        // the watermark stays coherent for the next real append.
        XCTAssertEqual(second.month.turns, 1)

        try append("a.jsonl", [
            assistantLine(id: "ccc3", at: now.addingTimeInterval(-2 * 3600), input: 50),
        ], modified: now.addingTimeInterval(-8 * 60))
        let third = try index.refresh(now: now)
        XCTAssertEqual(third.month.turns, 2)
        XCTAssertEqual(third.month.inputTokens, 150)
    }

    func testAHalfWrittenLineIsCountedOnlyOnceItIsFinished() throws {
        let complete = assistantLine(id: "a2", at: now.addingTimeInterval(-2 * 3600), input: 40)
        let half = String(complete.prefix(complete.count / 2))

        try writeRaw(
            "a.jsonl",
            assistantLine(id: "a1", at: now.addingTimeInterval(-3 * 3600), input: 20) + "\n" + half
        )
        let index = makeIndex(store: try scratchDefaults())

        let first = try index.refresh(now: now)
        XCTAssertEqual(first.month.turns, 1, "a line with no newline yet is not a line")
        XCTAssertEqual(first.month.inputTokens, 20)

        try appendRaw("a.jsonl", String(complete.dropFirst(half.count)) + "\n")
        let second = try index.refresh(now: now)

        XCTAssertEqual(second.month.turns, 2, "the offset never advanced over the partial line")
        XCTAssertEqual(second.month.inputTokens, 60)
    }

    // MARK: - Lines that are not turns

    func testRowsThatAreNotUsableAssistantTurnsContributeNothing() throws {
        let stamp = ProviderDate.iso8601.string(from: now.addingTimeInterval(-3600))
        try write("a.jsonl", [
            "not json at all",
            "",
            #"{"type":"user","timestamp":"\#(stamp)","message":{"role":"user"}}"#,
            // Assistant, but with no usage block.
            #"{"type":"assistant","timestamp":"\#(stamp)","message":"# +
            #"{"id":"n1","model":"claude-opus-5"}}"#,
            // Claude Code rendering an API error as a turn: no model ran.
            assistantLine(id: "n2", at: now.addingTimeInterval(-3600), model: "<synthetic>"),
            // A timestamp nothing can parse: dropped rather than stamped with
            // the time it was read.
            #"{"type":"assistant","timestamp":"whenever","message":"# +
            #"{"id":"n3","model":"claude-opus-5","usage":{"input_tokens":5}}}"#,
            // A number outside Double: the line will not parse at all, and the
            // file has to carry on past it.
            #"{"type":"assistant","timestamp":"\#(stamp)","message":"# +
            #"{"id":"n4","model":"claude-opus-5","usage":{"input_tokens":1e999}}}"#,
            assistantLine(id: "good", at: now.addingTimeInterval(-1800), input: 11),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1)
        XCTAssertEqual(totals.month.inputTokens, 11)
    }

    func testTokenFiguresThatAreNotCountsAreTakenAsZero() throws {
        let stamp = ProviderDate.iso8601.string(from: now.addingTimeInterval(-3600))
        try write("a.jsonl", [
            #"{"type":"assistant","timestamp":"\#(stamp)","message":"# +
            #"{"id":"a1","model":"claude-opus-5","usage":"# +
            #"{"input_tokens":-5,"output_tokens":true,"cache_read_input_tokens":"250"}}}"#,
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1, "a corrupt usage block is still a turn that happened")
        XCTAssertEqual(totals.month.inputTokens, 0, "a negative count is corruption, not a refund")
        XCTAssertEqual(totals.month.outputTokens, 0, "JSON true bridges to 1 and must not read as a token")
        XCTAssertEqual(totals.month.cacheCreationTokens, 0, "an omitted field spent nothing")
        XCTAssertEqual(totals.month.cacheReadTokens, 250)
        // 250 cache reads at 0.50 per million.
        XCTAssertEqual(try XCTUnwrap(totals.month.estimatedUSD), 0.000125, accuracy: 1e-12)
    }

    func testATurnThatSpentNothingIsStillATurn() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-3600),
                          input: 0, output: 0, cacheCreation: 0, cacheRead: 0),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1)
        XCTAssertEqual(totals.month.inputTokens, 0)
        XCTAssertEqual(try XCTUnwrap(totals.month.estimatedUSD), 0, accuracy: 1e-12)
        XCTAssertNotEqual(totals.month, .empty, "a free turn is not the absence of turns")
    }

    // MARK: - The windows

    func testTheDayBoundarySeparatesTodayFromTheRestOfTheWeek() throws {
        let midnight = Calendar.current.startOfDay(for: now)
        try write("a.jsonl", [
            assistantLine(id: "y1", at: midnight.addingTimeInterval(-1), input: 1),
            assistantLine(id: "t1", at: midnight, input: 10),
            assistantLine(id: "t2", at: now.addingTimeInterval(-3600), input: 100),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.today.turns, 2)
        XCTAssertEqual(totals.today.inputTokens, 110, "midnight belongs to the day it opens")
        XCTAssertEqual(totals.week.turns, 3)
        XCTAssertEqual(totals.month.turns, 3)
    }

    func testTheSessionWindowDropsTheTurnsBeforeTheBlockOpened() throws {
        // 06:30 and then 11:30 — five hours apart, so the second opens a new
        // block at the top of its own hour and the first is on the far side.
        try write("a.jsonl", [
            assistantLine(id: "a1", at: today(6, 30), input: 1_000),
            assistantLine(id: "a2", at: today(11, 30), input: 7),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.sessionWindow.turns, 1)
        XCTAssertEqual(totals.sessionWindow.inputTokens, 7)
        XCTAssertEqual(totals.today.turns, 2, "the day still holds both")
    }

    func testTheSessionWindowKeepsEveryTurnOfTheBlockItIsIn() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: today(8, 0), input: 1),
            assistantLine(id: "a2", at: today(10, 0), input: 2),
            assistantLine(id: "a3", at: today(11, 30), input: 4),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.sessionWindow.turns, 3)
        XCTAssertEqual(totals.sessionWindow.inputTokens, 7)
    }

    func testANegativeLookbackIsTreatedAsNoneAtAll() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-1), input: 900),
            assistantLine(id: "a2", at: now, input: 3),
        ], modified: now.addingTimeInterval(60))

        let totals = try makeIndex(store: try scratchDefaults(), lookback: -1_000).refresh(now: now)

        XCTAssertEqual(totals.month.turns, 1, "with no lookback only a turn dated exactly now survives")
        XCTAssertEqual(totals.month.inputTokens, 3)
    }

    func testDaysFallOutOfTheWindowsButTheLastTurnIsStillRemembered() throws {
        let last = now.addingTimeInterval(-3600)
        try write("a.jsonl", [
            assistantLine(id: "a1", at: now.addingTimeInterval(-2 * 3600)),
            assistantLine(id: "a2", at: last),
        ])
        let index = makeIndex(store: try scratchDefaults())
        XCTAssertEqual(try index.refresh(now: now).month.turns, 2)

        let later = try index.refresh(now: now.addingTimeInterval(40 * 24 * 3600))

        XCTAssertEqual(later.month, .empty)
        XCTAssertEqual(later.today, .empty)
        XCTAssertEqual(later.week, .empty)
        XCTAssertEqual(later.sessionWindow, .empty)
        XCTAssertTrue(later.byModel.isEmpty)
        XCTAssertEqual(
            later.lastTurnAt, last,
            "nothing today has to stay distinguishable from nothing since March"
        )
    }

    // MARK: - The block boundary itself

    func testABlockStaysOpenForFiveHoursAndNotASecondLonger() throws {
        let calendar = Calendar.current

        XCTAssertNil(
            ClaudeCodeIndex.sessionBlockStart(of: [], seed: nil, now: now, calendar: calendar),
            "no turns and no block means no window, not a window at zero"
        )
        XCTAssertEqual(
            ClaudeCodeIndex.sessionBlockStart(
                of: [], seed: now.addingTimeInterval(-(5 * 3600 - 1)), now: now, calendar: calendar
            ),
            now.addingTimeInterval(-(5 * 3600 - 1))
        )
        XCTAssertNil(
            ClaudeCodeIndex.sessionBlockStart(
                of: [], seed: now.addingTimeInterval(-5 * 3600), now: now, calendar: calendar
            ),
            "five hours to the second is the block having run out"
        )
    }

    func testABlockOpensAtTheTopOfTheHourOfTheTurnThatStartedIt() throws {
        let start = ClaudeCodeIndex.sessionBlockStart(
            of: [indexed(today(11, 37, 42))],
            seed: nil,
            now: now,
            calendar: Calendar.current
        )
        XCTAssertEqual(start, today(11))
    }

    func testAGapOfAWholeWindowOpensTheNextBlockAndOneSecondLessDoesNot() throws {
        let calendar = Calendar.current

        let opened = ClaudeCodeIndex.sessionBlockStart(
            of: [indexed(today(6), id: "a"), indexed(today(11), id: "b")],
            seed: nil,
            now: today(11, 30),
            calendar: calendar
        )
        XCTAssertEqual(opened, today(11))

        let held = ClaudeCodeIndex.sessionBlockStart(
            of: [indexed(today(6), id: "a"), indexed(today(10, 59, 59), id: "b")],
            seed: nil,
            now: today(10, 59, 59),
            calendar: calendar
        )
        XCTAssertEqual(held, today(6), "a second short of the window is the same block")
    }

    func testTheSeedCarriesTheChainAcrossADayOfUnbrokenWork() throws {
        // The turn that opened this block fell out of `recent` hours ago, so
        // only the seed knows where the boundary is.
        let start = ClaudeCodeIndex.sessionBlockStart(
            of: [indexed(today(11, 30))],
            seed: today(8),
            now: now,
            calendar: Calendar.current
        )
        XCTAssertEqual(start, today(8), "a turn inside the block does not restart it")
    }

    func testAGapBetweenTwoTurnsOlderThanTheSeedStillOpensABlock() throws {
        // Both turns predate the seed, so neither is a window's length past it;
        // the gap between them is what opens the new block.
        let start = ClaudeCodeIndex.sessionBlockStart(
            of: [indexed(today(4), id: "a"), indexed(today(9, 30), id: "b")],
            seed: today(10),
            now: today(10),
            calendar: Calendar.current
        )
        XCTAssertEqual(start, today(9))
    }

    // MARK: - Models and money

    func testByModelSplitsTheMonthAndAddsBackUpToIt() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: today(9), model: "claude-opus-5",
                          input: 1_000_000, output: 200_000),
            assistantLine(id: "a2", at: today(10), model: "claude-haiku-4-5",
                          input: 2_000_000, output: 400_000),
            assistantLine(id: "a3", at: today(11), model: "claude-haiku-4-5",
                          input: 0, output: 0),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals.byModel.count, 2)
        XCTAssertEqual(totals.byModel["claude-opus-5"]?.turns, 1)
        XCTAssertEqual(totals.byModel["claude-haiku-4-5"]?.turns, 2)

        let parts = totals.byModel.values
        XCTAssertEqual(parts.reduce(0) { $0 + $1.turns }, totals.month.turns)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.inputTokens }, totals.month.inputTokens)
        XCTAssertEqual(parts.reduce(0) { $0 + $1.outputTokens }, totals.month.outputTokens)

        // opus 5: 1M in at $5 plus 200k out at $25. haiku 4.5: 2M in at $1 plus
        // 400k out at $5.
        XCTAssertEqual(try XCTUnwrap(totals.byModel["claude-opus-5"]?.estimatedUSD), 10, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.byModel["claude-haiku-4-5"]?.estimatedUSD), 4, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(totals.month.estimatedUSD), 14, accuracy: 1e-9)
    }

    func testOneUnpricedModelLeavesTheTotalUnstatedWithoutHidingTheTokens() throws {
        try write("a.jsonl", [
            assistantLine(id: "a1", at: today(10), model: "claude-opus-5",
                          input: 1_000_000, output: 0),
            assistantLine(id: "a2", at: today(11), model: "claude-quasar-9", input: 500, output: 5),
        ])

        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertNil(totals.month.estimatedUSD, "part of a bill would read as a smaller bill")
        XCTAssertEqual(totals.month.turns, 2)
        XCTAssertEqual(totals.month.inputTokens, 1_000_500, "the tokens are still counted")
        XCTAssertNil(totals.byModel["claude-quasar-9"]?.estimatedUSD)
        XCTAssertEqual(try XCTUnwrap(totals.byModel["claude-opus-5"]?.estimatedUSD), 5, accuracy: 1e-9)
    }

    // MARK: - A root that is not there

    func testARootThatDoesNotExistIsReportedRatherThanAnsweredEmpty() throws {
        let missing = root.appendingPathComponent("nowhere", isDirectory: true)
        let index = ClaudeCodeIndex(root: missing, store: try scratchDefaults())

        // Deliberately not empty totals: "Claude Code is not installed here" is
        // something to tell the user, and a zero would read as "installed and
        // idle".
        XCTAssertThrowsError(try index.refresh(now: now)) { error in
            guard let reported = error as? ProviderError, case .configuration = reported else {
                return XCTFail("expected a configuration error, got \(error)")
            }
        }
    }

    func testARootThatIsAFileIsReportedTheSameWay() throws {
        let file = root.appendingPathComponent("projects")
        try Data("not a directory".utf8).write(to: file)
        let index = ClaudeCodeIndex(root: file, store: try scratchDefaults())

        XCTAssertThrowsError(try index.refresh(now: now)) { error in
            guard let reported = error as? ProviderError, case .configuration = reported else {
                return XCTFail("expected a configuration error, got \(error)")
            }
        }
    }

    func testAnEmptyRootAnswersEmptyTotals() throws {
        let totals = try makeIndex(store: try scratchDefaults()).refresh(now: now)

        XCTAssertEqual(totals, .empty)
        XCTAssertNil(totals.lastTurnAt, "read and found nothing is not the same as never read")
    }

    // MARK: - Persistence

    func testTheSumsSurviveARelaunchAndATranscriptThatDidNot() throws {
        let store = try scratchDefaults()
        try write("a.jsonl", [assistantLine(id: "a1", at: today(9), input: 100)])
        try write("b.jsonl", [assistantLine(id: "b1", at: today(10), input: 200)])

        let first = try makeIndex(store: store).refresh(now: now)
        XCTAssertEqual(first.month.turns, 2)

        try FileManager.default.removeItem(at: root.appendingPathComponent("b.jsonl"))
        let second = try makeIndex(store: store).refresh(now: now)

        XCTAssertEqual(second.month.turns, 2, "the work happened whether or not the file survived")
        XCTAssertEqual(second.month.inputTokens, 300)
        XCTAssertEqual(second.lastTurnAt, today(10))
    }

    func testCorruptStoredStateIsDiscardedRatherThanFailedOverAndOver() throws {
        try write("a.jsonl", [assistantLine(id: "a1", at: today(10), input: 100)])

        let corrupt: [(label: String, payload: Data)] = [
            ("garbage", Data("not a state at all".utf8)),
            ("empty", Data()),
            ("wrongShape", Data(#"{}"#.utf8)),
            ("wrongTypes", Data(#"{"f":"nope","d":[],"r":[]}"#.utf8)),
            ("truncated", Data(#"{"f":[],"d":[],"r":["#.utf8)),
        ]

        for (label, payload) in corrupt {
            let store = try scratchDefaults("corrupt-\(label)")
            store.set(payload, forKey: stateKey)

            let totals = try makeIndex(store: store).refresh(now: now)

            XCTAssertEqual(totals.month.turns, 1, "\(label): the log is readable whatever the state said")
            XCTAssertNotEqual(
                store.data(forKey: stateKey), payload,
                "\(label): a value nothing can decode has to go, or it fails at every launch"
            )
        }

        // Not even data: an older build, or another app, writing over the key.
        let store = try scratchDefaults("corrupt-not-data")
        store.set("nonsense", forKey: stateKey)
        XCTAssertEqual(try makeIndex(store: store).refresh(now: now).month.turns, 1)
        XCTAssertNotNil(store.data(forKey: stateKey), "the state was rewritten as something readable")
    }

    func testAStoreThatWasNeverWrittenToIsJustAnEmptyIndex() throws {
        let store = try scratchDefaults()
        XCTAssertNil(store.data(forKey: stateKey))

        try write("a.jsonl", [assistantLine(id: "a1", at: today(10), input: 100)])
        XCTAssertEqual(try makeIndex(store: store).refresh(now: now).month.turns, 1)
        XCTAssertNotNil(store.data(forKey: stateKey))
    }
}
