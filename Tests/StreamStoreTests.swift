import XCTest
@testable import Crackstreams

@MainActor
final class StreamStoreTests: XCTestCase {
    func testURLValidation() {
        XCTAssertNotNil(StreamStore.validURL("https://watch.example/game"))
        XCTAssertNotNil(StreamStore.validURL("http://127.0.0.1:8080/live.m3u8"))
        XCTAssertNil(StreamStore.validURL("file:///tmp/live.m3u8"))
        XCTAssertNil(StreamStore.validURL("javascript:alert(1)"))
        XCTAssertNil(StreamStore.validURL("https://user:secret@watch.example/game"))
        XCTAssertNil(StreamStore.validURL("not a URL"))
    }

    func testRejectsFifthStreamAndPreservesInput() {
        let store = StreamStore()
        for slot in store.slots {
            slot.load(URL(string: "https://invalid.example/\(slot.id.uuidString)")!)
        }
        store.input = "https://watch.example/fifth-game"
        XCTAssertFalse(store.addFromInput())
        XCTAssertEqual(store.input, "https://watch.example/fifth-game")
        XCTAssertEqual(store.message, "All four panes are in use. Close one or drop the link onto a pane to replace it.")
        store.stopAll()
    }

    func testCloseMakesPaneReusableAndResetsState() {
        let store = StreamStore()
        let slot = store.slots[0]
        slot.load(URL(string: "https://invalid.example/game")!)
        store.close(slot)
        XCTAssertTrue(slot.isEmpty)
        XCTAssertNil(slot.player)
        XCTAssertNil(slot.sourceURL)
        XCTAssertEqual(slot.title, "Empty slot")
        store.input = "https://watch.example/new-game"
        XCTAssertTrue(store.addFromInput())
        XCTAssertEqual(store.input, "")
        XCTAssertEqual(store.slots[0].state, .resolving)
        store.stopAll()
    }

    func testFirstActivePaneIsAudibleAndOthersAreMuted() {
        let store = StreamStore()
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/one")!, into: store.slots[2]))
        XCTAssertFalse(store.slots[2].isMuted)
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/two")!))
        XCTAssertTrue(store.slots[0].isMuted)
        store.stopAll()
    }
}
