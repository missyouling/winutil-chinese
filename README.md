# 🎯 WinUtil 中文版 / Chinese Edition

> 全中文化的 Windows 系统优化工具 — 基于 [Chris Titus Tech WinUtil](https://github.com/ChrisTitusTech/winutil)
>
> Fully localized Chinese edition of the Windows Utility Toolbox

---

## 🚀 快速使用 / Quick Start

### 中文

在 **Windows PowerShell（管理员身份）** 中运行以下命令：

```powershell
irm https://win.mozuiapp.cn/ | iex
```

### English

Run the following command in **Windows PowerShell (as Administrator)**:

```powershell
irm https://win.mozuiapp.cn/ | iex
```

> **注意**：需要将域名 `win.mozuiapp.cn` 替换为你实际绑定的域名
>
> **Note**: Replace `win.mozuiapp.cn` with your actual domain

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
| 🌐 **完全中文** | 界面、按钮、提示全部中文化 |

### English

| Feature | Description |
|:---|:---|
| 🖥️ **App Install** | One-click install of popular apps (browsers, dev tools, media tools, etc.) |
| ⚙️ **Tweaks** | Adjust Windows settings, optimize performance & privacy |
| 📋 **Config** | Enable or disable Windows features |
| 📱 **AppX Manager** | Manage built-in Windows app packages |
| 🎯 **Presets** | Standard / Minimal / Advanced — apply with one click |
| 🌙 **Theme** | Auto / Dark / Light mode |
| 🌐 **Chinese UI** | Full Chinese localization |

---

## 🛠️ 部署说明 / Deployment

### Cloudflare Workers

```bash
# 1. 复制 worker.js 内容
cat cloudflare-worker/src/worker.js

# 2. 在 Cloudflare Dashboard 创建 Worker 并粘贴代码
# 3. 绑定自定义域名，如 win.mozuiapp.cn
# 4. 用户即可通过以下命令使用：
#    irm https://你的域名/ | iex
```

### Cloudflare Pages

```bash
# 1. 在 Cloudflare Pages 中连接此 GitHub 仓库
# 2. 部署设置：无需构建命令，直接部署
# 3. 绑定自定义域名
```

---

## 📁 项目结构 / Project Structure

```
├── winutil.ps1                  # 编译好的完整脚本（660KB）
├── xaml/
│   └── inputXML.xaml            # 中文化 XAML 界面（1923 行）
├── config/
│   ├── applications.json        # 应用配置（已翻译）
│   ├── tweaks.json              # 优化配置（已翻译）
│   ├── feature.json             # 功能配置（已翻译）
│   ├── appx.json                # AppX 配置（已翻译）
│   ├── preset.json              # 预设方案（已翻译）
│   └── ...
├── functions/
│   ├── public/                  # 公开函数
│   └── private/                 # 私有函数（提示信息已中文化）
├── scripts/
│   ├── main.ps1                 # 主入口
│   └── start.ps1                # 启动脚本
├── cloudflare-worker/           # Cloudflare Workers 部署文件
│   ├── src/worker.js            # 含嵌入脚本的 Worker（702KB）
│   ├── worker.js.template       # Worker 模板
│   ├── wrangler.toml            # Wrangler 配置
│   └── deploy.sh                # 部署脚本
├── cloudflare-pages/            # Cloudflare Pages 部署文件
│   ├── functions/index.js       # Pages Function
│   ├── winutil.ps1              # 中文脚本副本
│   └── index.html               # 欢迎页
├── compile.py                   # Linux 编译脚本
└── server.js                    # 本地测试服务器
```

---

## 🔧 本地开发 / Local Development

### 中文

```bash
# 编译脚本
python3 compile.py

# 本地测试
node server.js
# 访问 http://localhost:8080/
```

### English

```bash
# Compile the script
python3 compile.py

# Local test server
node server.js
# Visit http://localhost:8080/
```

---

## 📜 翻译范围 / Translation Scope

| 文件 / File | 行数 / Lines | 翻译项 / Items |
|:---|:---:|:---:|
| `xaml/inputXML.xaml` | 1,923 | 按钮标签、工具提示全部中文化 |
| `config/*.json` (×8) | — | 970 个 Content/Description 字段 |
| `functions/*.ps1` | — | ~40 条 Write-Host 提示信息 |

---

## 🙏 致谢 / Credits

- **[Chris Titus Tech](https://github.com/ChrisTitusTech)** — 原始 WinUtil 作者
- **[MyDrift-user](https://github.com/MyDrift-user)** — UI 贡献
- **[Marterich](https://github.com/Marterich)** — 优化与运行空间
- **[DeveloperDurp](https://github.com/DeveloperDurp)** — 运行空间架构

---

## 📄 许可证 / License

MIT License — 与 [ChrisTitusTech/winutil](https://github.com/ChrisTitusTech/winutil) 一致
