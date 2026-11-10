# Ventoy + AI 维护 PE

一个可启动 U 盘方案：Ventoy 菜单里放两套救援环境，两边都内置同一个局域网 AI 维护
agent（`ai-rescue`），开机后自动在 8734 端口提供诊断/远程执行接口，凭每次开机随机
生成的令牌鉴权。

## 组成与来源（如实标注）

| 组件 | 来源 | 说明 |
|---|---|---|
| `Ventoy-AI-Rescue-USB.img` | Ventoy **官方发行版 1.1.18** 为基座 + 本项目两个 ISO 与菜单定制 | 可直接写 U 盘的整盘镜像（布局与 Ventoy2Disk 一致，用 mtools 填充）。另做过 Ventoy **源码编译**实验：源码能编译打包出 `ventoy-1.1.18-linux.tar.gz`，但用其载荷组装的镜像在 QEMU BIOS 启动时卡在 SeaBIOS "Booting from Hard Disk..."（扇区内容与打包产物逐字节一致、引导链就是不往下走），未通过启动验证，**交付镜像不用它**；官方基座版同配置约 60 s 进菜单。官方载荷的 EFI 二进制带签名，Secure Boot 兼容性以官方为准 |
| `AI-Rescue-PE.iso` | **本项目自建** | Debian 13 Live 救援系统（rescue-agent + ai-debug），**不是微软 WinPE**，只是借用 PE 这个形态名。构建脚本 `build/build-pe.sh` |
| `HotPE-Fusion-AIRescue.iso` | HotPE V2.8.251018（第三方免费软件）为基座的融合版 | 见下节。**只存于构建机，绝不上传 GitHub/CI**（含第三方免费软件，仅个人 U 盘自用） |
| `ai-rescue.exe` | 本项目 Go 源码静态编译 | Windows 版 agent，PE32+ x86-64 单文件（strip 构建 `-ldflags '-s -w'`，7,502,336 字节）；已验证可复现构建（两次构建逐位一致，sha256 `bb18289ddc3b24464f8e06f9ee35732b2cddcd798ca06fb79d49e9d1143a680c`） |

### 融合版 WinPE 的做法（拼接法）

以 HotPE 为基座（其实测带 PowerShell 与 .NET，工具模块最全），并入：

- `ai-rescue.exe` → WIM 内 `\Windows\System32\`
- agent 自启：追加到 HotPE 自身的 `\Windows\Pecmd.ini` 末尾一行
  （网络初始化之后执行 `ai-rescue.exe agent`）
- 微PE 的便携工具（文件级并入，无注册表/驱动级集成）→ WIM 内 `\ExtraTools\`
  （Everything、Wimtool；微PE 的便携版 Dism++ 未并，因 HotPE 已内置 Dism++ 模块）
- 为塞进原版 WIM 的尺寸上限，融合版还做了两处实测瘦身：ai-rescue.exe 用 strip
  构建；HotPE 随机壁纸集只保留一张（LOGO 壁纸未动）。细节见 `docs/winpe-assets.md`
- FirPE：其发行物是写盘程序、ISO 需在 Windows 上运行生成，Linux 构建机无法解出
  其 PE 文件系统，故**未并入**，资产盘点仅据官方文档（见 `docs/winpe-assets.md`）

打包不用整盘重打包：原版 HotPE ISO 是 UDF Bridge（ISO9660 树只有 README 存根），
实测 xorriso 重打包会 CDBOOT 找不到 BOOTMGR、genisoimage 的 `-udf` 重打包会让
bootmgr 卡在 Loading files 循环（cdrkit 的 UDF 大文件 extent 实现有缺陷）。
最终采用**原位拼接**：原版 Boot.wim 在 ISO 中是单段连续 extent（偏移 10600448，
长 670543552），把融合 WIM 全量重压缩（LZX/64K）到不超过原长、零填充到恰好等长
后 dd 覆写该段——ISO 其余字节与原版逐位一致（头/尾区域哈希已验）。脚本见
`build/fusion-build.sh`。

## 验证结果（QEMU TCG 纯模拟，无 KVM）

- Linux PE 直启：登录提示、rescue/rescue 登录、shell、`ai-debug diagnose` 退出码 0
  ——全部通过（`logs/machine/qemu-pe-report.txt` 等）。
- Linux PE agent：开机横幅令牌 → `GET /health` 200、`/info` 200、`/diagnose` 200
  （4792 字节报告）、`POST /exec` 正常、无令牌访问 `/diagnose` 返回 401、
  以开机令牌 SSH 登录成功。
- 原版 HotPE ISO 对照启动：约 302 s 进入 Windows 标志画面（证明测试环境本身正常，
  融合版 v3 的失败确系重打包问题）。
- 融合版 v4（拼接法）：QEMU 进 HotPE 桌面、agent 自启 /health 200、/info 无令牌
  401；抽验 Everything、WimTool 可打开，`ai-rescue.exe diagnose` 在 PE 内出完整
  报告（`logs/machine/qemu-fusion-diag.log`、`tools-check.log`）。
  注：TCG 下须给 QEMU 加 `-cpu max`，默认 qemu64 模型会让 Win11 内核在标志画面后
  反复复位（原版 HotPE 同样如此，是模拟器问题、与镜像无关）。
- Ventoy 镜像：QEMU 实测约 63 s 进菜单（两条别名都在），选第一项后还有一层
  启动模式子菜单，选 "Boot in normal mode" 后 Linux PE 正常启动、agent
  /health 200（`logs/machine/qemu-ventoy-official.log`）。

## v2 更新（2026-11-09，九项）

产物在构建机 `/data/home/dist-v2/`（旧 `/data/home/dist/` 原样保留），清单见
`dist/MANIFEST.md` 的 v2 部分。

1. **卷满误报修复**：空间告警（CRITICAL <3% / WARN <10%）只对「含 Windows
   安装的卷」触发；U 盘/Ventoy 分区/无 Windows 的小分区只在 [Volumes] 列表
   如实显示，不进 findings；PE 系统盘 X: 永不告警。真机首启时 1 GiB 的
   Ventoy 分区被报 CRITICAL 即此问题。Linux 版 ai-debug 同步：跳过只读
   挂载、<2GiB 文件系统与启动介质。
2. **固定令牌**：`rescue-config/agent.conf` 新增 `RESCUE_TOKEN`（≥8 字符
   时生效），两版 agent 启动即用它，不再每次开机随机；横幅与
   rescue-token.txt 照常输出并标注 `token source: fixed (agent.conf)`。
   未配置时行为与 v1 完全一致。
3. **命令双名统一**：Windows 版注入 `ai-debug.cmd` 转发 `ai-rescue.exe`，
   Linux 版镜像内加 `ai-rescue` 软链指向 `ai-debug`；两边 `ai-debug` 与
   `ai-rescue` 都可用。
4. **bcdedit / wevtutil 回退**：diagnose 找工具时先查 PATH，再遍历各卷
   `Windows\System32` 借用已安装系统的副本，全无才如实标注跳过。
5. **桌面重开入口**：融合版 WIM 的 Default 与 Public 桌面各注入
   `AI维护-重开.cmd`（双击重开 agent）；agent 横幅加「关闭本窗口即停止
   服务」提示。
6. **Linux 守护确认**：`rescue-agent.service` 已有 `Restart=on-failure` +
   `RestartSec=3`，查实保留（Windows 侧 PE 环境无真守护，靠第 5 项）。
7. **一键动作接口** `POST /action`（与 /exec 同级令牌鉴权，JSON 入出参）：
   - `cleanup`（可 `dry_run`）：对每个含 Windows 安装的卷清固定白名单——
     `Windows\Temp`、各用户 `AppData\Local\Temp`、
     `Windows\SoftwareDistribution\Download`、`$Recycle.Bin` 内容，以及
     `Windows\Logs\CBS` 下的 .log/.cab 文件；pagefile.sys / hiberfil.sys /
     Prefetch 明确不动；逐卷逐项返回删除前后大小。Linux 版对已挂载
     （读写）的 Windows 卷实现同一白名单。
   - `fixboot`：定位 ESP（FAT 卷含 \EFI，必要时 mountvol 挂无盘符卷到
     S:）→ `bcdboot <卷>:\Windows /s <ESP> /f ALL`，逐步返回输出与成败，
     失败如实报错。
   - Linux 版对 fixboot 返回 `{"error":"not supported on linux-pe"}`。
8. **硬件兼容强化**：
   - Windows 融合版基座 WIM 自带完整 DriverStore（434 个驱动包），已逐项
     核查主流有线网卡 INF 与 HWID 覆盖：Intel（e1000/82574/I217/I219
     等 nete1*/net1*/netx* 系列）、Realtek（RTL8168/8111 rt640x64、
     RTL8139 netrtl64、USB RTL8153 rtux64w10/rtucx21）、Broadcom
     （b57nd60a/bnxtnd）、Qualcomm Atheros（netl1c/l1e/l160a）、ASIX USB
     （AX88179/AX88772）全部命中——基座已覆盖，未再叠加注入重复驱动包。
     关键驱动版本示例：rt640x64 10.068.0815.2023（2023-08-15）。
   - Linux PE（内核 6.12.107+deb13）模块核查：e1000/e1000e/igb/ixgbe、
     r8169、8139too、virtio_net、tg3、bnx2、alx、r8152、asix、
     ax88179_178a 与 usbhid 全部在盘，rtl_nic/tigon 固件齐备，无需补编。
   - Ventoy 镜像双启动回归：SeaBIOS（Legacy）与 OVMF（UEFI）下均进
     Ventoy 菜单、两 ISO 条目可见（截图 `logs/machine/v2-ventoy-*.png`）。
   - **Secure Boot**：本镜像未做签名处理。使用时需在目标机关闭
     Secure Boot，或按 Ventoy 官方流程注册其密钥（MokManager），
     否则 UEFI 安全启动会拦截。
9. **只读查看前端**：两版 agent 内置同一单文件 HTML 面板（Go 版 embed
   进二进制，Linux 版随脚本打包），资源全内联、无外链，中文、手机
   自适应。扫横幅二维码（带令牌的局域网地址 `http://<IP>:8734/?token=…`）
   即打开：状态总览（主机名/内存/SMART/各卷容量条，数据来自 /info）、
   诊断报告（触发 GET /diagnose，findings 按级分色卡片 + 原文展开）。
   **页面纯只读：没有任何操作按钮，JS 只调 GET /info 与 GET
   /diagnose**；清理/修复/命令执行仍由 AI 经 /action、/exec（令牌
   鉴权不变）完成。无/错令牌访问页面返回 401 提示页。

经用户决定取消、未实现：diagnose 报告自动落盘档案（rescue-reports）、
drivers-backup / drivers-restore 动作、fixboot 的 BCD 备份步骤。

### v2 验证结果（QEMU，宿主机侧经 hostfwd 从客户机外部访问）

- 融合版：/health 200、无令牌 401、固定令牌 /info 200/错令牌 401；
  diagnose findings 无小卷误报（回归通过）；桌面双份「AI维护-重开.cmd」
  与 System32\ai-debug.cmd 在位，`ai-debug diagnose` 实跑出报告；
  bcdedit 回退路径有记录（本次 QEMU 引导方式下 bcdedit 枚举失败、报告
  如实标注跳过）。日志 `logs/machine/qemu-fusion-v2-test.log`。
- /action cleanup（融合版，对 QEMU 骨架 Windows 卷）：dry_run 只报数
  不删；实删释放 4,221,057 字节，五个白名单目标清空、CBS 仅删
  .log/.cab（保留 keep.txt），白名单外样本（System32 文件、Data 文件、
  pagefile.sys）完好——客户机内 dir 与优雅关机后宿主机 mtools 双向
  核实。日志 `logs/machine/qemu-retest-test.log`。
- /action fixboot（融合版）：ESP 与目标卷定位、bcdboot 调用链验证
  通过；但 bcdboot 本体因测试骨架卷缺 `System32\bootstr.dll` 报错
  c0000001。该文件是真实 Windows 安装的标配（所有精简 PE 均剔除
  它），骨架卷未能播种到正版副本，故 QEMU 内未取得 bcdboot 成功
  字样；agent 对失败如实返回、未假报成功。给骨架卷补入任意真实
  Windows 的 bootstr.dll 后可复测。
- 面板（k）：融合版与 Linux 版均从宿主机外部打开：带令牌 200 且含
  状态区元素，无令牌/错令牌 401；页面源码无 /exec、/action 引用。
- Linux PE：ai-debug diagnose 退出码 0、/health 200、ai-rescue 别名
  可用；cleanup 对读写挂载的骨架卷同白名单实测（释放 4,220,928
  字节，七项文件检查全对）；fixboot 返回 not supported 如实标注。
  （该轮 diagnose 有一条 dmesg I/O 错误 CRITICAL，系 QEMU/TCG 模拟
  存储噪声，与空间误报规则无关。）
- 网络：融合版 e1000 拿到 DHCP 10.0.2.15 且 agent 外部可达；Linux PE
  在 e1000 与 rtl8139 两种模拟网卡下均识别接口并 DHCP 拿址。
- USB 键鼠：QEMU 默认 USB 输入下可操作 PE 桌面/终端（记通过）。

## v3 更新（2026-11-10，三项）

### 1) BitLocker 解锁（64 位与 32 位版均带）

- `ai-debug unlock [设备]`：列出检测到的 BitLocker 卷 → 操作者在本机
  终端输入恢复密钥（48 位数字）或卷密码 → cryptsetup（bitlk 类型）
  解锁 → 挂载到 `/mnt/bitlocker-<分区>`。64 位版挂载顺序：内核
  ntfs3 读写 → ntfs-3g 读写 → ntfs3 只读 → ntfs-3g 只读；32 位版因
  bookworm i386 内核未编入 ntfs3，走 ntfs-3g 读写。dislocker 作为
  备用工具一并装入（主路径未用到）。
- **密钥纪律**：恢复密钥/密码只在运行时从本机终端读入（交给
  cryptsetup 的交互提示），不落盘、不进日志、不进 agent 的 HTTP
  接口、不写进任何报告。
- diagnose 明确标注 BitLocker 卷：未解锁输出「BitLocker 加密，
  未解锁」，解锁后输出已解锁与挂载点，不再默默跳过。检测含整盘
  （无分区）BitLocker 卷与解锁后的状态变化。
- 验证级别（QEMU，如实）：cryptsetup 官方测试镜像
  （aes-xts-128 / aes-xts-256 / aes-cbc-256）均可正确解密、blkid
  识别为 NTFS 且 UUID 与测试向量一致；但官方镜像的 NTFS 本身不
  一致（$MFTMirr 损坏），任何 Linux NTFS 驱动都无法挂载，因此
  挂载段以「真实解密 + 一致 NTFS 镜像代演解密后设备状态」验证
  unlock 后半程：64 位 ntfs3 读写挂载与写读往返通过、32 位
  ntfs-3g 读写挂载与写读往返通过、diagnose 已解锁标注通过。
  真实 Windows BitLocker 卷的完整端到端（真卷解密并挂载）未在
  本次验证覆盖，首次真机使用即为真验；解锁后若 NTFS 处于休眠/
  不一致状态，unlock 会保留解密设备并给出回 Windows 运行
  chkdsk /f 的指引，不强行修复加密卷。

### 2) 32 位 i686 精简兜底版（AI-Rescue-PE-32.iso）

- 基底为 Debian 12 bookworm i386（Debian 13 已取消 i386 内核），
  内核 6.1 686-pae，以 Legacy BIOS 为主。功能只保留：联网
  （e1000/rtl8139 等老网卡）、diagnose、cleanup、只读 panel、
  BitLocker 解锁；不做 fixboot 深修。
- 体积 234,252,288 字节（约 223 MB）；QEMU 以 pentium3 + 768 MB
  内存验证：rtl8139 与 e1000 均 DHCP 拿址、agent 上线、
  /health 200、无令牌 401、diagnose 退出码 0 且为中文输出。

### 3) 本机输出全中文

- ai-debug 输出、开机横幅、agent 控制台信息全部中文（技术名词/
  路径/命令名保留英文）；错误提示同样中文。
- 本机 tty 汉字显示走 fbterm + 子集化字体（Noto Sans CJK SC 按
  GB2312 常用字子集化，约 1.5 MB）：tty1 自动登录后由 .profile
  钩子进入 fbterm。构建中顺带修复了两个潜伏问题（v1 起即在）：
  ① tty1 会话实际未稳定建立（live-config 的 autologin drop-in
  依赖不可靠）→ 构建显式装入 getty@tty1 autologin drop-in；
  ② rescue 用户不在 video 组、打不开 /dev/fb0，fbterm 秒退、
  本机控制台黑屏/菱形乱码 → drop-in 以 ExecStartPre 在每次登录
  前把 rescue 加入 video 组。
- QEMU 验证：ISO 直启后 tty1 的 fbterm 会话驻留，截屏可见
  fbterm 渲染的中文横幅与 diagnose 中文输出（fbcon 下则只会显示
  菱形替代字形——这正是需要 fbterm 的原因）。网页 panel 与报告
  文件中的中文一直正常，不受 tty 影响。

### v3 产物（/data/home/dist-v3/）

| 文件 | 字节 | sha256 |
|---|---|---|
| AI-Rescue-PE.iso | 397,410,304 | `36994bb5fa36ae3131c4d29d5ed3a9c563e3f8d136fbff757ff831ee18c40587` |
| AI-Rescue-PE-32.iso | 234,252,288 | `8e8c1d883935aed18c79c922a5bb31e7b4390e754b3450c743340bf6497b2726` |
| HotPE-Fusion-AIRescue.iso | 1,109,088,256 | `82a80d15f82e41d641d3c2a0bdf02a659dc431bd2d9c97b5df00d0fc220bbf56`（与 dist-v2 原文件相同，未改） |
| Ventoy-AI-Rescue-USB.img | 2,147,483,648 | `8d4d0f4fa27b397faae4575302c074960d7942d0f0f9744193e463582a566db0` |

Ventoy 镜像为 Ventoy 1.1.18 基座 + 上述两个 Linux ISO + 融合
ISO（dist-v2 原文件）+ ventoy.json（含 32 位条目）。Secure Boot
提醒沿用前文：需关闭 Secure Boot 或注册 Ventoy 密钥。

## 产物清单

见 `dist/MANIFEST.md`（名称/大小/sha256/存放位置）。

## 使用方法

### 写 U 盘

整盘镜像（2 GiB）直接写：

```bash
dd if=Ventoy-AI-Rescue-USB.img of=/dev/sdX bs=4M status=progress   # 或用 balenaEtcher
```

或在任意 U 盘上用官方 Ventoy2Disk 装好 Ventoy 后，把 `AI-Rescue-PE.iso` 与
`HotPE-Fusion-AIRescue.iso` 拷进 U 盘根目录，并拷入本仓库的 `build/ventoy.json`
到 U 盘的 `ventoy/` 目录（菜单别名）。

### 连接 agent

1. 用 U 盘启动目标机，在 Ventoy 菜单里选一套救援环境（选完 ISO 后 Ventoy 还会
   显示一层启动模式子菜单，选 "Boot in normal mode"），接网线（DHCP）。
2. 屏幕上 agent 控制台会打印本次开机的令牌与二维码；同一局域网内用浏览器打开
   `http://ai-rescue.local:8734`（或屏幕显示的 IP:8734）：
   - `GET /health` 健康检查（免令牌）
   - `GET /info`、`GET /diagnose` 系统信息与一键诊断报告（需令牌）
   - `POST /exec` 远程执行命令（需令牌，`Authorization: Bearer <令牌>`）
3. Linux PE 侧另可用开机令牌直接 SSH：`ssh rescue@<IP>`（密码即令牌）；
   命令行一键诊断：`ai-debug diagnose`。

### 任意网络（可选）

不在同一局域网时，可在救援环境里用 `ssh -R` 反向隧道把 8734 转到一台有公网
地址的跳板机再访问；本项目不内置任何隧道凭据，按需临时使用。

## CI（InstaBox GitHub App)

- 工作流：`.github/workflows/build.yml`，`runs-on: instabox-medium`
  （InstaBox 官方自托管 runner 标签，免费档可用、不耗 GitHub 分钟）。
- 触发：`push` 与手动 `workflow_dispatch`。
- 流程：在全新机上装依赖 → 下载并按 sha256 校验 Ventoy 官方 1.1.18 发行包 →
  `build/build-pe.sh` 构建 `AI-Rescue-PE.iso` → QEMU 冒烟验证（TCG 限时，
  以串口出现登录横幅/令牌为通过）→ 产物与日志作为 workflow artifacts 上传
  （Actions 页面下载，保留 14 天）。
- **融合版 WinPE 不进 CI、不上传**：它内含 HotPE/微PE 等第三方免费软件，
  只允许在构建机本地制作、放个人 U 盘使用；CI 只构建本项目自有源码的 Linux PE。

## 安全说明

- 仓库内无任何密码、密钥、节点 UUID 真值；agent 令牌为每次开机随机生成，
  只出现在目标机屏幕上。
- 本项目与任何代理/VPN 无关，构建与验证全程未 publish 任何端口。
