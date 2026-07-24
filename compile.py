#!/usr/bin/env python3
"""WinUtil 中文版 — 终极编译脚本
将整个 PowerShell 脚本彻底 Base64 编码，输出为纯 ASCII 文件，
完全绕过 `irm` ANSI 解码对中文的破坏。"""

import json, os, glob, sys, base64
from datetime import datetime

def compile_winutil(source_dir: str, output_path: str):
    version = datetime.now().strftime("%y.%m.%d")
    print(f"编译 WinUtil 中文版 v{version}")
    print(f"源目录: {source_dir} → {output_path}\n")

    body_parts = []

    # 1. scripts/start.ps1
    with open(os.path.join(source_dir, "scripts", "start.ps1"), "r", encoding="utf-8") as f:
        body_parts.append(f.read().replace("#{replaceme}", version))
    print("✅ scripts/start.ps1")

    # 2. functions/
    func_count = 0
    for root, _, files in os.walk(os.path.join(source_dir, "functions")):
        for f in sorted(files):
            if f.endswith(".ps1"):
                with open(os.path.join(root, f), "r", encoding="utf-8") as fh:
                    body_parts.append(fh.read())
                func_count += 1
    print(f"✅ functions/ — {func_count} 个文件")

    # 3. config/*.json → Base64 内嵌
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

    body_parts.append("$sync.configs = @{}\n")
    for name, data in configs.items():
        b64 = base64.b64encode(data.encode("utf-8")).decode("ascii")
        body_parts.append(
            f'$sync.configs.{name} = [System.Text.Encoding]::UTF8.GetString('
            f'[System.Convert]::FromBase64String(\'{b64}\')) | ConvertFrom-Json\n'
        )
    print(f"✅ config/ — {len(configs)} 个文件（Base64 编码）")

    # 4. xaml/inputXML.xaml → Base64
    with open(os.path.join(source_dir, "xaml", "inputXML.xaml"), "rb") as f:
        xaml_bytes = f.read()
    xaml_b64 = base64.b64encode(xaml_bytes).decode("ascii")
    body_parts.append(
        '$inputXML = [System.Text.Encoding]::UTF8.GetString('
        f'[System.Convert]::FromBase64String(\'{xaml_b64}\'))\n'
    )
    print(f"✅ xaml/inputXML.xaml（Base64, {len(xaml_bytes)} 字节原始）")

    # 5. autounattend.xml
    aupath = os.path.join(source_dir, "tools", "autounattend.xml")
    if os.path.exists(aupath):
        with open(aupath, "r", encoding="utf-8") as f:
            autounattend = f.read()
        body_parts.append(f"\n$WinUtilAutounattendXml = @'\n{autounattend}\n'@\n")
        print("✅ tools/autounattend.xml")

    # 6. scripts/main.ps1
    with open(os.path.join(source_dir, "scripts", "main.ps1"), "r", encoding="utf-8") as f:
        body_parts.append(f.read())
    print("✅ scripts/main.ps1")

    # 7. 合并 body，加 UTF-8 BOM → Base64 → 纯 ASCII 输出
    body = "\ufeff" + "\n".join(body_parts)
    body_b64 = base64.b64encode(body.encode("utf-8")).decode("ascii")

    # 纯 ASCII 包装：Base64 → 临时文件 → 点引用执行
    output = (
        "<#\n"
        + ".NOTES\n"
        + "    Author         : Chris Titus @christitustech\n"
        + "    Runspace Author: @DeveloperDurp\n"
        + "    GitHub         : https://github.com/ChrisTitusTech\n"
        + "    Chinese Edition: https://github.com/missyouling/winutil-chinese\n"
        + f"    Version        : {version}\n"
        + ".DESCRIPTION\n"
        + "    This file is Base64-encoded to avoid encoding corruption\n"
        + "    when using `irm | iex` on non-English systems.\n"
        + "#>\n"
        + "# Base64 encoded body => decoded to temp file => dot-sourced\n"
        + "$__b64 = @'\n"
        + body_b64
        + "\n'@\n"
        + "$__temp = [System.IO.Path]::GetTempFileName() + '.ps1'\n"
        + "[System.IO.File]::WriteAllBytes($__temp, [System.Convert]::FromBase64String($__b64))\n"
        + ". $__temp\n"
        + "Remove-Item $__temp -Force\n"
    )

    with open(output_path, "w", encoding="utf-8") as f:
        f.write(output)

    kb = len(output) / 1024
    has_non_ascii = any(ord(c) > 127 for c in output)
    print(f"\n✅ 编译完成！{output_path} ({kb:.1f} KB)")
    print(f"   Body Base64: {len(body_b64)} 字符 ({len(body_b64)*3//4} 字节原始)")
    print(f"   输出文件含非 ASCII 字符: {has_non_ascii}")
    if has_non_ascii:
        # 找出哪些行有非 ASCII 字符
        for i, line in enumerate(output.split("\n"), 1):
            if any(ord(c) > 127 for c in line):
                print(f"   L{i}: {line[:80]}")


if __name__ == "__main__":
    s = sys.argv[1] if len(sys.argv) > 1 else "/opt/data/winutil-zh"
    o = sys.argv[2] if len(sys.argv) > 2 else "/opt/data/winutil-zh/winutil.ps1"
    compile_winutil(s, o)
