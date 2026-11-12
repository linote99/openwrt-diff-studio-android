// ErrorExplain.swift
// Port of com.linote.diffstudio.ErrorExplain (Java, MIT).
//
// Port of errors.js explainError(): friendly message first, raw
// diagnostics second.

import Foundation

public enum ErrorExplain {
    public struct Result {
        public let message: String
        public let details: String
        public init(message: String, details: String) {
            self.message = message
            self.details = details
        }
    }

    private struct Rule {
        let pattern: String
        let options: NSRegularExpression.Options
        let zh: String
        let en: String
    }

    private static let rules: [Rule] = [
        Rule(pattern: "Release versions are identical",
             options: [], zh: "旧版和新版是同一个版本，请重新选择两份发行包。",
             en: "The old and new releases are identical. Select two different releases."),
        Rule(pattern: "Unsupported OTA format",
             options: [], zh: "此补丁格式不受支持，请使用新版工具重新生成补丁。",
             en: "This patch format is unsupported. Regenerate it with the latest tool."),
        Rule(pattern: "Unsafe |Invalid |Duplicate|excessive|Cyclic|escapes root|Cannot find payload content|Unsupported forward tar hardlink|Root image exceeds|Oversized package database",
             options: [], zh: "安装包或补丁的结构不符合要求。请确认文件完整，并选择可信的完整发行包或补丁。",
             en: "The package or patch structure is invalid. Verify the file and select a trusted complete release or patch."),
        Rule(pattern: "Device/base mismatch: (?:family|profile)|different device families|Incompatible full releases: profile",
             options: [], zh: "补丁与设备型号不匹配，请选择该机型的补丁。",
             en: "The patch is for a different device model. Select a matching patch."),
        Rule(pattern: "Device/base mismatch: version",
             options: [], zh: "设备版本与补丁起始版本不一致，请检查旧包是否选对。",
             en: "The device version does not match the patch base. Check the selected old release."),
        Rule(pattern: "No completed update to roll back|journal\\.json.*No such file",
             options: [], zh: "没有可撤销的已完成补丁。",
             en: "There is no completed patch to roll back."),
        Rule(pattern: "Rollback backup corrupt|Boot recovery backup checksum mismatch|Missing transaction recovery runtime",
             options: [], zh: "撤销所需的恢复文件缺失或校验失败，无法安全恢复。请保留现场及技术详情。",
             en: "Recovery files are missing or corrupt. Rollback cannot proceed safely; retain the diagnostics."),
        Rule(pattern: "Insufficient|No space left|insufficient space",
             options: [], zh: "设备可用空间不足。请释放空间后重新检查。",
             en: "The device has insufficient free space. Free space and check again."),
        Rule(pattern: "checksum|verification failed|Invalid.*blob|Bad CRC|BadZipFile",
             options: .caseInsensitive, zh: "文件校验失败，补丁或恢复文件可能不完整。请重新获取可信文件。",
             en: "File verification failed. The patch or recovery file may be incomplete; obtain a trusted copy again."),
        Rule(pattern: "portable (?:updater )?runtime|Packaged updater BusyBox lacks|applet not found|(?:python3|stat|mountpoint):.*not found",
             options: .caseInsensitive, zh: "更新环境不完整，请使用新版 Diff Studio 重新生成补丁并完整解压更新器。",
             en: "The updater environment is incomplete. Regenerate the patch with the latest Diff Studio and extract the complete updater."),
        Rule(pattern: "Authentication|authentication failed|Bad authentication|Permission denied.*password",
             options: .caseInsensitive, zh: "SSH 登录失败，请检查 root 密码。",
             en: "SSH login failed. Check the root password."),
        Rule(pattern: "Connection refused|Unable to connect|No route to host|timed out|Timeout|NetworkError|Failed to fetch|XHR|offline|EOF|Connection.*(?:closed|reset)|Socket.*closed",
             options: .caseInsensitive, zh: "无法与设备完成通信。请检查连接和管理地址；若正在更新，可稍后重新检查状态。",
             en: "Communication with the device failed. Check the connection and management address; if updating, check its status again later."),
        Rule(pattern: "Resource temporarily unavailable|BlockingIOError|still updating|recovery is pending|still running",
             options: [], zh: "设备正在更新或恢复，请等待完成后重新检查状态。",
             en: "The device is updating or recovering. Wait and check its status again."),
        Rule(pattern: "Object not found|RPC.*not.*register|RPC.*unavailable",
             options: [], zh: "系统补丁服务暂不可用，请重新连接网页或检查插件是否已安装并启用。",
             en: "The system patch service is unavailable. Reconnect or check that the plugin is installed and enabled."),
        Rule(pattern: "Unexpected RPC arguments|RPC arguments|Unknown OTA command|Unsupported.*command",
             options: [], zh: "更新器与设备插件的接口不兼容，请更新工具或插件后重试。",
             en: "The updater and device plugin interfaces are incompatible. Update the tool or plugin and retry."),
        Rule(pattern: "File changed during update",
             options: [], zh: "系统文件在写入期间发生变化，本次更新已中止，请检查设备状态。",
             en: "A system file changed during the update. The update stopped; check the device status."),
        Rule(pattern: "already exists|Output staging exists",
             options: [], zh: "输出文件已存在，请选择其他文件名或目录。",
             en: "The output file already exists. Choose another filename or directory."),
        Rule(pattern: "Select a single complete release ZIP|full release|Missing release identity|Full release has no",
             options: [], zh: "无法识别完整发行包或版本信息，请选择该项目的完整发行 ZIP。",
             en: "The full release or version information could not be identified. Select a complete release ZIP from this project."),
        Rule(pattern: "Incomplete patch inspection response",
             options: [], zh: "补丁检查结果不完整，未开始更新。请更新插件并重新检查补丁。",
             en: "Patch inspection is incomplete. No update started. Update the plugin and inspect the patch again."),
        Rule(pattern: "Inspect this patch|Upload differs|Review this device|reviewed patch|Device SSH identity changed",
             options: [], zh: "检查结果已失效或设备发生变化，请重新连接并检查后再应用。",
             en: "The review is stale or the device changed. Connect and review again before applying."),
        Rule(pattern: "Permission denied|Operation not permitted",
             options: .caseInsensitive, zh: "操作权限不足，请检查 root 权限及目标文件系统状态。",
             en: "Permission was denied. Check root access and the target filesystem state."),
        Rule(pattern: "Read-only file system|Input/output error",
             options: .caseInsensitive, zh: "设备存储无法正常写入，请检查文件系统及存储错误。",
             en: "Device storage cannot be written. Check filesystem and storage errors."),
    ]

    private static let basePattern = "Device/base mismatch: version; device=([^;]+); patch base=([^;]+); patch target=([^;]+)"
    private static let conflictPattern = "Rollback conflict: (.+)"
    private static let cjkPattern = "[\\u3400-\\u9fff]"
    private static let rawPattern = "[{}]|Traceback"
    private static let localPattern = "^(?:Select an? |Drop |Enter the device management address)"

    private static func matches(_ text: String, pattern: String, options: NSRegularExpression.Options = []) -> Bool {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static func captureGroups(_ text: String, pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        var out: [String] = []
        for i in 1..<m.numberOfRanges {
            if let r = Range(m.range(at: i), in: text) {
                out.append(String(text[r]))
            } else {
                out.append("")
            }
        }
        return out
    }

    public static func explain(_ original: String?, english: Bool) -> Result {
        let original = original ?? ""
        var text = original.replacingOccurrences(of: "^(?:RuntimeError|ValueError|Error):\\s*", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = text.components(separatedBy: "\n")
        var candidates: [String] = [text]
        candidates += lines.reversed()
        for line in candidates {
            if let parsed = try? Json.parse(line),
               let map = Json.map(parsed),
               case .string(let err) = map["error"] {
                text = err
                break
            }
        }
        let message: String
        if let base = captureGroups(text, pattern: basePattern), base.count >= 3 {
            if base[0] == base[2] {
                message = english
                    ? "The device already runs the target version. Check whether the old/new packages were swapped or the patch was already applied."
                    : "设备已经是补丁的目标版本。请检查旧包、新包是否选反，或是否重复应用。"
            } else {
                message = english
                    ? "The device runs \(base[0]), but this patch updates \(base[1]) to \(base[2]). Generate a patch using the device's current release as the old package."
                    : "设备当前为 \(base[0])，补丁要求从 \(base[1]) 更新到 \(base[2])。请使用与设备当前版本相同的旧包重新生成补丁。"
            }
        } else if let conflict = captureGroups(text, pattern: conflictPattern), let first = conflict.first {
            let parts = first.components(separatedBy: "; changed=")
            let path = parts[0]
            var fields = ""
            if parts.count > 1, !parts[1].isEmpty {
                fields = parts[1].components(separatedBy: ",").map { label($0, english: english) }.joined(separator: english ? ", " : "、")
            }
            message = english
                ? "Rollback stopped to preserve later changes to \(path)\(fields.isEmpty ? "" : " (\(fields))")."
                : "无法撤销：\(path) 在更新后又发生了变化\(fields.isEmpty ? "" : "（\(fields)）")。已停止以保留后续修改。"
        } else if (matches(text, pattern: cjkPattern) && !matches(text, pattern: rawPattern)) || matches(text, pattern: localPattern) {
            message = text
        } else {
            var found: String? = nil
            for r in rules where matches(text, pattern: r.pattern, options: r.options) {
                found = english ? r.en : r.zh
                break
            }
            message = found ?? (english
                ? "The operation did not complete. Expand technical details for the cause."
                : "操作未完成。请展开技术详情查看具体原因。")
        }
        return Result(message: message, details: original)
    }

    private static func label(_ k: String, english en: Bool) -> String {
        switch k {
        case "sha256": return en ? "content" : "内容"
        case "size": return en ? "size" : "大小"
        case "mode": return en ? "permissions" : "权限"
        case "uid": return en ? "owner" : "所有者"
        case "gid": return en ? "group" : "用户组"
        case "kind": return en ? "file type" : "文件类型"
        case "target": return en ? "link target" : "链接目标"
        case "xattrs": return en ? "extended attributes" : "扩展属性"
        case "boot": return en ? "boot image" : "启动镜像"
        default: return k
        }
    }
}
