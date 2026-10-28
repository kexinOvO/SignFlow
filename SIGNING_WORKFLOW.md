# Signing and Renewal Workflow

Last reviewed: 2026-10-27.

## 四种证据

| 证据 | 来源 | 可以说明 | 不能说明 |
|---|---|---|---|
| 项目设置 | xcodebuild Build Settings / PBX | Team、Bundle ID、Scheme、Embed 关系 | 已构建或已安装 |
| 本地产物签名 | codesign + security cms + Security API | 指定本地 Bundle 的完整性、证书、Profile、有效期和授权 | 设备上是同一签名 |
| 设备安装记录 | devicectl info apps | 查询时存在的 Bundle ID、版本、Build | 已安装 Profile 的到期时间 |
| 此任务部署结果 | 成功安装命令 + 后续版本查询 + 此任务验证产物 | 已完成该任务的安装操作与元数据确认 | 通过公开 API 直接读取了设备端 Profile |

`DeploymentEvidence.deviceSignatureVerified` 当前保持 false。界面显示具体来源与查询时间；绝不把本地日期伪装成设备端签名日期。

设备详情可以按设备显示「预计 Profile 到期」。它追溯同一项目、设备和 Bundle ID 最近一次由 SignFlow 确认的安装任务，使用该任务的本地产物记录，而不是当前可能已经变化的本地产物。设备安装查询需要能与当时的版本或 Build 对应；后续明确发现应用不存在、版本变化、替换失败或安装结果不明时停止推算。没有完整安装签名、切换设备或安装进行中也显示无法确认。主 App 与其嵌套扩展取最早的 Profile 日期；Watch 独立计算。外部以相同版本覆盖安装仍无法通过版本查询识别，因此结果保留「预计」和上次安装确认时间。Profile 日期也不是证书有效性保证。现有自动续签调度仍依据本地产物签名。

## 状态机

待检查 → 检查中 → 待续签 → 准备构建 → 构建中 → 验证签名 → 等待设备 / 安装中 → 验证安装 → 已完成。

还包括已取消、等待用户操作、可重试失败、不可重试失败、部分成功。每个阶段保存事件和快照，错误分为面向用户的说明、建议与原始技术信息。

1. 检查路径与 Xcode 环境，读取之前已验证的本地签名作为基线。
2. 检查可用开发签名身份。认证或信任问题等待用户，不自动重复认证。
3. 在专属目录用参数数组调用 Xcode。开启自动资源更新时加入 `-allowProvisioningUpdates`；设备注册另有显式开关。续签构建另行执行下文的专属 Profile 刷新，并清除本次命令中的固定 Profile 选择。两项参数先检查本机 help 是否支持。
4. 搜索 Bundle ID 匹配的真实产物，确认应有的主 App、Watch、Extension 均存在。
5. 对根 App 与所有实际发现的 App / appex 做严格签名检查；递归框架完整性由 codesign deep verify 覆盖。
6. 解码每个 embedded.mobileprovision，检查 Team / Application Identifier、证书成员与有效期、实际 Entitlements 授权，检查嵌套团队一致。
7. 新旧比较：全部 Profile 与签名必须有效；旧组件不可消失；原有组件的 Profile 到期时间必须全部严格延长，创建时间不能倒退，团队必须一致。无旧基线是「首次建立基线」，不记为续签。
8. 刷新后到期时间仍未延长时停止续签，记录各 Bundle 的 Profile UUID 与到期时间，等待 Xcode 账户 / 资源处理。
9. 对两个平台分别检查目标设备、Profile 的设备 UDID 与开发者模式。安装前用 `device info details` 建立连接并读取当前能力；支持 `--show` 的工具请求 `detailed`，旧工具省略该参数。连接后的 ID、UDID、平台必须与选择一致。Watch 直接安装判断使用连接后的能力，不使用尚未连接时列表中的能力快照。设备离线时保留已验证的产物等待。
10. 初次接管已安装同 Bundle ID 的应用时暂停确认风险；已知团队变化始终停止。只调用 install，不调用 uninstall。
11. 安装后再次查询 Bundle ID 与版本，缺失版本或结果不匹配均不是成功。
12. Watch 不支持直接安装或不能确认新构建已传播时保持待验证；iPhone 成功不能掩盖 Watch 失败。

「签名已更新，部署失败」会体现在任务 summary 与分设备结果中；临时错误有限重试，其余为部分成功或需要用户操作。仅完整续签与部署完成才更新项目 lastRenewal。

## 续签时刷新专属 Profile

`-allowProvisioningUpdates` 允许更新资源，但现有 Profile 仍符合要求时 Xcode 会复用。`ProfileRefreshService` 在续签构建前检查新旧两个缓存位置：`~/Library/Developer/Xcode/UserData/Provisioning Profiles/` 与 `~/Library/MobileDevice/Provisioning Profiles/`。

范围来自旧签名基线，包含主 App、Watch 与扩展。只暂时移出 Team 与 Bundle ID 精确匹配、到期时间不晚于基线的开发 Profile；共享通配、分发、其他团队、其他应用、无法解码和已更新的 Profile 均保留。无旧基线时不猜测缓存范围。关闭资源更新或已知团队变化会在变更前停止。

先将匹配文件复制到 SignFlow 数据目录的 `SigningBackups/<操作 UUID>/`，校验内容，写入原路径与 SHA-256 恢复记录，以 `USER_DATA` 登记中央 AAR，成功后才临时移出原文件。备份不标记可重新生成或可安全删除，不自动清理。

构建成功、失败或取消后都恢复缺失的旧缓存，保留 Xcode 在相同路径新生成的文件。备份与恢复记录保留。启动及下一次构建会先恢复未完成记录；恢复路径限制在已知缓存目录，备份内容变化会停止恢复。AAR 不可用时明确报告；初始登记失败不会变更缓存。恢复和其登记不会被任务取消中断。

同一 AppModel 的签名构建串行经过共享刷新服务，避免另一个 SignFlow 构建观察到临时缺失的 Profile；其他检查和设备任务仍可并行。系统中的其他 Xcode 进程可能同时更新缓存，发生变化时停止刷新，恢复时不覆盖已有文件。

依据：[Apple 的自动签名刷新说明](https://developer.apple.com/help/account/provisioning-profiles/edit-download-or-delete-profiles/)。

## 恢复与重试

等待设备可以继续；达到临时失败重试上限则等待手动操作。指数退避最大一小时。相同基线的终止失败不会被新的周期检查重新赋予完整预算。

恢复时重新检查已有产物。如果已过期或无效则不能部署；用户重试相关签名错误会建立新 Attempt 重新构建。如果上一安装没有明确成功记录，不以相同版本号推断其签名已更新。

## Apple 官方边界

- [Apple 账户与 Personal Team](https://developer.apple.com/help/account/basics/about-your-developer-account)：免费资源与有效期限制。
- [Signing & Capabilities](https://help.apple.com/xcode/mac/current/en.lproj/dev60b6fbbc7.html)：由 Xcode 管理签名资源。
- [设备运行工作流](https://help.apple.com/xcode/mac/current/en.lproj/dev5a825a1ca.html)：账户、团队、设备与开发者签名。
- [SMAppService main app](https://developer.apple.com/documentation/servicemanagement/smappservice/mainapp?language=objc)：登录启动，而非睡眠期间执行。

本机参数依据 Xcode 27 的 `xcodebuild -help`、`xcrun devicectl help ...` 实际输出。当前没有完成 Personal Team 的真实自动刷新与完整设备部署验收。
