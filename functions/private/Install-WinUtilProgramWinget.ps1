function Install-WinUtilProgramWinget {
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

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
        $originalId = $program
        if ($program.StartsWith("msstore:", [System.StringComparison]::OrdinalIgnoreCase)) {
            $source = "msstore"
            $program = $program.Substring("msstore:".Length)
        }

        if ($Action -eq 'Install') {
            $arguments = @("install", "--id", $program, "--accept-package-agreements", "--accept-source-agreements", "--source", $source, "--silent")
        } else {
            $arguments = @("uninstall", "--id", $program, "--source", $source, "--silent")
        }

        Write-WinUtilLog -Component "Package" -Message "$Action winget package: $program (source: $source)"
        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -PassThru
        $exited = $process.WaitForExit($TimeoutSeconds * 1000)
        if (-not $exited) {
            $process.Kill()
            Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action winget package TIMEOUT: $program (exceeded ${TimeoutSeconds}s)"
            if ($null -ne $FailedPackages) {
                [void]$FailedPackages.Add("$originalId (winget:超时)")
            }
        } else {
            Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program (exit code: $($process.ExitCode))"
            if ($process.ExitCode -ne 0) {
                Write-WinUtilLog -Level "ERROR" -Component "Package" -Message "$Action winget package failed: $program (exit code: $($process.ExitCode))"
                if ($null -ne $FailedPackages) {
                    [void]$FailedPackages.Add("$originalId (winget)")
                }
            }
        }
    }
}
