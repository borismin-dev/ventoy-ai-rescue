# WinPE 三家资产盘点（FirPE / HotPE / 微PE）

盘点时间：2026-11-08。方法：官方渠道下载原包，在 InstaBox main-1 上用 7z / wimlib 解开逐项清点；
环境项（PowerShell / .NET / 脚本宿主）以 WIM 文件清单实查为准，不是看宣传页。

## 取得方式与校验

| PE | 版本 | 官方渠道 | 产物 | 大小 | SHA-256 |
|---|---|---|---|---|---|
| HotPE | V2.8.251018 | hotpe.top 官方 CDN（p0.hotpe.top） | HotPE-V2.8.251018.iso | 1,109,088,256 | `2d8de0efde0017d60374da9310125d76085d87aad5a2300701949afb18a73ad4` |
| 微PE | V2.3（64 位，2023-06-22） | wepe.com.cn 下载页列出的高校镜像（兰州大学 mirrors.lzu.edu.cn） | WePE_64_V2.3.exe（NSIS 自解压） | 238,591,028 | `8c847f0dc0f40918d861b0d9e7faf63b2d9a8b8bc524c8114a21438d0235a34a` |
| FirPE | V1.9.3 | 官方 GitHub 仓库 luyuanbo79/firpe 的 Release | FirPE-V1.9.3.exe | 1,244,006,424 | `58204a87caf74282a11f42a6e57c601638a497f58d751727c7f1db6d8e160c15` |

踩过的坑（如实记录）：
- 微PE 山东大学镜像（mirrors.sdu.edu.cn）对脚本下载返回长亭 WAF 的 JS 挑战页（14,863 字节 HTML），
  换兰州大学镜像后一次成功。官网自带下载同样先落到 WAF 页。
- FirPE 官网 firpe.cn/page-247 有 JS Cookie 校验，页面列出的分发渠道是星辰云盘（Cloudreve，需 JS 会话）、
  天翼云盘、移动云盘、SharePoint 直链代理等网盘方式；早先按 V1.9.2 尝试时只拿到云盘落地页 HTML。
  最终走通的是官方 GitHub Release 直链（V1.9.3）。
- FirPE 的 exe 是官方写入器程序本体，**不是自解压包**：7z 报 "Cannot open the file as archive"，在 Linux 上无法解包盘点；
  按官方文档（docs.firpe.cn）FAQ，ISO 由写入程序在 Windows 下点「生成 ISO」产生。因此 FirPE 一节只有官方文档口径，标注未实测。

## HotPE V2.8.251018（实测盘点）

- 结构：ISO（UDF Bridge）根目录含 `HotPE/Boot.wim`（670,543,552 字节，WIM 内 6,145 个文件）、
  `HotPE/Data/Drives/Network.7z`（257,743,745 字节，网卡驱动包）+ `Network.index`（DrvIndex 索引）、
  `HotProgMods/*.HPM` 模块目录、标准 Boot/EFI 启动文件。ISO 内还自带 ventoy.dat（官方即考虑 Ventoy 场景）。
- 外置模块（HotProgMods，PreInstall）：浏览器、DiskGenius 6.0.1.1645、Dism++ 10.1.1002.1、
  PartAssist（傲梅分区助手）10.7、WinNTSetup 5.4.1.0、NTPWEDIT 2.1.0.6357、NT6Bootfix、WIT、MoreTools。
- WIM 内置：7-Zip、Edgeless 插件系统（Program Files\Edgeless，含 plugin_loader 与 PECMD.EXE）、
  Drives 安装器（DrvIndex.exe、SRS.7z 存储驱动包）、StartAllBack 等。
- 启动链：`Windows\Pecmd.ini` + Pecmd.exe 驱动（WIM 内无 winpeshl.ini / startnet.cmd）；
  ISO 上的 `HotPE\HotPE.INI` 会在初始化时 `FORX !\PETools\PETools.INI ... LOAD`——
  即从任意盘符根目录加载 `\PETools\PETools.INI`，这是 HotPE 官方留的外置自启扩展点。
  融合版最终未走这条（拼接法不能往 ISO 侧加文件，见文末），改用 WIM 内 Pecmd.ini 末尾追加一行。
- 环境实测（WIM 清单）：
  - **PowerShell：有**（Windows\System32\WindowsPowerShell\v1.0\powershell.exe）。
  - **.NET：有**（Windows\Microsoft.NET\assembly GAC，含 System.Runtime v4.0）。
  - wpeinit.exe 在位；脚本宿主方面 PECMD 是主通道，cmd 可用。

## 微PE V2.3 64 位（实测盘点）

- 结构：NSIS 安装包解开后直接是 PE 文件系统（Windows / Program Files / Users），无单独外置工具盘；
  工具全部内置在 WIM 映像内。
- Program Files 工具：7-zip、DiskGenius、Dism++、Everything、GhostCGI、WinNTSetup、Wimtool、
  PAProCn（傲梅分区助手专业版）、Memtest、Snapshot、RunScanner、Imagine、Freewb、FixLegacyUefi、
  Orderdrv、WepeGuide，另有自带 `PETools.ini`（其外置工具配置）。
- 启动链：`Windows\Pecmd.ini`（PECMD 驱动）；未发现 winpeshl.ini / startnet.cmd。
- 环境实测（文件系统清点）：
  - **PowerShell：无**（无 powershell.exe）。
  - **.NET：无**（无 Windows\Microsoft.NET 目录）。
  - **cscript.exe：未发现**（WSH 基本被精简，脚本能力以 PECMD/批处理为主）。
  - 网卡/存储驱动：以 Windows INF 内置集 + VMD 等补丁驱动为主（见其 2.3 更新说明），无独立大驱动包。

## FirPE V1.9.3（官方文档口径，未实测）

- 官方定位：Win11PE + Win03PE 双内核（V1.9.x 为兼容线，Win11 23H2 内核），U盘三分区方案，
  写入程序可生成 ISO。工具集与集成方式以 docs.firpe.cn 为准。
- 因安装包不可在 Linux 解包（见上），其 PowerShell / .NET / 驱动构成**未做文件级核实**，不下结论。
- 融合影响：FirPE 的工具未能文件级并入融合版（原因同上），融合版的第三方工具来源为 HotPE + 微PE 两家。

## 环境对照（与立项假设的核对）

立项时的口径是「三家网络通、带网卡驱动、没有 PowerShell 和 .NET、跑脚本不确定」，逐项核对结果：

| 项 | HotPE | 微PE | FirPE |
|---|---|---|---|
| 联网/网卡驱动 | 有独立大驱动包 Network.7z（257MB）+ DrvIndex | 内置 INF 集，无独立驱动包 | 未核实 |
| PowerShell | **有**（假设不成立） | 无（假设成立） | 未核实 |
| .NET | **有**（假设不成立） | 无（假设成立） | 未核实 |
| 脚本 | PECMD + cmd + PowerShell | PECMD + cmd | 未核实 |

结论：ai-rescue 的 Windows 版走 Go 静态单文件 exe 是对的——在微PE 里没有 PowerShell/.NET 可依赖，
在 HotPE 里虽有也不必依赖；同一 exe 两家通吃，只依赖 Win32 本身。

## Linux 侧等价补齐（AI-Rescue-PE 对照）

融合方向是「以新编译 PE 为本体」：Linux 版 AI-Rescue-PE 按品类对齐三家的工具面——
分区/磁盘：parted、gparted、testdisk、photorec（DiskGenius/分区助手类）；数据恢复：gddrescue、photorec；
镜像/部署：rsync、chntpw（NTPWEDIT 类）、smartmontools；网络：iproute2、openssh、curl/wget；
诊断：ai-debug 规则引擎 + LLM。网卡覆盖靠 Debian 内核全量驱动 + firmware-linux-free，
与 WinPE 的驱动包路线不同，但对常见有线网卡（含 QEMU e1000）开箱可用（已实测）。

## 融合版构成（HotPE 为基座）

选 HotPE 为基座的理由：三家中只有它同时具备完整外置模块系统、独立网卡驱动大包、PowerShell 与 .NET，
且留有官方 PETools 自启扩展点，改动面最小。

并入内容（全部在 Boot.wim 内部，原因见文末打包方法）：
- `ai-rescue.exe`（Go 静态编译，零依赖）注入 Boot.wim 的 `\Windows\System32\`；
- agent 自启：往 WIM 内 `\Windows\Pecmd.ini` **末尾追加一行**
  `EXEC !cmd /c start /min X:\Windows\System32\ai-rescue.exe agent`
  （该位置在网络初始化与外置 INI 加载之后，agent 起来时网已通）；
- 微PE 便携工具文件级并入 WIM 内 `\ExtraTools\`：Everything、Wimtool
  （免安装、单目录可运行的才并；开机后位于 `X:\ExtraTools\`）。
  微PE 的便携版 Dism++ **未并**：HotPE 已内置 Dism++ 模块，重复并入只挤占尺寸预算。

未并入及原因（不假称已集成）：
- FirPE 全部工具：原包在 Linux 不可解包，无法做文件级并入。
- 微PE/HotPE 的驱动包与需注册表/服务注册的组件：文件拷贝不等于集成，这类需要 DISM/PECMD 级处理，
  本轮未做；HotPE 自带驱动包保持原样未动。
- 需 DISM 注册的驱动：无。

## 打包方法与实测史（2026-11-08，QEMU TCG 验证）

原版 HotPE ISO 是 UDF Bridge：ISO9660 树只有 README.TXT 存根，bootmgr 只能经 UDF 定位。
整盘重打包路线三连败，逐条如实记录：

1. **xorriso 重打包（ISO9660/Joliet）**：BIOS 引导报 `CDBOOT: Couldn't find BOOTMGR`
   （文件名改全大写、禁 boot-info-table 均无效）——cdboot 只认原盘的 UDF 结构。
2. **genisoimage `-udf` 重打包（v3）**：能过 CDBOOT 进入 bootmgr 的 Loading files，
   但 1500 s 内进度条反复回退（85%→78%→45%）、截屏哈希以约 1020 s 周期整帧重复，
   从未进入 winload。对照实验：**原版 ISO 在同一 QEMU 配置下约 302 s 即进入
   Windows 标志画面**，证明环境无罪、cdrkit 的 UDF 大文件 extent 实现是元凶
   （此判断经机内 `agy` 咨询印证，其给出的 UDF 机理与实测现象吻合）。
3. **拼接法 + 64K 分块（v4a）**：改走原位拼接（见下），但 WIM 重压缩时用了
   LZX chunk 65536——bootmgr 成功挂载 WIM、读 BCD，却在加载 winload.exe 时报
   **0xc0000098**。bootmgr 内置 LZX 解压只支持 chunk ≤32768（原版即 32768），
   64K 是本次失败根源（同样经 agy 咨询确认）。

最终方法（拼接法）：原版 Boot.wim 在 ISO 中为单段连续 extent（偏移 10600448、
长 670543552，区域 sha256 与文件 sha256 一致，已验）。融合 WIM（注入上述内容后
以 **LZX:100、chunk 32768** 全量重压缩）压到不超过原长、零填充至恰好等长，
dd 覆写 ISO 副本的该段；ISO 其余字节与原版逐位一致（头区/尾区哈希双验通过）。
WIM 尾部零填充无害：WIM 是头部偏移驱动格式，bootmgr 不依赖物理 EOF。

为塞进原长所做的实测瘦身（wimlib 的 LZX 产物比原版微软编码大约 1.2 MB，
且注入物本身要占约 6 MB，不瘦身必超）：ai-rescue.exe 改 strip 构建
（`-ldflags '-s -w'`，10,871,808 → 7,502,336 字节，WIM 内存储省约 2.9 MB，
两次构建仍逐位一致）；HotPE 的随机壁纸集（`Windows\Web\Wallpaper\HotPE`，
约 6 MB）只保留一张（Pecmd 的 LOGO 壁纸 `Windows\img0.jpg` 未动）；
微PE 便携 Dism++ 不并（理由如上）。最终融合 WIM 669,848,410 字节（余量 695,142）。
成品即以此法产出，QEMU 验证结论见仓库 README 与 `dist/MANIFEST.md`。
