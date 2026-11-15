// Noted: FineTune 併進 Noted 後不帶 Sparkle。上游的畫面還拿 UpdateManager 當參數，
// 這裡留一個空殼讓它們不用改簽名。
import Foundation
import Combine

final class UpdateManager: NSObject, ObservableObject {}
