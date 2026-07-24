function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "已成功卸载 CTT PowerShell 配置文件。" -ForegroundColor Green
}
