import Foundation
import Testing
@testable import MonitorCore

/// Runs a test with German number formatting ("12,5 GB"), whatever language the machine is set to.
/// The texts themselves are German in a plain `swift test` (the catalog is not compiled there).
struct GermanFormatting: SuiteTrait, TestTrait, TestScoping {
    var isRecursive: Bool { true }

    func provideScope(for test: Test, testCase: Test.Case?,
                      performing function: @Sendable () async throws -> Void) async throws {
        try await Format.$locale.withValue(Locale(identifier: "de_DE")) {
            try await function()
        }
    }
}

extension Trait where Self == GermanFormatting {
    static var germanFormatting: Self { GermanFormatting() }
}
