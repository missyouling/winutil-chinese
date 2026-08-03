# 🎯 WinUtil 中文版

> 全中文化的 Windows 系统优化工具，基于 [Chris Titus Tech WinUtil](https://github.com/ChrisTitusTech/winutil)，界面、配置、提示信息全部中文化。

---

## 🚀 快速使用

在 **Windows PowerShell（管理员身份）** 中运行：

```powershell
irm https://win.mozuiapp.com/win | iex
```

- `https://你的域名/` 为欢迎页面（浏览器访问），macOS 风格毛玻璃设计，自动适配 Bing 每日壁纸背景
- `https://你的域名/win` 返回编译好的 PowerShell 脚本（`irm` 专用）
- 脚本整体 Base64 编码，完全避免 `irm` 在中文系统上的 ANSI 解码乱码问题

> 自托管部署方法见下方「自托管部署」章节。

---

## 📦 功能特性

| 功能 | 说明 |
|:---|:---|
| 🖥️ **应用安装** | 一键安装常用软件，内置 **344 个应用**、29 个分类（浏览器、开发工具、多媒体、通讯、办公、游戏等） |
| ⚙️ **系统优化** | 81 项优化/撤销优化，覆盖性能、隐私、Windows 更新策略 |
| 📋 **功能配置** | 启用或禁用 33 项 Windows 功能 |
| 📱 **AppX 管理** | 管理 33 项 Windows 内置应用包（移除/恢复） |
| 🌐 **DNS 切换** | 一键切换 8 组公共 DNS（Google、Cloudflare、OpenDNS、Quad9、AdGuard 等） |
| 🎯 **预设方案** | Standard / Minimal / Advanced / AppxDefault 一键应用 |
| 🌙 **主题切换** | 自动 / 浅色 / 深色主题 |
| 💿 **Win11 创建工具** | 下载、挂载、验证并保存 Windows 11 ISO |
| 🔄 **Windows 更新** | 更新设置与安全策略管理 |
| 🌐 **完全中文** | XAML 界面、JSON 配置、PowerShell 提示全部中文化 |

### 命令行参数

```powershell
irm https://你的域名/win | iex            # 打开图形界面
irm https://你的域名/win | iex -Preset Standard   # 直接应用预设
irm https://你的域名/win | iex -Config xxx.json   # 导入配置
irm https://你的域名/win | iex -Offline           # 离线模式
```

| 参数 | 说明 |
|:---|:---|
| `-Preset` | 预设方案：`Standard` / `Minimal` / `Advanced` |
| `-Config` | 导入 JSON 配置文件（导出/导入功能对应） |
| `-Offline` | 离线模式（跳过联网检测） |

---

## 🛠️ 自托管部署

### 方案一：Cloudflare Pages（推荐，自动从 GitHub 部署）

1. 在 Cloudflare Pages 中点击 **"Create a project"** → **"Connect Git"**
2. 选择本仓库，构建设置：**无构建命令**，输出目录留空
3. 部署后绑定自定义域名
4. 每次 `git push` 后自动重新部署
5. 推送前需手动将编译好的 `winutil.ps1` 同步到 `cloudflare-pages/` 目录

### 方案二：Cloudflare Workers

1. 在 Cloudflare Dashboard 创建一个 **Worker**
2. 打开 `cloudflare-worker/src/worker.js`，复制全部内容
3. 粘贴到 Worker 编辑器，点击 **"Save and Deploy"**
4. 绑定自定义域名，运行 `irm https://你的域名/win | iex` 即可使用

### 方案三：自建 Web 服务器

```bash
# 1. 编译脚本（生成 winutil.ps1）
python3 compile.py

# 2. 启动 HTTP 服务（Node.js）
node server.js
# 或 Python
python3 -m http.server 8080 --bind 0.0.0.0

# 3. 运行 irm http://你的IP:8080/win | iex 使用工具
```

> 自定义域名部署：将 `winutil.ps1` 放到任意 Web 服务器，确保响应头包含 `Content-Type: text/plain; charset=utf-8` 与 `Access-Control-Allow-Origin: *` 即可。

---

## 🔧 本地开发

```bash
# 克隆仓库
git clone https://github.com/missyouling/winutil-chinese.git
cd winutil-chinese

# 编译（生成 winutil.ps1，整体 Base64 编码输出纯 ASCII 文件）
python3 compile.py

# 本地测试
python3 -m http.server 8080
# 浏览器: http://localhost:8080/            → 欢迎页面
# PowerShell: irm http://localhost:8080/win | iex → 运行工具
```

### 编译模型

`compile.py` 按以下顺序组装 `winutil.ps1`：

1. `scripts/start.ps1` — 替换 `#{replaceme}` 为当前日期版本号（如 `26.08.03`）
2. `functions/`（public 33 个 + private 52 个）— 全部函数递归拼接
3. `config/*.json`（9 个）— Base64 编码内嵌为 `$sync.configs.*`；`applications.json` 的键自动加 `WPFInstall` 前缀
4. `xaml/inputXML.xaml`（1924 行）— Base64 编码内嵌为 `$inputXML`
5. `tools/autounattend.xml` — 内嵌无人值守安装模板
6. `scripts/main.ps1` — 主入口与 GUI 初始化逻辑
7. 合并后的 body 整体 Base64 编码，输出为纯 ASCII 文件（`irm | iex` 无乱码）

> 也可用 `Compile.ps1`（PowerShell 版，支持 `-Run` 直接启动 GUI）。

### 运行测试

```powershell
# Pester 单元测试（23 个测试文件，CI 上 468 项断言）
Import-Module Pester -MinimumVersion 5.0
Invoke-Pester -Path 'pester/*.Tests.ps1' -Output Detailed
```

### 持续集成（GitHub Actions）

| Workflow | 触发 | 内容 |
|:---|:---|:---|
| **Compile Check** | push/PR 到 main | Ubuntu 上运行 `python3 compile.py`，校验编译产物 |
| **Pester Tests** | push/PR 到 main | Windows 上运行全部 Pester 单元测试 |
| **Release** | 推送 `v*` 标签 | 构建 Release，附带编译好的 `winutil.ps1` 资产 |

---

## 📁 项目结构

```
├── winutil.ps1                  # 编译产物（Base64 编码纯 ASCII，约 1.1 MB，不提交）
├── compile.py                   # Linux/Python 编译脚本（推荐）
├── Compile.ps1                  # PowerShell 编译脚本（-Run 可直接启动 GUI）
├── server.js                    # Node.js 本地 HTTP 服务
├── xaml/
│   └── inputXML.xaml            # 中文化 WPF 界面（1924 行）
├── config/                      # 全部配置（中文）
│   ├── applications.json        # 344 个应用（29 分类，winget/choco 双源）
│   ├── tweaks.json              # 81 项系统优化
│   ├── feature.json             # 33 项 Windows 功能
│   ├── appx.json                # 33 项 AppX 管理
│   ├── preset.json              # 4 套预设方案
│   ├── dns.json                 # 8 组 DNS
│   ├── appnavigation.json       # 导航配置
│   ├── themes.json              # 主题配置
│   └── strings.json             # 界面字符串
├── functions/
│   ├── public/                  # 33 个公开函数
│   └── private/                 # 52 个私有函数
├── scripts/
│   ├── start.ps1                # 启动脚本（管理员提权、参数处理）
│   └── main.ps1                 # 主入口与 GUI 初始化
├── pester/                      # 23 个 Pester 测试文件
├── tools/
│   └── autounattend.xml         # 无人值守安装模板
├── cloudflare-pages/            # CF Pages 部署目录
│   ├── index.html               # 欢迎页（macOS 风格毛玻璃）
│   ├── winutil.ps1              # 脚本副本（部署用）
│   ├── _redirects               # /win → /winutil.ps1
│   └── _headers                 # UTF-8 + CORS 响应头
├── cloudflare-worker/           # CF Workers 部署（备选）
├── docs/                        # Hugo 文档站
├── lint/                        # PSScriptAnalyzer 规则
└── .github/workflows/           # CI/CD（compile-check / unittests / release）
```

---

## 🙏 致谢

- **[Chris Titus Tech](https://github.com/ChrisTitusTech)** — 原始 WinUtil 作者
- **[MyDrift-user](https://github.com/MyDrift-user)** — UI 贡献
- **[Marterich](https://github.com/Marterich)** — 优化与运行空间
- **[DeveloperDurp](https://github.com/DeveloperDurp)** — 运行空间架构

---

## 📄 许可证

MIT License — 与 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) 一致
