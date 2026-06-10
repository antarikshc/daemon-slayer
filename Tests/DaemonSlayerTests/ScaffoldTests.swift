import XCTest
@testable import daemonslayer

final class ScaffoldTests: XCTestCase {
    func testDefaultConfigHysteresis() {
        let c = Config.default
        XCTAssertEqual(c.requiredConsecutiveSamples(for: .ownerlessNoIDE), 4)
        XCTAssertEqual(c.requiredConsecutiveSamples(for: .ownerlessWithIDE), 30)
    }
}
