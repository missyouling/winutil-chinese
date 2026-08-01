function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs,

        [Parameter(Mandatory=$false)]
        [System.Collections.ArrayList]$FailedPackages = $null,

        [Parameter(Mandatory=$false)]
        [int]$TimeoutSeconds = 300
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -PassThru
    $exited = $process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $exited) {
        $process.Kill()
        Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action choco package(s) TIMEOUT: $($Programs -join ', ') (exceeded ${TimeoutSeconds}s)"
        if ($null -ne $FailedPackages) {
            foreach ($p in $Programs) {
                [void]$FailedPackages.Add("$p (choco:超时)")
            }
        }
    } else {
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
}
