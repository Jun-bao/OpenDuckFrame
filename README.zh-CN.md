<p align="center"><img src="Design/AppIcon/AppIcon.appiconset/AppIcon-256.png" alt="OpenDuckFrame" width="128" height="128"></p>
<h1 align="center">OpenDuckFrame · 开源小鸭</h1>
<p align="center"><b>让 Mac 上的画面更流畅、更清晰。</b></p>
<p align="center">选一个窗口、一块屏幕或一个视频，实时补帧与超分。</p>
<p align="center"><a href="https://openduckframe.cn/">官网与使用指南</a> · <a href="README.md">English</a> · <b>简体中文</b></p>
<p align="center">Apple 芯片 · macOS 14+ · <a href="LICENSE">MIT 开源</a></p>

默认补帧模型为 **ODF-VFI 四阶段精简版**，由 RIFE 4.25 做结构精简得到，沿用上游权重、未重新训练，模型处理开销更低。现有 RIFE 4.25 配置保持兼容并改用 ODF-VFI，加载时会校验实际四阶段权重；画质表现仍取决于素材。

## 简介

OpenDuckFrame 是一款原生 Mac 画质增强应用。浏览器视频、游戏与串流窗口、整块显示器，或本地视频文件，
都可以作为输入源，在同一个工作台里配置补帧和超分。画面在你的 Mac 上处理，无需账号，也不上传。

- **补帧引擎可选。** 工作台提供 ODF-VFI（默认）、Apple 低延迟和 Apple 帧率转换。
  可选帧率与质量随引擎、输入来源变化；苹果选项需要系统与硬件支持。实际表现以呈现帧率和观看结果为准。
- **苹果超分。** 在受支持的 macOS 26+ 设备上选择苹果实时超分或视频超分。较大画面可能先缩小再处理；实时采集使用苹果视频超分时需先关闭补帧。
- **常用设置随时切换。** 保存游戏、电影、动画等配置；窗口和显示器模式的输出跟随来源，视频文件可在指定显示器全屏。
- **也能播放本地视频。** 支持 MKV、MP4、MOV、WebM 等常见格式，提供字幕、兼容显示器上的 HDR 播放、断点续播、
  变速，以及 Finder 空格键快速预览。
- **本机生成字幕。** 在支持的 macOS 上生成、翻译并导出文本字幕；首次使用时系统可能需要下载语言模型。
- **隐私优先。** 无账号、广告或播放统计，详见 [隐私政策](PRIVACY.md)。

播放器提供 17 种界面语言，画质工作台支持中文和英文。实验后端与具体条件见 [功能说明](docs/features.md)。

<p align="center"><img src="Website/assets/openduckframe-library-v2.webp" alt="OpenDuckFrame v0.1.0 在 Mac 上的技术库实机界面" width="900"></p>
<p align="center"><sub>v0.1.0 旧版界面。当前技术库提供 ODF-VFI 和两种苹果插帧选项。</sub></p>

## 开始使用

下载 [Mac 安装包](https://github.com/Jun-bao/OpenDuckFrame/releases/latest/download/OpenDuckFrame.dmg)，
或查看 [版本列表](https://github.com/Jun-bao/OpenDuckFrame/releases)。
社区安装包使用临时签名，**未经过 Apple 公证**，首次打开可能被 macOS 拦截。
确认信任来源后，由你在系统设置 → 隐私与安全性中决定是否允许打开。
由于社区版使用临时签名，升级后可能需要重新授予屏幕录制或辅助功能权限。
需要 Apple 芯片和 macOS 14 或更高版本。

应用会检查经过更新签名的版本，并由你选择安装时间。也可以使用 **OpenDuckFrame → 检查更新**，
或在同一菜单关闭自动检查。更新不会上传你的媒体内容。

1. 打开 **文件 → 画质工作台**（⇧⌘E）。
2. 选择窗口、显示器或视频文件作为输入。采集窗口或显示器时，按 macOS 提示授予屏幕录制权限。
3. 选择补帧、超分或同时开启。窗口模式点击 **延迟增强**，在倒计时结束前切到要增强的窗口，
   届时会自动选定该窗口并开始增强；倒计时默认 3 秒，可在工作台 **设置** 中改为 1–20 秒。
   显示器和视频文件点击 **开始增强**。
4. 观看增强画面，并通过帧率显示查看实际输出帧率。

权限、常见设置和排查方法见 [快速上手](docs/quick-start.md)。

## 系统要求

| 能力 | 要求 |
|---|---|
| 应用与本地播放 | Apple 芯片 Mac，macOS 14 或更高版本 |
| 窗口 / 显示器采集 | 屏幕录制权限；受保护内容可能无法采集 |
| Apple 低延迟插帧 | macOS 26+ 及运行时支持；实时窗口 X2/X4，文件 X2 |
| Apple 帧率转换 | macOS 15.4+ 及运行时支持；偏向画质，速度与延迟因设备而异 |
| 苹果超分 | macOS 26+ 和支持的 Mac；尺寸与倍率以设备支持为准；视频超分可能需要下载苹果模型 |
| ODF-VFI 补帧 | Apple 芯片；实际速度取决于分辨率、质量和显示器刷新率 |
| 字幕生成与翻译 | macOS 26+，以及可用的系统语言模型 |
| 实验性动画后端 | 额外模型与运行库，见 [功能说明](docs/features.md) |

目前不支持 Intel Mac、Windows、iPhone 或 iPad。倍率代表请求的处理模式，实际显示帧率需要以运行结果为准。

Apple 低延迟在窗口／显示器模式下会按设备支持的尺寸处理，再将生成帧恢复到来源尺寸；工作台显示实际处理尺寸。缩小处理尺寸可能使生成帧的细节变软，文件输入仍保留原有尺寸要求。
实时增强还会在时间与内存上限内预留至少 80 毫秒自适应缓冲，并在有限延迟内按顺序呈现有效帧，以部分操作响应速度换取更稳定的输出；这不保证达到 60 FPS。
0.5.0 为苹果低延迟实时增强增加可选的“自动视频”：估计常见 24／25／30 FPS 并整理播放时间轴，申请更多缓冲（140 毫秒，受上限约束）。默认仍为“通用窗口”。声音由原应用播放，可能感知到音画偏移。

Fast X2 窗口优化按 GPU 能力、内存上限和准备时的实测耗时判断，不再使用设备型号白名单。准备预算充足时保留原尺寸，否则缩小生成帧的处理尺寸；准备耗时不能代替持续帧率实测。

本地视频插帧赶不上播放时，会保留原画并丢弃迟到的合成结果，避免等待模型拖慢原片；这不代表算力不足时仍能达到所选倍率。

## 从源码构建

需要 Apple 芯片 Mac、带 macOS 26.4 或更高 SDK 的 Xcode、Python 3，以及以下构建工具：

```sh
brew install xcodegen meson ninja cmake pkg-config
git clone https://github.com/Jun-bao/OpenDuckFrame.git
cd OpenDuckFrame
./Apps/Mac/Scripts/build.sh Debug
open .build/Build/Products/Debug/OpenDuckFrame.app
```

构建优化版本：

```sh
./Apps/Mac/Scripts/build.sh Release
```

首次构建会获取固定版本的依赖、生成 Xcode 工程、打包运行库并检查应用。Debug 产物在 `.build/` 下；
Release 还会在仓库根目录生成供本机使用的 `OpenDuckFrame.app`。本地构建采用临时签名，
Developer ID 签名、公证与 App Store 打包使用独立的 [发行流程](RELEASING.md)。

生成工程前会从固定提交的源码包准备 RifeMetal，并应用本仓的流式输入输出优化补丁。
来源、许可与生成目录见 [运行库构建说明](ThirdParty/rife-metal/README.md)。

修改工程配置请编辑 [`Apps/Mac/project.yml`](Apps/Mac/project.yml)。默认构建不构建额外的实验运行库，
相关条件见 [功能说明](docs/features.md#optional-runtimes)。

## 仓库结构

```text
Apps/Mac/          原生界面、实时采集、资源、Quick Look 与构建定义
Modules/           媒体播放、画质增强与字幕源码
Platform/macOS/    Mac 渲染与音频实现
Scripts/           构建、检查、本地化与发行工具
ThirdParty/        依赖版本锁、部分第三方源码与许可声明
Design/            应用图标源文件与可复现导出
Website/           早期静态页与 README 配图；openduckframe.cn 官网另行维护
docs/              上手、功能与项目说明
```

编译关系见 [REPOSITORY_LAYOUT.md](REPOSITORY_LAYOUT.md)。生成工程、应用包、依赖构建产物、
私钥、本机日志与测试媒体不进入 Git。

## 交流与参与

故障和功能建议请提交 [Issue](https://github.com/Jun-bao/OpenDuckFrame/issues)，
使用问题和配置分享可前往 [Discussions](https://github.com/Jun-bao/OpenDuckFrame/discussions)。
反馈时附上应用版本、macOS 版本、Mac 型号、来源分辨率、引擎和实际输出帧率；不要直接上传私人画面或未经检查的诊断日志。

开发约定见 [CONTRIBUTING.md](CONTRIBUTING.md)，安全问题的私下反馈方式见 [SECURITY.md](SECURITY.md)，
版本记录见 [CHANGELOG.md](CHANGELOG.md)。

## 许可证与致谢

OpenDuckFrame 自有代码采用 [MIT 许可证](LICENSE)，基于
[Khua Player](https://github.com/nake13/khuaplayer) 开发并保留原作者版权声明。
FFmpeg、RIFE、模型权重等组件各自保留其许可证，见 [第三方声明](THIRD_PARTY_NOTICES.md)。
名称和图标的使用说明见 [TRADEMARK.md](TRADEMARK.md)。
