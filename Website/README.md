# OpenDuckFrame 官网

OpenDuckFrame（开源小鸭）的静态产品页，介绍 Mac 实时补帧、超分和本地播放。

产品源码、构建说明、隐私政策和反馈入口：
[super-individual-ai/OpenDuckFrame](https://github.com/super-individual-ai/OpenDuckFrame)。

## 本地预览

直接用浏览器打开 `index.html`，无需安装依赖或构建。也可以运行：

```sh
python3 -m http.server 4178 --bind 127.0.0.1
```

然后访问 `http://127.0.0.1:4178`。

## 内容与资源

- `index.html`：页面结构与默认中文内容。
- `main.js`：品牌配置、中英文文案、主题切换和补帧原理示意动画。
- `styles.css`：桌面与移动端样式。
- `assets/openduckframe-icon.png`：成品应用图标。
- `assets/openduckframe-library.webp`：v0.1.0 应用技术库实机截图。

首页按钮指向公开仓库的源码构建指南；打包下载单独链接至 Releases。
补帧动画标明为原理示意，不代表实测帧率。系统要求和功能范围以产品源码与公开说明为准。
