import XCTest
@testable import FlyCommander

/// T3：显式起始目录解析（--start-dir / FLY_START_DIR）——纯函数，参数与真环境隔离。
final class StartPathTests: XCTestCase {
    private func explicit(_ args: [String], _ env: [String: String]) -> String? {
        MainViewController.explicitStartPath(arguments: args, environment: env)
    }

    func testArgumentWinsOverEnvironment() {
        XCTAssertEqual(explicit(["app", "--start-dir", "/arg"], ["FLY_START_DIR": "/env"]), "/arg")
    }

    func testEnvironmentOnly() {
        XCTAssertEqual(explicit(["app"], ["FLY_START_DIR": "/env"]), "/env")
    }

    func testNeitherReturnsNil() {
        XCTAssertNil(explicit(["app"], [:]))
    }

    func testArgumentWithoutValueFallsBackToEnvironment() {
        XCTAssertEqual(explicit(["app", "--start-dir"], ["FLY_START_DIR": "/env"]), "/env")
    }

    func testArgumentWithoutValueAndNoEnvReturnsNil() {
        XCTAssertNil(explicit(["app", "--start-dir"], [:]))
    }

    func testEmptyArgumentValueIgnored() {
        XCTAssertEqual(explicit(["app", "--start-dir", ""], ["FLY_START_DIR": "/env"]), "/env",
                       "空串参数值应忽略并回落环境变量")
        XCTAssertNil(explicit(["app", "--start-dir", ""], [:]))
    }

    func testEmptyEnvironmentIgnored() {
        XCTAssertNil(explicit(["app"], ["FLY_START_DIR": ""]))
    }
}
