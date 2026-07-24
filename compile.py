#!/usr/bin/env python3
"""WinUtil 中文版 — 编译脚本（Linux 版）
根据 AGENTS.md 的编译流程，生成最终的 winutil.ps1"""

import json
import os
import glob
import sys
from datetime import datetime

def compile_winutil(source_dir: str, output_path: str):
    version = datetime.now().strftime("%y.%m.%d")
    
    print(f"编译 WinUtil 中文版 v{version}")
    print(f"源目录: {source_dir}")
    print(f"输出: {output_path}\n")
    
    lines = []
    
    # 1. 读取 scripts/start.ps1
    start_path = os.path.join(source_dir, "scripts", "start.ps1")
    with open(start_path, "r", encoding="utf-8") as f:
        content = f.read()
    content = content.replace("#{replaceme}", version)
    lines.append(content)
    lines.append("\n")
    print("✅ scripts/start.ps1")
    
    # 2. 追加 functions/ 下所有文件
    functions_dir = os.path.join(source_dir, "functions")
    ps1_files = []
    for root, dirs, files in os.walk(functions_dir):
        for f in sorted(files):
            if f.endswith(".ps1"):
                ps1_files.append(os.path.join(root, f))
    ps1_files.sort()
    
    for fpath in ps1_files:
        with open(fpath, "r", encoding="utf-8") as f:
            content = f.read()
        lines.append(content)
        lines.append("\n")
    print(f"✅ functions/ — {len(ps1_files)} 个文件")
    
    # 3. 嵌入 config/*.json 到 $sync.configs 对象
    config_dir = os.path.join(source_dir, "config")
    configs = {}
    for json_file in sorted(glob.glob(os.path.join(config_dir, "*.json"))):
        name = os.path.splitext(os.path.basename(json_file))[0]
        with open(json_file, "r", encoding="utf-8") as f:
            data = f.read()
        configs[name] = data
    
    for name, data in configs.items():
        if name == "applications":
            # Special-case: keys get WPFInstall prefix in compiled config
            parsed = json.loads(data)
            wpfformat = {}
            for key, value in parsed.items():
                wpfformat[f"WPFInstall{key}"] = value
            configs[name] = json.dumps(wpfformat, ensure_ascii=False, indent=2)
    
    # Write configs as PowerShell hashtable with proper escaping
    lines.append("$sync.configs = @{\n")
    for name, data in configs.items():
        key = name.replace("applications", "WPFInstall")
        # Escape single quotes for PowerShell single-quoted strings
        escaped = data.replace("'", "''")
        lines.append(f'    "{name}" = \'{escaped}\'\n')
    lines.append("}\n")
    lines.append("\n")
    print(f"✅ config/ — {len(configs)} 个文件")
    
    # 4. 嵌入 xaml/inputXML.xaml
    xaml_path = os.path.join(source_dir, "xaml", "inputXML.xaml")
    with open(xaml_path, "r", encoding="utf-8") as f:
        xaml_content = f.read()
    # Escape for PowerShell string
    xaml_escaped = xaml_content.replace("'", "''")
    lines.append(f"$inputXML = @'\n{xaml_content}\n'@\n")
    lines.append("\n")
    print(f"✅ xaml/inputXML.xaml ({len(xaml_content)} 字符)")
    
    # 5. 嵌入 tools/autounattend.xml
    autounattend_path = os.path.join(source_dir, "tools", "autounattend.xml")
    if os.path.exists(autounattend_path):
        with open(autounattend_path, "r", encoding="utf-8") as f:
            autounattend_content = f.read()
        lines.append(f"$WinUtilAutounattendXml = @'\n{autounattend_content}\n'@\n")
        lines.append("\n")
        print(f"✅ tools/autounattend.xml")
    
    # 6. 追加 scripts/main.ps1
    main_path = os.path.join(source_dir, "scripts", "main.ps1")
    with open(main_path, "r", encoding="utf-8") as f:
        content = f.read()
    lines.append(content)
    print("✅ scripts/main.ps1")
    
    # 写入输出文件
    output = "\n".join(lines)
    with open(output_path, "w", encoding="utf-8") as f:
        f.write(output)
    
    size_kb = len(output) / 1024
    print(f"\n✅ 编译完成！输出: {output_path} ({size_kb:.1f} KB)")

if __name__ == "__main__":
    source = sys.argv[1] if len(sys.argv) > 1 else "/opt/data/winutil-zh"
    output = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/winutil-zh/winutil.ps1"
    compile_winutil(source, output)
