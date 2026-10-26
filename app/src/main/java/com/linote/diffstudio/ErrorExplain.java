package com.linote.diffstudio;

import com.linote.diffstudio.core.Json;

import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/** Port of errors.js explainError(): friendly message first, raw diagnostics second. */
public final class ErrorExplain {
    private ErrorExplain() {}

    public static final class Result {
        public final String message, details;

        Result(String message, String details) {
            this.message = message;
            this.details = details;
        }
    }

    private static final Object[][] RULES = {
            {Pattern.compile("Release versions are identical"), "旧版和新版是同一个版本，请重新选择两份发行包。", "The old and new releases are identical. Select two different releases."},
            {Pattern.compile("Unsupported OTA format"), "此补丁格式不受支持，请使用新版工具重新生成补丁。", "This patch format is unsupported. Regenerate it with the latest tool."},
            {Pattern.compile("Unsafe |Invalid |Duplicate|excessive|Cyclic|escapes root|Cannot find payload content|Unsupported forward tar hardlink|Root image exceeds|Oversized package database"), "安装包或补丁的结构不符合要求。请确认文件完整，并选择可信的完整发行包或补丁。", "The package or patch structure is invalid. Verify the file and select a trusted complete release or patch."},
            {Pattern.compile("Device/base mismatch: (?:family|profile)|different device families|Incompatible full releases: profile"), "补丁与设备型号不匹配，请选择该机型的补丁。", "The patch is for a different device model. Select a matching patch."},
            {Pattern.compile("Device/base mismatch: version"), "设备版本与补丁起始版本不一致，请检查旧包是否选对。", "The device version does not match the patch base. Check the selected old release."},
            {Pattern.compile("No completed update to roll back|journal\\.json.*No such file"), "没有可撤销的已完成补丁。", "There is no completed patch to roll back."},
            {Pattern.compile("Rollback backup corrupt|Boot recovery backup checksum mismatch|Missing transaction recovery runtime"), "撤销所需的恢复文件缺失或校验失败，无法安全恢复。请保留现场及技术详情。", "Recovery files are missing or corrupt. Rollback cannot proceed safely; retain the diagnostics."},
            {Pattern.compile("Insufficient|No space left|insufficient space"), "设备可用空间不足。请释放空间后重新检查。", "The device has insufficient free space. Free space and check again."},
            {Pattern.compile("checksum|verification failed|Invalid.*blob|Bad CRC|BadZipFile", Pattern.CASE_INSENSITIVE), "文件校验失败，补丁或恢复文件可能不完整。请重新获取可信文件。", "File verification failed. The patch or recovery file may be incomplete; obtain a trusted copy again."},
            {Pattern.compile("portable (?:updater )?runtime|Packaged updater BusyBox lacks|applet not found|(?:python3|stat|mountpoint):.*not found", Pattern.CASE_INSENSITIVE), "更新环境不完整，请使用新版 Diff Studio 重新生成补丁并完整解压更新器。", "The updater environment is incomplete. Regenerate the patch with the latest Diff Studio and extract the complete updater."},
            {Pattern.compile("Authentication|authentication failed|Bad authentication|Permission denied.*password", Pattern.CASE_INSENSITIVE), "SSH 登录失败，请检查 root 密码。", "SSH login failed. Check the root password."},
            {Pattern.compile("Connection refused|Unable to connect|No route to host|timed out|Timeout|NetworkError|Failed to fetch|XHR|offline|EOF|Connection.*(?:closed|reset)|Socket.*closed", Pattern.CASE_INSENSITIVE), "无法与设备完成通信。请检查连接和管理地址；若正在更新，可稍后重新检查状态。", "Communication with the device failed. Check the connection and management address; if updating, check its status again later."},
            {Pattern.compile("Resource temporarily unavailable|BlockingIOError|still updating|recovery is pending|still running"), "设备正在更新或恢复，请等待完成后重新检查状态。", "The device is updating or recovering. Wait and check its status again."},
            {Pattern.compile("Object not found|RPC.*not.*register|RPC.*unavailable"), "系统补丁服务暂不可用，请重新连接网页或检查插件是否已安装并启用。", "The system patch service is unavailable. Reconnect or check that the plugin is installed and enabled."},
            {Pattern.compile("Unexpected RPC arguments|RPC arguments|Unknown OTA command|Unsupported.*command"), "更新器与设备插件的接口不兼容，请更新工具或插件后重试。", "The updater and device plugin interfaces are incompatible. Update the tool or plugin and retry."},
            {Pattern.compile("File changed during update"), "系统文件在写入期间发生变化，本次更新已中止，请检查设备状态。", "A system file changed during the update. The update stopped; check the device status."},
            {Pattern.compile("already exists|Output staging exists"), "输出文件已存在，请选择其他文件名或目录。", "The output file already exists. Choose another filename or directory."},
            {Pattern.compile("Select a single complete release ZIP|full release|Missing release identity|Full release has no"), "无法识别完整发行包或版本信息，请选择该项目的完整发行 ZIP。", "The full release or version information could not be identified. Select a complete release ZIP from this project."},
            {Pattern.compile("Incomplete patch inspection response"), "补丁检查结果不完整，未开始更新。请更新插件并重新检查补丁。", "Patch inspection is incomplete. No update started. Update the plugin and inspect the patch again."},
            {Pattern.compile("Inspect this patch|Upload differs|Review this device|reviewed patch|Device SSH identity changed"), "检查结果已失效或设备发生变化，请重新连接并检查后再应用。", "The review is stale or the device changed. Connect and review again before applying."},
            {Pattern.compile("Permission denied|Operation not permitted", Pattern.CASE_INSENSITIVE), "操作权限不足，请检查 root 权限及目标文件系统状态。", "Permission was denied. Check root access and the target filesystem state."},
            {Pattern.compile("Read-only file system|Input/output error", Pattern.CASE_INSENSITIVE), "设备存储无法正常写入，请检查文件系统及存储错误。", "Device storage cannot be written. Check filesystem and storage errors."},
    };

    private static final Pattern BASE = Pattern.compile("Device/base mismatch: version; device=([^;]+); patch base=([^;]+); patch target=([^;]+)");
    private static final Pattern CONFLICT = Pattern.compile("Rollback conflict: (.+)");
    private static final Pattern CJK = Pattern.compile("[\\u3400-\\u9fff]");
    private static final Pattern RAW = Pattern.compile("[{}]|Traceback");
    private static final Pattern LOCAL = Pattern.compile("^(?:Select an? |Drop |Enter the device management address)");

    public static Result explain(String original, boolean english) {
        if (original == null) original = "";
        String text = original.replaceFirst("^(?:RuntimeError|ValueError|Error):\\s*", "").trim();
        String[] lines = text.split("\n", -1);
        String[] candidates = new String[lines.length + 1];
        candidates[0] = text;
        for (int i = 0; i < lines.length; i++) candidates[i + 1] = lines[lines.length - 1 - i];
        for (String line : candidates) {
            try {
                Map<String, Object> parsed = Json.map(Json.parse(line));
                if (parsed != null && parsed.get("error") instanceof String) {
                    text = (String) parsed.get("error");
                    break;
                }
            } catch (RuntimeException ignored) {
                // plain legacy diagnostics
            }
        }
        String message;
        Matcher base = BASE.matcher(text);
        Matcher conflict = CONFLICT.matcher(text);
        if (base.find()) {
            message = english
                    ? "The device runs " + base.group(1) + ", but this patch updates " + base.group(2) + " to " + base.group(3) + ". Generate a patch using the device's current release as the old package."
                    : "设备当前为 " + base.group(1) + "，补丁要求从 " + base.group(2) + " 更新到 " + base.group(3) + "。请使用与设备当前版本相同的旧包重新生成补丁。";
            if (base.group(1).equals(base.group(3))) {
                message = english ? "The device already runs the target version. Check whether the old/new packages were swapped or the patch was already applied."
                        : "设备已经是补丁的目标版本。请检查旧包、新包是否选反，或是否重复应用。";
            }
        } else if (conflict.find()) {
            String[] parts = conflict.group(1).split("; changed=", -1);
            String path = parts[0];
            String fields = "";
            if (parts.length > 1 && !parts[1].isEmpty()) {
                StringBuilder sb = new StringBuilder();
                for (String k : parts[1].split(",", -1)) {
                    if (sb.length() > 0) sb.append(english ? ", " : "、");
                    sb.append(label(k, english));
                }
                fields = sb.toString();
            }
            message = english ? "Rollback stopped to preserve later changes to " + path + (fields.isEmpty() ? "" : " (" + fields + ")") + "."
                    : "无法撤销：" + path + " 在更新后又发生了变化" + (fields.isEmpty() ? "" : "（" + fields + "）") + "。已停止以保留后续修改。";
        } else if ((CJK.matcher(text).find() && !RAW.matcher(text).find()) || LOCAL.matcher(text).find()) {
            message = text;
        } else {
            message = english ? "The operation did not complete. Expand technical details for the cause." : "操作未完成。请展开技术详情查看具体原因。";
            for (Object[] r : RULES) {
                if (((Pattern) r[0]).matcher(text).find()) {
                    message = (String) r[english ? 2 : 1];
                    break;
                }
            }
        }
        return new Result(message, original);
    }

    private static String label(String k, boolean en) {
        switch (k) {
            case "sha256": return en ? "content" : "内容";
            case "size": return en ? "size" : "大小";
            case "mode": return en ? "permissions" : "权限";
            case "uid": return en ? "owner" : "所有者";
            case "gid": return en ? "group" : "用户组";
            case "kind": return en ? "file type" : "文件类型";
            case "target": return en ? "link target" : "链接目标";
            case "xattrs": return en ? "extended attributes" : "扩展属性";
            case "boot": return en ? "boot image" : "启动镜像";
            default: return k;
        }
    }
}
