# 产物清单（MANIFEST）

构建机：InstaBox main-1（`m_agqyqiykhhc2xqyinwogy3t7aq`），构建日期 2026-11-08。
所有镜像只存于构建机 `/data/home/dist/`，未上传任何网盘/GitHub；融合版 ISO 含第三方
免费软件，按约定**永不上传**，仅供用户个人 U 盘使用。

| 产物 | 大小（字节） | SHA-256 | 存放位置 | 验证结论 |
|---|---|---|---|---|
| AI-Rescue-PE.iso | 327,155,712 | `262755f68a93b0490dd5fc3026b898b1361eb955c713a25f47f63f533ec62264` | 机内 `/data/home/dist/` | QEMU 直启通过：登录/rescue 登录/ai-debug diagnose 退出码 0；agent /health、/info、/diagnose 200、/exec 正常、无令牌 401、SSH 令牌登录成功 |
| HotPE-Fusion-AIRescue.iso | 1,109,088,256 | `d8601821c03e4ba15e224fcb8115518f5f69dcc3e51d087f6c56051fe6981ceb` | 机内 `/data/home/dist/`（仅此一份） | QEMU 通过（须 `-cpu max`，见 README 注）：进 HotPE 桌面、agent 自启、/health 200（`os: windows-pe`）、/info 无令牌 401；抽验 Everything、WimTool 可打开，`ai-rescue.exe diagnose` 在 PE 内出完整报告 |
| Ventoy-AI-Rescue-USB.img | 2,147,483,648 | `6d15849a194064070fd02575e0b8a25b8281c522fd97c83470a91d34f1c90e8d` | 机内 `/data/home/dist/` | 官方 Ventoy 1.1.18 载荷 + 上面两个 ISO + `ventoy/ventoy.json` 别名。QEMU 实测：约 63 s 进菜单 → 选 Linux PE → 启动模式子菜单选 normal mode → agent /health 200（hostname `ai-rescue`） |

组件：

| 组件 | 大小（字节） | SHA-256 | 说明 |
|---|---|---|---|
| ai-rescue.exe（strip 构建） | 7,502,336 | `bb18289ddc3b24464f8e06f9ee35732b2cddcd798ca06fb79d49e9d1143a680c` | 已注入融合版 WIM 的 `\Windows\System32\`；两次构建逐位一致。机内路径 `/data/home/build/winpe/ai-rescue.exe` |
| 融合 WIM（填充后） | 670,543,552 | `48144d109b214f25c516b4cf4991036ed774850af92feab9ebea789e64525563` | 实际内容 669,848,410 字节 + 零填充；与原版 ISO 仅此段不同（头/尾哈希双验） |
| 基座 HotPE 原版 ISO | 1,109,088,256 | `2d8de0efde0017d60374da9310125d76085d87aad5a2300701949afb18a73ad4` | 官方 CDN 下载，融合版的字节基底 |

已淘汰的中间产物（不交付；体积大的已在机内磁盘清理时删除，仅留哈希存档）：

| 产物 | SHA-256 | 淘汰原因 |
|---|---|---|
| 融合 v3（genisoimage UDF 重打包） | `fd7ebc9300b9773a668f23b6d12c93be16e2729662e80b40d96d46ed38166133` | bootmgr 卡在 Loading files 循环（cdrkit UDF 缺陷） |
| 融合 v4a（拼接 + LZX 64K 分块） | `ad275eaacbc128f3f7969e226adbea008565ffe9cb2c42985e38e42e204cc22a` | winload.exe 报 0xc0000098（bootmgr 只支持 ≤32K 分块） |
| 第一版 Ventoy 镜像 | `a25db3ed98e967e61ea52bc2978b077690b2948549ead15a92cbcc2eaae20953` | 内含 v3 融合 ISO |
| 源码载荷版 Ventoy 镜像 | `44867c8ef429af4d9384cb055771c6e7694377fe94dfd109a1e2fabbef013573` | Ventoy 源码编译载荷组装的镜像在 QEMU BIOS 启动时卡在 SeaBIOS "Booting from Hard Disk..."，引导链未通过验证（源码打包产物 `ventoy-1.1.18-linux.tar.gz` 仍在机构建目录） |
