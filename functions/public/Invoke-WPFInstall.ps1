function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, choco, or scoop with automatic
        fallback and timeout. If the preferred manager fails (non-zero exit code or
        timeout), the next available manager for that app is tried automatically.
    #>

    $PackagesToInstall = $sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ }

    if($sync.ProcessRunning) {
        $msg = "[安装应用] An安装过程正在进行中。"
        Show-WinUtilMessage -Message $msg -Title "Winutil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToInstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to install or upgrade."
        Show-WinUtilMessage -Message $WarningMsg -Title $AppTitle -Button "OK" -Icon "Warning"
        return
    }

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Install" -Message "Install requested for $(@($PackagesToInstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToInstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Install" -Message "Install selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToInstall", $PackagesToInstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToInstall, $ManagerPreference)

        $totalPackages = @($PackagesToInstall).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Install" -Message "Install packages count: $totalPackages"

        # Build per-package manager order from preference
        # E.g. Winget preference → try winget first, fallback choco, then scoop
        $managerPriority = switch ($ManagerPreference) {
            "Winget" { @("winget", "choco") }
            "Choco"  { @("choco", "winget") }
            default  { @("winget", "choco") }
        }

        try {
            $sync.ProcessRunning = $true
            $failedPackages = [System.Collections.ArrayList]::new()
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            foreach ($package in $PackagesToInstall) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                $installed = $false
                $appName = $package.content
                $lastError = ""

                foreach ($manager in $managerPriority) {
                    # Skip scoop entirely (removed package manager)
                    if ($manager -eq "scoop") { continue }

                    $packageId = $package.$manager
                    if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                        continue
                    }

                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "尝试 $manager 安装 $appName ($position/$totalPackages)" -Percent $startPercent
                    }

                    $currentStatus = "skipped"
                    switch ($manager) {
                        "winget" {
                            Install-WinUtilWinget
                            $process = Start-Process -FilePath winget -ArgumentList @("install", "--id", $packageId, "--accept-package-agreements", "--accept-source-agreements", "--source", "winget", "--silent") -NoNewWindow -PassThru
                            $exited = $process.WaitForExit(300000)  # 5 min timeout
                            if (-not $exited) {
                                $process.Kill()
                                $lastError = "winget:超时"
                            } else {
                                if ($process.ExitCode -eq 0) { $installed = $true; $currentStatus = "ok" }
                                else { $lastError = "winget($($process.ExitCode))" }
                            }
                            Write-WinUtilLog -Component "Package" -Message "Install winget package: $packageId → exit=$($process.ExitCode) installed=$installed"
                        }
                        "choco" {
                            Install-WinUtilChoco
                            $process = Start-Process -FilePath choco -ArgumentList @("install", $packageId, "-y") -NoNewWindow -PassThru
                            $exited = $process.WaitForExit(300000)
                            if (-not $exited) {
                                $process.Kill()
                                $lastError = "choco:超时"
                            } else {
                                if ($process.ExitCode -eq 0) { $installed = $true; $currentStatus = "ok" }
                                else { $lastError = "choco($($process.ExitCode))" }
                            }
                            Write-WinUtilLog -Component "Package" -Message "Install choco package: $packageId → exit=$($process.ExitCode) installed=$installed"
                        }
                    }

                    if ($installed) { break }
                }

                $completedPackages++
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)

                if ($installed) {
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "已安装 $appName ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                } else {
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "安装失败 $appName ($completedPackages/$totalPackages)" -Percent $completedPercent
                    }
                    if ($null -ne $failedPackages) {
                        [void]$failedPackages.Add("$appName ($lastError)")
                    }
                }
            }

            Write-Host "==========================================="
            if ($failedPackages.Count -gt 0) {
                Write-Host "--      安装完成（部分失败）  ---"
                Write-Host "失败 ($($failedPackages.Count)): $($failedPackages -join ', ')"
                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow completed with failures: $($failedPackages -join ', ')"
            } else {
                Write-Host "--      安装已完成          ---"
                Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            }
            Write-Host "==========================================="
            if ($hasUI) {
                if ($failedPackages.Count -gt 0) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "$($sync.configs.strings.msgInstallFinished)（$($failedPackages.Count) 个失败）" -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
                } else {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label $sync.configs.strings.msgInstallFinished -Percent 100
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
                }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "错误: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Install workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        } finally {
            if ($hasUI) {
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $true
                    }
                }
            }
            $sync.ProcessRunning = $False
        }
    }
}
