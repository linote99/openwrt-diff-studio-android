# 更新日志

## 1.0.3（versionCode 4）

- 更新设备页标题由 “OpenWrt Patch Updater” 改为 “OpenWrt Updater”。
- 仓库整理：签名密钥移出仓库，改为读取本地 `keystore.properties`；附带 Gradle Wrapper、许可证和第三方声明。

## 1.0.2（versionCode 3）

- 新增应用内关于页：版本信息、使用说明、注意事项，底部为“友情链接”（GitHub 主页、Lino 笔记）。
- 顶部新增 ⓘ 按钮进入关于页，支持返回键退出。

## 1.0.1（versionCode 2）

- 修复部分手机的保存对话框把导出文件名截短并改成 `.bin` 的问题：导出时自动恢复完整文件名和 `.zip` / `.ota` 扩展名，同名文件自动加序号；无法改名时提示手动修改扩展名。

## 1.0.0（versionCode 1）

- 首个版本：电脑版 OpenWrt Diff Studio 的安卓移植，支持生成差异包（E5、MU300 / F50 / V50 / U30Air）和通过 SSH 更新设备。
