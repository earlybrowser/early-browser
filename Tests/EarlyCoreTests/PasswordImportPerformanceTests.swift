// SPDX-License-Identifier: MPL-2.0

import Foundation
import Testing
@testable import EarlyCore

@Suite @MainActor
struct PasswordImportPerformanceTests {
    @Test func bulkMergeScalesAndKeepsConflictRules() {
        for count in [10_000, 20_000] {
            let rows = (0..<count).map {
                PasswordCSV.Row(origin: "https://example.invalid", username: "user-\($0)", password: "synthetic")
            }
            let vault = PasswordVault(fileURL: nil, key: nil)
            let start = ContinuousClock.now
            let summary = vault.importRows(rows)
            let elapsed = start.duration(to: .now)
            #expect(summary.added == count && vault.logins.count == count)
            let again = vault.importRows(rows + [.init(origin: rows[0].origin, username: rows[0].username, password: "different")])
            #expect(again.duplicates == count && again.conflicts == 1 && again.added == 0)
            #expect(vault.logins.first?.password == "synthetic")
            print("Password merge \(count) rows: \(elapsed)")
        }
    }
}
