import Foundation
import XCTest
@testable import JoyConKeys

@MainActor
final class ControllerEngineTests: XCTestCase {
    private func makeEngine() throws -> ControllerEngine {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("JoyConKeysTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }

        let store = MappingStore(fileURL: directory.appendingPathComponent("mappings.json"))
        store.mappings = Dictionary(
            uniqueKeysWithValues: PadButton.allCases.map { ($0, .unassigned) })
        return ControllerEngine(
            store: store, startBackend: false, promptForAccessibility: false)
    }

    func testDisconnectReleasesStickOwnedByRemovedDevice() throws {
        let engine = try makeEngine()
        let firstDevice = NSObject()
        let secondDevice = NSObject()
        let firstStick = NSObject()

        engine.backendConnected(
            id: ObjectIdentifier(firstDevice), side: .left, name: "first")
        engine.backendConnected(
            id: ObjectIdentifier(secondDevice), side: .right, name: "second")
        engine.backendStick(
            device: ObjectIdentifier(firstDevice), stick: ObjectIdentifier(firstStick),
            up: 1, right: 0)
        XCTAssertEqual(engine.pressed, [.stickUp])

        engine.backendDisconnected(id: ObjectIdentifier(firstDevice), name: "first")

        XCTAssertTrue(engine.pressed.isEmpty)
        XCTAssertEqual(engine.connected.map(\.name), ["second"])
    }

    func testDisconnectResumesAnotherHeldStick() throws {
        let engine = try makeEngine()
        let firstDevice = NSObject()
        let secondDevice = NSObject()
        let firstStick = NSObject()
        let secondStick = NSObject()

        engine.backendConnected(
            id: ObjectIdentifier(firstDevice), side: .left, name: "first")
        engine.backendConnected(
            id: ObjectIdentifier(secondDevice), side: .right, name: "second")
        engine.backendStick(
            device: ObjectIdentifier(secondDevice), stick: ObjectIdentifier(secondStick),
            up: 0, right: 1)
        engine.backendStick(
            device: ObjectIdentifier(firstDevice), stick: ObjectIdentifier(firstStick),
            up: 1, right: 0)
        XCTAssertEqual(engine.pressed, [.stickUp])

        engine.backendDisconnected(id: ObjectIdentifier(firstDevice), name: "first")

        XCTAssertEqual(engine.pressed, [.stickRight])
    }

    func testButtonHighlightRemainsWhileAnotherDeviceStillHoldsButton() throws {
        let engine = try makeEngine()
        let firstObject = NSObject()
        let secondObject = NSObject()
        let firstDevice = ObjectIdentifier(firstObject)
        let secondDevice = ObjectIdentifier(secondObject)

        engine.backendButton(device: firstDevice, .buttonA, pressed: true)
        engine.backendButton(device: secondDevice, .buttonA, pressed: true)
        engine.backendButton(device: firstDevice, .buttonA, pressed: false)

        XCTAssertEqual(engine.pressed, [.buttonA])
        engine.backendButton(device: secondDevice, .buttonA, pressed: false)
        XCTAssertTrue(engine.pressed.isEmpty)
    }
}

final class RepeatCoordinatorTests: XCTestCase {
    func testCoalescesPendingWorkAndRejectsItAfterCancellation() {
        let coordinator = KeySynth.RepeatCoordinator()
        let token = coordinator.begin()

        XCTAssertTrue(coordinator.claim(token))
        XCTAssertFalse(coordinator.claim(token), "only one repeat may be pending")

        coordinator.cancel(token)
        XCTAssertFalse(coordinator.shouldExecute(token))
        coordinator.finish(token)
        XCTAssertFalse(coordinator.claim(token), "cancelled streams cannot be re-armed")
    }
}

final class AttemptBudgetTests: XCTestCase {
    func testAttemptBudgetIsBounded() {
        var budget = AttemptBudget(limit: 5)
        for expected in 1...5 {
            XCTAssertTrue(budget.take())
            XCTAssertEqual(budget.attempts, expected)
        }
        XCTAssertTrue(budget.exhausted)
        XCTAssertFalse(budget.take())
        XCTAssertEqual(budget.attempts, 5)
    }
}
