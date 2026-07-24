#!/usr/bin/env python3
"""批量翻译 XAML 英文文本为中文"""
import re

with open("xaml/inputXML.xaml", "r", encoding="utf-8") as f:
    xaml = f.read()

changes = {}

# === Updates 页面 ===
changes['Text="Windows Update Profiles"'] = 'Text="Windows 更新配置文件"'
changes['Text="Choose how Windows receives updates. Each profile replaces the Windows Update settings managed by WinUtil."'] = 'Text="选择 Windows 接收更新的方式。每个配置将替换 WinUtil 管理的更新设置。"'
changes['Text="Recommended"'] = 'Text="推荐配置"'
changes['Text="Balanced security and stability"'] = 'Text="平衡安全与稳定"'
changes['Text="- Defers feature updates for 365 days"'] = 'Text="- 推迟功能更新 365 天"'
changes['Text="- Defers quality updates for 4 days"'] = 'Text="- 推迟质量更新 4 天"'
changes['Text="- Excludes drivers from quality updates"'] = 'Text="- 从质量更新中排除驱动"'
changes['Text="- Prevents automatic restarts while a user is signed in"'] = 'Text="- 登录时阻止自动重启"'
changes['Text="Available on Windows Pro, Enterprise, and Education editions."'] = 'Text="适用于 Win 专业版/企业版/教育版。"'
changes['Text="Windows Default"'] = 'Text="Windows 默认"'
changes['Text="Return control to Windows"'] = 'Text="交还控制权给 Windows"'
changes['Text="- Removes Windows Update policies applied by WinUtil"'] = 'Text="- 移除 WinUtil 应用的更新策略"'
changes['Text="- Restores update service startup settings"'] = 'Text="- 恢复更新服务启动设置"'
changes['Text="- Re-enables update scheduled tasks"'] = 'Text="- 重新启用更新计划任务"'
changes['Text="Use this to undo the Recommended or Disable profile."'] = 'Text="用于撤销推荐或禁用配置。"'
changes['Text="Disable Updates"'] = 'Text="禁用更新"'
changes['Text="Advanced use only"'] = 'Text="仅限高级用户"'
changes['Text="- Disables automatic update policy"'] = 'Text="- 禁用自动更新策略"'
changes['Text="- Stops update services and scheduled tasks"'] = 'Text="- 停止更新服务和计划任务"'
changes['Text="- Clears downloaded update files"'] = 'Text="- 清除已下载更新文件"'
changes['Text="Security updates will not be installed while this profile is active."'] = 'Text="此配置激活期间不安装安全更新。"'
changes['Text="Changes apply system-wide. Restart Windows after switching profiles. Use Restore Defaults to undo WinUtil update policies."'] = 'Text="更改作用于全系统。切换配置后重启 Windows。使用恢复默认可撤销策略。"'

# === Win11 Creator 页面 ===
changes['Text="Step 1 - Select Windows 11 ISO"'] = 'Text="步骤 1 - 选择 Windows 11 ISO"'
changes['Text="Step 2 - Mount &amp; Verify ISO"'] = 'Text="步骤 2 - 挂载和验证 ISO"'
changes['Text="Step 3 - Modify install.wim"'] = 'Text="步骤 3 - 修改 install.wim"'

# Inline text for Step 1
changes['Step 1 - Select Windows 11 ISO'] = '步骤 1 - 选择 Windows 11 ISO'
changes['Browse to your locally saved Windows 11 ISO file. Only official ISOs'] = '浏览本地的 Windows 11 ISO 文件。仅支持'
changes['downloaded from Microsoft are supported.'] = '从 Microsoft 下载的官方 ISO。'
changes['NOTE:'] = '注意：'
changes['This is only meant for Fresh and New Windows installs.'] = '仅适用于全新 Windows 安装。'
changes['No ISO selected...'] = '未选择 ISO...'
changes["!!WARNING!! You must use an official Microsoft ISO"] = "!!警告！！ 必须使用官方 Microsoft ISO"
changes['Download the Windows 11 ISO directly from Microsoft.com.'] = '直接从 Microsoft.com 下载 Windows 11 ISO。'
changes['Third-party, pre-modified, or unofficial images are not supported'] = '不支持第三方、预先修改或非官方映像'
changes['and may produce broken results.'] = '可能导致损坏结果。'
changes['On the Microsoft download page, choose:'] = '在 Microsoft 下载页面选择：'
changes['- Edition  : Windows 11'] = '- 版本：Windows 11'
changes['- Language : your preferred language'] = '- 语言：首选语言'
changes['- Architecture : 64-bit (x64)'] = '- 架构：64-bit'

# Step 2 inline
changes['Mount the ISO and confirm it contains a valid Windows 11'] = '挂载 ISO 并确认包含有效的 Windows 11'
changes['install.wim before any modifications are made.'] = 'install.wim，然后再修改。'
changes['Select Edition:'] = '选择版本：'

# Step 3 inline
changes['The ISO contents will be extracted to a temporary working directory,'] = 'ISO 内容将提取到临时工作目录，'
changes['install.wim will be modified (components removed, tweaks applied),'] = 'install.wim 将被修改（移除组件、应用优化），'
changes['and the result will be repackaged. This process may take several minutes'] = '然后重新打包。此过程可能需要数分钟，'
changes['depending on your hardware.'] = '具体取决于硬件。'

# Step 4 inline
changes['Step 4 - Output: What would you like to do with the modified image?'] = '步骤 4 - 输出：如何处理修改后的映像？'
changes['!! All data on the selected USB drive will be permanently erased !!'] = '!! 所选 U 盘上的所有数据将被永久擦除 !!'
changes['Select a removable USB drive below, then click Erase &amp; Write.'] = '选择下方的可移动 U 盘，然后点击擦除和写入。'
changes['Status Log'] = '状态日志'
changes['Ready. Please select a Windows 11 ISO to begin.'] = '就绪。请选择 Windows 11 ISO 开始。'

# === AppX page ===
changes['Note: Select the Windows AppX packages you wish to install or remove.'] = '注意：选择要安装或移除的 Windows AppX 包。'
changes['Install Selected registers a local manifest when available, then falls back to the Microsoft Store.'] = '安装选中将在可用时注册本地清单，否则回退到 Microsoft Store。'
changes['Remove Selected removes packages for the current user and all new user profiles.'] = '移除选中将移除当前和所有新用户的包。'

# === Font Scaling ===
changes['Text="Font Scaling"'] = 'Text="字体缩放"'
changes['Text="Small"'] = 'Text="小"'
changes['Text="Large"'] = 'Text="大"'

# === Filters label ===
changes['Text="Filters"'] = 'Text="筛选"'

# === Tweaks notes ===
changes['Note: Hover over items to get a better description. Please be careful as many of these tweaks will heavily modify your system.'] = '注意：悬停查看详细说明。谨慎操作，许多优化将大幅修改系统。'
changes['Recommended selections are for normal users and if you are unsure do NOT check anything else!'] = '推荐选项适用于普通用户，不确定请不要勾选其他选项！'

# === 应用推荐/恢复默认/禁用更新 按钮 ===
# These are buttons inside the Update profiles page
# Content="应用推荐" already translated
# Content="恢复默认" already translated  
# Content="禁用更新" already translated

# === Apply all ===
applied = 0
skipped = []
for old, new in changes.items():
    count = xaml.count(old)
    if count > 0:
        xaml = xaml.replace(old, new)
        applied += count
    else:
        skipped.append(old[:70])

with open("xaml/inputXML.xaml", "w", encoding="utf-8") as f:
    f.write(xaml)

print(f"✅ 翻译了 {applied} 处")
if skipped:
    print(f"⚠️ {len(skipped)} 项未找到:")
    for s in skipped:
        print(f"   - {s}")
