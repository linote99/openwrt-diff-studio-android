# OpenWrt Diff Studio（安卓版）

在手机上比较两版 OpenWrt 完整发行包，生成只包含变更文件的差异包，并通过 SSH 直接更新设备。保留配置、额外插件和用户数据。

> 当前版本：**1.0.3**（versionCode 4）。

## 功能

- **生成差异包**：选择旧版和新版完整发行 ZIP（E5 的 ext4 根文件系统，或 MU300 / F50 / V50 / U30Air 的 tar 根文件系统），分析变更文件、内核与启动镜像、软件包依赖。可以导出完整更新包 ZIP（含 `update.ota`、电脑端更新器和说明），也可以只导出 `.ota`。导出格式与电脑版 OpenWrt Diff Studio 相同。
- **更新设备（OpenWrt Updater）**：导入 `.ota`，用 SSH（root + 密码）连接设备，先检查空间、本地修改、依赖和版本，再应用更新。更新时自动显示进度，支持完成后自动重启、手动重启、读取设备状态和回滚结果提示。检查与应用之间会核对设备身份，防止中途换了设备。
- **适配手机网络**：手机连上“无互联网”的设备 Wi-Fi 时，App 会自动选择能到达设备地址的网络（Wi-Fi、USB 网络共享或以太网）。
- **长任务不中断**：分析、导出和写入期间使用前台服务并保持唤醒；设备端事务独立运行，关闭 App 也不会中断设备写入。
- **其他**：中英文界面、深浅色主题、应用内关于页（使用说明与注意事项）；可以在文件管理器中用本应用直接打开 `.ota` 或 `.zip`。

## 系统要求

- Android 8.0（API 26）或更高版本。
- 更新设备时，手机需要和设备在同一网络（连接设备 Wi-Fi 或 USB 网络共享），并知道设备的 root 密码。默认管理地址：E5 为 `192.168.9.1`，MU300 为 `192.168.77.1`；也可以填写 `地址:端口`。

## 安装

APK 通过 GitHub Release 附件提供：<https://github.com/linote99/openwrt-diff-studio-android/releases>

下载后按 Android 系统提示安装。1.0.x 各版本使用同一签名，可以直接覆盖升级。

## 使用说明

1. **生成差异包**：在“生成差异包”页分别选择旧版（设备当前运行的版本）和新版完整 ZIP，点击“分析差异”，确认结果后点击“导出差异包”或“仅导出 .ota 文件”。
2. **更新设备**：在“更新设备”页选择 `.ota`，填写设备地址和 root 密码，点击“连接并检查”；全部检查通过后点击“确认应用此补丁”。

注意事项：只导入可信来源的补丁（补丁会以 root 权限写入系统文件）；旧版必须与设备当前运行的版本一致；更新期间不要断电或手动重启设备；分析 E5 发行包需要手机有足够的剩余空间（通常几百 MB 以上）。

## 构建

使用 Android Studio 打开项目，或在命令行运行：

```
./gradlew assembleRelease
```

项目配置：Android Gradle Plugin 8.7.3、Gradle 8.9（已附 Gradle Wrapper）、Java 17、compileSdk / targetSdk 35、minSdk 26。依赖 JSch 0.2.21（mwiede 分支）和 Bouncy Castle 1.79。

**签名**：仓库不包含签名密钥。正式签名时，把 `keystore.properties.example` 复制为 `keystore.properties`（已被 `.gitignore` 忽略），填入自己的密钥路径和密码；没有该文件时会生成未签名的 APK（`app-release-unsigned.apk`）。

**换行符**：`app/src/main/assets/` 下的设备端运行时文件有 SHA-256 指纹校验，`.gitattributes` 已禁止对它们做换行符转换，请不要修改这些文件的内容或换行符。

## 工程结构

```
app/src/main/java/com/linote/diffstudio/
  MainActivity.java     界面（生成差异包 / 更新设备 / 关于）
  WorkService.java      前台服务，长任务保活
  AndroidIo.java        系统文件访问、导出文件名修复、选网连接
  ErrorExplain.java     错误解释规则
  core/                 差分协议、发行包解析（ext4 / tar）、差异比较与导出
  ssh/Remote.java       SSH 设备更新流程（JSch + Bouncy Castle）
app/src/main/assets/ota/     设备端运行时文件
app/src/main/assets/bundle/  导出完整更新包时附带的电脑端更新器文件
```

## 许可证

应用自身源码采用 **MIT License**，许可文本见 [`LICENSE`](LICENSE)。以下内容不在 MIT 许可范围内：

- `app/src/main/java/com/linote/diffstudio/core/Ext4.java`：按 dissect.extfs 的行为实现，采用 **AGPL-3.0-or-later**（见 [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt)）。因为 APK 包含这个文件，发布的 APK 整体按 AGPL-3.0 分发，对应源码即本仓库。
- `app/src/main/assets/` 下的文件来自电脑版 OpenWrt Diff Studio，版权归其原作者。
- JSch、Bouncy Castle 等依赖库按各自许可证分发。

完整说明见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md)。

## 链接

- GitHub 主页：<https://github.com/linote99>
- Lino 笔记：<https://www.linote.top/>
