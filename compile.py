#!/usr/bin/env python3
"""WinUtil 中文版 — 编译脚本（Linux 版）
所有含中文的嵌入内容（XAML + JSON 配置）均 Base64 编码，
绕过 PowerShell 5.x `irm | iex` 管线编码问题。"""

import json, os, glob, sys, base64
from datetime import datetime

def b64_encode_json(data: str) -> str:
    """JSON 字符串 → Base64"""
    return base64.b64encode(data.encode("utf-8")).decode("ascii")

def compile_winutil(source_dir: str, output_path: str):
    version = datetime.now().strftime("%y.%m.%d")
    print(f"编译 WinUtil 中文版 v{version}")
    print(f"源目录: {source_dir} → {output_path}\n")

    lines = []

    # 1. start.ps1
    with open(os.path.join(source_dir, "scripts", "start.ps1"), "r", encoding="utf-8") as f:
        lines.append(f.read().replace("#{replaceme}", version))
    print("✅ scripts/start.ps1")

    # 2. functions/
    for root, _, files in os.walk(os.path.join(source_dir, "functions")):
        for f in sorted(files):
            if f.endswith(".ps1"):
                with open(os.path.join(root, f), "r", encoding="utf-8") as fh:
                    lines.append(fh.read())
    print("✅ functions/ — 84 个文件")

    # 3. config/*.json → Base64 嵌入 + 显式 UTF-8 解码
    config_dir = os.path.join(source_dir, "config")
    configs = {}
    for jf in sorted(glob.glob(os.path.join(config_dir, "*.json"))):
        name = os.path.splitext(os.path.basename(jf))[0]
        with open(jf, "r", encoding="utf-8") as f:
            data = f.read()
        if name == "applications":
            parsed = json.loads(data)
            wpfformat = {f"WPFInstall{k}": v for k, v in parsed.items()}
            data = json.dumps(wpfformat, ensure_ascii=False, indent=2)
        configs[name] = data

    lines.append("$sync.configs = @{}\n")
    for name, data in configs.items():
        b64 = b64_encode_json(data)
        lines.append(
            f'$sync.configs.{name} = [System.Text.Encoding]::UTF8.GetString('
            f'[System.Convert]::FromBase64String(\'{b64}\')) | ConvertFrom-Json\n'
        )
    print(f"✅ config/ — {len(configs)} 个文件（Base64 编码）")

    # 4. xaml/inputXML.xaml → Base64
    with open(os.path.join(source_dir, "xaml", "inputXML.xaml"), "rb") as f:
        xaml_bytes = f.read()
    xaml_b64 = base64.b64encode(xaml_bytes).decode("ascii")
    lines.append(
        '$inputXML = [System.Text.Encoding]::UTF8.GetString('
        f'[System.Convert]::FromBase64String(\'{xaml_b64}\'))\n'
    )
    print(f"✅ xaml/inputXML.xaml（Base64, {len(xaml_bytes)} 字节原始）")

    # 5. autounattend.xml
    aupath = os.path.join(source_dir, "tools", "autounattend.xml")
    if os.path.exists(aupath):
        with open(aupath, "r", encoding="utf-8") as f:
            autounattend = f.read()
        lines.append(f"\n$WinUtilAutounattendXml = @'\n{autounattend}\n'@\n")
        print("✅ tools/autounattend.xml")

    # 6. main.ps1
    with open(os.path.join(source_dir, "scripts", "main.ps1"), "r", encoding="utf-8") as f:
        lines.append(f.read())
    print("✅ scripts/main.ps1")

    # 写入 UTF-8 BOM
    output = "\n".join(lines)
    with open(output_path, "w", encoding="utf-8-sig") as f:
        f.write(output)

    kb = len(output) / 1024
    print(f"\n✅ 编译完成！{output_path} ({kb:.1f} KB)")

if __name__ == "__main__":
    s = sys.argv[1] if len(sys.argv) > 1 else "/opt/data/winutil-zh"
    o = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/winutil-zh/winutil.ps1"
    compile_winutil(s, o)
