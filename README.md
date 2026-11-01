# M365Hub for macOS — 原生 SwiftUI 版

不再用 Electron：这是一个原生 macOS 应用（SwiftUI 控件 + AppKit 网关进程管理），
体积只有网关二进制（约 12MB）+ 一个 SwiftUI 壳（几 MB），不再是 109MB 的 Electron。

## 液态玻璃

药丸（输入条、导航、发送键）用的是苹果自己的 Liquid Glass：
macOS 26+ 上走 SwiftUI `.glassEffect(.regular)`（真折射 + 高光 + 形变，
见 `M365HubApp/Glass.swift`）；更早的 macOS 自动退回 `ultraThinMaterial`，
不会崩、只是没有折射。编译需要带 macOS 26 SDK 的 Xcode（Xcode 26+），
运行时在旧系统上走退回路径。

## 构建（需要一台 Mac）

1. 编网关（在 m365hub Go 源码目录里）：
   `bash ~/workspace/m365hub-mac-swiftui/build-gateway.sh`
   （把 darwin/arm64 的 m365hub 二进制放进 `M365HubApp/Resources/m365hub`）
2. 在 Xcode 里打开 `M365HubApp.xcodeproj`，选 My Mac，Build & Run。
3. 首次打开：网关若已在 127.0.0.1:8230 跑着会被直接接管（不杀）；
   否则应用自己起一个，退出应用（Cmd+Q）时只停自己起的那个。
   默认管理员密码首次登录强制改密（与旧控制台一致）。

## 注意（老实话）

- 1.0.6 修了工程文件损坏问题：1.0.5 的 project.pbxproj 里有 5 处对象 ID 撞号
  （工程对象与配置表共用一个 ID，Xcode 打开就报 damaged / _setSavedArchiveVersion），
  已全部换成唯一 ID 并校验通过；另把之前漏打进包的 Assets.xcassets（AppIcon）补上了。
- 1.0.7 修了 Xcode 26 以下编不过的问题：Glass.swift 的 `.glassEffect` 只用 `#available` 挡不住，
  旧 SDK 里根本没有这个符号，改成 `#if compiler(>=6.2)` 编译期分支（Xcode 26 走真液态玻璃，
  旧 Xcode 走 ultraThinMaterial）；MathView.swift 的 `sizeToFit()` 是 UIKit 才有的方法，
  macOS 的 SwiftMath 标签改用 `sizeThatFits(.zero)`。Xcode 16 也能编了，想看真折射效果再升 Xcode 26。
- 1.0.8 修 MathView 的公式尺寸：`sizeThatFits` 只在 SwiftMath 的 main 分支有，正式版 1.7.3
  的 macOS 标签没有它，改成 `fittingSize`（1.7.3 在 macOS 上重写了这个属性，值就是排版尺寸，
  且它是 AppKit 自带的属性，换哪个 SwiftMath 版本都编得过）。
- 1.0.9 修 ChatView 的文件选择：单文件版 `.fileImporter` 回的是 `Result<URL, Error>`，
  但 `handlePicked` 要的是 `Result<[URL], Error>`，改成 `allowsMultipleSelection: true`
  的多选版（顺带支持一次选多个附件）。
- 这个工程是在 Linux 上写的，**没有经过 Xcode 编译**，第一次在 Mac 上
  Build 是验收步骤：若有 API 细节报错（例如 glassEffect 的 SDK 版本），
  按 Xcode 的提示改 Glass.swift 里的 availability 门即可，逻辑不用动。
- 数学公式：原生端没有 KaTeX，LaTeX 源码会去标记后以纯文本显示，
  不渲染成排版公式；这是原生版相对网页版唯一的功能降级。
- Mac 上没有“拍照上传”的系统相机选择器，所以 ＋ 菜单里的第三项是
  从照片图库/文件里选图；iPhone 式相机直拍只在安卓原生版里有。
- 应用未签名、未沙箱化（与旧 Electron 版一致），首次打开需右键 → 打开。

## 1.0.1：数学公式（SwiftMath，原生）

- 聊天里助手的数学公式不再是 LaTeX 源码：工程已接入 Swift Package
  `SwiftMath`（mgriebling/SwiftMath，iosMath 的 Swift 移植，1.7.0+），
  用 `MTMathUILabel` 原生排版，不用 WebView、不用 JavaScript。
- 行内公式嵌进文字行，独立公式（`\[...\]`、`$$...$$`、```latex 代码块）
  居中显示；代码块里的公式不解析；`$20` 这类文本不受影响；
  SwiftMath 拒绝的写法会原样显示 LaTeX 源码，内容不丢失。
- 首次在 Xcode 里 Build 需要联网一次以下载 SwiftMath（约几 MB）。
  如果自动解析失败，手动加一次即可：Xcode 菜单 File > Add Package
  Dependencies，粘贴 https://github.com/mgriebling/SwiftMath.git。

## 1.0.2：聊天指定账号（2026-10-31）

- 聊天顶栏多了账号下拉框：默认“轮询”（全部账号轮询，和以前一样），
  选一个账号后聊天和生图都只用这个号；选择记在 UserDefaults
  （m365hub-chat-account），下次打开还在。下拉框显示邮箱 @ 前面那段。
- 聊天原样发请求：续聊只发新打的原话，不加提示词；API 调用不受影响。
- 网关已重编（darwin/arm64，含 DoH、会话复用、pin 账号、Plain 聊天）。
  Mac 工程仍未在真机 Xcode 里编译过，首次 Build 仍是验收步骤。

## 1.0.3：修云端对话拉取失败（2026-10-31）

- 对话页云端拉取报 token refresh DNS 被拒：云端对话客户端是裸
  `http.Client`，没走带 DoH 兜底的 outbound 拨号器；现已改走
  `outbound.HTTPClient()`（每次请求现取），设备码登录的两处 Token
  请求同样换过去。Mac 工程仍未在真机 Xcode 里编译过。

## 1.0.4：助手消息可复制（2026-10-31，与安卓 1.2.10 同款）

- 每条助手消息下面多了个“📋 复制全部”按键，点一下整条复制走，
  按钮短暂变成“已复制全部内容”。复制的是去标记后的纯文本：
  加粗/标题/列表标记去掉，公式留 `$...$` 源码，代码块留源码原样。
- 文字本身也能自由复制了：消息区开了 `.textSelection(.enabled)`，
  助手和自己发的消息都能拖选其中一段，只复制那一段。
- 网关未改（仍是 1.0.3 的 darwin/arm64 二进制）。Mac 工程仍未在
  真机 Xcode 里编译过，首次 Build 时顺带确认复制按钮与拖选都生效。

## 1.0.5（2026-10-31，网关只修生图下载）
与 Android 1.2.12 同一个网关修法：Designer 图片下载改走 outbound 共享传输（DoH 兜底），之前用裸 http.Client，在直连 DNS 被拒的手机上取图失败，生图只剩一句话、图是空白的。应用代码未改，只重编了 Resources/m365hub。包 sha256 e1fd83d732710f0f2d1679e736ecab7bef88762bfa48ea50c2aeb6a25544a263。

## 1.0.6：应用图标换成新版（2026-10-31）
- 图标换成用户给的机器人新图标（Designer__4.png）：新增 M365HubApp/Assets.xcassets/AppIcon.appiconset（16–1024 十档），pbxproj 已接线（Resources 阶段 + 两处 ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon）。
- 应用代码未改，网关未改。Mac 工程仍未在真机 Xcode 里编译过，首次 Build 时顺带确认图标在 Dock 与启动台里显示正常。包 sha256 290b930d3e88fe3a9af9af94056ebe1254afe7ac2af2155b61a6db03440ebefb。
