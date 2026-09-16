# CC-CloudMusicNCM

一个运行在 **CC:Tweaked**(ComputerCraft) 高级电脑上的网易云音乐客户端。
界面使用 [Basalt](https://github.com/Pyroxenium/Basalt2) 搭建，中文通过
`Lib/utf8display.lua` 渲染成点阵图后由 Basalt 绘制；所有数据来自本地
**`ncm`** 库(`require("ncm")`，安装在 `/ncm`),不经过任何自建远程代理。

> 这是与本仓库同作者的另一个项目 `netease-ncm-lua`(纯 Lua 网易云 API
> 移植 + 命令行客户端)配套的图形界面。本仓库只包含 UI 客户端本身。

---

## 功能

- **中文界面**:导航栏 推荐/发现/漫游/播客/喜欢/收藏/最近,搜索、播放栏、
  弹窗等均使用 `Lib/utf8display.lua` 的 `strToBimg` 渲染中文。
- **扫码登录**:调用 `ncm.login_qr_key` / `login_qr_create` /
  `login_qr_check`,把登录 URL 用 CC 字体的 3x2 子像素点阵画进登录浮层;
  登录成功后把 cookie 写入 `/ncm_cookie`,下次启动自动读取。
- **搜索播放**:输入关键字搜索单曲,结果列表可直接点击播放。
- **内容页**:推荐歌单、排行榜、每日推荐、我的歌单、我喜欢的音乐、最近播放。
  点击歌单进入其歌曲列表,支持返回。
- **播放**:解析歌曲直链(`ncm.song_url_v1`)后交给
  `/ncm/lib/speaker.lua` 播放(speaker 程序请求其转码服务得到 DFPWM,
  电脑 CPU 占用极低)。
- **最近播放**:本地记录(`/ccncm_recent`)。

## 前置条件

1. Minecraft + **CC:Tweaked** 模组。
2. **高级电脑(Advanced Computer)** 且 **启用 HTTP**(`http` API 可用)。
3. **`ncm` 库安装在 `/ncm`**:用 `netease-ncm-lua` 仓库的 `install.lua`
   在电脑上安装。安装后应能看到 `/ncm/init.lua`、`/ncm/lib.lua`、
   `/ncm/lib/speaker.lua`、`/ncm/lib/cc_big_http.lua`、`/ncm/lib/aeslua/`。
4. **一个扬声器**外设(`peripheral.find("speaker")` 能找到)。
5. speaker 程序的**转码服务可达**(默认 `http://newgmapi.liulikeji.cn/api/ffmpeg`,
   可在 speaker 程序里用 `-server` 改;本客户端只通过启动 speaker 间接使用它,
   数据路径本身不依赖任何远程代理)。
6. 能访问 `music.163.com`(由 `ncm` 发起),以及能访问
   `Lib/utf8display.lua` 里配置的字体 URL;或者准备一个本地字体(见下)。

## 安装

### 一键安装(install.lua)

本仓库自带 `install.lua`,可以直接在电脑上下载并解压到 `/ccncm`:

```
wget run https://cdn.jsdelivr.net/gh/colorgarden/CC-CloudMusicNCM@main/install.lua
```

运行后**先选择下载源**:

```
Choose a download source:
  1) jsDelivr (recommended)
  2) GitHub raw
  3) ghproxy.net (GitHub proxy)
  4) Custom URL
Select [1]:
```

- 直接回车、或输入无法识别的值时,默认使用 **1(jsDelivr)**,不会报错;
  输入 1..3 选择对应镜像。
- 输入 **4** 会再要求输入一个基础 URL(即包含 `dist/ccncm.tar` 的目录)。
- 安装器会**先**从选定的源下载;该源不可用或下载的包不完整时,自动依次回退到
  其它已知镜像。每次尝试都会打印所用的基础 URL,发生回退时会多打印一行提示。
  下载后会校验包里是否有 `ccncm/startup.lua`、`Lib/basalt.lua`、
  `Lib/utf8display.lua`、`icons/Home.lua`,只有校验通过才算成功。
- 若电脑上还没有 `ncm` 库(`/ncm/init.lua` 不存在),安装器会先用 `[y/N]`
  询问是否通过 ghproxy 镜像下载并运行 `netease-ncm-lua` 的安装器,装好后继续。

如果要固定下载源(例如脚本化/无人值守安装),把基础 URL 作为**第一个参数**
传入即可**跳过菜单**:

```
wget run <上面的 install.lua URL> https://my.mirror/ccncm
```

### 手动安装

1. 按 `netease-ncm-lua` 的说明在电脑上装好 `ncm`(会落到 `/ncm`)。
2. 把**整个本项目目录**拷到电脑上。`Lib/`、`icons/`、`ccncm/` 必须与
   `startup.lua` 同级——因为 `require("Lib.basalt")`、`require("icons.Home")`
   是**相对于正在运行的程序的目录**解析的。
   例如拷到 `/CCNCM/`,则应有 `/CCNCM/startup.lua`、`/CCNCM/Lib/basalt.lua`…
3. 若要开机自启,把项目放在电脑根目录(使 `/startup.lua` 存在);放在子目录
   时需手动运行(见下)。

> 拷贝方式随你:游戏内存盘、`pastebin`、HTTP 下载、直接放进存档的
> `computercraft/computer/<id>/` 目录等均可。

### 可选:本地字体

默认字体是 `Lib/utf8display.lua` 里的远程 URL,首次使用时下载,**只在内存中
缓存**,每次开机都会重新下载。若想离线/加速,把该字体 Lua 文件存成
电脑根目录的 `/ccncm_font.lua`;客户端会优先加载它。

## 运行

在项目的父目录执行(假设项目在 `/CCNCM`):

```
CCNCM/startup
```

若项目就在电脑根目录,开机后会自动运行 `/startup`(即 `startup.lua`)。

界面使用**电脑自身的终端**,不需要显示器(monitor)。

## 目录结构

```
startup.lua          入口:加载 ccncm.app,失败时打印 ASCII 错误
ccncm/
  app.lua            Basalt 界面与交互(布局、页面、登录浮层、播放)
  data.lua           数据层:所有 ncm 调用、cookie、播放器启动
  bimg.lua           utf8display 位图小工具(ProcessStrToBimg / ConcatBimg)
  qr.lua             用 qr.encode 的矩阵生成 Basalt 位图(3x2 子像素打包)
  strings.lua        中文界面文案(以十进制字节转义保存,源码保持 ASCII)
Lib/
  basalt.lua         第三方 UI 框架
  utf8display.lua    中文点阵渲染
  json.lua           第三方 JSON 库(rxi)
icons/*.lua          图标位图
```

## 数据与文件

| 路径            | 用途                                   |
|-----------------|----------------------------------------|
| `/ncm_cookie`   | 登录 cookie(与 `ncm/cli` 同一约定)   |
| `/ccncm_recent` | 最近播放列表(CC `textutils.serialize`) |
| `/ccncm_font.lua` | 可选本地字体(存在则优先使用)        |

## 已知限制

- **播放会阻塞界面**:按题目约定,歌曲链接交给
  `shell.run("/ncm/lib/speaker.lua", url, "-id", "ccncm")`。speaker 程序会
  接管终端并同步播放到结束,期间 Basalt 界面不刷新;播放结束后界面会重绘。
  没有应用内的暂停/继续/进度/音量控制(speaker 决定)。
- **只支持单曲搜索**(`type=1`),没有专辑/歌手/MV 搜索。
- **喜欢/收藏只读**:可以浏览“我喜欢的音乐”和“我的歌单”,不能在客户端里
  加/取消喜欢或编辑歌单。
- **需要登录的页面**(喜欢/收藏)在未登录时只弹出“需要登录”提示;漫游
  (每日推荐)匿名也可用。
- **播客页目前是占位**,仅提示“暂未实现”。
- **无损音质可能因账号权限失败**:客户端先请求 `lossless`,失败后自动回退到
  `standard`;若仍无直链(版权/地区/会员),会弹出错误。
- **布局按 51x19 及以上终端**设计;窗口过小会显得拥挤(列表可滚动)。
  目前只在电脑自身终端渲染,不驱动 monitor。
- **字体每次开机重新下载**(除非放置 `/ccncm_font.lua`)。
- **“最近播放”是本地记录**,不是网易云的云端播放历史。
- 源码文件(`.lua`)保持 **ASCII**:所有中文界面文案以 `\ddd` 十进制字节
  转义写在 `ccncm/strings.lua` 中,运行时再还原成 UTF-8。

## 开发/验证

在开发机上用 CraftOS-PC 无头模式做了加载与数据联调(项目内的 `ccncm/*.lua`
全部通过 `luac -p`)。示例命令(把项目与 `ncm` 放进某个 CraftOS 数据目录的
`computer/0/` 后):

```
cd /path/to/craftos2
timeout -k 5 120 env SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy \
  ./craftos --headless --rom /path/to/rom/assets/lua -d /path/to/data \
  -o keepOpenOnShutdown=false -o http_enable=true -o http_timeout=8000 \
  --exec "shell.run('/boot_test.lua')" < /dev/null
```

已实测通过:`search`、`login_qr_key`、`login_qr_create`、`login_qr_check(801)`、
`personalized`、`toplist`、`playlist_track_all`、`song_url_v1` 均返回正常,
登录二维码渲染为 18x12 单元格并可在 51x19 终端放下。真机“扫码 803 → 保存
cookie → 播放”这段依赖手机扫码和扬声器/转码服务,未在纯 Headless 环境下
端到端跑通。

## 许可与第三方归属

- 本仓库整体以 **GPL-2.0** 发布,见 `LICENSE`。
- **Basalt**(`Lib/basalt.lua`,压缩版):MIT License,作者
  [Pyroxenium](https://github.com/Pyroxenium/Basalt2)。本仓库内文件为压缩
  产物,未保留头部声明;上游许可为 MIT。
- **`Lib/utf8display.lua`**:来自 xingluo 的 ComputerCraft-Utf8 项目
  (默认字体 URL 指向 `git.liulikeji.cn/xingluo/ComputerCraft-Utf8`),
  文件头部未声明许可证。
- **`Lib/json.lua`**:[rxi/json.lua](https://github.com/rxi/json.lua),
  MIT License,完整文本见 `Lib/json.lua.LICENSE`。
- **`ccncm/qr.lua` 的 3x2 子像素打包算法**:改写自 `ncm.util.qrcode.printCC`
  (GPL-2.0),其来源注明为 GMapiServer 的 `qr_bimg_utils.py`;二维码本身的
  编码由 `ncm.util.qrcode.encode` 完成,本项目未自行实现编码器。
- **`icons/*.lua`**:本项目自带的图标资源。

---

## 依赖与许可

本仓库以 **GPL-2.0** 发布(见 LICENSE)。

| 组件 | 用途 | 许可 | 说明 |
|---|---|---|---|
| [Basalt](https://github.com/Pyroxenium/Basalt2) | UI 框架(`Lib/basalt.lua`) | **GPL-2.0** | 第三方,未改动;与本项目同协议,兼容 |
| [ComputerCraft-Utf8](https://git.liulikeji.cn/xingluo/ComputerCraft-Utf8) | 中文像素渲染(Lib/utf8display.lua,含字体管理器) | **上游未声明任何许可证** | 仓库无 LICENSE 文件、README 无声明;按现状使用并署名 |
| [fusion-pixel-font](https://github.com/TakWolf/fusion-pixel-font) | 像素字体(中/日/韩/拉丁,8px 与 12px) | **SIL Open Font License 1.1 (OFL-1.1)** | 来自 ComputerCraft-Utf8 的 fonts/;OFL 要求署名并随附许可声明 |
| [rxi/json.lua](https://github.com/rxi/json.lua) | JSON 编解码(Lib/json.lua) | MIT (c) 2020 rxi | 见 Lib/json.lua.LICENSE |
| `icons/*.lua` | 图标点阵(31 个) | **GPL-2.0** | **并非本项目自绘**:来自参考客户端(与 ComputerCraft-Utf8 / liulikeji 项目同源) |

### 字体依赖(重要)

单个字体文件 **1.68 MB(8px)/ 4.04 MB(12px)**,**超过 CC 电脑 1 MB 的磁盘上限**,因此
Lib/utf8display.lua 默认**从网络加载字体**(默认即上游 fonts/fusion-pixel-8px-proportional-zh_hans.lua)。
后果:

- 服务器白名单必须放行字体所在主机(默认 git.liulikeji.cn),否则中文全部显示为占位符;
- 加载一份 8px 字体约占用 **6 MB 内存**,12px 约 **10.5 MB**(上游 README 数据);
- 无法用"字体子集化"绕开:界面固定文案可以子集化,但**搜索结果的歌名是任意中文**,必须完整 CJK 字形表。
