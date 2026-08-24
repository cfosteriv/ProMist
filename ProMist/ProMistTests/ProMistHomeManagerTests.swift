import XCTest
@testable import ProMist

@MainActor
final class ProMistHomeManagerTests: XCTestCase {
    func testRemovingStaleAssociationClearsTheCompleteLocalMatterLink() {
        let fan = KnownFan(deviceID: 42, name: "Patio")
        fan.homeIdentifier = UUID()
        fan.homeAccessoryIdentifier = UUID()
        fan.matterNodeID = 0x1234
        fan.isMatterCommissioned = true
        let manager = ProMistHomeManager(startServices: false)

        manager.removeStaleAssociation(from: fan)

        XCTAssertNil(fan.homeIdentifier)
        XCTAssertNil(fan.homeAccessoryIdentifier)
        XCTAssertNil(fan.matterNodeID)
        XCTAssertFalse(fan.isMatterCommissioned)
        XCTAssertEqual(fan.deviceID, 42)
        XCTAssertEqual(fan.name, "Patio")
    }
}
