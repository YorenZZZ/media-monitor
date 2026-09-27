# Media Monitor

[English](README.en.md) · 中文

一个 macOS 菜单栏小工具，把正在播放的音乐、视频和直播集中到一个面板里：看播放状态、进度，并直接暂停或继续。

<p>
  <img src="docs/main-light.png" width="300" alt="主面板（浅色）">
  <img src="docs/main-dark.png" width="300" alt="主面板（深色）">
</p>

## 支持的播放器

| 来源 | 显示内容 | 可以做的操作 |
| --- | --- | --- |
| 汽水音乐 | 歌名、歌手、封面、进度 | 播放/暂停、上一首/下一首、拖动进度 |
| 哔哩哔哩、LX Music、IINA（桌面客户端） | 系统「正在播放」提供的标题和进度 | 播放/暂停、拖动进度等（视客户端支持而定） |
| 抖音（桌面客户端） | 是否在播放 | 播放/暂停 |
| 虎牙直播（桌面客户端） | 直播间标题、主播、是否有声音 | 点击会切到客户端（该客户端不接受外部控制） |
| Chrome 里的哔哩哔哩、虎牙、抖音网页 | 标题、进度、直播状态 | 播放/暂停、拖动进度、快进/快退 10 秒、切到对应标签页 |

多个来源同时播放时，最近开始播放的会显示在最上面，其余列在「其他会话」里。

## 系统要求

- macOS 14.2 或更高版本，Apple 芯片（M 系列）
- 从源码构建需要 Xcode 命令行工具（`xcode-select --install`），不需要完整的 Xcode
- 网页播放需要 Google Chrome

## 安装

```bash
git clone https://github.com/YorenZZZ/media-monitor.git
cd media-monitor
./build.sh --install
```

`build.sh` 会把 App 构建到 `outputs/Media Monitor.app`；加上 `--install` 会复制到「应用程序」文件夹并启动。启动后菜单栏会出现一个图标，点击即可打开面板。

### 首次使用时的系统授权

- **辅助功能**：读取和控制汽水音乐、读取虎牙直播间标题需要。面板顶部会出现提示，点「去授权」后在 系统设置 › 隐私与安全性 › 辅助功能 里打开 Media Monitor。
- **录制系统音频**：只用于判断虎牙直播客户端当前有没有声音，不会录制或保存任何音频。
- **自动化**：控制部分播放器时 macOS 可能会询问一次，选「允许」。

## 安装 Chrome 扩展（网页播放）

Chrome 不允许其他程序直接安装扩展，所以需要你手动完成最后一步：

1. 点击菜单栏图标，再点右上角的齿轮进入「设置」。
2. 在「Chrome 扩展」一栏点 **安装**。
   - 如果没检测到 Chrome，会提示「请先安装该浏览器」。
   - 检测到的话，会打开 Chrome 的扩展页 `chrome://extensions`，并在访达中选中扩展文件夹。
3. 在扩展页右上角打开 **开发者模式**。
4. 把访达里选中的 `ChromeExtension` 文件夹拖进扩展页。

几秒后设置页会显示「Chrome 扩展已安装」。已经打开的标签页会被自动识别，不需要刷新。

<img src="docs/settings-light.png" width="300" alt="设置页">

扩展文件放在 `~/Library/Application Support/Media Monitor/ChromeExtension`。以后更新 App 时会自动同步新版本，重启 Chrome 后生效。

## 隐私

- 所有数据只在本机处理，不上传任何内容。唯一的网络请求是：播放器提供的封面是网络图片时，从该地址下载封面来显示。
- Chrome 扩展只把网页标题、网站域名、时长、当前进度和播放状态通过 Chrome 本地通信（Native Messaging）发给本机的 Media Monitor。
- 虎牙客户端的声音只用来计算实时音量，不会录制或保存。

## 卸载

1. 退出 Media Monitor（面板右下角「退出」），把「应用程序」里的 Media Monitor 移到废纸篓。
2. 在 `chrome://extensions` 里移除「Media Monitor Browser Bridge」。
3. 可选：删除 `~/Library/Application Support/Media Monitor` 和 `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/io.github.yorenzzz.media_monitor.json`。

## 项目结构

| 路径 | 内容 |
| --- | --- |
| `Sources/` | App 本体（Swift / SwiftUI） |
| `Helper/NowPlayingHelper.m` | 读取系统「正在播放」信息的辅助库 |
| `ChromeExtension/` | Chrome 扩展，构建时打包进 App |
| `Tools/` | 构建时生成 App 图标 |
| `build.sh` | 构建脚本 |

## 许可证

[MIT](LICENSE)
