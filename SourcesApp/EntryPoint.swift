import Foundation
import SwiftUI

@main
struct EntryPoint {
    static func main() {
        if isRunningUnderXCTest {
            // Keep the process alive so the test runner can attach.
            // The actual tests are run by XCTest inside the loaded
            // aibarsTests bundle; we just need to not exit.
            RunLoop.main.run()
            return
        }
        aibarsApp.main()
    }

    private static var isRunningUnderXCTest: Bool {
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            return true
        }
        if NSClassFromString("XCTestCase") != nil {
            return true
        }
        for arg in CommandLine.arguments {
            if arg.contains("xctest") || arg.contains("XCTest") {
                return true
            }
        }
        return false
    }
}
