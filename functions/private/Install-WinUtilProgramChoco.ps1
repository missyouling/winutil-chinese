function Install-WinUtilProgramChoco {
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
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
    if ($process.ExitCode -ne 0) {
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action choco package(s) failed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
        if ($null -ne $FailedPackages) {
            foreach ($p in $Programs) {
                [void]$FailedPackages.Add("$p (choco)")
            }
        }
    }
}
