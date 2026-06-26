import XCTest
@testable import Nemo

final class SQLiteStoreTests: XCTestCase {

    private func tempPath() -> String {
        NSTemporaryDirectory() + "nemo-test-\(UUID().uuidString).db"
    }

    func testMemoryRoundTrip() throws {
        let store = try XCTUnwrap(SQLiteStore(path: tempPath()))
        var m = Memory(title: "Q3 deadline", content: "Oct 15", category: Nemo.Category.decisions.rawValue,
                       entities: ["Q3", "Acme"], importance: 4)
        m.weight = 1.2; m.pinned = true; m.sourceSegmentIds = [UUID(), UUID()]
        store.saveMemories([m])

        let loaded = store.loadMemories()
        XCTAssertEqual(loaded.count, 1)
        let r = loaded[0]
        XCTAssertEqual(r.id, m.id)
        XCTAssertEqual(r.title, "Q3 deadline")
        XCTAssertEqual(r.entities, ["Q3", "Acme"])
        XCTAssertEqual(r.importance, 4)
        XCTAssertEqual(r.weight, 1.2, accuracy: 1e-9)
        XCTAssertTrue(r.pinned)
        XCTAssertEqual(r.sourceSegmentIds, m.sourceSegmentIds)
    }

    func testSaveReplacesAndCounts() throws {
        let store = try XCTUnwrap(SQLiteStore(path: tempPath()))
        store.saveMemories([Memory(title: "A", content: "a"), Memory(title: "B", content: "b")])
        XCTAssertEqual(store.memoryCount, 2)
        store.saveMemories([Memory(title: "C", content: "c")])   // full replace
        XCTAssertEqual(store.memoryCount, 1)
        XCTAssertEqual(store.loadMemories().first?.title, "C")
    }

    /// Delta saves keep the DB exactly equal to the passed set across add / edit / remove, including
    /// when the snapshot is seeded from disk by a fresh store rather than from a prior in-process save.
    func testDeltaSaveAddEditRemove() throws {
        let path = tempPath()
        var a = Memory(title: "A", content: "a")
        let b = Memory(title: "B", content: "b")
        do {
            let store = try XCTUnwrap(SQLiteStore(path: path))
            store.saveMemories([a, b])
        }
        // New store: snapshot must be seeded from disk so the removal of `b` is detected.
        let store = try XCTUnwrap(SQLiteStore(path: path))
        XCTAssertEqual(store.memoryCount, 2)
        a.content = "a-edited"; a.updated = Date()
        store.saveMemories([a])                                  // edit A, drop B
        let loaded = store.loadMemories()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.id, a.id)
        XCTAssertEqual(loaded.first?.content, "a-edited")
    }

    /// Editing one segment's flag leaves the FTS index intact (text unchanged ⇒ still searchable).
    func testDeltaSaveSegmentsPreservesFTS() throws {
        let store = try XCTUnwrap(SQLiteStore(path: tempPath()))
        var s = TranscriptSegment(text: "the quarterly planning deadline is firm", start: Date(), end: Date())
        store.saveSegments([s])
        XCTAssertEqual(store.searchTranscript("planning"), [s.id])
        s.consolidated = true                                    // non-text change
        store.saveSegments([s])
        XCTAssertEqual(store.searchTranscript("planning"), [s.id])   // FTS still indexes it
        XCTAssertEqual(store.loadSegments().first?.consolidated, true)
    }

    func testSegmentRoundTripAndFTS() throws {
        let store = try XCTUnwrap(SQLiteStore(path: tempPath()))
        let s1 = TranscriptSegment(text: "the quarterly planning deadline is firm", start: Date(), end: Date())
        let s2 = TranscriptSegment(text: "lunch was pizza", start: Date(), end: Date())
        store.saveSegments([s1, s2])

        XCTAssertEqual(store.loadSegments().count, 2)
        let hits = store.searchTranscript("planning")
        XCTAssertEqual(hits, [s1.id])
    }

    func testMigrateFromJSONIfEmpty() throws {
        let store = try XCTUnwrap(SQLiteStore(path: tempPath()))
        let mems = [Memory(title: "Imported", content: "x")]
        let segs = [TranscriptSegment(text: "hello", start: Date(), end: Date())]
        store.migrateFromJSONIfEmpty(memories: mems, segments: segs)
        XCTAssertEqual(store.memoryCount, 1)
        // Idempotent: a second call with different data does not overwrite the now-populated DB.
        store.migrateFromJSONIfEmpty(memories: [Memory(title: "Other", content: "y")], segments: [])
        XCTAssertEqual(store.loadMemories().first?.title, "Imported")
    }
}
