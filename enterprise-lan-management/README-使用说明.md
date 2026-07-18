# 使用说明（README）

> **许可声明**：本仓库内容仅供个人与公司内部交流、学习、自研参考使用；未经厦门金奕鸣科技有限公司书面许可，不得擅自商用或再分发。版权归属厦门金奕鸣科技有限公司，客服 13599530881。完整条款见 [LICENSE](./LICENSE)。

本目录提供"公司局域网电脑互联互通"的**自动发现 + 自部署**方案：脚本在每台电脑上自动检测本机、自动扫描采集公司其他电脑，并基于采集结果直接完成部署。详见 `互联互通方案.md`。

## 目录结构

```
enterprise-lan-management/
├── 互联互通方案.md          # 方案、架构、运行步骤、安全与升级路径
├── 商业授权与上线说明.md     # ★商业闭环：版本权益、授权签发/激活、门禁、安全设计
├── README-使用说明.md       # 本文件
├── LICENSE                  # 版权与许可（含商业授权条款）
├── build/
│   └── installer.iss        # ★InnoSetup 安装包模板（M1）
└── scripts/
    ├── wizard-gui.ps1       # ★★主入口：中文图形化配置向导（WinForms 窗口，推荐）
    ├── wizard.ps1           # 中文控制台配置向导（无图形界面时的备选）
    ├── wizard-preview.html  # 向导界面原型预览（可点击，用于确认 UX）
    ├── company-config.json  # 由向导生成的配置（也可手工编辑）
    ├── lib-init.ps1         # 初始化：UTF-8 编码 + 自动提权
    ├── lib-discovery.ps1    # 发现库（被其他脚本引用）
    ├── lib-audit.ps1        # 审计库：统一写溯源日志（被其他脚本引用）
    ├── lib-license.ps1      # ★授权库：RSA 签名校验 + 有效期/设备数/功能门禁
    ├── gen-license.ps1      # ★厂商授权签发工具（仅厂商内部，私钥不入库）
    ├── sign-scripts.ps1     # ★代码签名工具（M1）：Authenticode 批量签名 + 校验
    ├── install.ps1          # ★安装引导器（M1）：部署脚本集 + 快捷方式 + 卸载项
    ├── deploy.ps1           # 核心：自动检测+采集+部署（每台运行）
    ├── discover.ps1         # 仅发现并打印对端（预览，只读）
    ├── manager.ps1          # 统一管控：批量远程执行 / 上网管控 / 网络体检
    ├── netpolicy.ps1        # 上网管控：按主机允许/禁止上网 + 网关黑名单导出
    ├── netcheck.ps1         # 网络体检：只读检查网络健康并集中汇总
    ├── collect-pcinfo.ps1   # 单台快速自检（可选）
    ├── lib-console.ps1      # ★集中控制台共享库（M3）：设备注册表+任务队列（被 console/agent 引用）
    ├── console.ps1          # ★集中控制台服务（M3）：本地 Web + REST API + 任务队列
    ├── agent.ps1            # ★终端代理（M3）：注册+拉取任务+本地执行+上报
    └── console.html         # 控制台仪表盘前端（由 console.ps1 提供）
```

## 快速开始（推荐：图形化向导一站式）

以**管理员 PowerShell**（开始菜单搜 PowerShell → 右键"以管理员身份运行"）进入 `scripts/`，运行图形化向导（暗色窗口、鼠标点选、带「上一步 / 下一步 / 退出」）：
```powershell
cd <本仓库路径>\scripts
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass   # 若系统禁止脚本
.\wizard-gui.ps1
```
向导用中文图形界面逐步选配（互联模式 / 管理账号 / 文件服务器 / 自动改名 / RustDesk / 发现范围 / 安全），
最后可选择「生成并开始部署」或「仅生成配置」。
无图形界面或偏好命令行的环境，可改用 `.\wizard.ps1`（等价的中文控制台向导）。

> 想先看界面：双击打开 `scripts/wizard-preview.html` 走一遍原型，确认无误再运行 `wizard-gui.ps1`。

## 进阶：手动步骤（不使用向导）

1. **填配置**：编辑 `scripts/company-config.json`（工作组名 / 管理账号 / 共享路径 / 文件服务器策略）。
2. **预览发现**：在任一台电脑（管理员 PowerShell）运行 `.\discover.ps1`，确认能看到网内其他电脑。
3. **部署**：
   - 文件服务器那台：`.\deploy.ps1 -FileServer`
   - 其余每台：`.\deploy.ps1`
   - 每台都会自动检测本机、扫描对端、映射共享盘 `S:`、上报自身与清单、启用 WinRM。
4. **统一管控**：管理机运行 `.\manager.ps1`（读取中心清单批量操作）。
   - 一键收集全网资产并导出 Excel：`.\manager.ps1 -CollectInventory -FileServerHost <文件服务器>`
     （优先 Import-Excel / Excel COM 生成 `.xlsx`；未安装 Excel 时自动降级为 `.csv`）。
   - 仅列出已发现主机：`.\manager.ps1 -ListOnly -FileServerHost <文件服务器>`。

## 集中管理控制台（M3，可选 · 降低运维成本）

在管理机/文件服务器上启动 Web 控制台，把"批量远程执行"升级为**任务队列**：控制台下发任务（command / netpolicy / netcheck），各终端 `agent.ps1` 主动拉取、在本地执行并回写结果——无需逐台 WinRM 手工操作，也天然兼容既有的 `Mgmt$` 资产/审计数据。

```powershell
# 1) 管理机启动控制台（需 remotemgmt 授权；管理员令牌在启动时打印）
.\console.ps1 -Lan        # -Lan 让局域网其他电脑可访问（首次需：netsh http add urlacl url=http://+:<端口>/ user=...）

# 2) 每台终端以管理员运行代理（粘贴控制台启动时打印的令牌）
.\agent.ps1 -ConsoleUrl http://<管理机IP>:8080 -Token <控制台令牌>

# 3) 浏览器打开 http://localhost:8080/ ：
#    - 查看在线设备、资产清单（兼容 Mgmt$ 共享）、上网策略/审计
#    - 在「新建任务」选类型与 Payload（如 {"command":"Get-Service WinRM|ConvertTo-Json"}），
#      目标留空=全部已注册设备，点「创建并下发」即可，结果实时回传
```

> 说明：控制台数据默认存于 `scripts/console-data/`（已在 `.gitignore` 排除）；多控制台可 `-DataDir` 指向共享 UNC。中心存储当前为 JSON 文件，规模上来后见《商业闭环后续开发方案》4.3 升级为 SQLite。

## 安全溯源与网络管控（上网管控 / 网络体检）

系统已内置**审计溯源**、**上网管控（可上网 / 可禁用）**、**网络体检**三层能力，全部复用中心清单与 WinRM 通道，不新增服务器。

**统一审计溯源**：所有部署/管控动作自动写入 JSONL 日志（本地 + 中心 `Mgmt$\audit`），改名动作另写溯源对照表 `Mgmt$\audit\rename-<新名>.json`，供公司追责。

**上网管控（按主机允许/禁止上网）**：
```powershell
# 管理机批量：全网禁止 / 恢复上网；加 -HardCut 一并断 DNS
.\manager.ps1 -FileServerHost <文件服务器> -NetPolicy deny
.\manager.ps1 -FileServerHost <文件服务器> -NetPolicy allow
.\manager.ps1 -FileServerHost <文件服务器> -NetPolicy deny -HardCut
# 单台：本机或远端（-ComputerName）
.\netpolicy.ps1 -Action deny -FileServerHost <文件服务器>
.\netpolicy.ps1 -Report -FileServerHost <文件服务器>          # 查看策略报表
# 导出被禁主机的 IP/MAC 黑名单，供路由器/网关侧封禁
.\netpolicy.ps1 -ExportGatewayBlacklist .\blacklist.csv -FileServerHost <文件服务器>
```

**网络体检（只读检查）**：
```powershell
.\manager.ps1 -FileServerHost <文件服务器> -NetCheck   # 全网体检并集中上报
.\manager.ps1 -FileServerHost <文件服务器> -NetReport  # 汇总"上网策略"+"网络体检"
.\netcheck.ps1 -FileServerHost <文件服务器>            # 本机体检并上报
```
体检项：网络类别、IP 冲突、网关可达、DNS 解析、SMB/RDP 监听、监听端口、多网卡、WinRM。结论分 `健康 / 注意 / 异常`。

## 配置要点（company-config.json）

| 字段 | 说明 |
|------|------|
| `WorkgroupName` | 工作组名（所有电脑一致） |
| `MgmtUser` | 统一管理账号名（密码运行时现场输入，不落盘） |
| `ShareRoot` | 文件服务器共享根目录（如 `D:\CompanyShare`） |
| `FileServer` | `AUTO`（自动认领/复用）或填固定主机名 |
| `Discover` | `auto`（本机子网）或指定范围如 `192.168.1.1-254` |
| `MapDriveLetter` | 映射共享盘的盘符（默认 `S`） |
| `AutoRename` | `true` 时把默认主机名（WIN-xxxx / DESKTOP-xxxx）自动改为 `<RenamePrefix>-NN` |
| `RenamePrefix` | 改名前缀（默认 `PC`，即 PC-01、PC-02…） |
| `InstallRustDesk` | `true` 时若本机为家庭版，自动安装 RustDesk 作 RDP 替代 |
| `RustDeskSetPw` | `true` 时部署过程中**现场输入** RustDesk 无人值守密码（不落盘，推荐） |
| `UseDomain` / `DomainName` / `DomainController` | 域模式参数（仅记录；加域需手动执行，向导会给出命令） |
| `TrustedHosts` | `discovered`（对端IP）/ `*`（全部）/ `off`（不改动）/ 具体地址 |
| `BlockRdpPublic` | `true` 表示遵循"RDP 不暴露公网"原则 |
| `RemoteAccess` | `none` / `tailscale` / `zerotier`（远程办公组网，脚本仅提示不代装） |

> 兼容说明：旧字段 `RustDeskPassword`（明文）与 `RustDeskServer` 仍被 `deploy.ps1` 识别；但推荐用向导的 `RustDeskSetPw` 现场输入密码，避免明文存盘。

## 重要提醒

- 家庭版 Windows 不支持 RDP 主机；开启 `InstallRustDesk` 后，脚本会在家庭版电脑上自动安装 RustDesk 作为远程桌面替代（向导中选择"部署时输入无人值守密码"即可安全启用，不写入配置文件）。
- 自动改名（`AutoRename`）会在部署时把默认名改为 `PC-01` 等。为避免并发重名，建议**先跑文件服务器、再逐台跑客户端**，或预分配主机名。改名需重启生效。
- 不要把 RDP(3389) 暴露到公网；远程办公用 VPN / 零信任组网。
- 详见 `互联互通方案.md` 第 7 节（安全）与第 8 节（升级路径）。

## 商业授权与上线（闭环）

本软件已具备完整商业闭环，详见 [商业授权与上线说明.md](./商业授权与上线说明.md)。要点：

- **授权即激活**：厂商用 `gen-license.ps1` 以 RSA-2048 私钥签发 `company.lic`，客户放入 `scripts/` 即激活，无需联网。
- **版本权益**：Free（3 台、仅基础互联）/ Trial（25 台、30 天全功能）/ Pro（50 台）/ Enterprise（不限、含技术支持）。
- **功能门禁**：资产清单、上网管控、网络体检、批量远程管控等高级能力按授权版本开放；无授权按 Free 运行，超额/过期即阻断并提示升级——形成持续营收闭环。
- **安全**：公钥内嵌客户端，私钥仅厂商持有（`vendor.key.json` 已 `.gitignore`，绝不入库/分发），授权不可伪造或篡改。

厂商首次发布前**必须**运行一次 `gen-license.ps1` 以生成密钥对并把公钥写入 `lib-license.ps1`。

## 配套教程（可视化）

- `金网通-开发实战教程.html`：可视化演示 + 自研扩展教程。含项目演示、架构图、全用户/每台电脑自动检查说明、权限最大化与用户决策、快速开始、开发教程（环境/目录/核心模块/自研扩展）以及出品与许可声明。用浏览器打开即可，支持键盘 ←/→ 翻页。
- 质量说明（v6）：所有脚本/配置已统一 **UTF-8 带 BOM**，运行期输出强制 UTF-8，彻底消除中文乱码；入口脚本经 `lib-init.ps1` 在需要时自动提权（UAC 由用户确认）。
