import XCTest
@testable import MahjongData
import MahjongCore

final class MahjongDataTests: XCTestCase {
    func testEveryTileHasAName() {
        for tile in Tile.allCanonical {
            let name = MahjongData.name(for: tile)
            XCTAssertFalse(name.english.isEmpty, "\(tile.code) english")
            XCTAssertFalse(name.traditional.isEmpty, "\(tile.code) traditional")
            XCTAssertFalse(name.jyutping.isEmpty, "\(tile.code) jyutping")
        }
    }

    func testKnownNames() {
        XCTAssertEqual(MahjongData.name(for: .s(1)).english, "One Bamboo")
        XCTAssertEqual(MahjongData.name(for: .s(1)).traditional, "一索")
        XCTAssertEqual(MahjongData.name(for: .redDragon).traditional, "紅中")
        XCTAssertEqual(MahjongData.name(for: .m(5)).traditional, "五萬")
        XCTAssertTrue(MahjongData.name(for: .s(1)).note.contains("bird"))
    }
}
