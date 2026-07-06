# 踩坑经验 — 跨 Service 协作 / 并发 / 资源管理

> 更新: 2026-03-05

## 功能交互 / 跨 Service 协作（Round 3-4 优化）

### L-008: 两个 Service 写同一 CoreGraphics 资源会互相覆盖
- **现象**: 设置 gamma 调整后拖动亮度滑块，gamma 效果消失（或反之）
- **原因**: GammaService 和 BrightnessService 都调用 CGSetDisplayTransfer*，后调用的完全覆盖前者
- **解法**: 指定 GammaService 为唯一写入者；BrightnessService 把亮度因子存入 softwareBrightnessFactors，GammaService 在 applyFormula 里读取并乘入 rHi/gHi/bHi
- **教训**: 两个 Service 共享底层资源时，必须指定唯一所有者，其他方通过接口影响而不是直接写
- **日期**: 2026-03-04

### L-009: macOS 睡眠/唤醒会重置所有 CGSetDisplayTransfer* 效果
- **现象**: gamma 调整和软件亮度在 Mac 睡眠后全部丢失
- **原因**: macOS 睡眠时重置 display transfer function 到系统默认值，CGSetDisplayTransfer* 效果不持久
- **解法**: 注册 NSWorkspace.didWakeNotification，唤醒后延迟 500ms 对所有显示器重新 apply
- **教训**: 写 display 硬件状态的功能都必须考虑睡眠唤醒后重置，测试要覆盖此场景
- **日期**: 2026-03-04

### L-010: CGDisplayRegisterReconfigurationCallback 必须用 passRetained
- **现象**: 理论 crash 风险：C 回调访问悬空指针
- **原因**: passUnretained 不增加引用计数，self 被释放后回调访问悬空指针
- **解法**: passRetained + 配对 release（在 stopMonitoring/deinit 里）
- **教训**: 传给 C 回调的 self 指针一律用 passRetained，项目中已出现两次（DisplayManager + ConfigProtectionService）
- **日期**: 2026-03-04

### L-011: AutoBrightness 与手动调节必须有 cooldown 机制
- **现象**: 手动调亮度 2 秒后被 AutoBrightness 覆盖
- **原因**: applyBrightness 只检查差值，没有"用户最近手动操作"保护
- **解法**: setBrightness 增加 isAutoAdjust 参数，手动调用时记录 lastManualAdjustDate，AutoBrightness 检查 30s cooldown
- **教训**: 自动调节功能必须有手动干预后的暂停机制
- **日期**: 2026-03-04

## 并发 / 资源管理（Round 5 优化）

### L-012: GammaService activeAdjustments 字典必须加锁
- **现象**: 数据竞争风险——BrightnessService 从 background queue 读 hasActiveAdjustment，GammaService 从 MainActor 写 activeAdjustments
- **原因**: 字典无同步保护，多线程并发读写是 Swift 的 undefined behavior（可能崩溃或数据损坏）
- **解法**: 新增 NSLock，所有 activeAdjustments 读写都加锁（hasActiveAdjustment/apply/reapply/reset 等）
- **教训**: 凡是被多个 Actor 访问的可变状态，无论是否当前触发了 race，都必须加锁
- **日期**: 2026-03-04

### L-013: GammaService 量化路径必须同步 brightness factor
- **现象**: 软件亮度在量化模式（quantizationLevels < 256）下静默失效
- **原因**: applyFormula 读取 softwareBrightness factor，applyQuantizedTable 没有读取，两路径不一致
- **解法**: applyQuantizedTable 同样读取 brightnessFactor 并缩放 rHi/gHi/bHi
- **教训**: 同一 Service 有多条执行路径时，所有路径都必须应用相同的修改逻辑
- **日期**: 2026-03-04

### L-014: 睡眠唤醒时 BrightnessService 必须在 GammaService 之前 reapply
- **现象**: 屏幕唤醒时短暂闪白（满亮度）后才恢复
- **原因**: 先调 GammaService.reapply 时 softwareBrightnessFactors 尚未恢复，applyFormula 读到 1.0 写入硬件
- **解法**: 唤醒时先 BrightnessService.reapply，再 GammaService.reapply（确保 factor 已就绪）
- **教训**: 有依赖关系的 reapply 必须按依赖顺序调用；BrightnessService 是 GammaService 的数据提供方
- **日期**: 2026-03-04

### L-015: NSWindow 关闭必须停止关联的 SCStream
- **现象**: 用户点 PiP/Stream 窗口的红色关闭按钮，串流仍在后台运行耗资源
- **原因**: NSWindowController 未实现 NSWindowDelegate.windowWillClose，关闭事件不触发 stopCapture
- **解法**: PiPWindowController/StreamWindowController 实现 windowWillClose → viewModel.stopCapture()，同时设 window.delegate = self
- **教训**: 系统提供的关闭入口（红色按钮）和 app 内关闭按钮都要清理资源，不能只处理其中一个
- **日期**: 2026-03-04

### L-016: 遍历 Dictionary 时禁止同时调用 removeValue
- **现象**: NotchOverlayManager.screenParametersChanged() 遍历 overlayWindows 时调用 removeValue，潜在崩溃
- **原因**: Swift Dictionary 不支持在 for-in 迭代过程中修改自身，行为未定义
- **解法**: 收集待删 key 到临时数组，循环外统一删除
- **教训**: 任何 for-in 遍历集合时，不能对该集合做增删操作（同语言里的 ConcurrentModificationException 等价问题）
- **日期**: 2026-03-04

### L-017: UserDefaults key 必须有应用命名空间前缀
- **现象**: SettingsService/AutoBrightnessService/ConfigProtectionService 用裸 key（如 "launchAtLogin"）
- **原因**: 裸 key 可能与 macOS 系统 defaults 或未来第三方库冲突，导致读到意外值或覆盖系统设置
- **解法**: 统一加 `fd.` 前缀（fd.launchAtLogin, fd.AutoBrightnessEnabled 等）
- **教训**: UserDefaults key 命名规范：`<app_prefix>.<key>`
- **日期**: 2026-03-04

### L-018: Mirror source/target API 查询方向
- **现象**: refreshMirrorState 用 CGDisplayMirrorsDisplay(source) 查询，永远返回 nil（source 不克隆任何人）
- **原因**: CGDisplayMirrorsDisplay(X) 返回"X 克隆的目标"，而 SOURCE 本身不是克隆者
- **解法**: 反向查询——遍历所有显示器，找 CGDisplayMirrorsDisplay(candidate) == source 的那个（即 target）
- **教训**: Mirror API 语义：SOURCE 是被克隆的，TARGET 才是克隆者；查询应该从 TARGET 视角（"谁在克隆我"）
- **日期**: 2026-03-04

### L-019: IOPMAssertion 必须先 release 再创建新 assertion
- **现象**: ManageDisplayView 每次打开防睡眠开关都泄漏一个 IOPMAssertion，旧 ID 被覆盖无法 release
- **原因**: createSleepAssertion() 未检查 sleepAssertionID != 0，直接覆盖
- **解法**: 创建前先 release 旧 assertion；onDisappear 只在 !preventSleep 时 release（保持开关 ON 时持续生效）
- **教训**: 系统资源（IOPMAssertion、IO iterator 等）必须严格配对 create/release，覆盖 ID 前先 release 旧的
- **日期**: 2026-03-04

### L-029: 自定义键盘快捷键需要 Input Monitoring 权限，不是 Accessibility
- **现象**: 用户设置了自定义亮度快捷键（如 Cmd+↑），按下后没有任何反应，看起来像是"系统快捷键优先级更高"
- **原因**: BrightnessKeyService 的 CGEventTap 同时监听 `.keyDown`/`.keyUp`（不只是媒体键的 NSSystemDefined 事件）；macOS 10.15+ 对监听原始键盘事件的 event tap 要求 **Input Monitoring** 权限（`IOHIDCheckAccess(kIOHIDRequestTypeListenEvent)`），和控制其他 App 用的 Accessibility 权限是两码事。权限缺失时 `CGEvent.tapCreate` 直接返回 nil，之前的代码只在 console 打一行日志，UI 上完全无感知，用户会误以为是系统抢了优先级，实际上是我们的 tap 根本没装上
- **解法**: `start()` 里先调 `IOHIDCheckAccess`，状态为 `.unknown` 时用 `IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)` 主动弹系统权限框；状态已是 `.denied`（例如反复用 ad-hoc 签名重新构建触发过一次拒绝）时系统不会再弹框，只能引导用户去 系统设置 → 隐私与安全性 → 输入监控 手动开启（或自己在终端跑 `tccutil reset ListenEvent <bundle-id>` 清掉旧记录）；BrightnessKeyService 新增 `@Published var inputMonitoringStatus`，Settings 页在快捷键开启但权限未授予时显示提示条 + "Open Settings" 按钮深链到该设置页
- **教训**: 任何监听全局键盘事件（而非只发送/合成事件）的 CGEventTap 都要检查 Input Monitoring，而不是想当然地用 AXIsProcessTrusted；权限缺失必须有用户可见的 UI 反馈，不能只写 console log，否则用户无法自助排查
- **日期**: 2026-07-05
