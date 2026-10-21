import XCTest

/// Exercises the real screen hierarchy on Simulator. Hardware output is checked
/// separately on an iPhone; unavailable sensor states must still expose the tools.
@MainActor
final class ToolAccessUITests: XCTestCase {
    func testEveryOriginalToolIsReachableAndSelectionsSurviveDestinationChanges() {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        let app = XCUIApplication()
        app.launch()

        for destination in ["camera", "lidar", "vision", "maps", "assist"] {
            XCTAssertTrue(app.buttons["destination.\(destination)"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["destination.\(destination)"].isHittable)
        }
        assertScreen("camera", in: app)
        XCTAssertTrue(app.buttons["Reset"].exists)
        attachScreenshot("Camera", app: app)

        app.buttons["destination.lidar"].tap()
        for tool in ["depth", "pointCloud", "mesh", "data"] {
            selectTool(tool, section: "lidar", in: app)
            assertScreen("lidar.\(tool)", in: app)
            attachScreenshot("LiDAR - \(tool)", app: app)
        }

        app.buttons["destination.vision"].tap()
        assertScreen("vision.live", in: app)
        for tool in ["live", "fused", "depthLab", "fusion", "haptics", "benchmarks", "inspector"] {
            selectTool(tool, section: "vision", in: app)
            assertScreen("vision.\(tool)", in: app)
            if tool == "haptics" {
                XCTAssertTrue(app.staticTexts["Core Haptics engine"].exists)
            } else if tool == "benchmarks" {
                XCTAssertTrue(app.staticTexts["PROFILER"].exists)
            }
            attachScreenshot("AI Vision - \(tool)", app: app)
        }

        app.buttons["destination.maps"].tap()
        assertScreen("maps", in: app)
        attachScreenshot("Maps", app: app)
        app.buttons["destination.assist"].tap()
        assertScreen("assist", in: app)
        XCTAssertTrue(app.staticTexts["Navigation Assist"].exists)
        attachScreenshot("Assist", app: app)

        // Exercise the actual shortcut and state retention, not a duplicate list
        // of destinations disconnected from the rendered views.
        app.buttons["assist.showVision"].tap()
        assertScreen("vision.inspector", in: app)
        app.buttons["destination.lidar"].tap()
        assertScreen("lidar.data", in: app)
        app.buttons["destination.camera"].tap()
        assertScreen("camera", in: app)
    }

    private func selectTool(_ tool: String, section: String, in app: XCUIApplication) {
        let button = app.buttons["\(section).tool.\(tool)"]
        let row = app.scrollViews["\(section).tools"]
        XCTAssertTrue(row.waitForExistence(timeout: 5))
        for _ in 0..<6 where !button.isHittable {
            row.swipeLeft()
        }
        XCTAssertTrue(button.isHittable, "Tool must be directly reachable: \(section).\(tool)")
        button.tap()
    }

    private func assertScreen(_ screen: String, in app: XCUIApplication,
                              file: StaticString = #filePath, line: UInt = #line) {
        let content = app.descendants(matching: .any).matching(identifier: "screen.\(screen)").firstMatch
        XCTAssertTrue(content.waitForExistence(timeout: 10), "Expected rendered tool: \(screen)",
                      file: file, line: line)
    }

    private func attachScreenshot(_ name: String, app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
