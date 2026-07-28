function Install-WinUtilScoop {
    <#
    .SYNOPSIS
        Installs Scoop package manager if not already installed.
        Uses a 120-second timeout to prevent hanging on network issues.
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
            & $installerPath
            if (Get-Command scoop -ErrorAction SilentlyContinue) {
                Write-WinUtilLog -Component "Scoop" -Message "Scoop installed successfully"
            } else {
                throw "Scoop installation completed but scoop command not found"
            }
        } catch {
            Write-WinUtilLog -Level "ERROR" -Component "Scoop" -Message "Scoop install failed: $_"
            throw "Scoop 安装失败: $_"
        }
    } else {
        Write-WinUtilLog -Component "Scoop" -Message "Scoop already installed"
    }
}
