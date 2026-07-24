# 🎯 WinUtil 中文版 / Chinese Edition

> 全中文化的 Windows 系统优化工具 — 基于 [Chris Titus Tech WinUtil](https://github.com/ChrisTitusTech/winutil)
>
> Fully localized Chinese edition of the Windows Utility Toolbox

---

## 🚀 快速使用 / Quick Start

### 中文

在 **Windows PowerShell（管理员身份）** 中运行：

```powershell
irm https://win.mozuiapp.com/win | iex
```

> `https://win.mozuiapp.com/` 为欢迎页面（浏览器访问）— 采用 **macOS 风格毛玻璃设计**，自动适配 Bing 每日壁纸背景
>
> `https://win.mozuiapp.com/win` 返回 PowerShell 脚本（`irm` 专用）

### English

Run the following command in **Windows PowerShell (as Administrator)**:

```powershell
irm https://win.mozuiapp.com/win | iex
```

> `https://win.mozuiapp.com/` serves a welcome page (for browsers) — **macOS-style glassmorphism design** with Bing daily wallpaper background
>
> `https://win.mozuiapp.com/win` serves the PowerShell script (for `irm`)

> **注意 / Note**: Replace `win.mozuiapp.com` with your actual domain if self-hosting

---

## 📦 功能特性 / Features

### 中文

| 功能 | 说明 |
|:---|:---|
| 🖥️ **应用安装** | 一键安装常用软件（浏览器、开发工具、多媒体工具等） |
| ⚙️ **系统优化** | 调整 Windows 设置，优化系统性能与隐私 |
| 📋 **功能配置** | 启用或禁用 Windows 功能 |
| 📱 **AppX 管理** | 管理 Windows 内置应用包 |
| 🎯 **预设方案** | Standard / Minimal / Advanced 一键应用 |
| 🌙 **主题切换** | 自动 / 深色 / 浅色主题 |
| 🌐 **完全中文** | 界面、按钮、提示、配置全部中文化 |

### English

| Feature | Description |
|:---|:---|
| 🖥️ **App Install** | One-click install of popular apps (browsers, dev tools, media tools, etc.) |
| ⚙️ **Tweaks** | Adjust Windows settings, optimize performance & privacy |
| 📋 **Config** | Enable or disable Windows features |
| 📱 **AppX Manager** | Manage built-in Windows app packages |
| 🎯 **Presets** | Standard / Minimal / Advanced — apply with one click |
| 🌙 **Theme** | Auto / Dark / Light mode |
| 🌐 **Chinese UI** | Full Chinese localization (XAML UI, configs, prompts) |

---

## 🛠️ 自托管部署 / Self-Hosting Deployment

### 方案一：Cloudflare Workers（推荐）

1. 在 Cloudflare Dashboard 创建一个 **Worker**
2. 打开 `cloudflare-worker/src/worker.js`，复制全部内容
3. 粘贴到 Worker 编辑器，点击 **"Save and Deploy"**
4. 绑定自定义域名（如 `win.mozuiapp.com`）
5. 完成！访问即可看到欢迎页，运行 `irm .../win \| iex` 即可使用

### 方案二：Cloudflare Pages（自动从 GitHub 部署）

1. 在 Cloudflare Pages 中点击 **"Create a project"** → **"Connect Git"**
2. 选择 `missyouling/winutil-chinese` 仓库
3. 构建设置：**无构建命令**，输出目录留空
4. 部署后绑定自定义域名
5. 每次 `git push` 后自动重新部署

### 方案三：自建 Web 服务器

```bash
# 1. 编译脚本
python3 compile.py

# 2. 启动 HTTP 服务
python3 -m http.server 8080 --bind 0.0.0.0

# 3. 访问 http://your-ip:8080/ 查看欢迎页
# 4. 运行 irm http://your-ip:8080/win | iex 使用工具
```

---

## 📁 项目结构 / Project Structure

```
├── winutil.ps1                  # 编译好的完整脚本（UTF-8 BOM，~635KB）
├── xaml/
│   └── inputXML.xaml            # 中文化 XAML 界面（1923 行）
├── config/
│   ├── applications.json        # 应用配置（已全部翻译）
│   ├── tweaks.json              # 系统优化配置（已全部翻译）
│   ├── feature.json             # Windows 功能配置（已翻译）
│   ├── appx.json                # AppX 管理配置（已翻译）
│   ├── preset.json              # 预设方案（已翻译）
│   ├── appnavigation.json       # 导航配置
│   ├── dns.json                 # DNS 配置
│   └── themes.json              # 主题配置
├── functions/
│   ├── public/                  # 公开函数（Write-Host 信息已中文化）
│   └── private/                 # 私有函数（提示信息已中文化）
├── scripts/
│   ├── main.ps1                 # 主入口
│   └── start.ps1                # 启动脚本
├── tools/
│   └── autounattend.xml         # 无人值守安装模板
├── cloudflare-worker/           # Workers 部署
│   ├── src/worker.js            # 含嵌入脚本（~700KB）
│   ├── worker.js.template       # Worker 模板
│   ├── wrangler.toml            # Wrangler 配置
│   └── deploy.sh                # 本地编译部署脚本
├── cloudflare-pages/            # Pages 部署
│   ├── index.html               # macOS 风格欢迎页（毛玻璃设计）
│   ├── _redirects               # 路由规则
│   ├── _headers                 # 响应头（UTF-8 + CORS）
│   └── winutil.ps1              # 脚本副本
└── compile.py                   # Linux 编译脚本
```

---

## 🔧 本地开发 / Local Development

```bash
# 克隆仓库
git clone https://github.com/missyouling/winutil-chinese.git
cd winutil-chinese

# 编译（生成 winutil.ps1）
python3 compile.py

# 本地测试
python3 -m http.server 8080
# 浏览器: http://localhost:8080/          → 欢迎页面
# PowerShell: irm http://localhost:8080/win | iex  → 运行工具
```

### 自定义域名

1. 编译 `python3 compile.py`
2. 将 `winutil.ps1` 部署到你的 Web 服务器
3. 确保响应头包含 `Content-Type: text/plain; charset=utf-8`
4. 用户在 PowerShell 中运行 `irm https://你的域名/win | iex`

---

## 📜 翻译范围 / Translation Scope

| 文件 / File | 范围 / Scope | 翻译项 / Items |
|:---|:---:|:---:|
| `xaml/inputXML.xaml` | 按钮标签、工具提示全部中文化 | 1,923 行 |
| `config/*.json` (×8) | Content/Description 字段中文化 | 970+ 字段 |
| `functions/*.ps1` | Write-Host 提示信息中文化 | ~40 条 |
| 编码 | UTF-8 BOM | 兼容 PowerShell 5.x |
| 变量安全 | `$Var:` → `${Var}:` | 避免歧义解析 |

---

## 🙏 致谢 / Credits

- **[Chris Titus Tech](https://github.com/ChrisTitusTech)** — 原始 WinUtil 作者
- **[MyDrift-user](https://github.com/MyDrift-user)** — UI 贡献
- **[Marterich](https://github.com/Marterich)** — 优化与运行空间
- **[DeveloperDurp](https://github.com/DeveloperDurp)** — 运行空间架构

---

## 📄 许可证 / License

MIT License — 与 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) 一致
