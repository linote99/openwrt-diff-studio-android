# OpenWrt Diff Studio（Android 与 iOS）

在手机上比较两版 OpenWrt 完整发行包，生成差异包，并通过 SSH 更新设备。

> 当前发布版：**1.1.2**（versionCode 7）。同步 Diff Studio 桌面更新运行时的已验证共享模块，加入 F50 Pro、U30 Pro 和 LYM-10K 的差异包文件名标识；Android bootstrap 也会区分临时运行目录 session ID 与用户已审核的补丁 ID。设备端仍重新校验补丁内容。

## 功能

- **生成差异包**：选择旧版和新版完整发行 ZIP（E5 的 ext4 根文件系统，或 MU300 / F50 / F50 Pro / U30 Pro / V50 / U30Air 的 tar 根文件系统），分析变更文件、内核与启动镜像、软件包依赖。可导出完整更新包 ZIP（含 `update.ota`、电脑端更新器和说明），也可只导出 `.ota`；格式与电脑版 OpenWrt Diff Studio 相同。
- **版本摘要**：分析成功后保存新版 `.owrt-index.json` 摘要。下次可直接用摘要代替旧版完整包；摘要可在应用内查看、导出或删除。
- **更新设备（OpenWrt Updater）**：通过 SSH 连接设备，先检查空间、本地修改、依赖与版本，再应用更新。检查与应用之间会核对设备身份；补丁会以 root 权限写入系统文件。
- **适配手机网络与长任务**：自动选择能到达设备的 Wi-Fi、USB 网络共享或以太网；分析、导出和写入期间使用前台服务并保持唤醒。
- 中英文界面、深浅色主题，以及从文件管理器打开 `.ota` 或 `.zip`。

## 系统要求与安装

- Android 8.0（API 26）或更高版本。
- 更新设备时，手机须与设备在同一网络，并知道设备的 root 密码。默认管理地址：E5 为 `192.168.9.1`，MU300 为 `192.168.77.1`；也可填写 `地址:端口`。
- 已发布的 1.1.1 及更早 APK 使用同一签名证书；本地 debug APK 使用 Android 标准 debug 签名，不能覆盖安装到正式签名版上。当前发布的 1.1.2 APK 使用 Android 标准 debug 签名，不能覆盖安装到正式签名版。

## 使用提示

1. 在“生成差异包”页选择设备当前版本（完整 ZIP 或保存的版本摘要）与新版完整 ZIP，点击“分析差异”，确认后导出差异包。
2. 在“更新设备”页导入 `.ota`，填写设备地址和 root 密码，点击“连接并检查”；检查通过后再确认应用补丁。

只使用可信来源的补丁；旧版必须与设备当前运行版本一致（保存摘要不代表设备已更新）；更新期间不要断电或手动重启设备。分析发行包前请预留足够存储空间。

## 构建

需要 Android Gradle Plugin 8.7.3、Gradle 8.9（已附 Gradle Wrapper）、JDK 17、compileSdk / targetSdk 35、minSdk 26。

```sh
./gradlew testDebugUnitTest
./gradlew assembleDebug
./gradlew assembleRelease
```

仓库不包含签名密钥或密码。复制 `keystore.properties.example` 为未提交的 `keystore.properties`，并填入你自己密钥的信息后才会签名；没有该文件时会生成未签名 APK。若要覆盖安装到现有用户设备，必须使用与已发布 APK 相同的私钥。此发行包不提供该私钥。

`app/src/main/assets/` 中的设备端运行时文件应保持字节不变；导出更新器使用的文件清单位于 `app/src/main/assets/bundle/e5/files.json` 和 `app/src/main/assets/bundle/mu300/files.json`。如改动相关资产，需重新核对清单及兼容性。

## iOS 版本

iOS 工程位于 [`ios/`](ios/)，Xcode 项目为 [`ios/DiffStudio.xcodeproj`](ios/DiffStudio.xcodeproj)，构建与测试说明见 [iOS README](ios/README-iOS.md)。根目录的 [GitHub Actions workflow](.github/workflows/build-ipa.yml) 会在 iOS 文件变更推送到 `main` 时运行，也可手动触发；成功后在 Actions run 的 Artifacts 中下载 `DiffStudio-unsigned`。

Actions 生成的 IPA **未签名，不能直接安装**；需先用 AltStore 或 Sideloadly 自签。Android 工程仍位于仓库根目录，iOS 工程与 Android 文件分开放置。

## 许可证

应用自身源码采用 MIT License（见 [`LICENSE`](LICENSE)）。`app/src/main/java/com/linote/diffstudio/core/Ext4.java` 按项目现有声明采用 AGPL-3.0-or-later（见 [`LICENSES/AGPL-3.0.txt`](LICENSES/AGPL-3.0.txt)）。`app/src/main/assets/` 中的桌面工具与设备端文件、JSch、JZlib、jBCrypt、Bouncy Castle 等不属于本项目 MIT 许可范围；详见 [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md) 及各自许可文件。

## 1.1.2 测试与安装提示
`./gradlew testDebugUnitTest` 与 `./gradlew assembleDebug` 已通过（JDK 17）；E5 / MU300 两份导出清单各 18 项资源哈希均匹配。APK 包名为 `com.linote.diffstudio`，版本为 1.1.2（versionCode 7），使用 Android 标准 debug 签名，不能覆盖安装到 1.1.1 及更早的正式签名版；迁移前请备份数据，卸载旧版可能清除应用数据。本版尚未在真实手机或路由器上测试。
## 链接

- GitHub 主页：<https://github.com/linote99>
- Lino 笔记：<https://www.linote.top/>
