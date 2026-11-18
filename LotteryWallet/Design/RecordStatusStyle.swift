import SwiftUI

extension RecordStatus {
    var tint: Color {
        switch self {
        case .pending: Palette.warning
        case .won: Palette.profit
        case .lost: Color.secondary
        case .prizeFloat: Palette.warning
        }
    }

    var symbol: String {
        switch self {
        case .pending: "clock"
        case .won: "checkmark.seal.fill"
        case .lost: "xmark.circle"
        case .prizeFloat: "hourglass"
        }
    }
}
