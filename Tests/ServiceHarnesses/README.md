# 服务回归 harness

在 macOS 15+、已安装 Xcode 命令行工具的环境执行：

```sh
./scripts/test-services.sh
```

脚本相对自身定位仓库，可从任意工作目录调用。七组共 87 项检查，失败返回非零退出码。生成源码、编译器缓存和可执行文件均放在 `/tmp/notch-services.*`，退出时清理，不改变 SwiftPM 配置。

`assemble.py` 每次读取当前生产源码。目录内 Swift 文件只包含依赖替身和断言，不保存另一套业务实现。生产标记改变时脚本明确失败，避免悄悄测试旧实现。

| 组 | 实际生产代码 | 最小替身 | 检查数 |
| --- | --- | --- | --- |
| HUD | 完整 `HUDStateManager` | AX 查询与申请、Defaults、MediaKeyInterceptor、HUD 展示端 | 30 |
| 日历管理 | 完整 `CalendarManager`、真实 `CalendarSelectionState` 枚举 | CalendarService、Defaults、轻量日历 / 事件模型 | 11 |
| 日历查询 | 完整 `CalendarService`（不含模型转换扩展） | EventKit 数据源及查询记录、轻量模型 | 4 |
| 日历 UI 逻辑 | `BoringCalendar` 中的 `scrollToRelevantEvent`、`filteredEvents` 原方法 | Defaults、事件列表与记录调用的 ScrollViewProxy | 7 |
| 电池通知 | 完整 `BatteryStatusViewModel`，通过同文件扩展调用私有通知入口 | Defaults、电池数据源、可见状态、记录通知的 coordinator | 6 |
| 快速分享生命周期 | 完整 `QuickShareService`、`SharingStateManager` 和 `SharingLifecycleDelegate` | 分享服务发现、空暂存数据源、受控临时文件删除 | 7 |
| 硬件控制 | 完整 `VolumeManager`、`HardwareBrightnessManager`、`SerialScalarControl` | 可故障注入的音频设备、亮度读写、HUD 展示端 | 22 |

HUD 注入缺少权限、授予 / 撤销权限、tap 启动失败、隐藏 / 恢复及关闭状态；验证用户开关保留和错误区分。日历验证全部取消不会退回全选、持久化枚举保留空集合、恢复选择和旧异步结果不能覆盖新日期。滚动验证开关关闭时不滚动及排队后关闭的取消行为。查询验证按日的半开日期区间、只使用指定的提醒列表；过滤覆盖两个开关的四种组合，包括全天提醒事项。

HUD 组不请求真实系统权限，也不安装事件 tap。日历管理组不访问个人日历；服务组使用 EventKit 替身注入固定提醒，记录查询的列表 IDs，不读取真实日历内容、不申请权限、不写入事件或提醒事项。这些故障注入结果不能代替真实 TCC 授权、媒体按键、锁屏、日历 UI 和系统设置的本机验收。

电池组覆盖关闭开关、正常发送、隐藏/锁屏 gate、延迟中关闭或隐藏、恢复后新事件，使用替身而不监视真实电池。快速分享组将 fixture 文件登记到生产代码的请求资源表，直接模拟真实 delegate 回调，覆盖超过两秒仍保留资源、成功、失败、取消、重复回调、两个请求互不提前清理。只创建测试服务对象，不调用 `perform`，不显示 picker，不发送内容；测试文件仅位于随机 `/private/tmp/notch-share-harness-*` 目录并在退出时清理。

保存完整检查日志：

```sh
mkdir -p build/validation/shu
./scripts/test-services.sh > build/validation/shu/service-tests-final.log 2>&1
```


媒体链路组使用实际生产管理器验证硬件量化回读、写入失败、读回失败、静音、软件静音回退、连续相对亮度调节及隐藏展示 gate；不调用真实 CoreAudio 写操作或 XPC 亮度服务。HUD 组增加主进程路径与最近媒体事件诊断、tap 失败同步关闭展示以及关闭时释放回调。脚本另对实际 `MediaKeyInterceptor` 与最小业务替身做 typecheck，不安装系统 event tap。

`Tests/NotchInteractionTests/MediaKeyRoutingTests.swift` 和 `SerialScalarControlTests.swift` 额外覆盖 14 项纯逻辑测试：已知键解码、成对按下/抬起、长按重复、孤立重复、停用清理、串行事务、只发布实际回读、不可用或失败路径、XPC 超时/错误/回复只完成一次。

会话取消覆盖隐藏后迅速恢复：已排队的旧代号亮度操作不写硬件；已经写入但迟到的读回只同步实际状态，不重新打开 HUD。媒体键主队列动作同样携带 tap 生命周期代号，停用或恢复 tap 后不执行旧动作。

诊断回归额外验证最近媒体事件仅保留 20 条，保留时间、方向、按下/抬起、重复与消费状态，排除非媒体键；最后控制结果包含实际读回、成功/失败和时间。量化读回必须记录硬件返回值，读回缺失必须记录 `Unavailable` 与明确错误，不能用旧缓存或请求目标代替；旧生命周期迟到结果不能覆盖当前诊断。
