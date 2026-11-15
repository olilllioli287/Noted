import Foundation

/// 測試版（bundle id 以 `.suite-dev` 結尾，`./build.sh --dev` 建出的 Noted Dev）才認測試用的環境變數與指令通道。
/// 正式版與別人自建的版本一律忽略它們，避免外部帶入環境變數改掉資料夾或開出指令通道。
public enum DevBuild {
    public static let isDev: Bool = Bundle.main.bundleIdentifier?.hasSuffix(".suite-dev") == true

    /// 只有測試版才回傳真正的環境變數，其他版本回傳空字典。
    public static let environment: [String: String] = isDev ? ProcessInfo.processInfo.environment : [:]
}
