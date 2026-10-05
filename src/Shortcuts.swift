import Foundation

/// Maps a Command+digit (1..9) key code to a zero-based row index,
/// choose-gui style. Covers both the top-row digits and the numeric keypad.
func commandDigitRowIndex(_ keyCode: UInt16) -> Int? {
    switch keyCode {
    case 18, 83: return 0 // 1
    case 19, 84: return 1 // 2
    case 20, 85: return 2 // 3
    case 21, 86: return 3 // 4
    case 23, 87: return 4 // 5
    case 22, 88: return 5 // 6
    case 26, 89: return 6 // 7
    case 28, 91: return 7 // 8
    case 25, 92: return 8 // 9
    default: return nil
    }
}
