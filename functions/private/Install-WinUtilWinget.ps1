function Install-WinUtilWinget {
    <#

    .SYNOPSIS
        Installs WinGet if not already installed.

    .DESCRIPTION
        installs winGet if needed
    #>
    if ((Test-WinUtilPackageManager -winget) -eq "installed") {
        return
    }

    Write-Host "WinGet 未安装。正在安装..." -ForegroundColor Red

    Install-PackageProvider -Name NuGet -Force
    Install-Module -Name Microsoft.WinGet.Client -Force
    Repair-WinGetPackageManager -AllUsers
}
