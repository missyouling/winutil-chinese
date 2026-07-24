function Invoke-WinUtilInstallPSProfile {
    if (-not (Get-Command wt)) {
        Write-Host "未找到 Windows Terminal。正在安装..."
        Install-WinUtilWinget
        winget install Microsoft.WindowsTerminal --source winget --silent
    }

    if (-not (Get-Command pwsh)) {
        Write-Host "未找到 PowerShell 7。正在安装..."
        Install-WinUtilWinget
        winget install Microsoft.PowerShell --source winget --installer-type wix --silent
    }

    wt new-tab pwsh -NoExit -Command "irm https://github.com/ChrisTitusTech/powershell-profile/raw/main/setup.ps1 | iex"
}
