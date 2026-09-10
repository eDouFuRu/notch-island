# 工位充电岛 · NotchIsland

把 MacBook 的刘海变成一块可交互的小岛：鼠标移到刘海上就展开，放着媒体控制、日历、系统音量／亮度提示、歌词、番茄钟、截图暂存和一排系统快捷工具。

基于开源项目 [boring.notch](https://github.com/TheBoredTeam/boring.notch)（GPL-3.0）二次开发，加入了一只番薯角色「薯队长」和围绕它的动画、番茄钟玩法，以及一套系统工具页。

<p align="center"><img src="boringNotch/Assets.xcassets/ShuIcon-captain.imageset/icon.png" width="160" alt="薯队长"></p>

## 下载安装

到 [Releases](../../releases) 下载最新的 `NotchIsland-<版本>.dmg`，打开后把「工位充电岛」拖进「应用程序」。

**运行要求：macOS 15.0 或更高、Apple Silicon（M 系列）机型。** Intel 机型未做过验证。

### 首次打开需要手动放行

这个应用**没有经过 Apple 公证（notarization）**，因为作者没有付费的 Apple Developer 账号。首次双击时 macOS 会拦下它，提示无法验证开发者、可能含有恶意软件。放行步骤：

1. 双击一次（被拦下，先点「完成」／「好」关掉提示）；
2. 打开「**系统设置 → 隐私与安全性**」，滚到底部会看到刚才被拦下的记录，点「**仍要打开**」；
3. 再双击一次，在弹窗里点「打开」。

macOS 15 之后 Apple 取消了「按住 Control 点图标 → 打开」的旧绕过路径，所以请走上面的系统设置。如果你更习惯命令行，也可以直接去掉隔离标记（这等于自己承担「不经 Gatekeeper 校验」的风险）：

```sh
xattr -dr com.apple.quarantine /Applications/工位充电岛.app
```

放行一次之后，以后正常双击即可。

### 会请求哪些权限，用来做什么

| 权限 | 用途 | 不给会怎样 |
|---|---|---|
| 辅助功能 | 接管系统音量／亮度 HUD、把系统通知横幅转显到刘海、锁屏快捷键 | 这些功能不可用，其余功能正常 |
| 屏幕录制 | 截屏与录屏工具 | 截屏／录屏不可用 |
| 日历、音乐控制等 | 对应的小岛面板 | 该面板为空 |

应用不上传任何数据：番茄钟记录、暂存文件、通知内容都只留在本机。

## 功能

- **媒体与日历**：展开即见的播放控制、专辑封面、日历事件。
- **系统 HUD**：内置屏幕亮度、音量、静音的刘海提示，替代系统原生大方块。
- **歌词**：联网匹配当前播放歌曲的同步歌词，在刘海里滚动显示。
- **番茄钟（红薯钟）**：自定义专注与休息时长，支持暂停、离线结算，配一套薯队长 2.5D 动画。
- **截图暂存**：应用内截屏录屏、系统快捷键截图自动进入暂存区，可拖出使用。
- **系统工具页**：截屏、录屏、秒表、计时器、闹钟、音量／亮度滑块，以及蓝牙、Wi-Fi、夜览、原彩显示、显示模式、音频输出等开关与入口。可自选显示哪些工具及顺序。标注「打开设置」的项是跳转系统设置的快捷入口，不代表直接切换系统状态。
- **应用通知转显**：任意 App 的桌面横幅都可以转显到刘海上，可逐个 App 开关、单独控制是否显示内容预览。
- **中英双语界面**。

### 关于企业内部通知源

代码里对一款企业内部 IM（bundle id `com.electron.redcity`）做了通知解析适配，因为作者所在公司用它。对其他人来说这只是一条多余的适配规则，不影响任何功能，也不会向外发送任何数据。

## 自行构建

```sh
git clone <这个仓库>
cd notch-island
open boringNotch.xcodeproj
```

在 Xcode 里选择 **NotchIslandNext** scheme，把签名改成你自己的开发者账号（或「Sign to Run Locally」），然后 Build & Run。需要 Xcode 16 或更高、macOS 15 SDK。

纯逻辑模块可以脱离 Xcode 直接测：

```sh
swift test                     # 核心逻辑单元测试
./scripts/test-services.sh     # 服务层检查（不触碰真实硬件）
python3 scripts/audit-localization.py   # 中英词条一致性
```

发布版二进制是用作者本机的自签证书签的，那套脚本涉及本机钥匙串，没有包含在这个仓库里。

## 已知限制

- 没有 Apple 公证，首次打开需手动放行（见上）。
- 没有自动更新，新版本需要回到 Releases 页手动下载。
- 只构建、只验证过 Apple Silicon。
- 触发区固定为系统的物理刘海矩形，非刘海机型不适用。

## 许可与上游

本项目以 **GPL-3.0** 授权，与上游 boring.notch 保持一致：你可以自由使用、修改、再分发，但衍生作品必须同样开源并保留许可证。

- 上游：[TheBoredTeam/boring.notch](https://github.com/TheBoredTeam/boring.notch)，本项目基于其提交 `16b0f11f51c79d42e27c10d77fd9e53c11410fdb`（v2.7.3）。
- 许可证全文见 [LICENSE](LICENSE)，第三方组件声明见 [THIRD_PARTY_LICENSES](THIRD_PARTY_LICENSES)，上游原始说明见 [docs/upstream/README-boring-notch.md](docs/upstream/README-boring-notch.md)。

## 关于角色形象

「薯队长」的插画与 2.5D 贴图是为本项目生成的原创素材。本项目是个人业余作品，与任何公司无关，也未获得任何公司背书。如果你认为其中某个素材侵犯了你的权利，请提 issue，我会撤下或替换。
