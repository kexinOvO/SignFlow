# Known Limitations

Last reviewed: 2026-10-27.

1. **Profile 刷新仍依赖 Xcode 与 Apple。** 续签已加入按 Team / Bundle ID 精确匹配的专属缓存备份刷新，覆盖主 App、Watch 与扩展。共享通配 Profile 保留，由用户在 Xcode 中处理；账户认证或 Apple 资源限制仍可能导致等待用户操作。
2. **设备部署证据分层。** 安装命令和后续 Bundle ID / 版本查询提供不同层级的证据。SignFlow 尚未直接读取设备上应用内的 Profile；应用启动与数据保留未单独验收。
3. **设备端应用签名未直接验证。** 卡片上的设备 Profile 到期时间依据该设备上一次经 SignFlow 确认的安装产物推算；外部以相同版本重新安装、证书过期或撤销均可能使实际情况不同。当前 devicectl 的 App 查询与版本校验不等同于读取已安装应用的签名期限。Apple 文档另有[设备 Profile 列表](https://help.apple.com/xcode/mac/current/en.lproj/devaafd622d2.html)，但列表本身不能证明某个已安装 App 使用了哪一份 Profile；该功能在当前 Xcode 27 和 watchOS 上尚未验证。
4. **Watch 的直接部署有门槛。** 连接后读取当前设备详情并确认 installapp 能力，真实所选 Watch 已公开此能力。没有公开能力的设备仍等待配套同步。相同版本的旧 Watch 安装不能证明新签名已传播，不能只据此认定续签任务完成。
5. **Xcode 账户必须自行配置。** 双重认证、信任、开发者模式与系统权限不能由 SignFlow 代办。团队成员资格不根据证书 Team ID 猜测。
6. **非 App Sandbox、未公证。** 为运行完整 Xcode 工具链禁用 App Sandbox。当前交付由本机 Apple Development 证书签名；跨 Mac 分发需要合适的 Developer ID、Hardened Runtime 配置与公证流程。
7. **后台运行是同一 App 进程。** 关闭主窗口可继续，退出即停止。没有 root daemon，不会让 Mac 强制唤醒；睡眠、关机与未登录期间不会执行。登录项与系统通知授权需要用户操作，未自动开启。
8. **日志保留不自动删除。** 设置保存保留天数用于管理提示；尚无按天自动清理。全局 AAR 清理只由人工确认执行。应用缓存重置需要明确确认，只处理自身查询目录。
9. **项目包含的构建脚本按 Xcode 原行为执行。** 用户应只导入信任的工程。SignFlow 不会移除脚本或替换 Entitlements 以迁就免费账户。
10. **Package 解析限制。** 导入默认禁止更新解析版本。缺少已准备的依赖时，先在 Xcode 处理。构建使用自己的 SourcePackages 目录，但工具链自身仍可能使用系统级签名 / SDK / 包缓存。
11. **迁移覆盖基本格式。** 已验证缺失 schema 的空旧状态迁移和未来 schema 拒绝；没有历史 SignFlow 生产数据库样本。损坏数据保留、自动任务停止。
12. **通用 IPA 未启用。** 存在 artifact source 协议与明确不支持的 IPA adapter，当前不提供 IPA 解包重签安装。
13. **macOS 14 未实际运行。** 部署目标设为 14，API 使用相应可用版本；实际运行与编译环境为 macOS / SDK 27 Beta。不同 SDK、旧系统、Intel Mac 和不同设备 OS 仍需回归。
14. **极端 UI 与长时间运行仍需验收。** 大规模项目 / 任务、VoiceOver 全流程、长期离线重试及系统升级后登录项恢复尚无长期测量结果。当前应用启动、原生导航与项目导入已做本机检查。
