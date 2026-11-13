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

    func testListedTitleSurvivesRetryAndIsClearedOnClose() {
        let store = StreamStore()
        let slot = store.slots[1]
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/stream/nfl-network")!, title: "NFL Network", into: slot))
        XCTAssertEqual(slot.title, "NFL Network")
        slot.retry()
        XCTAssertEqual(slot.title, "NFL Network")
        store.close(slot)
        XCTAssertEqual(slot.title, "Empty slot")
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/stream/nfl-network")!, into: slot))
        XCTAssertEqual(slot.title, "Nfl Network")
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

    func testSoloAudioSwitchesActiveAudioBetweenPanes() {
        let store = StreamStore()
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/one")!))
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/two")!))
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/three")!))
        XCTAssertFalse(store.slots[0].isMuted)
        XCTAssertTrue(store.slots[1].isMuted)
        XCTAssertTrue(store.slots[2].isMuted)

        store.soloAudio(store.slots[2])
        XCTAssertTrue(store.slots[0].isMuted)
        XCTAssertTrue(store.slots[1].isMuted)
        XCTAssertFalse(store.slots[2].isMuted)
        store.stopAll()
    }

    func testAudioButtonSwitchesSoundOrMixesWithOption() {
        let store = StreamStore()
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/one")!))
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/two")!))
        XCTAssertTrue(store.add(URL(string: "https://invalid.example/three")!))

        store.toggleAudio(store.slots[1])
        XCTAssertTrue(store.slots[0].isMuted)
        XCTAssertFalse(store.slots[1].isMuted)
        XCTAssertTrue(store.slots[2].isMuted)

        store.toggleAudio(store.slots[2], mixing: true)
        XCTAssertFalse(store.slots[1].isMuted)
        XCTAssertFalse(store.slots[2].isMuted)

        store.toggleAudio(store.slots[1])
        XCTAssertTrue(store.slots[1].isMuted)
        XCTAssertFalse(store.slots[2].isMuted)
        store.stopAll()
    }
}
