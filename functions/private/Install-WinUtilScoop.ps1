function Install-WinUtilScoop {
    <#
    .SYNOPSIS
        Installs Scoop package manager if not already installed.
        After installation, refreshes PATH so scoop is available immediately
        in the current session without restarting.
    #>
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-WinUtilLog -Component "Scoop" -Message "Scoop not found, installing..."
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        try {
            $webClient = New-Object System.Net.WebClient
            $installerPath = Join-Path $env:TEMP "install-scoop.ps1"
            $download = $webClient.DownloadFileTaskAsync("https://get.scoop.sh", $installerPath)
            if (-not $download.Wait(120000)) {
                $webClient.CancelAsync()
                throw "Scoop installer download timed out after 120 seconds"
            }
            # Run installer
            & $installerPath

            # Refresh PATH from user/machine environment so scoop is available immediately
            $userPath = [System.Environment]::GetEnvironmentVariable("Path", "User")
            $machinePath = [System.Environment]::GetEnvironmentVariable("Path", "Machine")
            if ($userPath) { $env:Path = $userPath + ";" + $env:Path }
            if ($machinePath) { $env:Path = $machinePath + ";" + $env:Path }

            # Also check common scoop install paths directly in case PATH refresh didn't pick it up
            if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
                $scoopPaths = @(
                    "$env:USERPROFILE\scoop\shims\scoop.cmd",
                    "$env:USERPROFILE\scoop\shims\scoop.exe",
                    "$env:SCOOP\shims\scoop.cmd",
                    "$env:SCOOP\shims\scoop.exe",
                    "$env:LOCALAPPDATA\scoop\shims\scoop.cmd",
                    "$env:LOCALAPPDATA\scoop\shims\scoop.exe"
                )
                foreach ($sp in $scoopPaths) {
                    if (Test-Path $sp) {
                        $scoopDir = Split-Path $sp -Parent
                        $env:Path = "$scoopDir;$env:Path"
                        break
                    }
                }
            }

            if (Get-Command scoop -ErrorAction SilentlyContinue) {
                Write-WinUtilLog -Component "Scoop" -Message "Scoop installed successfully"
            } else {
                Write-WinUtilLog -Level "ERROR" -Component "Scoop" -Message "Scoop 安装后未找到 scoop 命令。请尝试重启终端后手动安装。"
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Scoop" -Message "Scoop install failed: $_"
            Write-WinUtilLog -Level "ERROR" -Component "Scoop" -Message "Scoop 安装失败。将继续尝试其他包管理器。"
        }
    } else {
        Write-WinUtilLog -Component "Scoop" -Message "Scoop already installed"
    }
}
