function Install-WinUtilProgramScoop {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs,

        [Parameter(Mandatory=$false)]
        [System.Collections.ArrayList]$FailedPackages = $null
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs"
    } else {
        $arguments = "uninstall $Programs"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action scoop package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath scoop -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action scoop package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
    if ($process.ExitCode -ne 0) {
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action scoop package(s) failed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
        if ($null -ne $FailedPackages) {
            foreach ($p in $Programs) {
                [void]$FailedPackages.Add("$p (scoop)")
            }
        }
    }
}
