function Install-WinUtilScoop {
    <#
    .SYNOPSIS
        Installs Scoop package manager if not already installed
    #>
    if (-not (Get-Command scoop -ErrorAction SilentlyContinue)) {
        Write-WinUtilLog -Component "Scoop" -Message "Scoop not found, installing..."
        Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser -Force
        Invoke-RestMethod -Uri https://get.scoop.sh | Invoke-Expression
        Write-WinUtilLog -Component "Scoop" -Message "Scoop installed successfully"
    } else {
        Write-WinUtilLog -Component "Scoop" -Message "Scoop already installed"
    }
}
