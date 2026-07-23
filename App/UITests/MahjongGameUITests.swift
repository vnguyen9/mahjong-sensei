import XCTest

final class MahjongGameUITests: XCTestCase {
    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
    }

    func testLandscapeTableRouteOnIPad() {
        XCUIDevice.shared.orientation = .landscapeLeft
        let app = launch(route: "game-table-large")

        XCTAssertTrue(app.buttons["Exit"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts["Practice table"].exists)
        attachScreenshot(named: "Mahjong table landscape", app: app)
    }

    func testDragRouteKeepsButtonFallbackAndRiverTarget() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(route: "game-dragging")

        XCTAssertTrue(app.buttons["Discard"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Suggest"].exists)
        XCTAssertTrue(app.buttons["Undo"].exists)
        XCTAssertTrue(app.staticTexts["YOUR RIVER"].exists)
        XCTAssertTrue(app.staticTexts["Practice table"].exists)
        attachScreenshot(named: "Mahjong table iPhone portrait", app: app)
    }

    func testPungReactionShowsOnlyLegalChoices() {
        let app = launch(route: "game-claim-pung")

        XCTAssertTrue(app.buttons["Pung"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Pass"].exists)
        XCTAssertFalse(app.buttons["Chow"].exists)
        XCTAssertFalse(app.buttons["Kong"].exists)
        XCTAssertFalse(app.staticTexts["Claim this tile?"].exists)
    }

    func testHumanTurnRouteShowsWallDrawInstruction() {
        XCUIDevice.shared.orientation = .portrait
        let app = launch(route: "game-turn-human")

        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'Drew from the wall'"))
            .element(boundBy: 0).waitForExistence(timeout: 8))
    }

    func testComplexClaimRouteRetainsFocusedModal() {
        let app = launch(route: "game-complex-claim")

        XCTAssertTrue(app.staticTexts["Rob the kong?"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.buttons["Win · Rob Kong"].exists)
        XCTAssertTrue(app.buttons["Pass"].exists)
    }

    func testLearningDrawerUsesPublicTableLanguage() {
        let app = launch(route: "game-learning")

        XCTAssertTrue(app.staticTexts["Visible at this table"].waitForExistence(timeout: 8))
        XCTAssertTrue(app.staticTexts.matching(NSPredicate(format: "label CONTAINS 'unseen base tiles'"))
            .element(boundBy: 0).exists)
    }

    private func launch(route: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["MJ_SCREEN"] = route
        app.launch()
        return app
    }

    private func attachScreenshot(named name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
