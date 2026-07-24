<#
.NOTES
    Author         : Chris Titus @christitustech
    Runspace Author: @DeveloperDurp
    GitHub         : https://github.com/ChrisTitusTech
    Version        : 26.07.24
#>

param (
    [string]$Config,
    [ValidateSet("Standard", "Minimal", "Advanced", "")]
    [string]$Preset,
    [switch]$Offline
)

$PARAM_OFFLINE = $false
if ($Offline) {
    $PARAM_OFFLINE = $true
}

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host "WinUtil 无法在您的系统上运行。PowerShell 执行被安全策略限制。" -ForegroundColor Red
    return
}

if (!([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Output "WinUtil 需要以管理员身份运行。正在尝试重新启动。"
    $argList = @()

    $PSBoundParameters.GetEnumerator() | ForEach-Object {
        $argList += if ($_.Value -is [switch] -and $_.Value) {
            "-$($_.Key)"
        } elseif ($_.Value -is [array]) {
            "-$($_.Key) $($_.Value -join ',')"
        } elseif ($_.Value) {
            "-$($_.Key) '$($_.Value)'"
        }
    }

    $script = if ($PSCommandPath) {
        "& { & `'$($PSCommandPath)`' $($argList -join ' ') }"
    } else {
        "&([ScriptBlock]::Create((irm https://github.com/ChrisTitusTech/winutil/releases/latest/download/winutil.ps1))) $($argList -join ' ')"
    }

    $powershellCmd = if (Get-Command pwsh -ErrorAction SilentlyContinue) { "pwsh" } else { "powershell" }
    $processCmd = if (Get-Command wt.exe -ErrorAction SilentlyContinue) { "wt.exe" } else { "$powershellCmd" }

    if ($processCmd -eq "wt.exe") {
        Start-Process $processCmd -ArgumentList "$powershellCmd -ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    } else {
        Start-Process $processCmd -ArgumentList "-ExecutionPolicy Bypass -NoProfile -Command `"$script`"" -Verb RunAs
    }

    break
}

# Variable to sync between runspaces
$sync = [Hashtable]::Synchronized(@{})
$sync.version = "26.07.24"
$sync.configs = @{}
$sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
$sync.preferences = @{}
$sync.ProcessRunning = $false
$sync.Win11ISOProcessRunning = $false
$sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
$sync.selectedApps = [System.Collections.Generic.List[string]]::new()
$sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
$sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
$sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()
$sync.currentTab = "Install"

$dateTime = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$winutildir = "$env:LocalAppData\winutil"
$sync.winutildir = $winutildir

$logdir = "$winutildir\logs"
$sync.logPath = "$logdir\winutil_$dateTime.log"
$sync.transcriptPath = $sync.logPath
Start-Transcript -Path $sync.logPath -Append -NoClobber | Out-Null

$Host.UI.RawUI.WindowTitle = "WinUtil"
Clear-Host

function Initialize-WPFUI {
    [OutputType([void])]
    param(
        [Parameter(Mandatory)]
        [string]$TargetGridName
    )

    switch ($TargetGridName) {
        "appscategory"{
            # TODO
            # Switch UI generation of the sidebar to this function
            # $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            # ...

            # Create and configure a popup for displaying selected apps
            $selectedAppsPopup = New-Object Windows.Controls.Primitives.Popup
            $selectedAppsPopup.IsOpen = $false
            $selectedAppsPopup.PlacementTarget = $sync.WPFselectedAppsButton
            $selectedAppsPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $selectedAppsPopup.AllowsTransparency = $true

            # Style the popup with a border and background
            $selectedAppsBorder = New-Object Windows.Controls.Border
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "MainBackgroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderBrushProperty, "MainForegroundColor")
            $selectedAppsBorder.SetResourceReference([Windows.Controls.Control]::BorderThicknessProperty, "ButtonBorderThickness")
            $selectedAppsBorder.Width = 200
            $selectedAppsBorder.Padding = 5
            $selectedAppsPopup.Child = $selectedAppsBorder
            $sync.selectedAppsPopup = $selectedAppsPopup

            # Add a stack panel inside the popup's border to organize its child elements
            $sync.selectedAppsstackPanel = New-Object Windows.Controls.StackPanel
            $selectedAppsBorder.Child = $sync.selectedAppsstackPanel

            # Close selectedAppsPopup when mouse leaves both button and selectedAppsPopup
            $sync.WPFselectedAppsButton.Add_MouseLeave({
                if (-not $sync.selectedAppsPopup.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })
            $selectedAppsPopup.Add_MouseLeave({
                if (-not $sync.WPFselectedAppsButton.IsMouseOver) {
                    $sync.selectedAppsPopup.IsOpen = $false
                }
            })

            # Creates the popup that is displayed when the user right-clicks on an app entry
            # This popup contains buttons for installing, uninstalling, and viewing app information

            $appPopup = New-Object Windows.Controls.Primitives.Popup
            $appPopup.StaysOpen = $false
            $appPopup.Placement = [System.Windows.Controls.Primitives.PlacementMode]::Bottom
            $appPopup.AllowsTransparency = $true
            # Store the popup globally so the position can be set later
            $sync.appPopup = $appPopup

            $appPopupStackPanel = New-Object Windows.Controls.StackPanel
            $appPopupStackPanel.Orientation = "Horizontal"
            $appPopupStackPanel.Add_MouseLeave({
                $sync.appPopup.IsOpen = $false
            })
            $appPopup.Child = $appPopupStackPanel

            $appButtons = @(
            [PSCustomObject]@{ Name = "Install";    Icon = [char]0xE118 },
            [PSCustomObject]@{ Name = "Uninstall";  Icon = [char]0xE74D },
            [PSCustomObject]@{ Name = "Info";       Icon = [char]0xE946 }
            )
            foreach ($button in $appButtons) {
                $newButton = New-Object Windows.Controls.Button
                $newButton.Style = $sync.Form.Resources.AppEntryButtonStyle
                $newButton.Content = $button.Icon
                $appPopupStackPanel.Children.Add($newButton) | Out-Null

                # Dynamically load the selected app object so the buttons can be reused and do not need to be created for each app
                switch ($button.Name) {
                    "Install" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Install or Upgrade $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFInstall -PackagesToInstall $appObject
                        })
                    }
                    "Uninstall" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Uninstall $($appObject.content)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Invoke-WPFUnInstall -PackagesToUninstall $appObject
                        })
                    }
                    "Info" {
                        $newButton.Add_MouseEnter({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            $this.ToolTip = "Open the application's website in your default browser`n$($appObject.link)"
                        })
                        $newButton.Add_Click({
                            $appObject = $sync.configs.applicationsHashtable.$($sync.appPopupSelectedApp)
                            Start-Process $appObject.link
                        })
                    }
                }
            }
        }
        "appspanel" {
            $sync.ItemsControl = Initialize-InstallAppArea -TargetElement $TargetGridName
            Initialize-InstallCategoryAppList -TargetElement $sync.ItemsControl -Apps $sync.configs.applicationsHashtable
        }
        default {
            Write-Output "$TargetGridName not yet implemented"
        }
    }
}


function Invoke-WPFAppxInstall {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX install for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 100)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }
                Write-Host "正在安装 $($app.Content)"
                Install-WinUtilAPPX -Name $app.PackageId -StoreId $app.StoreId

                $completedPercent = [int](($position / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            Write-Host "================================="
            Write-Host "--   AppX 安装完成   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX install finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX 安装完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX install failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFAppxRemoval {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "An AppX process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    if ($null -eq $sync.selectedAppx -or $sync.selectedAppx.Count -eq 0) {
        Show-WinUtilMessage -Message "No AppX Package selected" -Title "Error" -Button "OK" -Icon "Error"
        return
    }

    $selected = @($sync.selectedAppx)
    $apps = $sync.configs.appxHashtable

    $sync.ProcessRunning = $true
    Invoke-WPFRunspace -ParameterList @(("selected", $selected), ("apps", $apps)) -ScriptBlock {
        param($selected, $apps)

        $totalPackages = @($selected).Count
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        $packageList = [System.Collections.Generic.List[string]]::new()

        try {
            Write-WinUtilLog -Component "AppX" -Message "Starting AppX removal for $totalPackages selected package(s)."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing AppX removal (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
            }

            for ($index = 0; $index -lt $totalPackages; $index++) {
                $key = $selected[$index]
                $app = $apps[$key]
                $position = $index + 1
                $startPercent = [int](($index / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing $($app.Content) ($position/$totalPackages)" -Percent $startPercent
                }

                if ($key -eq "WPFAppxMicrosoft_XboxGamingOverlay") {
                    # Making sure Game Bar isn't running
                    Write-WinUtilLog -Component "AppX" -Message "Stopping GameBarFTServer before removing Xbox Gaming Overlay."
                    Stop-Process -Name GameBarFTServer -Force -Confirm:$false -ErrorAction SilentlyContinue

                    # This stops annoying ms-gamebar popup when launching games.
                    Write-WinUtilLog -Component "AppX" -Message "Disabling Game DVR capture before removing Xbox Gaming Overlay."
                    Set-ItemProperty -Path HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\GameDVR -Name AppCaptureEnabled -Value 0
                }

                if ($key -eq "WPFAppxMicrosoft_WindowsNotepad") {
                    Write-WinUtilLog -Component "AppX" -Message "Stopping dllhost before removing Notepad."
                    Stop-Process -Name dllhost -Force -Confirm:$false -ErrorAction SilentlyContinue
                }

                Write-Host "正在移除 $($app.Content)"
                Write-WinUtilLog -Component "AppX" -Message "Removing $($app.Content) ($($app.PackageId))."
                Remove-WinUtilAPPX -Name $app.PackageId
                $packageList.Add($app.PackageId)

                if ($key -eq "WPFAppxMSTeams") {
                    # Uninstalls Microsoft Teams Meeting Add-in for Microsoft Office
                    Write-WinUtilLog -Component "AppX" -Message "Uninstalling Microsoft Teams meeting add-in package."
                    Get-Package -Name "Microsoft Teams*" -ErrorAction SilentlyContinue | Uninstall-Package -Force
                }

                $completedPercent = [int](($position / $totalPackages) * 90)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removed $($app.Content) ($position/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }

            if ($packageList.Count -gt 0) {
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Removing provisioned AppX packages" -Percent 90
                }
                Remove-WinUtilProvisionedAPPX -PackageList $packageList.ToArray()
            }

            Write-Host "================================="
            Write-Host "--   AppX 移除完成   ---"
            Write-Host "================================="
            Write-WinUtilLog -Component "AppX" -Message "AppX removal finished."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal finished" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "AppX removal failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX removal failed" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Error" -overlay "warning" }
            }
        }
        finally {
            $sync.ProcessRunning = $false
        }

    }
}

function Invoke-WPFButton {

    <#

    .SYNOPSIS
        Invokes the function associated with the clicked button

    .PARAMETER Button
        The name of the button that was clicked

    #>

    Param ([string]$Button)

    # Use this to get the name of the button
    #[System.Windows.MessageBox]::Show("$Button","Chris Titus Tech's Windows Utility","OK","Info")
    if (-not $sync.ProcessRunning -and -not $sync.Win11ISOProcessRunning) {
        Set-WinUtilTweaksProgressIndicator -Visible $false
    }

    # Check if button is defined in feature config with function or InvokeScript
    if ($sync.configs.feature.$Button) {
        $buttonConfig = $sync.configs.feature.$Button

        # If button has a function defined, call it
        if ($buttonConfig.function) {
            $functionName = $buttonConfig.function
            if (Get-Command $functionName -ErrorAction SilentlyContinue) {
                & $functionName
                return
            }
        }

        # If button has InvokeScript defined, execute the scripts
        if ($buttonConfig.InvokeScript -and $buttonConfig.InvokeScript.Count -gt 0) {
            foreach ($script in $buttonConfig.InvokeScript) {
                if (-not [string]::IsNullOrWhiteSpace($script)) {
                    Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
                }
            }
            return
        }
    }

    # Fallback to hard-coded switch for buttons not in feature.json
    Switch -Wildcard ($Button) {
        "WPFTab?BT" {Invoke-WPFTab $Button}
        "WPFInstall" {Invoke-WPFInstall}
        "WPFUninstall" {Invoke-WPFUnInstall}
        "WPFInstallUpgrade" {Invoke-WPFInstallUpgrade}
        "WPFCollapseAllCategories" {Invoke-WPFToggleAllCategories -Action "Collapse"}
        "WPFExpandAllCategories" {Invoke-WPFToggleAllCategories -Action "Expand"}
        "WPFStandard" {Invoke-WPFPresets "Standard" -checkboxfilterpattern "WPFTweak*"}
        "WPFMinimal" {Invoke-WPFPresets "Minimal" -checkboxfilterpattern "WPFTweak*"}
        "WPFAdvanced" {Invoke-WPFPresets "Advanced" -checkboxfilterpattern "WPFTweak*"}
        "WPFClearTweaksSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFTweak*"}
        "WPFClearInstallSelection" {Invoke-WPFPresets -imported $true -checkboxfilterpattern "WPFInstall*"}
        "WPFtweaksbutton" {Invoke-WPFtweaksbutton}
        "WPFOOSUbutton" {Invoke-WPFOOSU}
        "WPFAddUltPerf" {Invoke-WPFUltimatePerformance -Enable}
        "WPFRemoveUltPerf" {Invoke-WPFUltimatePerformance}
        "WPFundoall" {Invoke-WPFundoall}
        "WPFUpdatesdefault" {Invoke-WPFUpdatesdefault}
        "WPFUpdatesdisable" {Invoke-WPFUpdatesdisable}
        "WPFUpdatessecurity" {Invoke-WPFUpdatessecurity}
        "WPFGetInstalled" {Invoke-WPFGetInstalled -CheckBox "winget"}
        "WPFGetInstalledTweaks" {Invoke-WPFGetInstalled -CheckBox "tweaks"}
        "WPFAppxRemoval" {Invoke-WPFTab "WPFTab6BT"}
        "WPFBackToTweaks" {Invoke-WPFTab "WPFTab2BT"}
        "WPFInstallSelectedAppx" {Invoke-WPFAppxInstall}
        "WPFRemoveSelectedAppx" {Invoke-WPFAppxRemoval}
        "WPFDefaultAppxSelection" {Invoke-WPFPresets "AppxDefault" -checkboxfilterpattern "WPFAppx*"}
        "WPFSelectAllAppx" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $true}
        }
        "WPFClearAppxSelection" {
            $sync.configs.appxHashtable.Keys | ForEach-Object {$sync.$_.IsChecked = $false}
        }
        "WPFGetInstalledAppx" {
            $installedAppxPackages = Get-WinUtilInstalledAPPX
            foreach ($appx in $sync.configs.appxHashtable.GetEnumerator()) {
                if ($appx.Value.PackageId -in $installedAppxPackages) {
                    $sync.$($appx.Key).IsChecked = $true
                }
            }
        }
        "WPFCloseButton" {$sync.Form.Close(); Write-Host "再见！"}
        "WPFMinimizeButton" {$sync.Form.WindowState = [Windows.WindowState]::Minimized}
        "WPFMaximizeButton" {
            if ($sync.Form.WindowState -eq [Windows.WindowState]::Normal) {
                $sync.Form.WindowState = [Windows.WindowState]::Maximized
            } else {
                $sync.Form.WindowState = [Windows.WindowState]::Normal
            }
        }
        "WPFselectedAppsButton" {$sync.selectedAppsPopup.IsOpen = -not $sync.selectedAppsPopup.IsOpen}
    }
}

function Invoke-WPFFeatureInstall {
    <#

    .SYNOPSIS
        Installs selected Windows Features

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFFeatureInstall]安装过程正在进行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ScriptBlock {
        $Features = $sync.selectedFeatures
        $sync.ProcessRunning = $true
        if ($Features.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }

        $x = 0

        $Features | ForEach-Object {
            Invoke-WinUtilFeatureInstall $_
            $X++
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($x/$Features.Count) }
        }

        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }

        Write-Host "==================================="
        Write-Host "---   功能已安装    ---"
        Write-Host "---  可能需要重启  ---"
        Write-Host "==================================="
    }
}

function Invoke-WPFFixesNTPPool {
    <#
    .SYNOPSIS
        Configures Windows to use pool.ntp.org for NTP synchronization

    .DESCRIPTION
        Replaces the default Windows NTP server (time.windows.com) with
        pool.ntp.org for improved time synchronization accuracy and reliability.
    #>

    Start-Service w32time
    w32tm /config /update /manualpeerlist:"pool.ntp.org,0x8" /syncfromflags:MANUAL

    Restart-Service w32time
    w32tm /resync

    Write-Host "================================="
    Write-Host "-- NTP 配置完成 ---"
    Write-Host "================================="
}

function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "网络配置已重置。请重新启动计算机。"
}

function Invoke-WPFFixesUpdate {

    <#

    .SYNOPSIS
        Performs various tasks in an attempt to repair Windows Update

    .DESCRIPTION
        1. (Aggressive Only) Scans the system for corruption using the Invoke-WPFSystemRepair function
        2. Stops Windows Update Services
        3. Remove the QMGR Data file, which stores BITS jobs
        4. (Aggressive Only) Renames the DataStore and CatRoot2 folders
            DataStore - Contains the Windows Update History and Log Files
            CatRoot2 - Contains the Signatures for Windows Update Packages
        5. Renames the Windows Update Download Folder
        6. Deletes the Windows Update Log
        7. (Aggressive Only) Resets the Security Descriptors on the Windows Update Services
        8. Reregisters the BITS and Windows Update DLLs
        9. Removes the WSUS client settings
        10. Resets WinSock
        11. Gets and deletes all BITS jobs
        12. Sets the startup type of the Windows Update Services then starts them
        13. Forces Windows Update to check for updates

    .PARAMETER Aggressive
        If specified, the script will take additional steps to repair Windows Update that are more dangerous, take a significant amount of time, or are generally unnecessary

    #>

    param($Aggressive = $false)

    Write-Progress -Id 0 -Activity "Repairing Windows Update" -PercentComplete 0
    Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
    Write-Host "正在修复 Windows 更新..."
    # Wait for the first progress bar to show, otherwise the second one won't show
    Start-Sleep -Milliseconds 200

    if ($Aggressive) {
        Invoke-WPFSystemRepair
    }


    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Stopping Windows Update Services..." -PercentComplete 10
    # Stop the Windows Update Services
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping BITS..." -PercentComplete 0
    Stop-Service -Name BITS -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping wuauserv..." -PercentComplete 20
    Stop-Service -Name wuauserv -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping appidsvc..." -PercentComplete 40
    Stop-Service -Name appidsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Stopping cryptsvc..." -PercentComplete 60
    Stop-Service -Name cryptsvc -Force
    Write-Progress -Id 2 -ParentId 0 -Activity "Stopping Services" -Status "Completed" -PercentComplete 100


    # Remove the QMGR Data file
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Renaming/Removing Files..." -PercentComplete 20
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing QMGR Data files..." -PercentComplete 0
    Remove-Item "$env:allusersprofile\Application Data\Microsoft\Network\Downloader\qmgr*.dat" -ErrorAction SilentlyContinue


    if ($Aggressive) {
        # Rename the Windows Update Log and Signature Folders
        Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Log, Download, and Signature Folder..." -PercentComplete 20
        Rename-Item $env:systemroot\SoftwareDistribution\DataStore DataStore.bak -ErrorAction SilentlyContinue
        Rename-Item $env:systemroot\System32\Catroot2 catroot2.bak -ErrorAction SilentlyContinue
    }

    # Rename the Windows Update Download Folder
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Renaming the Windows Update Download Folder..." -PercentComplete 20
    Rename-Item $env:systemroot\SoftwareDistribution\Download Download.bak -ErrorAction SilentlyContinue

    # Delete the legacy Windows Update Log
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Removing the old Windows Update log..." -PercentComplete 80
    Remove-Item $env:systemroot\WindowsUpdate.log -ErrorAction SilentlyContinue
    Write-Progress -Id 3 -ParentId 0 -Activity "Renaming/Removing Files" -Status "Completed" -PercentComplete 100


    if ($Aggressive) {
        # Reset the Security Descriptors on the Windows Update Services
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting the WU Service Security Descriptors..." -PercentComplete 25
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the BITS Security Descriptor..." -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "bits", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Resetting the wuauserv Security Descriptor..." -PercentComplete 50
        Start-Process -NoNewWindow -FilePath "sc.exe" -ArgumentList "sdset", "wuauserv", "D:(A;;CCLCSWRPWPDTLOCRRC;;;SY)(A;;CCDCLCSWRPWPDTLOCRSDRCWDWO;;;BA)(A;;CCLCSWLOCRRC;;;AU)(A;;CCLCSWRPWPDTLOCRRC;;;PU)" -Wait
        Write-Progress -Id 4 -ParentId 0 -Activity "Resetting the WU Service Security Descriptors" -Status "Completed" -PercentComplete 100
    }


    # Reregister the BITS and Windows Update DLLs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Reregistering DLLs..." -PercentComplete 40
    $oldLocation = Get-Location
    Set-Location $env:systemroot\system32
    $i = 0
    $DLLs = @(
        "atl.dll", "urlmon.dll", "mshtml.dll", "shdocvw.dll", "browseui.dll",
        "jscript.dll", "vbscript.dll", "scrrun.dll", "msxml.dll", "msxml3.dll",
        "msxml6.dll", "actxprxy.dll", "softpub.dll", "wintrust.dll", "dssenh.dll",
        "rsaenh.dll", "gpkcsp.dll", "sccbase.dll", "slbcsp.dll", "cryptdlg.dll",
        "oleaut32.dll", "ole32.dll", "shell32.dll", "initpki.dll", "wuapi.dll",
        "wuaueng.dll", "wuaueng1.dll", "wucltui.dll", "wups.dll", "wups2.dll",
        "wuweb.dll", "qmgr.dll", "qmgrprxy.dll", "wucltux.dll", "muweb.dll", "wuwebv.dll"
    )
    foreach ($dll in $DLLs) {
        Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Registering $dll..." -PercentComplete ($i / $DLLs.Count * 100)
        $i++
        Start-Process -NoNewWindow -FilePath "regsvr32.exe" -ArgumentList "/s", $dll
    }
    Set-Location $oldLocation
    Write-Progress -Id 5 -ParentId 0 -Activity "Reregistering DLLs" -Status "Completed" -PercentComplete 100


    # Remove the WSUS client settings
    if (Test-Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate") {
        Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing WSUS client settings..." -PercentComplete 60
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -PercentComplete 0
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "AccountDomainSid", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "PingID", "/f" -RedirectStandardError "NUL"
        Start-Process -NoNewWindow -FilePath "REG" -ArgumentList "DELETE", "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate", "/v", "SusClientId", "/f" -RedirectStandardError "NUL"
        Write-Progress -Id 6 -ParentId 0 -Activity "Removing WSUS client settings" -Status "Completed" -PercentComplete 100
    }

    # Remove Group Policy Windows Update settings
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Removing Group Policy Windows Update settings..." -PercentComplete 60
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -PercentComplete 0
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "正在默认通过 Windows 更新提供驱动..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" -Name "ExcludeWUDriversInQualityUpdate" -ErrorAction SilentlyContinue
    Write-Host "正在默认 Windows 更新自动重启..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoRebootWithLoggedOnUsers" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUPowerManagement" -ErrorAction SilentlyContinue
    Write-Host "正在清除所有 Windows 更新策略设置..."
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "BranchReadinessLevel" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferFeatureUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings" -Name "DeferQualityUpdatesPeriodInDays" -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Microsoft\WindowsSelfHost" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Policies" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\WindowsStore\WindowsUpdate" -Recurse -Force -ErrorAction SilentlyContinue
    Start-Process -NoNewWindow -FilePath "secedit" -ArgumentList "/configure", "/cfg", "$env:windir\inf\defltbase.inf", "/db", "defltbase.sdb", "/verbose" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicyUsers" -Wait
    Start-Process -NoNewWindow -FilePath "cmd.exe" -ArgumentList "/c RD /S /Q $env:WinDir\System32\GroupPolicy" -Wait
    Start-Process -NoNewWindow -FilePath "gpupdate" -ArgumentList "/force" -Wait
    Write-Progress -Id 7 -ParentId 0 -Activity "Removing Group Policy Windows Update settings" -Status "Completed" -PercentComplete 100


    # Reset WinSock
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Resetting WinSock..." -PercentComplete 65
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Resetting WinSock..." -PercentComplete 0
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winsock", "reset"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "winhttp", "reset", "proxy"
    Start-Process -NoNewWindow -FilePath "netsh" -ArgumentList "int", "ip", "reset"
    Write-Progress -Id 7 -ParentId 0 -Activity "Resetting WinSock" -Status "Completed" -PercentComplete 100


    # Get and delete all BITS jobs
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Deleting BITS jobs..." -PercentComplete 75
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Deleting BITS jobs..." -PercentComplete 0
    Get-BitsTransfer | Remove-BitsTransfer
    Write-Progress -Id 8 -ParentId 0 -Activity "Deleting BITS jobs" -Status "Completed" -PercentComplete 100


    # Change the startup type of the Windows Update Services and start them
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Starting Windows Update Services..." -PercentComplete 90
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting BITS..." -PercentComplete 0
    Get-Service BITS | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting wuauserv..." -PercentComplete 25
    Get-Service wuauserv | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting AppIDSvc..." -PercentComplete 50
    # The AppIDSvc service is protected, so the startup type has to be changed in the registry
    Set-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Services\AppIDSvc" -Name "Start" -Value "3" # Manual
    Start-Service AppIDSvc
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Starting CryptSvc..." -PercentComplete 75
    Get-Service CryptSvc | Set-Service -StartupType Manual -PassThru | Start-Service
    Write-Progress -Id 9 -ParentId 0 -Activity "Starting Windows Update Services" -Status "Completed" -PercentComplete 100


    # Force Windows Update to check for updates
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Forcing discovery..." -PercentComplete 95
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Forcing discovery..." -PercentComplete 0
    try {
        (New-Object -ComObject Microsoft.Update.AutoUpdate).DetectNow()
    } catch {
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
        Write-Warning "Failed to create Windows Update COM object: $_"
    }
    Start-Process -NoNewWindow -FilePath "wuauclt" -ArgumentList "/resetauthorization", "/detectnow"
    Write-Progress -Id 10 -ParentId 0 -Activity "Forcing discovery" -Status "Completed" -PercentComplete 100
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Status "Completed" -PercentComplete 100

    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"

    $ButtonType = [System.Windows.MessageBoxButton]::OK
    $MessageboxTitle = "Reset Windows Update "
    $Messageboxbody = ("Stock settings loaded.`n Please reboot your computer")
    $MessageIcon = [System.Windows.MessageBoxImage]::Information

    [System.Windows.MessageBox]::Show($Messageboxbody, $MessageboxTitle, $ButtonType, $MessageIcon)
    Write-Host "==============================================="
    Write-Host "-- 将所有 Windows 更新设置重置为默认 -"
    Write-Host "==============================================="

    # Remove the progress bars
    Write-Progress -Id 0 -Activity "Repairing Windows Update" -Completed
    Write-Progress -Id 1 -Activity "Scanning for corruption" -Completed
    Write-Progress -Id 2 -Activity "Stopping Services" -Completed
    Write-Progress -Id 3 -Activity "Renaming/Removing Files" -Completed
    Write-Progress -Id 4 -Activity "Resetting the WU Service Security Descriptors" -Completed
    Write-Progress -Id 5 -Activity "Reregistering DLLs" -Completed
    Write-Progress -Id 6 -Activity "Removing Group Policy Windows Update settings" -Completed
    Write-Progress -Id 7 -Activity "Resetting WinSock" -Completed
    Write-Progress -Id 8 -Activity "Deleting BITS jobs" -Completed
    Write-Progress -Id 9 -Activity "Starting Windows Update Services" -Completed
    Write-Progress -Id 10 -Activity "Forcing discovery" -Completed
}

function Invoke-WPFFixesWinget {

    <#

    .SYNOPSIS
        Fixes WinGet by running `choco install winget`
    .DESCRIPTION
        BravoNorris for the fantastic idea of a button to reinstall WinGet
    #>
    # Install Choco if not already present
    try {
        Set-WinUtilTaskbaritem -state "Indeterminate" -overlay "logo"
        Write-Host "==> Starting WinGet Repair"
        Install-WinUtilWinget
    } catch {
        Write-Error "Failed to install WinGet: $_"
        Set-WinUtilTaskbaritem -state "Error" -overlay "warning"
    } finally {
        Write-Host "==> Finished WinGet Repair"
        Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
    }

}

function Invoke-WPFGetInstalled {
    <#
    .SYNOPSIS
        Invokes the function that gets the checkboxes to check in a new runspace

    .PARAMETER checkbox
        Indicates whether to check for installed 'winget' programs or applied 'tweaks'

    #>
    param($checkbox)
    if ($sync.ProcessRunning) {
        $msg = "[Invoke-WPFGetInstalled]安装过程正在进行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    if (($sync.ChocoRadioButton.IsChecked -eq $false) -and ((Test-WinUtilPackageManager -winget) -eq "not-installed") -and $checkbox -eq "winget") {
        return
    }
    $managerPreference = $sync.preferences.packagemanager
    $operation = [Hashtable]::Synchronized(@{
        Checkboxes = @()
        Error = $null
    })
    $completeAction = [Action[hashtable, string]]{
        param(
            [hashtable]$completedOperation,
            [string]$completedCheckbox
        )
        try {
            if ($completedOperation.Error) {
                Write-WinUtilLog -Level "ERROR" -Component "Install" -Message "Get installed state failed: $($completedOperation.Error)"
                Write-Warning "Unable to get installed state: $($completedOperation.Error)"
                return
            }

            if ($completedCheckbox -eq "winget") {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    if (-not $sync.selectedApps.Contains($checkboxName)) {
                        $sync.selectedApps.Add($checkboxName)
                    }
                }
                Reset-WPFCheckBoxes -checkboxfilterpattern "WPFInstall*"
            } else {
                foreach ($checkboxName in $completedOperation.Checkboxes) {
                    $sync.$checkboxName.ischecked = $True
                }
            }
        } finally {
            $sync.ProcessRunning = $false
            Set-WinUtilTaskbaritem -state "None"
        }
    }

    $sync.ProcessRunning = $true
    Set-WinUtilTaskbaritem -state "Indeterminate"
    try {
        Invoke-WPFRunspace -ParameterList @(
            ("managerPreference", $managerPreference),
            ("checkbox", $checkbox),
            ("operation", $operation),
            ("completeAction", $completeAction)
        ) -ScriptBlock {
            param (
                [string]$checkbox,
                [string]$managerPreference,
                [hashtable]$operation,
                [Action[hashtable, string]]$completeAction
            )
            try {
                if ($checkbox -eq "winget") {
                    switch ($managerPreference) {
                        "Choco" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox "choco"); break }
                        "Winget" { $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox); break }
                    }
                } elseif ($checkbox -eq "tweaks") {
                    $operation.Checkboxes = @(Invoke-WinUtilCurrentSystem -CheckBox $checkbox)
                }
            } catch {
                $operation.Error = $_.Exception.Message
            } finally {
                $sync.Form.Dispatcher.BeginInvoke($completeAction, [object[]]@($operation, $checkbox)) | Out-Null
            }
        }
    } catch {
        $operation.Error = $_.Exception.Message
        $completeAction.Invoke($operation, $checkbox)
    }
}

function Invoke-WPFImpex {
    <#

    .SYNOPSIS
        Handles importing and exporting of the checkboxes checked for the tweaks section

    .PARAMETER type
        Indicates whether to 'import' or 'export'

    .PARAMETER checkbox
        The checkbox to export to a file or apply the imported file to

    .EXAMPLE
        Invoke-WPFImpex -type "export"

    #>
    param(
        $type,
        $Config = $null
    )

    function ConfigDialog {
        if (!$Config) {
            switch ($type) {
                "export" { $FileBrowser = New-Object System.Windows.Forms.SaveFileDialog }
                "import" { $FileBrowser = New-Object System.Windows.Forms.OpenFileDialog }
            }
            $FileBrowser.InitialDirectory = [Environment]::GetFolderPath('Desktop')
            $FileBrowser.Filter = "JSON Files (*.json)|*.json"
            $FileBrowser.ShowDialog() | Out-Null

            if ($FileBrowser.FileName -eq "") {
                return $null
            } else {
                return $FileBrowser.FileName
            }
        } else {
            return $Config
        }
    }

    switch ($type) {
        "export" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    $allConfs = ($sync.selectedApps + $sync.selectedTweaks + $sync.selectedToggles + $sync.selectedFeatures + $sync.selectedAppx) | ForEach-Object { [string]$_ }
                    if (-not $allConfs) {
                        [System.Windows.MessageBox]::Show(
                            "No settings are selected to export. Please select at least one app, tweak, toggle, feature, or AppX package before exporting.",
                            "Nothing to Export", "OK", "Warning")
                        return
                    }
                    $jsonFile = $allConfs | ConvertTo-Json
                    $jsonFile | Out-File $Config -Force
                    "iex ""& { `$(irm https://christitus.com/win) } -Config '$Config'""" | Set-Clipboard
                }
            } catch {
                Write-Error "An error occurred while exporting: $_"
            }
        }
        "import" {
            try {
                $Config = ConfigDialog
                if ($Config) {
                    try {
                        if ($Config -match '^https?://') {
                            $jsonFile = (Invoke-WebRequest "$Config").Content | ConvertFrom-Json
                        } else {
                            $jsonFile = Get-Content $Config | ConvertFrom-Json
                        }
                    } catch {
                        Write-Error "Failed to load the JSON file from the specified path or URL: $_"
                        return
                    }
                    # TODO how to handle old style? detected json type then flatten it in a func?
                    # $flattenedJson = $jsonFile.PSObject.Properties.Where({ $_.Name -ne "Install" }).ForEach({ $_.Value })
                    $flattenedJson = $jsonFile

                    if (-not $flattenedJson) {
                        [System.Windows.MessageBox]::Show(
                            "The selected file contains no settings to import. No changes have been made.",
                            "Empty Configuration", "OK", "Warning")
                        return
                    }

                    # Clear all existing selections before importing so the import replaces
                    # the current state rather than merging with it
                    $sync.selectedAppx = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedApps = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedToggles = [System.Collections.Generic.List[string]]::new()
                    $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new()

                    Update-WinUtilSelections -flatJson $flattenedJson

                    if ($sync.Form) {
                        Reset-WPFCheckBoxes -doToggles $true
                    }
                }
            } catch {
                Write-Error "An error occurred while importing: $_"
            }
        }
    }
}

function Invoke-WPFInstall {
    <#
    .SYNOPSIS
        Installs the selected programs using winget, if one or more of the selected programs are already installed on the system, winget will try and perform an upgrade if there's a newer version to install.
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

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToInstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Install" -Message "Install package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app install (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if($packagesWinget.Count -gt 0 -and $packagesWinget -ne "0") {
                Install-WinUtilWinget
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Install -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installing Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilChoco
                Install-WinUtilProgramChoco -Action Install -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Installed Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--      安装已完成          ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Install" -Message "Install workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "应用安装完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
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

function Invoke-WPFInstallUpgrade {
    if ($sync.ChocoRadioButton.IsChecked) {
        Install-WinUtilChoco # Ensure Chocolatey is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList 'choco upgrade all -y'
    } else {
        Install-WinUtilWinget # Ensure WinGet is installed before upgrading

        Write-Host "==========================================="
        Write-Host "--           Updates started            ---"
        Write-Host "-- You can close this window if desired ---"
        Write-Host "==========================================="

        Start-Process -FilePath powershell.exe -ArgumentList '-NoExit winget upgrade --all --include-unknown --silent --accept-source-agreements --accept-package-agreements'
    }
}

function Invoke-WPFOOSU {
    if ($sync.ProcessRunning) {
        Show-WinUtilMessage -Message "Another process is currently running." -Title "WinUtil" -Button "OK" -Icon "Warning"
        return
    }

    $downloadPath = Join-Path $sync.winutildir "ooshutup10.exe"
    $sync.ProcessRunning = $true

    Invoke-WPFRunspace -ParameterList @(,("downloadPath", $downloadPath)) -ScriptBlock {
        param($downloadPath)

        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher

        try {
            Write-WinUtilLog -Component "OOSU" -Message "Downloading O&O ShutUp10++."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ (0%)" -Percent 0
            }

            Save-WinUtilFile -Uri "https://dl5.oo-software.com/files/ooshutup10/OOSU10.exe" -DestinationPath $downloadPath -ProgressCallback {
                param($percent)

                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Downloading O&O ShutUp10++ ($percent%)" -Percent $percent
                }
            }

            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Launching O&O ShutUp10++" -Percent 100
            }
            Start-Process -FilePath $downloadPath

            Write-WinUtilLog -Component "OOSU" -Message "O&O ShutUp10++ launched."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ launched" -Percent 100
            }
        }
        catch {
            Write-WinUtilLog -Level "ERROR" -Component "OOSU" -Message "O&O ShutUp10++ download failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "O&O ShutUp10++ download failed" -Percent 100
            }
            Write-Error "Couldn't download O&O ShutUp10. Please make sure you have an active Internet connection."
        }
        finally {
            $sync.ProcessRunning = $false
        }
    }
}

function Invoke-WPFPanelAutologin {
    Invoke-WebRequest -Uri https://live.sysinternals.com/Autologon.exe -OutFile "$winutildir\autologin.exe"
    Start-Process -FilePath "$winutildir\autologin.exe" -ArgumentList /accepteula
}

function Invoke-WPFPopup {
    param (
        [ValidateSet("Show", "Hide", "Toggle")]
        [string]$Action = "",

        [string[]]$Popups = @(),

        [ValidateScript({
            $invalid = $_.GetEnumerator() | Where-Object { $_.Value -notin @("Show", "Hide", "Toggle") }
            if ($invalid) {
                throw "Found invalid Popup-Action pair(s): " + ($invalid | ForEach-Object { "$($_.Key) = $($_.Value)" } -join "; ")
            }
            $true
        })]
        [hashtable]$PopupActionTable = @{}
    )

    if (-not $PopupActionTable.Count -and (-not $Action -or -not $Popups.Count)) {
        throw "Provide either 'PopupActionTable' or both 'Action' and 'Popups'."
    }

    if ($PopupActionTable.Count -and ($Action -or $Popups.Count)) {
        throw "Use 'PopupActionTable' on its own, or 'Action' with 'Popups'."
    }

    # Collect popups and actions
    $PopupsToProcess = if ($PopupActionTable.Count) {
        $PopupActionTable.GetEnumerator() | ForEach-Object { [PSCustomObject]@{ Name = "$($_.Key)Popup"; Action = $_.Value } }
    } else {
        $Popups | ForEach-Object { [PSCustomObject]@{ Name = "$_`Popup"; Action = $Action } }
    }

    $PopupsNotFound = @()

    # Apply actions
    foreach ($popupEntry in $PopupsToProcess) {
        $popupName = $popupEntry.Name

        if (-not $sync.$popupName) {
            $PopupsNotFound += $popupName
            continue
        }

        $sync.$popupName.IsOpen = switch ($popupEntry.Action) {
            "Show" { $true }
            "Hide" { $false }
            "Toggle" { -not $sync.$popupName.IsOpen }
        }
    }

    if ($PopupsNotFound.Count -gt 0) {
        throw "Could not find the following popups: $($PopupsNotFound -join ', ')"
    }
}

function Invoke-WPFPresets {
    <#

    .SYNOPSIS
        Sets the checkboxes in winutil to the given preset

    .PARAMETER preset
        The preset to set the checkboxes to

    .PARAMETER imported
        If the preset is imported from a file, defaults to false

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"

    #>

    param (
        [Parameter(position=0)]
        [Array]$preset = $null,

        [Parameter(position=1)]
        [bool]$imported = $false,

        [Parameter(position=2)]
        [string]$checkboxfilterpattern = "**"
    )

    if ($imported -eq $true) {
        $CheckBoxesToCheck = $preset
    } else {
        $CheckBoxesToCheck = $sync.configs.preset.$preset
    }

    # clear out the filtered pattern so applying a preset replaces the current
    # state rather than merging with it
    switch ($checkboxfilterpattern) {
        "WPFTweak*" { $sync.selectedTweaks = [System.Collections.Generic.List[string]]::new() }
        "WPFInstall*" { $sync.selectedApps = [System.Collections.Generic.List[string]]::new() }
        "WPFAppx*" { $sync.selectedAppx = [System.Collections.Generic.List[string]]::new() }
        "WPFeatures" { $sync.selectedFeatures = [System.Collections.Generic.List[string]]::new() }
        "WPFToggle" { $sync.selectedToggles = [System.Collections.Generic.List[string]]::new() }
        default {}
    }

    if ($preset) {
        Update-WinUtilSelections -flatJson $CheckBoxesToCheck
    }

    Reset-WPFCheckBoxes -doToggles $false -checkboxfilterpattern $checkboxfilterpattern
}

function Invoke-WPFRunspace {

    <#

    .SYNOPSIS
        Creates and invokes a runspace using the given scriptblock and argumentlist

    .PARAMETER ScriptBlock
        The scriptblock to invoke in the runspace

    .PARAMETER ArgumentList
        A list of arguments to pass to the runspace

    .PARAMETER ParameterList
        A list of named parameters that should be provided.
    .EXAMPLE
        Invoke-WPFRunspace `
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ArgumentList "Installadvancedip,Installbitwarden" `

        Invoke-WPFRunspace`
            -ScriptBlock $sync.ScriptsInstallPrograms `
            -ParameterList @(("PackagesToInstall", @("Installadvancedip,Installbitwarden")),("ChocoPreference", $true))
    #>

    [CmdletBinding()]
    [OutputType([System.IAsyncResult])]
    Param (
        $ScriptBlock,
        $ArgumentList,
        $ParameterList
    )

    if (-not ("WinUtilRunspaceCleanup" -as [type])) {
        Add-Type @"
using System;
using System.Management.Automation;

public sealed class WinUtilRunspaceCleanupState
{
    public PowerShell PowerShell { get; set; }
    public IAsyncResult Handle { get; set; }
}

public static class WinUtilRunspaceCleanup
{
    public static readonly System.Threading.WaitOrTimerCallback Callback = Cleanup;

    public static void Cleanup(object state, bool timedOut)
    {
        var cleanupState = state as WinUtilRunspaceCleanupState;
        if (cleanupState == null || cleanupState.PowerShell == null || cleanupState.Handle == null)
        {
            return;
        }

        try
        {
            cleanupState.PowerShell.EndInvoke(cleanupState.Handle);
        }
        catch
        {
        }
        finally
        {
            cleanupState.PowerShell.Dispose();
        }
    }
}
"@
    }

    Initialize-WinUtilRunspacePool | Out-Null

    # Create a PowerShell instance
    $powershell = [powershell]::Create()

    # Add Scriptblock and Arguments to runspace
    [void]$powershell.AddScript($ScriptBlock)
    [void]$powershell.AddArgument($ArgumentList)

    foreach ($parameter in $ParameterList) {
        [void]$powershell.AddParameter($parameter[0], $parameter[1])
    }

    $powershell.RunspacePool = $sync.runspace

    # Execute the RunspacePool
    $handle = $powershell.BeginInvoke()

    $cleanupState = [WinUtilRunspaceCleanupState]::new()
    $cleanupState.PowerShell = $powershell
    $cleanupState.Handle = $handle
    [System.Threading.ThreadPool]::RegisterWaitForSingleObject($handle.AsyncWaitHandle, [WinUtilRunspaceCleanup]::Callback, $cleanupState, -1, $true) | Out-Null

    # Return the handle
    return $handle
}

function Invoke-WPFSSHServer {
    <#

    .SYNOPSIS
        Invokes the OpenSSH Server install in a runspace

  #>

    Invoke-WPFRunspace -ScriptBlock {

        Invoke-WinUtilSSHServer

        Write-Host "======================================="
        Write-Host "--     OpenSSH Server installed!    ---"
        Write-Host "======================================="
    }
}

function Invoke-WPFSelectedCheckboxesUpdate ($type, $checkboxName) {
    $listName = switch -Regex ($checkboxName) {
        '^WPFInstall' { 'selectedApps' }
        '^WPFTweaks'  { 'selectedTweaks' }
        '^WPFToggle'  { 'selectedToggles' }
        '^WPFFeature' { 'selectedFeatures' }
        '^WPFAppx'    { 'selectedAppx' }
    }

    $selectionChanged = $false
    if ($type -eq "Add") {
        if (-not $sync.$listName.Contains($checkboxName)) {
            $sync.$listName.Add($checkboxName)
            $selectionChanged = $true
        }
    } else {
        $selectionChanged = $sync.$listName.Remove($checkboxName)
    }

    if ($listName -eq "selectedApps" -and $selectionChanged) {
        $sync.WPFselectedAppsButton.Content = "已选应用： $($sync.selectedApps.Count)"
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | ForEach-Object {
            Add-SelectedAppsMenuItem -name $sync.configs.applicationsHashtable.$_.Content -key $_
        }
    }
}

function Invoke-WPFSystemRepair {
    <#
    .SYNOPSIS
        Checks for system corruption using SFC, and DISM
        Checks for disk failure using Chkdsk

    .DESCRIPTION
        1. Chkdsk - Checks for disk errors, which can cause system file corruption and notifies of early disk failure
        2. SFC - scans protected system files for corruption and fixes them
        3. DISM - Repair a corrupted Windows operating system image
    #>

    Start-Process cmd.exe -ArgumentList "/c chkdsk /scan /perf" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c sfc /scannow" -NoNewWindow -Wait
    Start-Process cmd.exe -ArgumentList "/c dism /online /cleanup-image /restorehealth" -NoNewWindow -Wait

    Write-Host "==> Finished System Repair"
    Set-WinUtilTaskbaritem -state "None" -overlay "checkmark"
}

function Invoke-WPFTab {

    <#

    .SYNOPSIS
        Sets the selected tab to the tab that was clicked

    .PARAMETER ClickedTab
        The name of the tab that was clicked

    #>

    Param (
        [Parameter(Mandatory,position=0)]
        [string]$ClickedTab
    )

    $tabNav = Get-WinUtilVariables | Where-Object {$psitem -like "WPFTabNav"}
    $tabNumber = [int]($ClickedTab -replace "WPFTab","" -replace "BT","") - 1

    $filter = Get-WinUtilVariables -Type ToggleButton | Where-Object {$psitem -like "WPFTab?BT"}
    $sync.$tabNav.Items[$tabNumber].IsSelected = $true
    ($sync.GetEnumerator()).where{$psitem.Key -in $filter} | ForEach-Object {
        if ($ClickedTab -ne $PSItem.name) {
            $sync[$PSItem.Name].IsChecked = $false
        } else {
            $sync["$ClickedTab"].IsChecked = $true
        }
    }
    $sync.currentTab = $sync.$tabNav.Items[$tabNumber].Header
    $sync.tabManager = @{ currentTab = $tabNumber }
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Tab indexes: 0=应用安装, 1=系统优化, 2=功能配置, 3=Windows更新, 4=Win11创建工具, 5=AppX移除
    if ($tabNumber -eq 0) {
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($tabNumber -eq 1 -or $tabNumber -eq 5) {
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install(index 0), Tweaks(index 1), and AppX(index 5) tabs
    if ($tabNumber -eq 0 -or $tabNumber -eq 1 -or $tabNumber -eq 5) {
        $sync.SearchBar.Visibility = "Visible"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Visible"
        }
    } else {
        $sync.SearchBar.Visibility = "Collapsed"
        $searchIcon = ($sync.Form.FindName("SearchBar").Parent.Children | Where-Object { $_ -is [System.Windows.Controls.TextBlock] -and $_.Text -eq [char]0xE721 })[0]
        if ($searchIcon) {
            $searchIcon.Visibility = "Collapsed"
        }
        # Hide the clear button if it's visible
        $sync.SearchBarClearButton.Visibility = "Collapsed"
    }
}

function Invoke-WPFToggleAllCategories {
    <#
        .SYNOPSIS
            Expands or collapses all categories in the Install tab

        .PARAMETER Action
            The action to perform: "Expand" or "Collapse"

        .DESCRIPTION
            This function iterates through all category containers in the Install tab
            and expands or collapses their WrapPanels while updating the toggle button labels
    #>

    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet("Expand", "Collapse")]
        [string]$Action
    )

    try {
        if ($null -eq $sync.ItemsControl) {
            Write-Warning "ItemsControl 未初始化"
            return
        }

        $targetVisibility = if ($Action -eq "Expand") { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
        $targetPrefix = if ($Action -eq "Expand") { "-" } else { "+" }
        $sourcePrefix = if ($Action -eq "Expand") { "+" } else { "-" }

        # Iterate through all items in the ItemsControl
        $sync.ItemsControl.Items | ForEach-Object {
            $categoryContainer = $_

            # Check if this is a category container (StackPanel with children)
            if ($categoryContainer -is [System.Windows.Controls.StackPanel] -and $categoryContainer.Children.Count -ge 2) {
                # Get the WrapPanel (second child)
                $wrapPanel = $categoryContainer.Children[1]
                $wrapPanel.Visibility = $targetVisibility

                # Update the label to show the correct state
                $categoryLabel = $categoryContainer.Children[0]
                if ($categoryLabel.Content -like "$sourcePrefix*") {
                    $escapedSourcePrefix = [regex]::Escape($sourcePrefix)
                    $categoryLabel.Content = $categoryLabel.Content -replace "^$escapedSourcePrefix ", "$targetPrefix "
                }
            }
        }
    }
    catch {
        Write-Error "Error toggling categories: $_"
    }
}

function Invoke-WPFUIElements {
    <#
    .SYNOPSIS
        Adds UI elements to a specified Grid in the WinUtil GUI based on a JSON configuration.
    .PARAMETER configVariable
        The variable/link containing the JSON configuration.
    .PARAMETER targetGridName
        The name of the grid to which the UI elements should be added.
    .PARAMETER columncount
        The number of columns to be used in the Grid. If not provided, a default value is used based on the panel.
    .EXAMPLE
        Invoke-WPFUIElements -configVariable $sync.configs.applications -targetGridName "install" -columncount 5
    .NOTES
        Future me/contributor: If possible, please wrap this into a runspace to make it load all panels at the same time.
    #>

    param(
        [Parameter(Mandatory, Position = 0)]
        [PSCustomObject]$configVariable,

        [Parameter(Mandatory, Position = 1)]
        [string]$targetGridName,

        [Parameter(Mandatory, Position = 2)]
        [int]$columncount
    )

    $window = $sync.form

    $borderstyle = $window.FindResource("BorderStyle")
    $HoverTextBlockStyle = $window.FindResource("HoverTextBlockStyle")
    $ColorfulToggleSwitchStyle = $window.FindResource("ColorfulToggleSwitchStyle")
    $ToggleButtonStyle = $window.FindResource("ToggleButtonStyle")

    if (!$borderstyle -or !$HoverTextBlockStyle -or !$ColorfulToggleSwitchStyle) {
        throw "Failed to retrieve Styles using 'FindResource' from main window element."
    }

    $targetGrid = $window.FindName($targetGridName)

    if (!$targetGrid) {
        throw "Failed to retrieve Target Grid by name, provided name: $targetGrid"
    }

    # Clear existing ColumnDefinitions and Children
    $targetGrid.ColumnDefinitions.Clear() | Out-Null
    $targetGrid.Children.Clear() | Out-Null

    # Add ColumnDefinitions to the target Grid
    for ($i = 0; $i -lt $columncount; $i++) {
        $colDef = New-Object Windows.Controls.ColumnDefinition
        $colDef.Width = New-Object Windows.GridLength(1, [Windows.GridUnitType]::Star)
        $targetGrid.ColumnDefinitions.Add($colDef) | Out-Null
    }

    # Convert PSCustomObject to Hashtable
    $configHashtable = @{}
    $configVariable.PSObject.Properties.Name | ForEach-Object {
        $configHashtable[$_] = $configVariable.$_
    }

    $radioButtonGroups = @{}

    $organizedData = @{}
    # Iterate through JSON data and organize by panel and category
    foreach ($entry in $configHashtable.Keys) {
        $entryInfo = $configHashtable[$entry]

        # Create an object for the application
        $entryObject = [PSCustomObject]@{
            Name        = $entry
            Category    = $entryInfo.Category
            Content     = $entryInfo.Content
            Panel       = if ($entryInfo.Panel) { $entryInfo.Panel } else { "0" }
            Link        = $entryInfo.link
            Description = $entryInfo.description
            Type        = $entryInfo.type
            ComboItems  = $entryInfo.ComboItems
            Checked     = $entryInfo.Checked
            ButtonWidth = $entryInfo.ButtonWidth
            GroupName   = $entryInfo.GroupName  # Added for RadioButton groupings
        }

        if (-not $organizedData.ContainsKey($entryObject.Panel)) {
            $organizedData[$entryObject.Panel] = @{}
        }

        if (-not $organizedData[$entryObject.Panel].ContainsKey($entryObject.Category)) {
            $organizedData[$entryObject.Panel][$entryObject.Category] = @()
        }

        # Store application data in an array under the category
        $organizedData[$entryObject.Panel][$entryObject.Category] += $entryObject

    }

    # Initialize panel count
    $panelcount = 0

    # Iterate through 'organizedData' by panel, category, and application
    $count = 0
    foreach ($panelKey in ($organizedData.Keys | Sort-Object)) {
        # Create a Border for each column
        $border = New-Object Windows.Controls.Border
        $border.VerticalAlignment = "Stretch"
        [System.Windows.Controls.Grid]::SetColumn($border, $panelcount)
        $border.style = $borderstyle
        $targetGrid.Children.Add($border) | Out-Null

        # Use a DockPanel to contain the content
        $dockPanelContainer = New-Object Windows.Controls.DockPanel
        $border.Child = $dockPanelContainer

        # Create an ItemsControl for application content
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'

        # Set the ItemsPanel to a VirtualizingStackPanel
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.VirtualizingStackPanel])
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Set virtualization properties
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::IsVirtualizingProperty, $true)
        $itemsControl.SetValue([Windows.Controls.VirtualizingStackPanel]::VirtualizationModeProperty, [Windows.Controls.VirtualizationMode]::Recycling)

        # Add the ItemsControl directly to the DockPanel
        [Windows.Controls.DockPanel]::SetDock($itemsControl, [Windows.Controls.Dock]::Bottom)
        $dockPanelContainer.Children.Add($itemsControl) | Out-Null
        $panelcount++

        # Now proceed with adding category labels and entries to $itemsControl
        foreach ($category in ($organizedData[$panelKey].Keys | Sort-Object)) {
            $count++

            $label = New-Object Windows.Controls.Label
            $label.Content = $category -replace ".*__", ""
            $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $label.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $label.UseLayoutRounding = $true
            $itemsControl.Items.Add($label) | Out-Null
            $sync[$category] = $label

            # Sort entries by type (checkboxes first, then buttons, then comboboxes) and then alphabetically by Content
            $entries = $organizedData[$panelKey][$category] | Sort-Object @{Expression = {
                switch ($_.Type) {
                    'Button' { 1 }
                    'Combobox' { 2 }
                    default { 0 }
                }
            }}, Content
            foreach ($entryInfo in $entries) {
                $count++
                # Create the UI elements based on the entry type
                switch ($entryInfo.Type) {
                    "Toggle" {
                        $dockPanel = New-Object Windows.Controls.DockPanel
                        [System.Windows.Automation.AutomationProperties]::SetName($dockPanel, $entryInfo.Content)
                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.HorizontalAlignment = "Right"
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        $dockPanel.Children.Add($checkBox) | Out-Null
                        $checkBox.Style = $ColorfulToggleSwitchStyle

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.ToolTip = $entryInfo.Description
                        $label.HorizontalAlignment = "Left"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $label.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
                        $label.UseLayoutRounding = $true
                        $dockPanel.Children.Add($label) | Out-Null
                        $itemsControl.Items.Add($dockPanel) | Out-Null

                        $sync[$entryInfo.Name] = $checkBox
                        $sync[$entryInfo.Name].IsChecked = (Get-WinUtilToggleStatus $entryInfo.Name)

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                            # Skip applying tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtilTweaks $Sender.name
                            }
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                            # Skip undoing tweaks while an import is restoring toggle states
                            if (-not $sync.ImportInProgress) {
                                Invoke-WinUtiltweaks $Sender.name -undo $true
                            }
                        })
                    }

                    "ToggleButton" {
                        $toggleButton = New-Object Windows.Controls.Primitives.ToggleButton
                        $toggleButton.Name = $entryInfo.Name
                        $toggleButton.Content = $entryInfo.Content[1]
                        $toggleButton.ToolTip = $entryInfo.Description
                        $toggleButton.HorizontalAlignment = "Left"
                        $toggleButton.Style = $ToggleButtonStyle
                        [System.Windows.Automation.AutomationProperties]::SetName($toggleButton, $entryInfo.Content[0])

                        $toggleButton.Tag = @{
                            contentOn = if ($entryInfo.Content.Count -ge 1) { $entryInfo.Content[0] } else { "" }
                            contentOff = if ($entryInfo.Content.Count -ge 2) { $entryInfo.Content[1] } else { $contentOn }
                        }

                        $itemsControl.Items.Add($toggleButton) | Out-Null

                        $sync[$entryInfo.Name] = $toggleButton

                        $sync[$entryInfo.Name].Add_Checked({
                            $this.Content = $this.Tag.contentOn
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            $this.Content = $this.Tag.contentOff
                        })

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $toggleButton.Name) {
                            $toggleButton.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($toggleButton.Name) | Out-Null
                        }
                    }

                    "Combobox" {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        $horizontalStackPanel.Margin = "0,5,0,0"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $label = New-Object Windows.Controls.Label
                        $label.Content = $entryInfo.Content
                        $label.HorizontalAlignment = "Left"
                        $label.VerticalAlignment = "Center"
                        $label.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $label.UseLayoutRounding = $true
                        $horizontalStackPanel.Children.Add($label) | Out-Null

                        $comboBox = New-Object Windows.Controls.ComboBox
                        $comboBox.Name = $entryInfo.Name
                        $comboBox.SetResourceReference([Windows.Controls.Control]::HeightProperty, "ButtonHeight")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::WidthProperty, "ButtonWidth")
                        $comboBox.HorizontalAlignment = "Left"
                        $comboBox.VerticalAlignment = "Center"
                        $comboBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $comboBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $comboBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($comboBox, $entryInfo.Content)

                        foreach ($comboitem in ($entryInfo.ComboItems -split " ")) {
                            $comboBoxItem = New-Object Windows.Controls.ComboBoxItem
                            $comboBoxItem.Content = $comboitem
                            $comboBoxItem.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                            $comboBoxItem.UseLayoutRounding = $true
                            $comboBox.Items.Add($comboBoxItem) | Out-Null
                        }

                        $horizontalStackPanel.Children.Add($comboBox) | Out-Null
                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null

                        $comboBox.SelectedIndex = 0

                        # Set initial text
                        if ($comboBox.Items.Count -gt 0) {
                            $comboBox.Text = $comboBox.Items[0].Content
                        }

                        # Add SelectionChanged event handler to update the text property
                        $comboBox.Add_SelectionChanged({
                            $selectedItem = $this.SelectedItem
                            if ($selectedItem) {
                                $this.Text = $selectedItem.Content
                            }
                        })

                        $sync[$entryInfo.Name] = $comboBox
                    }

                    "Button" {
                        $button = New-Object Windows.Controls.Button
                        $button.Name = $entryInfo.Name
                        $button.Content = $entryInfo.Content
                        $button.HorizontalAlignment = "Left"
                        $button.SetResourceReference([Windows.Controls.Control]::MarginProperty, "ButtonMargin")
                        $button.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        if ($entryInfo.ButtonWidth) {
                            $baseWidth = [int]$entryInfo.ButtonWidth
                            $button.Width = [math]::Max($baseWidth, 350)
                        }
                        [System.Windows.Automation.AutomationProperties]::SetName($button, $entryInfo.Content)
                        $itemsControl.Items.Add($button) | Out-Null

                        $sync[$entryInfo.Name] = $button

                        if ($null -eq $sync.Buttons) {
                            $sync.Buttons = [System.Collections.Generic.List[PSObject]]::new()
                        }

                        if ($sync.Buttons -notcontains $button.Name) {
                            $button.Add_Click({
                                [System.Object]$Sender = $args[0]
                                Invoke-WPFButton $Sender.name
                            })
                            $sync.Buttons.Add($button.Name) | Out-Null
                        }
                    }

                    "RadioButton" {
                        # Check if a container for this GroupName already exists
                        if (-not $radioButtonGroups.ContainsKey($entryInfo.GroupName)) {
                            # Create a StackPanel for this group
                            $groupStackPanel = New-Object Windows.Controls.StackPanel
                            $groupStackPanel.Orientation = "Vertical"
                            [System.Windows.Automation.AutomationProperties]::SetName($groupStackPanel, $entryInfo.GroupName)

                            # Add the group container to the ItemsControl
                            $itemsControl.Items.Add($groupStackPanel) | Out-Null
                        }
                        else {
                            # Retrieve the existing group container
                            $groupStackPanel = $radioButtonGroups[$entryInfo.GroupName]
                        }

                        # Create the RadioButton
                        $radioButton = New-Object Windows.Controls.RadioButton
                        $radioButton.Name = $entryInfo.Name
                        $radioButton.GroupName = $entryInfo.GroupName
                        $radioButton.Content = $entryInfo.Content
                        $radioButton.HorizontalAlignment = "Left"
                        $radioButton.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $radioButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "ButtonFontSize")
                        $radioButton.ToolTip = $entryInfo.Description
                        $radioButton.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($radioButton, $entryInfo.Content)

                        if ($entryInfo.Checked -eq $true) {
                            $radioButton.IsChecked = $true
                        }

                        # Add the RadioButton to the group container
                        $groupStackPanel.Children.Add($radioButton) | Out-Null
                        $sync[$entryInfo.Name] = $radioButton
                    }

                    "Note" {
                        $textBlock = New-Object Windows.Controls.TextBlock
                        $textBlock.TextWrapping = "Wrap"
                        $textBlock.Margin = "5,5,5,5"
                        $textBlock.UseLayoutRounding = $true

                        $bulletRun = New-Object Windows.Documents.Run
                        $bulletRun.Text = [char]0x25CF
                        $bulletRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
                        $bulletRun.FontSize = 11.5

                        $textRun = New-Object Windows.Documents.Run
                        $textRun.Text = " $($entryInfo.Content)"
                        $textRun.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $textRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(19, 143, 83))

                        $textBlock.Inlines.Add($bulletRun)
                        $textBlock.Inlines.Add($textRun)

                        $itemsControl.Items.Add($textBlock) | Out-Null
                    }

                    default {
                        $horizontalStackPanel = New-Object Windows.Controls.StackPanel
                        $horizontalStackPanel.Orientation = "Horizontal"
                        [System.Windows.Automation.AutomationProperties]::SetName($horizontalStackPanel, $entryInfo.Content)

                        $checkBox = New-Object Windows.Controls.CheckBox
                        $checkBox.Name = $entryInfo.Name
                        $checkBox.Content = $entryInfo.Content
                        $checkBox.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                        $checkBox.ToolTip = $entryInfo.Description
                        $checkBox.SetResourceReference([Windows.Controls.Control]::MarginProperty, "CheckBoxMargin")
                        $checkBox.UseLayoutRounding = $true
                        [System.Windows.Automation.AutomationProperties]::SetName($checkBox, $entryInfo.Content)
                        if ($entryInfo.Checked -eq $true) {
                            $checkBox.IsChecked = $entryInfo.Checked
                        }
                        $horizontalStackPanel.Children.Add($checkBox) | Out-Null

                        if ($entryInfo.Link) {
                            $textBlock = New-Object Windows.Controls.TextBlock
                            $textBlock.Name = $checkBox.Name + "Link"
                            $textBlock.Text = "(?)"
                            $textBlock.ToolTip = $entryInfo.Link
                            $textBlock.Style = $HoverTextBlockStyle
                            $textBlock.UseLayoutRounding = $true

                            $textBlock.VerticalAlignment = "Center"
                            $textBlock.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "FontSize")
                            $textBlock.Tag = $checkBox

                            $textBlock.Add_MouseUp({
                                [System.Object]$Sender = $args[0]
                                Start-Process $Sender.ToolTip -ErrorAction Stop
                            })

                            $updateLinkMargin = {
                                [System.Object]$Sender = $args[0]
                                $linkedCheckBox = $Sender.Tag
                                $MarginTopBase = if ($linkedCheckBox) { $linkedCheckBox.Margin.Top } else { 0 }
                                $Sender.Margin = New-Object Windows.Thickness(
                                    [math]::Round($Sender.FontSize * 0.5),
                                    ($MarginTopBase - [math]::Round($Sender.FontSize / 2)),
                                    0, 0
                                )
                            }
                            $textBlock.Add_Loaded($updateLinkMargin)
                            $fontSizeDescriptor = [System.ComponentModel.DependencyPropertyDescriptor]::FromProperty(
                                [Windows.Controls.Control]::FontSizeProperty,
                                [Windows.Controls.TextBlock]
                            )
                            $fontSizeDescriptor.AddValueChanged($textBlock, $updateLinkMargin)

                            $horizontalStackPanel.Children.Add($textBlock) | Out-Null

                            $sync[$textBlock.Name] = $textBlock
                        }

                        $itemsControl.Items.Add($horizontalStackPanel) | Out-Null
                        $sync[$entryInfo.Name] = $checkBox

                        $sync[$entryInfo.Name].Add_Checked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $Sender.name
                        })

                        $sync[$entryInfo.Name].Add_Unchecked({
                            [System.Object]$Sender = $args[0]
                            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $Sender.name
                        })
                    }
                }
            }
        }
    }
}

function Invoke-WPFUIThread ($ScriptBlock) {
    $sync.form.Dispatcher.Invoke([action]$ScriptBlock)
}

function Invoke-WPFUltimatePerformance ([switch]$Enable) {
    if ($Enable) {
        powercfg /setactive (powercfg /duplicatescheme e9a42b02-d5df-448d-aa00-03f14749eb61 | Select-String -Pattern '[A-Fa-f0-9-]{36}').Matches.Value
        [System.Windows.MessageBox]::Show("Ultimate Power Plan plan installed and activated.","Success","OK","Information")
    } else {
        powercfg /restoredefaultschemes
        [System.Windows.MessageBox]::Show("Power Plan was reset to defaults.","Success","OK","Information")
    }
}

function Invoke-WPFUnInstall {
    param(
        [Parameter(Mandatory=$false)]
        [PSObject[]]$PackagesToUninstall = $($sync.selectedApps | Foreach-Object { $sync.configs.applicationsHashtable.$_ })
    )
    <#

    .SYNOPSIS
        Uninstalls the selected programs
    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFUnInstall]安装过程正在进行中。
        Show-WinUtilMessage -Message $msg -Title "Winutil" -Button "OK" -Icon "Warning"
        return
    }

    if ($PackagesToUninstall.Count -eq 0) {
        $WarningMsg = "Please select the program(s) to uninstall"
        Show-WinUtilMessage -Message $WarningMsg -Title $AppTitle -Button "OK" -Icon "Warning"
        return
    }

    $ButtonType = "YesNo"
    $MessageboxTitle = "Are you sure?"
    $Messageboxbody = ("This will uninstall the following applications: `n $($PackagesToUninstall | Select-Object Name, Description| Out-String)")
    $MessageIcon = "Information"

    $confirm = Show-WinUtilMessage -Message $Messageboxbody -Title $MessageboxTitle -Button $ButtonType -Icon $MessageIcon

    if($confirm -eq "No") {return}

    $ManagerPreference = $sync.preferences.packagemanager
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall requested for $(@($PackagesToUninstall).Count) selected package(s) using preference: $ManagerPreference"
    $packageSummary = Get-WinUtilPackageLogSummary -Packages $PackagesToUninstall -Preference $ManagerPreference
    Write-WinUtilLog -Component "Uninstall" -Message "Uninstall selected package(s): $($packageSummary -join '; ')"

    Invoke-WPFRunspace -ParameterList @(("PackagesToUninstall", $PackagesToUninstall),("ManagerPreference", $ManagerPreference)) -ScriptBlock {
        param($PackagesToUninstall, $ManagerPreference)

        $packagesSorted = Get-WinUtilSelectedPackages -PackageList $PackagesToUninstall -Preference $ManagerPreference

        $packagesWinget = $packagesSorted['Winget']
        $packagesChoco = $packagesSorted['Choco']
        $totalPackages = @($packagesWinget).Count + @($packagesChoco).Count
        $completedPackages = 0
        $hasUI = $null -ne $sync.Form -and $null -ne $sync.Form.Dispatcher
        Write-WinUtilLog -Component "Uninstall" -Message "Uninstall package manager split: winget=$(@($packagesWinget).Count), choco=$(@($packagesChoco).Count)"

        try {
            $sync.ProcessRunning = $true
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Preparing app uninstall (0/$totalPackages)" -Percent 0
                Invoke-WPFUIThread -ScriptBlock {
                    if ($null -ne $sync.ItemsControl) {
                        $sync.ItemsControl.IsEnabled = $false
                    }
                }
            }

            if ($packagesWinget -contains "Microsoft.Edge") {
                New-Item -Path "$Env:SystemRoot\SystemApps\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\MicrosoftEdge.exe" -Force
            }

            # Uninstall all selected programs in new window
            if($packagesWinget.Count -gt 0) {
                foreach ($program in $packagesWinget) {
                    $position = $completedPackages + 1
                    $startPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling $program ($position/$totalPackages)" -Percent $startPercent
                    }

                    Install-WinUtilProgramWinget -Action Uninstall -Programs @($program)
                    $completedPackages++
                    $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                    if ($hasUI) {
                        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled $program ($completedPackages/$totalPackages)" -Percent $completedPercent
                        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                    }
                }
            }
            if($packagesChoco.Count -gt 0) {
                $position = $completedPackages + 1
                $startPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalling Chocolatey packages ($position/$totalPackages)" -Percent $startPercent
                }

                Install-WinUtilProgramChoco -Action Uninstall -Programs $packagesChoco
                $completedPackages += @($packagesChoco).Count
                $completedPercent = [int](($completedPackages / $totalPackages) * 100)
                if ($hasUI) {
                    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Uninstalled Chocolatey packages ($completedPackages/$totalPackages)" -Percent $completedPercent
                    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($completedPercent / 100) }
                }
            }
            Write-Host "==========================================="
            Write-Host "--       Uninstalls have finished       ---"
            Write-Host "==========================================="
            Write-WinUtilLog -Component "Uninstall" -Message "Uninstall workflow completed."
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "应用卸载完成" -Percent 100
                Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
            }
        } catch {
            Write-Host "==========================================="
            Write-Host "错误: $_"
            Write-Host "==========================================="
            Write-WinUtilLog -Level "ERROR" -Component "Uninstall" -Message "Uninstall workflow failed: $($_.Exception.Message)"
            if ($hasUI) {
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall failed" -Percent 100
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

function Invoke-WPFUpdatesdefault {
    <#

    .SYNOPSIS
        Resets Windows Update settings to default

    #>
    Write-WinUtilLog -Component "Updates" -Message "Resetting Windows Update settings to default."

    Write-Host "正在移除 WinUtil 管理的 Windows 更新设置..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Removing Windows Update registry values managed by WinUtil."

    $registryValues = @(
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU"
            Names = @("NoAutoUpdate", "AUOptions", "NoAutoRebootWithLoggedOnUsers", "AUPowerManagement")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
            Names = @("ExcludeWUDriversInQualityUpdate", "DeferFeatureUpdates", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdates", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
            Names = @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata"
            Names = @("PreventDeviceMetadataFromNetwork")
        },
        @{
            Path = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching"
            Names = @("DontPromptForWindowsUpdate", "DontSearchWindowsUpdate", "DriverUpdateWizardWuSearchEnabled")
        },
        @{
            Path = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config"
            Names = @("DODownloadMode")
        }
    )

    foreach ($registryEntry in $registryValues) {
        foreach ($valueName in $registryEntry.Names) {
            Remove-ItemProperty -Path $registryEntry.Path -Name $valueName -ErrorAction SilentlyContinue
        }
    }

    $explorerPolicyPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer"
    $settingsPageVisibility = (Get-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue).SettingsPageVisibility
    if ($settingsPageVisibility -eq "hide:windowsupdate") {
        Write-Host "正在移除 WinUtil 旧版 Windows 更新页面限制..."
        Write-WinUtilLog -Component "Updates" -Message "Removing the legacy Windows Update settings page restriction."
        Remove-ItemProperty -Path $explorerPolicyPath -Name "SettingsPageVisibility" -ErrorAction SilentlyContinue
    }

    Write-Host "正在重新启用 Windows 更新服务..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update service startup types."

    Write-Host "已将 BITS 恢复为手动。"
    Write-WinUtilLog -Component "Updates" -Message "Restoring BITS service to Manual."
    Set-Service -Name BITS -StartupType Manual

    Write-Host "已将 wuauserv 恢复为手动。"
    Write-WinUtilLog -Component "Updates" -Message "Restoring wuauserv service to Manual."
    Set-Service -Name wuauserv -StartupType Manual

    Write-Host "已将 UsoSvc 恢复为自动。"
    Write-WinUtilLog -Component "Updates" -Message "Starting UsoSvc service and restoring startup type to Automatic."
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    Write-Host "正在启用更新相关的计划任务..." -ForegroundColor Green
    Write-WinUtilLog -Component "Updates" -Message "Enabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "===================================================" -ForegroundColor Green
    Write-Host "---  Windows Update Settings Reset to Default   ---" -ForegroundColor Green
    Write-Host "===================================================" -ForegroundColor Green

    Write-Host "注意：您必须重新启动系统才能使所有更改生效。" -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update default workflow completed. Restart required."
}

function Invoke-WPFUpdatesdisable {
    <#

    .SYNOPSIS
        Disables Windows Update

    .NOTES
        Disabling Windows Update is not recommended. This is only for advanced users who know what they are doing.

    #>
    $confirmation = Show-WinUtilMessage `
        -Message "Disabling Windows Update stops update services, disables scheduled tasks, and clears downloaded update files. Security updates will not be installed until defaults are restored. Continue?" `
        -Title "Disable Windows Update?" `
        -Button "YesNo" `
        -Icon "Warning"

    if ($confirmation -ne "Yes") {
        Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow cancelled."
        return
    }

    Write-WinUtilLog -Component "Updates" -Message "Disabling Windows Update settings."

    Write-Host "正在配置注册表设置..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Configuring Windows Update registry policy values for disable mode."
    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "NoAutoUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" -Name "AUOptions" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -Type DWord -Value 0

    foreach ($serviceName in @("BITS", "wuauserv", "UsoSvc")) {
        Write-Host "正在停止并禁用 $serviceName 服务。"
        Write-WinUtilLog -Component "Updates" -Message "Stopping and disabling $serviceName service."
        Stop-Service -Name $serviceName -Force -ErrorAction SilentlyContinue
        Set-Service -Name $serviceName -StartupType Disabled
    }

    Remove-Item -Path "C:\Windows\SoftwareDistribution\*" -Recurse -Force -ErrorAction SilentlyContinue
    Write-Host "已清除 SoftwareDistribution 文件夹。"
    Write-WinUtilLog -Component "Updates" -Message "Cleared SoftwareDistribution folder."

    Write-Host "正在禁用更新相关的计划任务..." -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Disabling update related scheduled tasks."

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue
    }

    Write-Host "=================================" -ForegroundColor Green
    Write-Host "--- Windows Update Is Disabled ---" -ForegroundColor Green
    Write-Host "=================================" -ForegroundColor Green

    Write-Host "注意：您必须重新启动系统才能使所有更改生效。" -ForegroundColor Yellow
    Write-WinUtilLog -Component "Updates" -Message "Windows Update disable workflow completed. Restart required."
}

function Invoke-WPFUpdatessecurity {
    <#

    .SYNOPSIS
        Sets Windows Update to recommended settings

    .DESCRIPTION
        1. Disables driver offering through Windows Update
        2. Defers feature updates for 365 days
        3. Defers quality updates for 4 days
        4. Prevents automatic restarts while a user is signed in

    #>

    Write-Host "正在禁用通过 Windows 更新提供的驱动..."
    Write-WinUtilLog -Component "Updates" -Message "Applying recommended Windows Update settings."
    Write-WinUtilLog -Component "Updates" -Message "Disabling driver offering through Windows Update."

    $windowsUpdatePolicyPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate"
    $automaticUpdatePolicyPath = Join-Path $windowsUpdatePolicyPath "AU"

    Write-Host "正在恢复 Windows 更新可用性..."
    Write-WinUtilLog -Component "Updates" -Message "Restoring Windows Update services and scheduled tasks before applying recommended settings."

    Remove-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoUpdate" -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" -Name "DODownloadMode" -ErrorAction SilentlyContinue

    Set-Service -Name BITS -StartupType Manual
    Set-Service -Name wuauserv -StartupType Manual
    Set-Service -Name UsoSvc -StartupType Automatic
    Start-Service -Name UsoSvc

    $Tasks =
        '\Microsoft\Windows\InstallService\*',
        '\Microsoft\Windows\UpdateOrchestrator\*',
        '\Microsoft\Windows\UpdateAssistant\*',
        '\Microsoft\Windows\WaaSMedic\*',
        '\Microsoft\Windows\WindowsUpdate\*',
        '\Microsoft\WindowsUpdate\*'

    foreach ($Task in $Tasks) {
        Get-ScheduledTask -TaskPath $Task -ErrorAction SilentlyContinue | Enable-ScheduledTask -ErrorAction SilentlyContinue
    }

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Force
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Device Metadata" -Name "PreventDeviceMetadataFromNetwork" -Type DWord -Value 1

    New-Item -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Force

    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontPromptForWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DontSearchWindowsUpdate" -Type DWord -Value 1
    Set-ItemProperty -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\DriverSearching" -Name "DriverUpdateWizardWuSearchEnabled" -Type DWord -Value 0

    New-Item -Path $windowsUpdatePolicyPath -Force
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "ExcludeWUDriversInQualityUpdate" -Type DWord -Value 1

    Write-Host "将功能更新推迟 365 天，质量更新推迟 4 天..."
    Write-WinUtilLog -Component "Updates" -Message "Deferring feature updates by 365 days and quality updates by 4 days."

    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferFeatureUpdatesPeriodInDays" -Type DWord -Value 365
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdates" -Type DWord -Value 1
    Set-ItemProperty -Path $windowsUpdatePolicyPath -Name "DeferQualityUpdatesPeriodInDays" -Type DWord -Value 4

    $legacySettingsPath = "HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings"
    foreach ($legacyValue in @("BranchReadinessLevel", "DeferFeatureUpdatesPeriodInDays", "DeferQualityUpdatesPeriodInDays")) {
        Remove-ItemProperty -Path $legacySettingsPath -Name $legacyValue -ErrorAction SilentlyContinue
    }

    Write-Host "防止用户在登录时自动重启..."
    Write-WinUtilLog -Component "Updates" -Message "Configuring scheduled automatic updates without restarting while users are signed in."

    New-Item -Path $automaticUpdatePolicyPath -Force
    # NoAutoRebootWithLoggedOnUsers only applies when automatic updates use option 4.
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUOptions" -Type DWord -Value 4
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "NoAutoRebootWithLoggedOnUsers" -Type DWord -Value 1
    Set-ItemProperty -Path $automaticUpdatePolicyPath -Name "AUPowerManagement" -Type DWord -Value 0

    Write-Host "================================="
    Write-Host "-- Updates Set to Recommended ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Updates" -Message "Recommended Windows Update settings workflow completed."
}

function Invoke-WPFtweaksbutton {
  <#

    .SYNOPSIS
        Invokes the functions associated with each group of checkboxes

  #>

  if($sync.ProcessRunning) {
    $msg = "[Invoke-WPFtweaksbutton]安装过程正在进行中。"
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  $Tweaks = $sync.selectedTweaks
  $dnsProvider = $sync["WPFchangedns"].text
  if (-not ($dnsProvider)) {
    $dnsProvider = "Default"
  }
  $restorePointTweak = "WPFTweaksRestorePoint"
  $restorePointSelected = $Tweaks -contains $restorePointTweak
  $tweaksToRun = @($Tweaks | Where-Object { $_ -ne $restorePointTweak })
  $totalSteps = [Math]::Max($Tweaks.Count, 1)
  $completedSteps = 0
  Write-WinUtilLog -Component "Tweaks" -Message "Tweaks requested: $(@($Tweaks).Count) selected tweak(s), DNS provider: $dnsProvider"

  if ($tweaks.count -eq 0 -and $dnsProvider -eq "Default") {
    $msg = "Please check the tweaks you wish to perform."
    [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
    return
  }

  if ($restorePointSelected) {
    $sync.ProcessRunning = $true

    if ($Tweaks.Count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Creating restore point" -Percent 0
    Write-WinUtilLog -Component "Tweaks" -Message "Creating restore point before applying selected tweaks."
    Invoke-WinUtilTweaks $restorePointTweak
    $completedSteps = 1

    if ($tweaksToRun.Count -eq 0 -and $dnsProvider -eq "Default") {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
      $sync.ProcessRunning = $false
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
      Write-Host "================================="
      Write-Host "--     优化已完成    ---"
      Write-Host "================================="
      Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed after restore point."
      return
    }
  }

  # The leading "," in the ParameterList is necessary because we only provide one argument and powershell cannot be convinced that we want a nested loop with only one argument otherwise
  Invoke-WPFRunspace -ParameterList @(("tweaks", $tweaksToRun), ("dnsProvider", $dnsProvider), ("completedSteps", $completedSteps), ("totalSteps", $totalSteps)) -ScriptBlock {
    param($tweaks, $dnsProvider, $completedSteps, $totalSteps)

    $sync.ProcessRunning = $true

    if ($completedSteps -eq 0) {
      if ($Tweaks.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
      } else {
        Invoke-WPFUIThread -ScriptBlock{ Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
      }
    }

    if ($dnsProvider -ne "Default") {
      Set-WinUtilDNS -DNSProvider $dnsProvider
    }

    for ($i = 0; $i -lt $tweaks.Count; $i++) {
      Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Applying $($tweaks[$i]) ($($completedSteps + 1)/$totalSteps)" -Percent ($completedSteps / $totalSteps * 100)
      Invoke-WinUtilTweaks $tweaks[$i]
      $completedSteps++
      $progress = $completedSteps / $totalSteps
      Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value $progress }
    }
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Tweaks finished" -Percent 100
    $sync.ProcessRunning = $false
    Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
    Write-Host "================================="
    Write-Host "--     优化已完成    ---"
    Write-Host "================================="
    Write-WinUtilLog -Component "Tweaks" -Message "Tweaks workflow completed."
  }
}

function Invoke-WPFundoall {
    <#

    .SYNOPSIS
        Undoes every selected tweak

    #>

    if($sync.ProcessRunning) {
        $msg = "[Invoke-WPFundoall]安装过程正在进行中。"
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    $tweaks = $sync.selectedTweaks

    if ($tweaks.count -eq 0) {
        $msg = "Please check the tweaks you wish to undo."
        [System.Windows.MessageBox]::Show($msg, "Winutil", [System.Windows.MessageBoxButton]::OK, [System.Windows.MessageBoxImage]::Warning)
        return
    }

    Invoke-WPFRunspace -ArgumentList $tweaks -ScriptBlock {
        param($tweaks)

        $sync.ProcessRunning = $true
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks requested: $(@($tweaks).Count) selected tweak(s)."
        if ($tweaks.count -eq 1) {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
        } else {
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
        }


        for ($i = 0; $i -lt $tweaks.Count; $i++) {
            Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undoing $($tweaks[$i]) ($($i + 1)/$($tweaks.Count))" -Percent ($i / $tweaks.Count * 100)
            Invoke-WinUtiltweaks $tweaks[$i] -undo $true
            Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -value ($i/$tweaks.Count) }
        }

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Undo Tweaks Finished" -Percent 100
        $sync.ProcessRunning = $false
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "None" -overlay "checkmark" }
        Write-Host "=================================="
        Write-Host "---  撤销优化已完成  ---"
        Write-Host "=================================="
        Write-WinUtilLog -Component "Tweaks" -Message "Undo tweaks workflow completed."

    }
}

function Invoke-WinUtilAutoRun {
    <#

    .SYNOPSIS
        Runs Install, Tweaks, and Features with optional UI invocation.
    #>

    function BusyWait {
        Start-Sleep -Milliseconds 100
        while ($sync.ProcessRunning) {
            Start-Sleep -Milliseconds 100
        }
    }

    if ($sync.selectedTweaks.Count -gt 0) {
        Write-Host "正在应用优化..."
        Invoke-WPFtweaksbutton
        BusyWait
    }

    if ($sync.selectedFeatures.Count -gt 0) {
        Write-Host "正在应用功能..."
        Invoke-WPFFeatureInstall
        BusyWait
    }

    if ($sync.selectedApps.Count -gt 0) {
        Write-Host "正在安装应用..."
        Invoke-WPFInstall
        BusyWait
    }

    if ($sync.selectedAppx.Count -gt 0) {
        Write-Host "正在移除 AppX 包..."
        Invoke-WPFAppxRemoval
        BusyWait
    }

    Write-Host "完成。"
}

function Add-SelectedAppsMenuItem {
    <#
    .SYNOPSIS
        This is a helper function that generates and adds the Menu Items to the Selected Apps Popup.

    .Parameter name
        The actual Name of an App like "Chrome" or "Brave"
        This name is contained in the "Content" property inside the applications.json
    .PARAMETER key
        The key which identifies an app object in applications.json
        For Chrome this would be "WPFInstallchrome" because "WPFInstall" is prepended automatically for each key in applications.json
    #>

    param ([string]$name, [string]$key)

    $selectedAppGrid = New-Object Windows.Controls.Grid

    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "*"}))
    $selectedAppGrid.ColumnDefinitions.Add((New-Object System.Windows.Controls.ColumnDefinition -Property @{Width = "30"}))

    # Sets the name to the Content as well as the Tooltip, because the parent Popup Border has a fixed width and text could "overflow".
    # With the tooltip, you can still read the whole entry on hover
    $selectedAppLabel = New-Object Windows.Controls.Label
    $selectedAppLabel.Content = $name
    $selectedAppLabel.ToolTip = $name
    $selectedAppLabel.HorizontalAlignment = "Left"
    $selectedAppLabel.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    [System.Windows.Controls.Grid]::SetColumn($selectedAppLabel, 0)
    $selectedAppGrid.Children.Add($selectedAppLabel)

    $selectedAppRemoveButton = New-Object Windows.Controls.Button
    $selectedAppRemoveButton.FontFamily = "Segoe MDL2 Assets"
    $selectedAppRemoveButton.Content = [string]([char]0xE711)
    $selectedAppRemoveButton.HorizontalAlignment = "Center"
    $selectedAppRemoveButton.Tag = $key
    $selectedAppRemoveButton.ToolTip = "Remove the App from Selection"
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor")
    $selectedAppRemoveButton.SetResourceReference([Windows.Controls.Control]::StyleProperty, "HoverButtonStyle")

    # Highlight the Remove icon on Hover
    $selectedAppRemoveButton.Add_MouseEnter({ $this.Foreground = "Red" })
    $selectedAppRemoveButton.Add_MouseLeave({ $this.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "MainForegroundColor") })
    $selectedAppRemoveButton.Add_Click({
            $sync.($this.Tag).isChecked = $false # On click of the remove button, we only have to uncheck the corresponding checkbox. This will kick of all necessary changes to update the UI
    })
    [System.Windows.Controls.Grid]::SetColumn($selectedAppRemoveButton, 1)
    $selectedAppGrid.Children.Add($selectedAppRemoveButton)
    # Add new Element to Popup
    $sync.selectedAppsstackPanel.Children.Add($selectedAppGrid)
}

function Close-WinUtilRunspacePool {
    if ($null -eq $sync -or -not $sync.ContainsKey("runspace") -or $null -eq $sync.runspace) {
        return
    }

    try {
        if ($sync.runspace.RunspacePoolStateInfo.State -notin @(
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closed,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Closing,
            [System.Management.Automation.Runspaces.RunspacePoolState]::Broken
        )) {
            $sync.runspace.Close()
        }
    } finally {
        $sync.runspace.Dispose()
        $sync.Remove("runspace")
    }
}

function Find-AppsByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Apps on the Install Tab and hides all entries that do not match the string

        .DESCRIPTION
            Filters application entries by name or description using literal string matching.
            Respects collapsed category state and handles null $sync gracefully.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .PARAMETER Category
            When provided, only applications in this exact category are shown.

        .NOTES
            - Uses module-scope $sync (no parameter needed; inherits from caller's scope)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing hashtable keys and null UI elements
            - Protected by try/catch to prevent UI thread crashes
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = "",

        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    # Validate that $sync exists and has required structure
    if ($null -eq $sync) {
        Write-Warning "Find-AppsByNameOrDescription: Global `$sync not found. Aborting search."
        return
    }

    if ($null -eq $sync.ItemsControl) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.ItemsControl not initialized. Aborting search."
        return
    }

    if ($null -eq $sync.configs -or $null -eq $sync.configs.applicationsHashtable) {
        Write-Warning "Find-AppsByNameOrDescription: `$sync.configs.applicationsHashtable not initialized. Aborting search."
        return
    }

    try {
        # Reset the visibility if the search string is empty or the search is cleared
        if ([string]::IsNullOrWhiteSpace($SearchString) -and [string]::IsNullOrWhiteSpace($Category)) {
            $sync.ItemsControl.Items | ForEach-Object {
                # Each item is a StackPanel container
                $_.Visibility = [Windows.Visibility]::Visible

                if ($_.Children.Count -ge 2) {
                    $categoryLabel = $_.Children[0]
                    $wrapPanel = $_.Children[1]

                    # Keep category label visible
                    $categoryLabel.Visibility = [Windows.Visibility]::Visible

                    # Respect the collapsed state of categories (indicated by + prefix)
                    if ($categoryLabel.Content -like "+*") {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                    }
                    else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    }

                    # Show all apps within the category
                    $wrapPanel.Children | ForEach-Object {
                        $_.Visibility = [Windows.Visibility]::Visible
                    }
                }
            }
            return
        }

        # Escape wildcard characters for literal matching
        $escapedSearchString = [System.Management.Automation.WildcardPattern]::Escape($SearchString)

        # Perform search
        $sync.ItemsControl.Items | ForEach-Object {
            # Each item is a StackPanel container with Children[0] = label, Children[1] = WrapPanel
            if ($_.Children.Count -ge 2) {
                $categoryLabel = $_.Children[0]
                $wrapPanel = $_.Children[1]
                $categoryHasMatch = $false

                # Keep category label visible
                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                # Search through apps in this category
                foreach ($appControl in $wrapPanel.Children) {
                    # Safely retrieve app entry from hashtable
                    $appTag = $appControl.Tag
                    $appEntry = $null

                    if (-not [string]::IsNullOrWhiteSpace($appTag) -and $sync.configs.applicationsHashtable.ContainsKey($appTag)) {
                        $appEntry = $sync.configs.applicationsHashtable[$appTag]
                    }

                    # Check if app matches search criteria
                    if ($null -ne $appEntry) {
                        $categoryMatch = -not [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Category -eq $Category
                        $contentMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Content -like "*$escapedSearchString*"
                        $descriptionMatch = [string]::IsNullOrWhiteSpace($Category) -and $appEntry.Description -like "*$escapedSearchString*"

                        if ($categoryMatch -or $contentMatch -or $descriptionMatch) {
                            # Show the App and mark that this category has a match
                            $appControl.Visibility = [Windows.Visibility]::Visible
                            $categoryHasMatch = $true
                        }
                        else {
                            $appControl.Visibility = [Windows.Visibility]::Collapsed
                        }
                    }
                    else {
                        # Hide app if no entry found (data integrity issue)
                        $appControl.Visibility = [Windows.Visibility]::Collapsed
                    }
                }

                # If category has matches, show the WrapPanel and update the category label to expanded state
                if ($categoryHasMatch) {
                    $wrapPanel.Visibility = [Windows.Visibility]::Visible
                    $_.Visibility = [Windows.Visibility]::Visible
                    # Update category label to show expanded state (-)
                    if ($categoryLabel.Content -like "+*") {
                        $categoryLabel.Content = $categoryLabel.Content -replace "^\+ ", "- "
                    }
                }
                else {
                    # Hide the entire category container if no matches
                    $_.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        Write-Warning "Find-AppsByNameOrDescription: An error occurred during search: $_"
        # Fail gracefully - do not crash the UI thread
        return
    }
}

function Find-TweaksByNameOrDescription {
    <#
        .SYNOPSIS
            Searches through the Tweaks on the Tweaks Tab and hides all entries that do not match the search string

        .DESCRIPTION
            Filters tweak entries by name or description using literal string matching (no wildcard expansion).
            Respects collapsed category state and handles null $sync gracefully.
            Safe for rapid keystroke events; no terminal spam on error conditions.

        .PARAMETER SearchString
            The string to be searched for. Wildcards are treated as literal characters.

        .NOTES
            - Uses module-scope $sync (resolved via global/script fallback if needed)
            - Performs literal matching (no wildcard expansion)
            - Safely handles missing UI elements and null properties
            - Protected by try/catch to prevent UI thread crashes
            - PowerShell 5.1 compatible (no ternary operators, no advanced language features)
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$SearchString = ""
    )

    # ------------------------------------------------------------------------------
    # 1. RESOLVE $SYNC WITH MULTI-LEVEL FALLBACK
    # ------------------------------------------------------------------------------

    if ($null -eq $Sync) {
        $Sync = $global:sync
        if ($null -eq $Sync) {
            $Sync = $script:sync
        }
    }

    # Validate that $Sync exists and has required structure
    if ($null -eq $Sync) {
        # Silent return - function called on every keystroke; no warning spam
        return
    }

    if ($null -eq $Sync.Form) {
        # Silent return - form not yet initialized
        return
    }

    # ------------------------------------------------------------------------------
    # 2. GET REFERENCE TO TWEAKS OR APPX PANEL
    # ------------------------------------------------------------------------------

    $panelName = "tweakspanel"
    if ($null -ne $Sync.currentTab -and $Sync.currentTab -eq "AppX") {
        $panelName = "appxpanel"
    }

    $tweaksPanel = $null
    try {
        $tweaksPanel = $Sync.Form.FindName($panelName)
    }
    catch {
        # Silent return - panel not found or disposed
        return
    }

    if ($null -eq $tweaksPanel) {
        # Silent return - panel doesn't exist
        return
    }

    # ------------------------------------------------------------------------------
    # 3. HANDLE EMPTY/WHITESPACE SEARCH STRING - RESET TO DEFAULT STATE
    # ------------------------------------------------------------------------------

    if ([string]::IsNullOrWhiteSpace($SearchString)) {
        try {
            $tweaksPanel.Children | ForEach-Object {
                $categoryBorder = $_

                # Safely set visibility
                if ($null -ne $categoryBorder) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }

                # Process each category
                if ($categoryBorder -is [Windows.Controls.Border]) {
                    $dockPanel = $null
                    if ($null -ne $categoryBorder.Child) {
                        $dockPanel = $categoryBorder.Child
                    }

                    if ($dockPanel -is [Windows.Controls.DockPanel]) {
                        $itemsControl = $null
                        $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                        if ($null -ne $itemsControl) {
                            # Show all items in the category
                            foreach ($item in $itemsControl.Items) {
                                if ($null -ne $item) {
                                    # Check if it's a category label (first Label in the ItemsControl)
                                    if ($item -is [Windows.Controls.Label]) {
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                    elseif ($item -is [Windows.Controls.DockPanel] -or $item -is [Windows.Controls.StackPanel]) {
                                        # Show all checkbox containers
                                        $item.Visibility = [Windows.Visibility]::Visible
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
        catch {
            # Silent catch - UI element may be disposed
            $null = $_
        }

        return
    }

    # ------------------------------------------------------------------------------
    # 4. PERFORM LITERAL SEARCH (NO WILDCARD EXPANSION)
    # ------------------------------------------------------------------------------

    try {
        # Normalize search term once for the entire operation
        $searchTerm = $SearchString
        if ($null -eq $searchTerm) {
            $searchTerm = ""
        }

        # Iterate through all categories
        $tweaksPanel.Children | ForEach-Object {
            $categoryBorder = $_
            $categoryHasMatch = $false

            if ($categoryBorder -is [Windows.Controls.Border]) {
                $dockPanel = $null
                if ($null -ne $categoryBorder.Child) {
                    $dockPanel = $categoryBorder.Child
                }

                if ($dockPanel -is [Windows.Controls.DockPanel]) {
                    $itemsControl = $null
                    $itemsControl = $dockPanel.Children | Where-Object { $_ -is [Windows.Controls.ItemsControl] } | Select-Object -First 1

                    if ($null -ne $itemsControl) {
                        $categoryLabel = $null

                        # Process all items (checkboxes, labels, panels) in the ItemsControl
                        for ($i = 0; $i -lt $itemsControl.Items.Count; $i++) {
                            $item = $itemsControl.Items[$i]

                            if ($null -eq $item) {
                                continue
                            }

                            # ------------------------------------------------------------
                            # Check if this is a category label (usually first Label)
                            # ------------------------------------------------------------

                            if ($item -is [Windows.Controls.Label]) {
                                $categoryLabel = $item
                                # Initially hide category label; show it only if matches found
                                $item.Visibility = [Windows.Visibility]::Collapsed
                            }

                            # ------------------------------------------------------------
                            # Check if this is a DockPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.DockPanel]) {
                                $checkbox = $null
                                $label = $null

                                # Safely extract checkbox and label
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1
                                $label = $item.Children | Where-Object { $_ -is [Windows.Controls.Label] } | Select-Object -First 1

                                # Check if tweak matches search criteria
                                $itemMatches = $false

                                if ($null -ne $label) {
                                    $labelContent = $label.Content
                                    $labelToolTip = $label.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $labelContent) {
                                        $labelContent = ""
                                    }
                                    if ($null -eq $labelToolTip) {
                                        $labelToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $labelContentStr = [string]$labelContent
                                    $labelToolTipStr = [string]$labelToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $labelContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $labelToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }

                            # ------------------------------------------------------------
                            # Check if this is a StackPanel containing a tweak checkbox
                            # ------------------------------------------------------------

                            elseif ($item -is [Windows.Controls.StackPanel]) {
                                $checkbox = $null
                                $checkbox = $item.Children | Where-Object { $_ -is [Windows.Controls.CheckBox] } | Select-Object -First 1

                                $itemMatches = $false

                                if ($null -ne $checkbox) {
                                    $checkboxContent = $checkbox.Content
                                    $checkboxToolTip = $checkbox.ToolTip

                                    # Safely null-check properties
                                    if ($null -eq $checkboxContent) {
                                        $checkboxContent = ""
                                    }
                                    if ($null -eq $checkboxToolTip) {
                                        $checkboxToolTip = ""
                                    }

                                    # Convert to string and perform LITERAL matching
                                    $checkboxContentStr = [string]$checkboxContent
                                    $checkboxToolTipStr = [string]$checkboxToolTip

                                    # Use IndexOf for literal matching (no wildcard interpretation)
                                    $contentMatch = $checkboxContentStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0
                                    $toolTipMatch = $checkboxToolTipStr.IndexOf($searchTerm, [System.StringComparison]::OrdinalIgnoreCase) -ge 0

                                    if ($contentMatch -or $toolTipMatch) {
                                        $itemMatches = $true
                                    }
                                }

                                # Set visibility based on match result
                                if ($itemMatches) {
                                    $item.Visibility = [Windows.Visibility]::Visible
                                    $categoryHasMatch = $true
                                }
                                else {
                                    $item.Visibility = [Windows.Visibility]::Collapsed
                                }
                            }
                        }

                        # ------------------------------------------------------------
                        # Update category label visibility and expanded/collapsed state
                        # ------------------------------------------------------------

                        if ($categoryHasMatch) {
                            # Show category label
                            if ($null -ne $categoryLabel) {
                                $categoryLabel.Visibility = [Windows.Visibility]::Visible

                                # Update category label to expanded state (change "+" to "-")
                                $labelContent = $categoryLabel.Content
                                if ($null -ne $labelContent) {
                                    $labelStr = [string]$labelContent

                                    # Safe string replacement without -replace regex
                                    if ($labelStr.StartsWith("+ ")) {
                                        $expandedLabel = "- " + $labelStr.Substring(2)
                                        $categoryLabel.Content = $expandedLabel
                                    }
                                }
                            }
                        }
                    }
                }

                # ----------------------------------------------------------------
                # Set category border visibility based on whether it has matches
                # ----------------------------------------------------------------

                if ($categoryHasMatch) {
                    $categoryBorder.Visibility = [Windows.Visibility]::Visible
                }
                else {
                    $categoryBorder.Visibility = [Windows.Visibility]::Collapsed
                }
            }
        }
    }
    catch {
        # Silent catch - UI elements may be disposed or in unexpected state
        # Do not log to terminal as this function is called on every keystroke
        $null = $_
    }
}

function Get-WinUtilInstalledAPPX {
    <#

    .SYNOPSIS
        Gets the names of AppX packages installed for all users

    #>

    # AppX module auto-loading can leave PowerShell 7 dependent on a temporary Windows PowerShell
    # compatibility proxy. Run the query in Windows PowerShell 5.1 so it remains available after
    # those temporary proxy files are removed.
    $ps5Command = {
        Get-AppxPackage -AllUsers -ErrorAction Stop | Select-Object -ExpandProperty Name
    }

    $packageOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command 2>&1
    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($packageOutput | Out-String).Trim()
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to get installed AppX packages: $failureDetails"
        return @()
    }

    return @($packageOutput)
}

function Get-WinUtilPackageLogSummary {
    param(
        [Parameter(Mandatory = $true)]
        [object[]]$Packages,

        [Parameter(Mandatory = $true)]
        [string]$Preference
    )

    @($Packages | ForEach-Object {
        $package = $_
        $packageName = @($package.Name, $package.Description, $package.winget, $package.choco) |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) -and $_ -ne "na" } |
            Select-Object -First 1

        if ([string]::IsNullOrWhiteSpace([string]$packageName)) {
            $packageName = "Unknown package"
        }

        if ($Preference -eq "Choco" -and -not [string]::IsNullOrWhiteSpace([string]$package.choco) -and $package.choco -ne "na") {
            "$packageName (choco: $($package.choco))"
        } elseif (-not [string]::IsNullOrWhiteSpace([string]$package.winget) -and $package.winget -ne "na") {
            "$packageName (winget: $($package.winget))"
        } else {
            "$packageName (no package id)"
        }
    })
}

function Get-WinUtilSelectedPackages {

     param(
         [Parameter(Mandatory = $true)]
         [object] $PackageList,

         [Parameter(Mandatory = $true)]
         [string] $Preference
     )

    if ($PackageList.count -eq 1) {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Indeterminate" -value 0.01 -overlay "logo" }
    } else {
        Invoke-WPFUIThread -ScriptBlock { Set-WinUtilTaskbaritem -state "Normal" -value 0.01 -overlay "logo" }
    }

    $packagesWinget = [System.Collections.ArrayList]::new()
    $packagesChoco = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
    }

    function Add-PackageId {
        param(
            [System.Collections.ArrayList]$Target,
            $PackageId
        )

        if ([string]::IsNullOrWhiteSpace([string]$PackageId) -or $PackageId -eq "na") {
            return
        }

        if (-not $Target.Contains($PackageId)) {
            $null = $Target.Add($PackageId)
        }
    }

    foreach ($package in $PackageList) {
        switch ($Preference) {
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Winget" {
                Add-PackageId -Target $packagesWinget -PackageId $package.winget
            }
        }
    }

    return $packages
}

Function Get-WinUtilToggleStatus ($ToggleSwitch) {

    $ToggleSwitchReg = $sync.configs.tweaks.$ToggleSwitch.registry

    if ($null -eq $sync.ToggleStatusCache) {
        $sync.ToggleStatusCache = @{}
    }

    if ($sync.ToggleStatusCache.ContainsKey($ToggleSwitch)) {
        return [bool]$sync.ToggleStatusCache[$ToggleSwitch]
    }

    if (-not (Get-PSDrive -Name HKU -ErrorAction SilentlyContinue)) {
        New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS | Out-Null
    }

    foreach ($regentry in $ToggleSwitchReg) {

        if (Test-Path $regentry.Path) {
            $regstate = (Get-ItemProperty -Path $regentry.Path).$($regentry.Name)
        } else {
            $regstate = $null
        }

        if ($null -eq $regstate) {
            switch ([string]$regentry.DefaultState) {
                "true"  { $regstate = $regentry.Value }
                "false" { $regstate = $regentry.OriginalValue }
            }
        }

        if ($regstate -ne $regentry.Value) {
            $sync.ToggleStatusCache[$ToggleSwitch] = $false
            return $false
        }
    }

    $sync.ToggleStatusCache[$ToggleSwitch] = $true
    return $true
}

function Get-WinUtilVariables {

    <#
    .SYNOPSIS
        Gets every form object of the provided type

    .OUTPUTS
        List containing every object that matches the provided type
    #>
    param (
        [Parameter()]
        [string[]]$Type
    )
    $keys = ($sync.keys).where{ $_ -like "WPF*" }
    if ($Type) {
        $output = $keys | ForEach-Object {
            try {
                $objType = $sync["$psitem"].GetType().Name
                if ($Type -contains $objType) {
                    Write-Output $psitem
                }
            }
            catch {
                $null = $_
            }
        }
        return $output
    }
    return $keys
}

    function Initialize-InstallAppArea {
        <#
            .SYNOPSIS
                Creates a [Windows.Controls.ScrollViewer] containing a [Windows.Controls.ItemsControl] which is setup to use Virtualization to only load the visible elements for performance reasons.
                This is used as the parent object for all category and app entries on the install tab
                Used to as part of the Install Tab UI generation

            .PARAMETER TargetElement
                The element to which the AppArea should be added

        #>
        param($TargetElement)
        $targetGrid = $sync.Form.FindName($TargetElement)
        $null = $targetGrid.Children.Clear()

        # Create the outer Border for the aren where the apps will be placed
        $Border = New-Object Windows.Controls.Border
        $Border.VerticalAlignment = "Stretch"
        $Border.SetResourceReference([Windows.Controls.Control]::StyleProperty, "BorderStyle")
        # Add a ScrollViewer, because the ItemsControl does not support scrolling by itself
        $scrollViewer = New-Object Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalAlignment = 'Stretch'
        $scrollViewer.VerticalAlignment = 'Stretch'
        $scrollViewer.CanContentScroll = $true
        $Border.Child = $scrollViewer

        ## Create the ItemsControl, which will be the parent of all the app entries
        $itemsControl = New-Object Windows.Controls.ItemsControl
        $itemsControl.HorizontalAlignment = 'Stretch'
        $itemsControl.VerticalAlignment = 'Stretch'
        $scrollViewer.Content = $itemsControl

        # Use WrapPanel to create dynamic columns based on AppEntryWidth and window width
        $itemsPanelTemplate = New-Object Windows.Controls.ItemsPanelTemplate
        $factory = New-Object Windows.FrameworkElementFactory ([Windows.Controls.WrapPanel])
        $factory.SetValue([Windows.Controls.WrapPanel]::OrientationProperty, [Windows.Controls.Orientation]::Horizontal)
        $factory.SetValue([Windows.Controls.WrapPanel]::HorizontalAlignmentProperty, [Windows.HorizontalAlignment]::Left)
        $itemsPanelTemplate.VisualTree = $factory
        $itemsControl.ItemsPanel = $itemsPanelTemplate

        # Add the Border containing the App Area to the target Grid
        $targetGrid.Children.Add($Border) | Out-Null

        return $itemsControl
    }

function Initialize-InstallAppEntry {
    <#
        .SYNOPSIS
            Creates the app entry to be placed on the install tab for a given app
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Apps should be placed
        .PARAMETER appKey
            The Key of the app inside the $sync.configs.applicationsHashtable
    #>
        param(
            [Windows.Controls.WrapPanel]$TargetElement,
            $appKey
        )

        $app = $sync.configs.applicationsHashtable.$appKey

        # Create the outer Border for the application type
        $border = New-Object Windows.Controls.Border
        $border.Style = $sync.Form.Resources.AppEntryBorderStyle
        $border.Tag = $appKey
        $border.ToolTip = $app.description
        $border.Add_MouseLeftButtonUp({
            $childCheckbox = ($this.Child | Where-Object {$_.Template.TargetType -eq [System.Windows.Controls.Checkbox]})[0]
            $childCheckBox.isChecked = -not $childCheckbox.IsChecked
        })
        $border.Add_MouseEnter({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallHighlightedColor")
            }
        })
        $border.Add_MouseLeave({
            if (($sync.$($this.Tag).IsChecked) -eq $false) {
                $this.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
            }
        })
        $border.Add_MouseRightButtonUp({
            # Store the selected app in a global variable so it can be used in the popup
            $sync.appPopupSelectedApp = $this.Tag
            # Set the popup position to the current mouse position
            $sync.appPopup.PlacementTarget = $this
            $sync.appPopup.IsOpen = $true
        })

        $checkBox = New-Object Windows.Controls.CheckBox
        # Sanitize the name for WPF
        $checkBox.Name = $appKey -replace '-', '_'
        # Store the original appKey in Tag
        $checkBox.Tag = $appKey
        $checkbox.Style = $sync.Form.Resources.AppEntryCheckboxStyle
        $checkbox.Add_Checked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Add" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallSelectedColor")
        })

        $checkbox.Add_Unchecked({
            Invoke-WPFSelectedCheckboxesUpdate -type "Remove" -checkboxName $this.Parent.Tag
            $borderElement = $this.Parent
            $borderElement.SetResourceReference([Windows.Controls.Control]::BackgroundProperty, "AppInstallUnselectedColor")
        })

        $contentPanel = New-Object Windows.Controls.StackPanel
        $contentPanel.Orientation = "Horizontal"
        $contentPanel.VerticalAlignment = [Windows.VerticalAlignment]::Center

        $icon = New-Object Windows.Controls.Grid
        $icon.SetResourceReference([Windows.FrameworkElement]::WidthProperty, "AppEntryIconSize")
        $icon.SetResourceReference([Windows.FrameworkElement]::HeightProperty, "AppEntryIconSize")
        $icon.Margin = New-Object Windows.Thickness(0, 0, 8, 0)
        $fallback = New-Object Windows.Controls.TextBlock
        $fallback.Text = $app.content.TrimStart(".").Substring(0, 1).ToUpper()
        $fallback.FontWeight = "Bold"; $fallback.HorizontalAlignment = "Center"; $fallback.VerticalAlignment = "Center"
        if ($app.link) { $fallback.Visibility = "Collapsed" }
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::FontSizeProperty, "AppEntryFontSize")
        $fallback.SetResourceReference([Windows.Controls.TextBlock]::ForegroundProperty, "ToggleButtonOnColor")
        [void]$icon.Children.Add($fallback)
        if ($app.link) {
            $logo = New-Object Windows.Controls.Image
            $logo.Stretch = [Windows.Media.Stretch]::Uniform
            $logo.Source = "https://www.google.com/s2/favicons?sz=64&domain_url=$([uri]::EscapeDataString($app.link))"
            $logo.Add_ImageFailed({ $this.Visibility = "Collapsed"; $this.Parent.Children[0].Visibility = "Visible" })
            [void]$icon.Children.Add($logo)
        }
        [void]$contentPanel.Children.Add($icon)

        # Create the TextBlock for the application name
        $appName = New-Object Windows.Controls.TextBlock
        $appName.Style = $sync.Form.Resources.AppEntryNameStyle
        $appName.Text = $app.content

        # Add FOSS label after the name if FOSS
        if ($app.foss -eq $true) {
            $fossRun = [System.Windows.Documents.Run]::new(" $([char]0x25CF)")
            $fossRun.Foreground = [Windows.Media.SolidColorBrush]::new([Windows.Media.Color]::FromRgb(110, 255, 114))
            $fossRun.FontSize = 11.5

            [void]$appName.Inlines.Add($fossRun)
        }
        [void]$contentPanel.Children.Add($appName)
        $checkBox.Content = $contentPanel

        # Add accessibility properties to make the elements screen reader friendly
        $checkBox.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)
        $border.SetValue([Windows.Automation.AutomationProperties]::NameProperty, $app.content)

        $border.Child = $checkBox
        if ($sync.selectedApps -contains $appKey) {
            $checkBox.IsChecked = $true
        }
        # Add the border to the corresponding Category
        $TargetElement.Children.Add($border) | Out-Null
        return $checkbox
    }

function Initialize-InstallCategoryAppList {
    <#
        .SYNOPSIS
            Clears the Target Element and sets up a "Loading" message. This is done, because loading of all apps can take a bit of time in some scenarios
            Iterates through all Categories and Apps and adds them to the UI
            Used to as part of the Install Tab UI generation
        .PARAMETER TargetElement
            The Element into which the Categories and Apps should be placed
        .PARAMETER Apps
            The Hashtable of Apps to be added to the UI
            The Categories are also extracted from the Apps Hashtable

    #>
        param(
            $TargetElement,
            $Apps
        )

        # Pre-group apps by category before creating WPF controls.
        $appsByCategory = @{}
        foreach ($appKey in $Apps.Keys) {
            $category = $Apps.$appKey.Category
            if (-not $appsByCategory.ContainsKey($category)) {
                $appsByCategory[$category] = @()
            }
            $appsByCategory[$category] += $appKey
        }
        $sync.InstallAppRenderQueue = [System.Collections.Queue]::new()

        foreach ($category in $($appsByCategory.Keys | Sort-Object)) {
            # Create a container for category label + apps
            $categoryContainer = New-Object Windows.Controls.StackPanel
            $categoryContainer.Orientation = "Vertical"
            $categoryContainer.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $categoryContainer.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            [System.Windows.Automation.AutomationProperties]::SetName($categoryContainer, $Category)

            # Bind Width to the ItemsControl's ActualWidth to force full-row layout in WrapPanel
            $binding = New-Object Windows.Data.Binding
            $binding.Path = New-Object Windows.PropertyPath("ActualWidth")
            $binding.RelativeSource = New-Object Windows.Data.RelativeSource([Windows.Data.RelativeSourceMode]::FindAncestor, [Windows.Controls.ItemsControl], 1)
            [void][Windows.Data.BindingOperations]::SetBinding($categoryContainer, [Windows.FrameworkElement]::WidthProperty, $binding)

            # Add category label to container
            $toggleButton = New-Object Windows.Controls.Label
            $toggleButton.Content = "- $Category"
            $toggleButton.Tag = "CategoryToggleButton"
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontSizeProperty, "HeaderFontSize")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::FontFamilyProperty, "HeaderFontFamily")
            $toggleButton.SetResourceReference([Windows.Controls.Control]::ForegroundProperty, "LabelboxForegroundColor")
            $toggleButton.Cursor = [System.Windows.Input.Cursors]::Hand
            $toggleButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
            $sync.$Category = $toggleButton

            # Add click handler to toggle category visibility
            $toggleButton.Add_MouseLeftButtonUp({
                param($categoryToggle)

                # Find the parent StackPanel (categoryContainer)
                $categoryContainer = $categoryToggle.Parent
                if ($categoryContainer -and $categoryContainer.Children.Count -ge 2) {
                    # The WrapPanel is the second child
                    $wrapPanel = $categoryContainer.Children[1]

                    # Toggle visibility
                    if ($wrapPanel.Visibility -eq [Windows.Visibility]::Visible) {
                        $wrapPanel.Visibility = [Windows.Visibility]::Collapsed
                        # Change - to +
                        $categoryToggle.Content = $categoryToggle.Content -replace "^- ", "+ "
                    } else {
                        $wrapPanel.Visibility = [Windows.Visibility]::Visible
                        # Change + to -
                        $categoryToggle.Content = $categoryToggle.Content -replace "^\+ ", "- "
                    }
                }
            })

            $null = $categoryContainer.Children.Add($toggleButton)

            # Add wrap panel for apps to container
            $wrapPanel = New-Object Windows.Controls.WrapPanel
            $wrapPanel.Orientation = "Horizontal"
            $wrapPanel.HorizontalAlignment = "Left"
            $wrapPanel.VerticalAlignment = "Top"
            $wrapPanel.Margin = New-Object Windows.Thickness(0, 0, 0, 0)
            $wrapPanel.Visibility = [Windows.Visibility]::Visible
            $wrapPanel.Tag = "CategoryWrapPanel_$category"

            $null = $categoryContainer.Children.Add($wrapPanel)

            # Add the entire category container to the target element
            $null = $TargetElement.Items.Add($categoryContainer)

            $sync.InstallAppRenderQueue.Enqueue([pscustomobject]@{
                Category = $category
                TargetElement = $wrapPanel
                AppKeys = @($appsByCategory[$category] | Sort-Object)
            })
        }

        Start-WinUtilInstallAppRendering
    }

function Initialize-WinUtilRunspacePool {
    if ($sync.runspace -and $sync.runspace.RunspacePoolStateInfo.State -eq [System.Management.Automation.Runspaces.RunspacePoolState]::Opened) {
        return $sync.runspace
    }

    if ($sync.runspace) {
        Close-WinUtilRunspacePool
    }

    # Set the maximum number of threads for the RunspacePool to the number of threads on the machine.
    $maxthreads = [Math]::Max([int]$env:NUMBER_OF_PROCESSORS, 1)

    # Create a new session state for parsing variables into our runspace.
    $hashVars = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'sync', $sync, $null
    $offlineVar = New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry -ArgumentList 'PARAM_OFFLINE', $PARAM_OFFLINE, $null
    $initialSessionState = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()

    $initialSessionState.Variables.Add($hashVars)
    $initialSessionState.Variables.Add($offlineVar)

    # Get every WinUtil/WPF function and add it to the session state.
    $functions = Get-ChildItem function:\ | Where-Object { $_.Name -imatch 'winutil|WPF' }
    foreach ($function in $functions) {
        $functionDefinition = Get-Content function:\$($function.Name)
        $functionEntry = New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry -ArgumentList $function.Name, $functionDefinition
        $initialSessionState.Commands.Add($functionEntry)
    }

    $sync.runspace = [runspacefactory]::CreateRunspacePool(
        1,                      # Minimum thread count
        $maxthreads,            # Maximum thread count
        $initialSessionState,   # Initial session state
        $Host                   # Machine to create runspaces on
    )

    $sync.runspace.Open()
    return $sync.runspace
}

function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$TabName]) {
        return
    }

    # Map Chinese tab names to internal switch labels
    $tabMap = @{
        "应用安装"       = "Install"
        "系统优化"       = "Tweaks"
        "功能配置"       = "Config"
        "Windows 更新"  = "Updates"
        "Win11 创建工具" = "Win11ISO"
        "AppX 移除"     = "AppX"
        "AppX"          = "AppX"
    }

    $normalizedTab = if ($tabMap.ContainsKey($TabName)) { $tabMap[$TabName] } else { $TabName }

    switch ($normalizedTab) {
        "Install" {
            Invoke-WPFUIElements -configVariable $sync.configs.appnavigation -targetGridName "appscategory" -columncount 1
            Initialize-WPFUI -targetGridName "appscategory"

            Initialize-WPFUI -targetGridName "appspanel"
        }
        "Tweaks" {
            Invoke-WPFUIElements -configVariable $sync.configs.tweaks -targetGridName "tweakspanel" -columncount 2
        }
        "Config" {
            Invoke-WPFUIElements -configVariable $sync.configs.feature -targetGridName "featurespanel" -columncount 2
        }
        "AppX" {
            Invoke-WPFUIElements -configVariable $sync.configs.appx -targetGridName "appxpanel" -columncount 2
        }
        "Win11ISO" {
            if ($sync.Form -and $sync.Form.Dispatcher) {
                $sync.Form.Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Invoke-WinUtilISOCheckExistingWork }) | Out-Null
            }
        }
    }

    $sync.InitializedTabs[$TabName] = $true
}

function Initialize-WinUtilTaskbarOverlayAssets {
    param(
        [bool]$IncludeLogo = $true,
        [bool]$IncludeStatusAssets = $true
    )

    if ($IncludeLogo -and -not $sync["logorender"]) {
        $sync["logorender"] = (Invoke-WinUtilAssets -Type "Logo" -Size 90 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["checkmarkrender"]) {
        $sync["checkmarkrender"] = (Invoke-WinUtilAssets -Type "checkmark" -Size 512 -Render)
    }

    if ($IncludeStatusAssets -and -not $sync["warningrender"]) {
        $sync["warningrender"] = (Invoke-WinUtilAssets -Type "warning" -Size 512 -Render)
    }
}

function Install-WinUtilAPPX {
    <#

    .SYNOPSIS
        Registers a local AppX package or installs it from the Microsoft Store

    .PARAMETER Name
        The AppX package name to install

    .PARAMETER StoreId
        The optional Microsoft Store product ID used when no local manifest is available

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [string]$StoreId
    )

    Write-WinUtilLog -Component "AppX" -Message "Installing AppX package: $Name"

    # AppX and DISM cmdlets are more reliable in Windows PowerShell 5.1. Query both installed and
    # provisioned package metadata because either can expose a local manifest that can be registered.
    $ps5Command = {
        $packageName = $args[0]
        $manifestPaths = [System.Collections.Generic.List[string]]::new()

        Get-AppxPackage -AllUsers -Name $packageName -ErrorAction SilentlyContinue |
            Sort-Object -Property Version -Descending |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue |
            Where-Object DisplayName -EQ $packageName |
            ForEach-Object {
                if (-not [string]::IsNullOrWhiteSpace($_.InstallLocation)) {
                    $manifestPaths.Add((Join-Path $_.InstallLocation "AppxManifest.xml"))
                }
            }

        $manifestPath = $manifestPaths |
            Select-Object -Unique |
            Where-Object { Test-Path -LiteralPath $_ } |
            Select-Object -First 1

        if ($null -ne $manifestPath) {
            Add-AppxPackage -Register $manifestPath -DisableDevelopmentMode -ErrorAction Stop
            Write-Output $manifestPath
        }
    }

    $manifestOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $Name 2>&1
    if ($LASTEXITCODE -eq 0 -and $null -ne $manifestOutput) {
        $manifestPath = ($manifestOutput | Select-Object -Last 1).ToString().Trim()
        if (-not [string]::IsNullOrWhiteSpace($manifestPath)) {
            Write-WinUtilLog -Component "AppX" -Message "Registered local AppX manifest for $Name`: $manifestPath"
            return
        }
    }

    if ($LASTEXITCODE -ne 0) {
        $failureDetails = ($manifestOutput | Out-String).Trim()
        Write-WinUtilLog -Level "WARN" -Component "AppX" -Message "Local AppX registration failed for $Name`: $failureDetails"
    }

    if ([string]::IsNullOrWhiteSpace($StoreId)) {
        $errorMessage = "Unable to install $Name because no local manifest or Microsoft Store ID is available."
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "No usable local manifest found for $Name. Installing Microsoft Store product $StoreId."
    Install-WinUtilWinget
    Install-WinUtilProgramWinget -Action Install -Programs @("msstore:$StoreId")
}

function Install-WinUtilChoco {
    if (-not (Get-Command -Name choco)) {
      Write-Host "Chocolatey 未安装。正在安装..."
      $installScript = Invoke-WebRequest -Uri https://community.chocolatey.org/install.ps1 -UseBasicParsing
      Invoke-Command -ScriptBlock ([scriptblock]::Create($installScript.Content))
    }
}

function Install-WinUtilProgramChoco {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    if ($Action -eq 'Install') {
        $arguments = "install $Programs -y"
    } else {
        $arguments = "uninstall $Programs -y"
    }

    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s): $($Programs -join ', ')"
    $process = Start-Process -FilePath choco -ArgumentList $arguments -NoNewWindow -Wait -PassThru
    Write-WinUtilLog -Component "Package" -Message "$Action choco package(s) completed: $($Programs -join ', ') (exit code: $($process.ExitCode))"
}

Function Install-WinUtilProgramWinget {
    param (
        [Parameter(Mandatory=$true)]
        [ValidateSet("Install", "Uninstall")]
        [string]$Action,

        [Parameter(Mandatory=$true)]
        [string[]]$Programs
    )

    foreach ($program in $Programs) {
        if ([string]::IsNullOrWhiteSpace($program) -or $program -eq "na") {
            continue
        }

        $source = "winget"
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
        $process = Start-Process -FilePath winget -ArgumentList $arguments -NoNewWindow -Wait -PassThru
        Write-WinUtilLog -Component "Package" -Message "$Action winget package completed: $program (exit code: $($process.ExitCode))"
    }
}

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

function Invoke-WinUtilAssets {
  param (
      $type,
      $Size,
      [switch]$render
  )

  if ($render -and $null -ne $sync) {
      if ($null -eq $sync.RenderedAssetCache) {
          $sync.RenderedAssetCache = @{}
      }

      $cacheKey = "$(([string]$type).ToLowerInvariant())|$Size"
      if ($sync.RenderedAssetCache.ContainsKey($cacheKey)) {
          return $sync.RenderedAssetCache[$cacheKey]
      }
  }

  # Create the Viewbox and set its size
  $LogoViewbox = New-Object Windows.Controls.Viewbox
  $LogoViewbox.Width = $Size
  $LogoViewbox.Height = $Size

  # Create a Canvas to hold the paths
  $canvas = New-Object Windows.Controls.Canvas
  $canvas.Width = 100
  $canvas.Height = 100

  # Define a scale factor for the content inside the Canvas
  $scaleFactor = $Size / 100

  # Apply a scale transform to the Canvas content
  $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
  $canvas.LayoutTransform = $scaleTransform

  switch ($type) {
      'logo' {
          $LogoPathData1 = @"
M 18.00,14.00
C 18.00,14.00 45.00,27.74 45.00,27.74
45.00,27.74 57.40,34.63 57.40,34.63
57.40,34.63 59.00,43.00 59.00,43.00
59.00,43.00 59.00,83.00 59.00,83.00
55.35,81.66 46.99,77.79 44.72,74.79
41.17,70.10 42.01,59.80 42.00,54.00
42.00,51.62 42.20,48.29 40.98,46.21
38.34,41.74 25.78,38.60 21.28,33.79
16.81,29.02 18.00,20.20 18.00,14.00 Z
"@
          $LogoPath1 = New-Object Windows.Shapes.Path
          $LogoPath1.Data = [Windows.Media.Geometry]::Parse($LogoPathData1)
          $LogoPath1.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData2 = @"
M 107.00,14.00
C 109.01,19.06 108.93,30.37 104.66,34.21
100.47,37.98 86.38,43.10 84.60,47.21
83.94,48.74 84.01,51.32 84.00,53.00
83.97,57.04 84.46,68.90 83.26,72.00
81.06,77.70 72.54,81.42 67.00,83.00
67.00,83.00 67.00,43.00 67.00,43.00
67.00,43.00 67.99,35.63 67.99,35.63
67.99,35.63 80.00,28.26 80.00,28.26
80.00,28.26 107.00,14.00 107.00,14.00 Z
"@
          $LogoPath2 = New-Object Windows.Shapes.Path
          $LogoPath2.Data = [Windows.Media.Geometry]::Parse($LogoPathData2)
          $LogoPath2.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#0567ff")

          $LogoPathData3 = @"
M 19.00,46.00
C 21.36,47.14 28.67,50.71 30.01,52.63
31.17,54.30 30.99,57.04 31.00,59.00
31.04,65.41 30.35,72.16 33.56,78.00
38.19,86.45 46.10,89.04 54.00,93.31
56.55,94.69 60.10,97.20 63.00,97.22
65.50,97.24 68.77,95.36 71.00,94.25
76.42,91.55 84.51,87.78 88.82,83.68
94.56,78.20 95.96,70.59 96.00,63.00
96.01,60.24 95.59,54.63 97.02,52.39
98.80,49.60 103.95,47.87 107.00,47.00
107.00,47.00 107.00,67.00 107.00,67.00
106.90,87.69 96.10,93.85 80.00,103.00
76.51,104.98 66.66,110.67 63.00,110.52
60.33,110.41 55.55,107.53 53.00,106.25
46.21,102.83 36.63,98.57 31.04,93.68
16.88,81.28 19.00,62.88 19.00,46.00 Z
"@
          $LogoPath3 = New-Object Windows.Shapes.Path
          $LogoPath3.Data = [Windows.Media.Geometry]::Parse($LogoPathData3)
          $LogoPath3.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#a3a4a6")

          $canvas.Children.Add($LogoPath1) | Out-Null
          $canvas.Children.Add($LogoPath2) | Out-Null
          $canvas.Children.Add($LogoPath3) | Out-Null
      }
      'checkmark' {
          $canvas.Width = 512
          $canvas.Height = 512

          $scaleFactor = $Size / 2.54
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 1.27,0 A 1.27,1.27 0 1,0 1.27,2.54 A 1.27,1.27 0 1,0 1.27,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#39ba00")

          # Define the checkmark path
          $checkmarkPathData = "M 0.873 1.89 L 0.41 1.391 A 0.17 0.17 0 0 1 0.418 1.151 A 0.17 0.17 0 0 1 0.658 1.16 L 1.016 1.543 L 1.583 1.013 A 0.17 0.17 0 0 1 1.599 1 L 1.865 0.751 A 0.17 0.17 0 0 1 2.105 0.759 A 0.17 0.17 0 0 1 2.097 0.999 L 1.282 1.759 L 0.999 2.022 L 0.874 1.888 Z"
          $checkmarkPath = New-Object Windows.Shapes.Path
          $checkmarkPath.Data = [Windows.Media.Geometry]::Parse($checkmarkPathData)
          $checkmarkPath.Fill = [Windows.Media.Brushes]::White

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($checkmarkPath) | Out-Null
      }
      'warning' {
          $canvas.Width = 512
          $canvas.Height = 512

          # Define a scale factor for the content inside the Canvas
          $scaleFactor = $Size / 512  # Adjust scaling based on the canvas size
          $scaleTransform = New-Object Windows.Media.ScaleTransform($scaleFactor, $scaleFactor)
          $canvas.LayoutTransform = $scaleTransform

          # Define the circle path
          $circlePathData = "M 256,0 A 256,256 0 1,0 256,512 A 256,256 0 1,0 256,0"
          $circlePath = New-Object Windows.Shapes.Path
          $circlePath.Data = [Windows.Media.Geometry]::Parse($circlePathData)
          $circlePath.Fill = [System.Windows.Media.BrushConverter]::new().ConvertFromString("#f41b43")

          # Define the exclamation mark path
          $exclamationPathData = "M 256 307.2 A 35.89 35.89 0 0 1 220.14 272.74 L 215.41 153.3 A 35.89 35.89 0 0 1 251.27 116 H 260.73 A 35.89 35.89 0 0 1 296.59 153.3 L 291.86 272.74 A 35.89 35.89 0 0 1 256 307.2 Z"
          $exclamationPath = New-Object Windows.Shapes.Path
          $exclamationPath.Data = [Windows.Media.Geometry]::Parse($exclamationPathData)
          $exclamationPath.Fill = [Windows.Media.Brushes]::White

          # Get the bounds of the exclamation mark path
          $exclamationBounds = $exclamationPath.Data.Bounds

          # Calculate the center position for the exclamation mark path
          $exclamationCenterX = ($canvas.Width - $exclamationBounds.Width) / 2 - $exclamationBounds.X
          $exclamationPath.SetValue([Windows.Controls.Canvas]::LeftProperty, $exclamationCenterX)

          # Define the rounded rectangle at the bottom (dot of exclamation mark)
          $roundedRectangle = New-Object Windows.Shapes.Rectangle
          $roundedRectangle.Width = 80
          $roundedRectangle.Height = 80
          $roundedRectangle.RadiusX = 30
          $roundedRectangle.RadiusY = 30
          $roundedRectangle.Fill = [Windows.Media.Brushes]::White

          # Calculate the center position for the rounded rectangle
          $centerX = ($canvas.Width - $roundedRectangle.Width) / 2
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::LeftProperty, $centerX)
          $roundedRectangle.SetValue([Windows.Controls.Canvas]::TopProperty, 324.34)

          # Add the paths to the Canvas
          $canvas.Children.Add($circlePath) | Out-Null
          $canvas.Children.Add($exclamationPath) | Out-Null
          $canvas.Children.Add($roundedRectangle) | Out-Null
      }
      default {
          Write-Host "无效类型: $type"
      }
  }

  # Add the Canvas to the Viewbox
  $LogoViewbox.Child = $canvas

  if ($render) {
      # Measure and arrange the canvas to ensure proper rendering
      $canvas.Measure([Windows.Size]::new($canvas.Width, $canvas.Height))
      $canvas.Arrange([Windows.Rect]::new(0, 0, $canvas.Width, $canvas.Height))
      $canvas.UpdateLayout()

      # Initialize RenderTargetBitmap correctly with dimensions
      $renderTargetBitmap = New-Object Windows.Media.Imaging.RenderTargetBitmap($canvas.Width, $canvas.Height, 96, 96, [Windows.Media.PixelFormats]::Pbgra32)

      # Render the canvas to the bitmap
      $renderTargetBitmap.Render($canvas)

      # Create a BitmapFrame from the RenderTargetBitmap
      $bitmapFrame = [Windows.Media.Imaging.BitmapFrame]::Create($renderTargetBitmap)

      # Create a PngBitmapEncoder and add the frame
      $bitmapEncoder = [Windows.Media.Imaging.PngBitmapEncoder]::new()
      $bitmapEncoder.Frames.Add($bitmapFrame)

      # Save to a memory stream
      $imageStream = New-Object System.IO.MemoryStream
      $bitmapEncoder.Save($imageStream)
      $imageStream.Position = 0

      # Load the stream into a BitmapImage
      $bitmapImage = [Windows.Media.Imaging.BitmapImage]::new()
      $bitmapImage.BeginInit()
      $bitmapImage.StreamSource = $imageStream
      $bitmapImage.CacheOption = [Windows.Media.Imaging.BitmapCacheOption]::OnLoad
      $bitmapImage.EndInit()
      if ($bitmapImage.CanFreeze) {
          $bitmapImage.Freeze()
      }

      if ($null -ne $sync -and $sync.ContainsKey("RenderedAssetCache")) {
          $sync.RenderedAssetCache[$cacheKey] = $bitmapImage
      }

      return $bitmapImage
  } else {
      return $LogoViewbox
  }
}

Function Invoke-WinUtilCurrentSystem {

    <#

    .SYNOPSIS
        Checks to see what tweaks have already been applied and what programs are installed, and checks the according boxes

    .EXAMPLE
        InvokeWinUtilCurrentSystem -Checkbox "winget"

    #>

    param(
        $CheckBox
    )
    if ($CheckBox -eq "choco") {
        $apps = (choco list | Select-String -Pattern "^\S+").Matches.Value
        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = ($_.Value.choco -split ";")[-1].Trim()
            if ($packageId -ne "na" -and $packageId -in $apps) {
                Write-Output $_.Key
            }
        }
    }

    if ($checkbox -eq "winget") {
        $originalEncoding = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new()
            $installedProgramOutput = @(winget list --accept-source-agreements --disable-interactivity 2>&1)
            if ($LASTEXITCODE -ne 0) {
                throw "winget list failed with exit code $LASTEXITCODE."
            }
        } finally {
            [Console]::OutputEncoding = $originalEncoding
        }
        $installedProgramText = $installedProgramOutput -join "`n"

        $sync.configs.applicationsHashtable.GetEnumerator() | ForEach-Object {
            $packageId = (($_.Value.winget -split ";")[-1] -replace "^msstore:", "").Trim()
            if ([string]::IsNullOrWhiteSpace($packageId) -or $packageId -eq "na") {
                return
            }

            $packagePattern = "(?im)[^\S\r\n]{2,}$([regex]::Escape($packageId))(?=[^\S\r\n]{2,}|$)"
            if ($installedProgramText -match $packagePattern) {
                Write-Output $_.Key
            }
        }
    }

    if ($CheckBox -eq "tweaks") {

        if (!(Test-Path 'HKU:\')) {$null = (New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS)}

        $sync.configs.tweaks | Get-Member -MemberType NoteProperty | ForEach-Object {

            $Config = $psitem.Name
            $entry = $sync.configs.tweaks.$Config
            $registryKeys = $entry.registry
            $serviceKeys = $entry.service
            $entryType = $entry.Type

            if ($registryKeys -or $serviceKeys) {
                $Values = @()

                if ($entryType -eq "Toggle") {
                    if (-not (Get-WinUtilToggleStatus $Config)) {
                        $values += $False
                    }
                } else {
                    $registryMatchCount = 0
                    $registryTotal = 0

                    Foreach ($tweaks in $registryKeys) {
                        Foreach ($tweak in $tweaks) {
                            $registryTotal++
                            $regstate = $null

                            if (Test-Path $tweak.Path) {
                                $regstate = Get-ItemProperty -Name $tweak.Name -Path $tweak.Path -ErrorAction SilentlyContinue | Select-Object -ExpandProperty $($tweak.Name)
                            }

                            if ($null -eq $regstate) {
                                switch ($tweak.DefaultState) {
                                    "true" {
                                        $regstate = $tweak.Value
                                    }
                                    "false" {
                                        $regstate = $tweak.OriginalValue
                                    }
                                    default {
                                        $regstate = $tweak.OriginalValue
                                    }
                                }
                            }

                            if ($regstate -eq $tweak.Value) {
                                $registryMatchCount++
                            }
                        }
                    }

                    if ($registryTotal -gt 0 -and $registryMatchCount -ne $registryTotal) {
                        $values += $False
                    }
                }

                Foreach ($tweaks in $serviceKeys) {
                    Foreach ($tweak in $tweaks) {
                        $Service = Get-Service -Name $tweak.Name

                        if ($Service) {
                            $actualValue = $Service.StartType
                            $expectedValue = $tweak.StartupType
                            if ($expectedValue -ne $actualValue) {
                                $values += $False
                            }
                        }
                    }
                }

                if ($values -notcontains $false) {
                    Write-Output $Config
                }
            }
        }
    }
}

function Invoke-WinUtilExplorerUpdate {
     <#
    .SYNOPSIS
        Refreshes the Windows Explorer
    #>
    param (
        [string]$action = "refresh"
    )

    if ($action -eq "refresh") {
        Invoke-WPFRunspace -ScriptBlock {
            # Define the Win32 type only if it doesn't exist
            if (-not ([System.Management.Automation.PSTypeName]'Win32').Type) {
                Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class Win32 {
    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = false)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, IntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out IntPtr lpdwResult);
}
"@
            }

            $HWND_BROADCAST = [IntPtr]0xffff
            $WM_SETTINGCHANGE = 0x1A
            $SMTO_ABORTIFHUNG = 0x2

            [Win32]::SendMessageTimeout($HWND_BROADCAST, $WM_SETTINGCHANGE,
                [IntPtr]::Zero, "ImmersiveColorSet", $SMTO_ABORTIFHUNG, 100,
                [ref]([IntPtr]::Zero))
        }
    } elseif ($action -eq "restart") {
        taskkill.exe /F /IM "explorer.exe"
        Start-Process "explorer.exe"
    }
}

function Invoke-WinUtilFeatureInstall ($CheckBox) {
    Write-WinUtilLog -Component "Feature" -Message "Applying feature action: $CheckBox"

    if ($sync.configs.feature.$CheckBox.feature) {
        foreach ($feature in $sync.configs.feature.$CheckBox.feature) {
            Write-Host "正在安装 $feature"
            Write-WinUtilLog -Component "Feature" -Message "Enabling Windows optional feature: $feature"
            Enable-WindowsOptionalFeature -Online -FeatureName $feature -All -NoRestart -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Enabled Windows optional feature: $feature"
        }
    }

    if ($sync.configs.feature.$CheckBox.InvokeScript) {
        foreach ($script in $sync.configs.feature.$CheckBox.InvokeScript) {
            Write-Host "正在运行 $CheckBox 的脚本"
            Write-WinUtilLog -Component "Feature" -Message "Running feature script for: $CheckBox"
            Invoke-Command -ScriptBlock ([scriptblock]::Create($script)) -ErrorAction Stop
            Write-WinUtilLog -Component "Feature" -Message "Completed feature script for: $CheckBox"
        }
    }
    Write-WinUtilLog -Component "Feature" -Message "Feature action completed: $CheckBox"
}

function Invoke-WinUtilFontScaling {
    <#

    .SYNOPSIS
        Applies UI and font scaling for accessibility

    .PARAMETER ScaleFactor
        Sets the scaling from 0.75 and 2.0.
        Default is 1.0 (100% - no scaling)

    .EXAMPLE
        Invoke-WinUtilFontScaling -ScaleFactor 1.25
        # Applies 125% scaling
    #>

    param (
        [double]$ScaleFactor = 1.0
    )

    # Validate if scale factor is within the range
    if ($ScaleFactor -lt 0.75 -or $ScaleFactor -gt 2.0) {
        Write-Warning "Scale factor must be between 0.75 and 2.0. Using 1.0 instead."
        $ScaleFactor = 1.0
    }

    # Define an array for resources to be scaled
    $fontResources = @(
        # Fonts
        "FontSize",
        "ButtonFontSize",
        "HeaderFontSize",
        "TabButtonFontSize",
        "ConfigTabButtonFontSize",
        "IconFontSize",
        "SettingsIconFontSize",
        "CloseIconFontSize",
        "AppEntryFontSize",
        "SearchBarTextBoxFontSize",
        "SearchBarClearButtonFontSize",
        "CustomDialogFontSize",
        "CustomDialogFontSizeHeader",
        "ConfigUpdateButtonFontSize",
        # Buttons and UI
        "CheckBoxBulletDecoratorSize",
        "ButtonWidth",
        "ButtonHeight",
        "TabButtonWidth",
        "TabButtonHeight",
        "IconButtonSize",
        "AppEntryWidth",
        "SearchBarWidth",
        "SearchBarHeight",
        "CustomDialogWidth",
        "CustomDialogHeight",
        "CustomDialogLogoSize",
        "ToolTipWidth"
    )

    # Apply scaling to each resource
    foreach ($resourceName in $fontResources) {
        try {
            # Get the default font size from the theme configuration
            $originalValue = $sync.configs.themes.shared.$resourceName
            if ($originalValue) {
                # Convert string to double since values are stored as strings
                $originalValue = [double]$originalValue
                # Calculates and applies the new font size
                $newValue = [math]::Round($originalValue * $ScaleFactor, 1)
                $sync.Form.Resources[$resourceName] = $newValue
            }
        }
        catch {
            Write-Warning "Failed to scale resource $resourceName : $_"
        }
    }

    # Store the scale factor so it can be reapplied after theme changes
    $sync.FontScaleFactor = $ScaleFactor

    # Update the font scaling percentage displayed on the UI
    if ($sync.FontScalingValue) {
        $percentage = [math]::Round($ScaleFactor * 100)
        $sync.FontScalingValue.Text = "$percentage%"
    }
}

function Write-Win11ISOLog {
    param([string]$Message)
    $ts = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$ts] $Message"
    $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
        $current = $sync["WPFWin11ISOStatusLog"].Text
        if ($current -eq "Ready. Please select a Windows 11 ISO to begin.") {
            $sync["WPFWin11ISOStatusLog"].Text = $logLine
        } else {
            $sync["WPFWin11ISOStatusLog"].Text += "`n$logLine"
        }
        $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
        $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
    })
}

function Invoke-WinUtilISOBrowse {
    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.OpenFileDialog]::new()
    $dlg.Title            = "Select Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso|All files (*.*)|*.*"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $isoPath    = $dlg.FileName
    $fileSizeGB = [math]::Round((Get-Item $isoPath).Length / 1GB, 2)

    $sync["WPFWin11ISOPath"].Text           = $isoPath
    $sync["WPFWin11ISOFileInfo"].Text       = "File size: $fileSizeGB GB"
    $sync["WPFWin11ISOFileInfo"].Visibility = "Visible"
    $sync["WPFWin11ISOMountSection"].Visibility       = "Visible"
    $sync["WPFWin11ISOVerifyResultPanel"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility      = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility      = "Collapsed"

    Write-Win11ISOLog "ISO selected: $isoPath  ($fileSizeGB GB)"
}

function Invoke-WinUtilISOMountAndVerify {
    $isoPath = $sync["WPFWin11ISOPath"].Text

    if ([string]::IsNullOrWhiteSpace($isoPath) -or $isoPath -eq "No ISO selected...") {
        [System.Windows.MessageBox]::Show("Please select an ISO file first.", "No ISO Selected", "OK", "Warning")
        return
    }

    Write-Win11ISOLog "Mounting ISO: $isoPath"
    Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Mounting ISO..." -Percent 10

    try {
        Mount-DiskImage -ImagePath $isoPath

        do {
            Start-Sleep -Milliseconds 500
        } until ((Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter)

        $driveLetter = (Get-DiskImage -ImagePath $isoPath | Get-Volume).DriveLetter + ":"
        Write-Win11ISOLog "Mounted at drive $driveLetter"

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Verifying ISO contents..." -Percent 30

        $wimPath = Join-Path $driveLetter "sources\install.wim"
        $esdPath = Join-Path $driveLetter "sources\install.esd"

        if (-not (Test-Path $wimPath) -and -not (Test-Path $esdPath)) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: install.wim/install.esd not found - not a valid Windows ISO."
            [System.Windows.MessageBox]::Show(
                "This does not appear to be a valid Windows ISO.`n`ninstall.wim / install.esd was not found.",
                "Invalid ISO", "OK", "Error")
            Set-WinUtilTweaksProgressIndicator -Visible $false
            return
        }

        $activeWim = if (Test-Path $wimPath) { $wimPath } else { $esdPath }

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "Reading image metadata..." -Percent 55
        $imageInfo = Get-WindowsImage -ImagePath $activeWim | Select-Object ImageIndex, ImageName

        if (-not ($imageInfo | Where-Object { $_.ImageName -match "Windows 11" })) {
            Dismount-DiskImage -ImagePath $isoPath
            Write-Win11ISOLog "ERROR: No 'Windows 11' edition found in the image."
            [System.Windows.MessageBox]::Show(
                "No Windows 11 edition was found in this ISO.`n`nOnly official Windows 11 ISOs are supported.",
                "Not a Windows 11 ISO", "OK", "Error")
            Set-WinUtilTweaksProgressIndicator -Visible $false
            return
        }

        $sync["Win11ISOImageInfo"] = $imageInfo

        $sync["WPFWin11ISOMountDriveLetter"].Text = "Mounted at: $driveLetter   |   Image file: $(Split-Path $activeWim -Leaf)"
        $sync["WPFWin11ISOEditionComboBox"].Dispatcher.Invoke([action]{
            $sync["WPFWin11ISOEditionComboBox"].Items.Clear()
            foreach ($img in $imageInfo) {
                [void]$sync["WPFWin11ISOEditionComboBox"].Items.Add("$($img.ImageIndex): $($img.ImageName)")
            }
            if ($sync["WPFWin11ISOEditionComboBox"].Items.Count -gt 0) {
                $proIndex = -1
                for ($i = 0; $i -lt $sync["WPFWin11ISOEditionComboBox"].Items.Count; $i++) {
                    if ($sync["WPFWin11ISOEditionComboBox"].Items[$i] -match "Windows 11 Pro(?![\w ])") {
                        $proIndex = $i; break
                    }
                }
                $sync["WPFWin11ISOEditionComboBox"].SelectedIndex = if ($proIndex -ge 0) { $proIndex } else { 0 }
            }
        })
        $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Visible"

        $sync["Win11ISODriveLetter"] = $driveLetter
        $sync["Win11ISOWimPath"]     = $activeWim
        $sync["Win11ISOImagePath"]   = $isoPath
        $sync["WPFWin11ISOModifySection"].Visibility = "Visible"

        Set-WinUtilTweaksProgressIndicator -Visible $true -Label "ISO verified" -Percent 100
        Write-Win11ISOLog "ISO verified OK.  Editions found: $($imageInfo.Count)"
    } catch {
        Write-Win11ISOLog "ERROR during mount/verify: $_"
        [System.Windows.MessageBox]::Show(
            "An error occurred while mounting or verifying the ISO:`n`n$_",
            "Error", "OK", "Error")
    } finally {
        Start-Sleep -Milliseconds 800
        Set-WinUtilTweaksProgressIndicator -Visible $false
    }
}

function Invoke-WinUtilISOModify {
    $isoPath     = $sync["Win11ISOImagePath"]
    $driveLetter = $sync["Win11ISODriveLetter"]
    $wimPath     = $sync["Win11ISOWimPath"]

    if (-not $isoPath) {
        [System.Windows.MessageBox]::Show(
            "No verified ISO found. Please complete Steps 1 and 2 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    $selectedItem     = $sync["WPFWin11ISOEditionComboBox"].SelectedItem
    $selectedWimIndex = 1
    if ($selectedItem -and $selectedItem -match '^(\d+):') {
        $selectedWimIndex = [int]$Matches[1]
    } elseif ($sync["Win11ISOImageInfo"]) {
        $selectedWimIndex = $sync["Win11ISOImageInfo"][0].ImageIndex
    }
    $selectedEditionName = if ($selectedItem) { ($selectedItem -replace '^\d+:\s*', '') } else { "Unknown" }
    Write-Win11ISOLog "Selected edition: $selectedEditionName (Index $selectedWimIndex)"

    $sync["WPFWin11ISOModifyButton"].IsEnabled = $false
    $sync["Win11ISOModifying"] = $true
    $sync["Win11ISOProcessRunning"] = $true

    $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')"
    if (Test-Path $workDir) {
        $workDir = Join-Path $env:TEMP "WinUtil_Win11ISO_$(Get-Date -Format 'yyyyMMdd_HHmmss')_$(([guid]::NewGuid()).ToString('N').Substring(0, 8))"
    }

    $autounattendContent = if ($WinUtilAutounattendXml) {
        $WinUtilAutounattendXml
    } else {
        $toolsXml = Join-Path $PSScriptRoot "..\..\tools\autounattend.xml"
        if (Test-Path $toolsXml) { Get-Content $toolsXml -Raw } else { "" }
    }

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $injectDrivers = $sync["WPFWin11ISOInjectDrivers"].IsChecked -eq $true

    $runspace.SessionStateProxy.SetVariable("sync",                $sync)
    $runspace.SessionStateProxy.SetVariable("isoPath",             $isoPath)
    $runspace.SessionStateProxy.SetVariable("driveLetter",         $driveLetter)
    $runspace.SessionStateProxy.SetVariable("wimPath",             $wimPath)
    $runspace.SessionStateProxy.SetVariable("workDir",             $workDir)
    $runspace.SessionStateProxy.SetVariable("selectedWimIndex",    $selectedWimIndex)
    $runspace.SessionStateProxy.SetVariable("selectedEditionName", $selectedEditionName)
    $runspace.SessionStateProxy.SetVariable("autounattendContent", $autounattendContent)
    $runspace.SessionStateProxy.SetVariable("injectDrivers",       $injectDrivers)

    $isoScriptFuncDef   = "function Invoke-WinUtilISOScript {`n" + ${function:Invoke-WinUtilISOScript}.ToString() + "`n}"
    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n"       + ${function:Write-Win11ISOLog}.ToString()       + "`n}"
    $runspace.SessionStateProxy.SetVariable("isoScriptFuncDef",   $isoScriptFuncDef)
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($isoScriptFuncDef))
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-WinUtilEditionIdFromName {
            param([string]$EditionName)

            $normalizedName = ($EditionName -replace '^Windows\s+11\s+', '').Trim()
            switch -Regex ($normalizedName) {
                '^Home Single Language$'      { return 'CoreSingleLanguage' }
                '^Home N$'                    { return 'CoreN' }
                '^Home$'                      { return 'Core' }
                '^Pro for Workstations N$'    { return 'ProfessionalWorkstationN' }
                '^Pro for Workstations$'      { return 'ProfessionalWorkstation' }
                '^Pro Education N$'           { return 'ProfessionalEducationN' }
                '^Pro Education$'             { return 'ProfessionalEducation' }
                '^Pro N$'                     { return 'ProfessionalN' }
                '^Pro$'                       { return 'Professional' }
                '^Education N$'               { return 'EducationN' }
                '^Education$'                 { return 'Education' }
                '^Enterprise LTSC N$'         { return 'EnterpriseSN' }
                '^Enterprise LTSC$'           { return 'EnterpriseS' }
                '^Enterprise N$'              { return 'EnterpriseN' }
                '^Enterprise$'                { return 'Enterprise' }
                default                       { return '' }
            }
        }

        function Get-WinUtilMountedImageEditionId {
            param(
                [Parameter(Mandatory)][string]$MountDir,
                [string]$EditionName,
                [scriptblock]$Logger
            )

            try {
                $dismOutput = & dism /English "/Image:$MountDir" /Get-CurrentEdition 2>&1
                foreach ($line in $dismOutput) {
                    if ($line -match '^\s*Current Edition\s*:\s*(.+?)\s*$') {
                        $editionId = $Matches[1].Trim()
                        if ($editionId) {
                            if ($Logger) { $null = $Logger.Invoke("Detected mounted image EditionID: $editionId") }
                            return $editionId
                        }
                    }
                }
            } catch {
                if ($Logger) { $null = $Logger.Invoke("Warning: could not detect mounted image EditionID with DISM: $_") }
            }

            $fallbackEditionId = Get-WinUtilEditionIdFromName -EditionName $EditionName
            if ($fallbackEditionId -and $Logger) {
                $null = $Logger.Invoke("Using fallback EditionID '$fallbackEditionId' from selected edition name.")
            }
            return $fallbackEditionId
        }

        function Get-DismImageInfoMap {
            param(
                [Parameter(Mandatory)][string]$ImagePath,
                [int]$Index = 1
            )

            $map = @{}
            $lines = & dism /English "/Get-ImageInfo" "/ImageFile:$ImagePath" "/Index:$Index"
            foreach ($line in $lines) {
                if ($line -match '^\s*([^:]+?)\s*:\s*(.*)$') {
                    $key = $Matches[1].Trim()
                    $val = $Matches[2].Trim()
                    if (-not $map.ContainsKey($key)) {
                        $map[$key] = $val
                    }
                }
            }
            return $map
        }

        function Invoke-WinUtilWimMetadataHydration {
            param(
                [Parameter(Mandatory)][string]$ImagePath,
                [Parameter(Mandatory)][string]$EditionName,
                [scriptblock]$Logger
            )

            $metadataLogger = $Logger

            function LogMeta([string]$Message) {
                if ($metadataLogger) {
                    $null = $metadataLogger.Invoke($Message)
                }
            }

            $before = Get-DismImageInfoMap -ImagePath $ImagePath -Index 1
            $undefinedBefore = @($before.GetEnumerator() | Where-Object { $_.Value -eq '<undefined>' } | ForEach-Object { $_.Key })

            if ($undefinedBefore.Count -eq 0) {
                LogMeta "Metadata check: no undefined DISM fields detected."
                return
            }

            LogMeta "Metadata check: undefined DISM fields detected: $($undefinedBefore -join ', ')"
            LogMeta "Attempting best-effort metadata hydration for install.wim..."

            $setImage = Get-Command Set-WindowsImage -ErrorAction SilentlyContinue
            if (-not $setImage) {
                LogMeta "Set-WindowsImage is unavailable on this host; cannot write additional WIM metadata fields."
                return
            }

            $targetName = if ($EditionName -and $EditionName -ne 'Unknown') { $EditionName } else { $before['Name'] }
            if (-not $targetName) { $targetName = 'Windows 11' }

            $targetDescription = if ($before['Description'] -and $before['Description'] -ne '<undefined>') {
                $before['Description']
            } else {
                $targetName
            }

            $setArgs = @{
                ImagePath   = $ImagePath
                Index       = 1
                Name        = $targetName
                Description = $targetDescription
                ErrorAction = 'Stop'
            }

            try {
                Set-WindowsImage @setArgs | Out-Null
                LogMeta "Applied Set-WindowsImage metadata updates (Name/Description)."
            } catch {
                LogMeta "Warning: Set-WindowsImage metadata update failed: $_"
            }

            $after = Get-DismImageInfoMap -ImagePath $ImagePath -Index 1
            $undefinedAfter = @($after.GetEnumerator() | Where-Object { $_.Value -eq '<undefined>' } | ForEach-Object { $_.Key })
            if ($undefinedAfter.Count -eq 0) {
                LogMeta "Metadata hydration complete: no undefined DISM fields remain."
            } else {
                LogMeta "Metadata hydration complete. Remaining undefined DISM fields: $($undefinedAfter -join ', ')"
                LogMeta "Note: some DISM metadata fields are read-only and come from Microsoft image internals."
            }
        }

        try {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
            })

            Log "Creating working directory: $workDir"
            $isoContents = Join-Path $workDir "iso_contents"
            $mountDir    = Join-Path $workDir "wim_mount"
            New-Item -ItemType Directory -Path $isoContents, $mountDir -Force
            SetProgress "Copying ISO contents..." 10

            Log "Copying ISO contents from $driveLetter to $isoContents..."
            & robocopy $driveLetter $isoContents /E /NFL /NDL /NJH /NJS
            Log "ISO contents copied."
            SetProgress "Mounting install.wim..." 25

            $sourceImageFileName = Split-Path $wimPath -Leaf
            $localWim = Join-Path $isoContents "sources\$sourceImageFileName"
            if (-not (Test-Path $localWim)) {
                throw "Copied ISO image file not found: sources\$sourceImageFileName"
            }
            Set-ItemProperty -Path $localWim -Name IsReadOnly -Value $false

            Log "Mounting install.wim (Index ${selectedWimIndex}: $selectedEditionName) at $mountDir..."
            Mount-WindowsImage -ImagePath $localWim -Index $selectedWimIndex -Path $mountDir
            SetProgress "Modifying install.wim..." 45
            $selectedEditionId = Get-WinUtilMountedImageEditionId -MountDir $mountDir -EditionName $selectedEditionName -Logger ${function:Log}

            Log "Applying WinUtil modifications to install.wim..."
            Invoke-WinUtilISOScript -ScratchDir $mountDir -ISOContentsDir $isoContents -AutoUnattendXml $autounattendContent -InjectCurrentSystemDrivers $injectDrivers -InstallEditionId $selectedEditionId -InstallImageIndex 1 -Log { param($m) Log $m }

            SetProgress "Cleaning up component store (WinSxS)..." 56
            Log "Running DISM component store cleanup (/ResetBase)..."
            & dism /English "/image:$mountDir" /Cleanup-Image /StartComponentCleanup /ResetBase | ForEach-Object { Log $_ }
            Log "Component store cleanup complete."

            SetProgress "Saving modified install.wim..." 65
            Log "Dismounting and saving install.wim. This will take several minutes..."
            Dismount-WindowsImage -Path $mountDir -Save
            Log "install.wim saved."

            SetProgress "Removing unused editions from install.wim..." 70
            Log "Exporting edition '$selectedEditionName' (Index $selectedWimIndex) to a single-edition install.wim..."
            $exportWim = Join-Path $isoContents "sources\install_export.wim"
            Export-WindowsImage -SourceImagePath $localWim -SourceIndex $selectedWimIndex -DestinationImagePath $exportWim
            Remove-Item -Path $localWim -Force
            Rename-Item -Path $exportWim -NewName "install.wim" -Force
            $localWim = Join-Path $isoContents "sources\install.wim"
            Log "Unused editions removed. install.wim now contains only '$selectedEditionName'."

            SetProgress "Hydrating WIM metadata..." 76
            Invoke-WinUtilWimMetadataHydration -ImagePath $localWim -EditionName $selectedEditionName -Logger ${function:Log}

            SetProgress "Dismounting source ISO..." 80
            Log "Dismounting original ISO..."
            Dismount-DiskImage -ImagePath $isoPath

            $sync["Win11ISOWorkDir"]     = $workDir
            $sync["Win11ISOContentsDir"] = $isoContents

            SetProgress "Modification complete" 100
            Log "install.wim modification complete. Choose an output option in Step 4."

            $sync["WPFWin11ISOOutputSection"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"
            })
        } catch {
            Log "ERROR during modification: $_"

            try {
                if (Test-Path $mountDir) {
                    $mountedImages = Get-WindowsImage -Mounted | Where-Object { $_.Path -eq $mountDir }
                    if ($mountedImages) {
                        Log "Cleaning up: dismounting install.wim (discarding changes)..."
                        Dismount-WindowsImage -Path $mountDir -Discard
                    }
                }
            } catch { Log "Warning: could not dismount install.wim during cleanup: $_" }

            try {
                $mountedISO = Get-DiskImage -ImagePath $isoPath
                if ($mountedISO -and $mountedISO.Attached) {
                    Log "Cleaning up: dismounting source ISO..."
                    Dismount-DiskImage -ImagePath $isoPath
                }
            } catch { Log "Warning: could not dismount ISO during cleanup: $_" }

            try {
                if (Test-Path $workDir) {
                    Log "Cleaning up: removing temp directory $workDir..."
                    Remove-Item -Path $workDir -Recurse -Force
                }
            } catch { Log "Warning: could not remove temp directory during cleanup: $_" }

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "An error occurred during install.wim modification:`n`n$_",
                    "Modification Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOModifying"] = $false
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOModifyButton"].IsEnabled = $true
                if ($sync["WPFWin11ISOOutputSection"].Visibility -ne "Visible") {
                    $sync["WPFWin11ISOSelectSection"].Visibility = "Visible"
                    $sync["WPFWin11ISOMountSection"].Visibility  = "Visible"
                    $sync["WPFWin11ISOModifySection"].Visibility = "Visible"
                }
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOCheckExistingWork {
    if ($sync["Win11ISOContentsDir"] -and (Test-Path $sync["Win11ISOContentsDir"])) { return }

    # Check if ISO modification is currently in progress
    if ($sync["Win11ISOModifying"]) {
        return
    }

    $existingWorkDir = Get-Item -Path (Join-Path $env:TEMP "WinUtil_Win11ISO*") |
        Where-Object { $_.PSIsContainer } | Sort-Object LastWriteTime -Descending | Select-Object -First 1

    if (-not $existingWorkDir) { return }

    $isoContents = Join-Path $existingWorkDir.FullName "iso_contents"
    if (-not (Test-Path $isoContents)) { return }

    $sync["Win11ISOWorkDir"]     = $existingWorkDir.FullName
    $sync["Win11ISOContentsDir"] = $isoContents

    $sync["WPFWin11ISOSelectSection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOMountSection"].Visibility  = "Collapsed"
    $sync["WPFWin11ISOModifySection"].Visibility = "Collapsed"
    $sync["WPFWin11ISOOutputSection"].Visibility = "Visible"

    $modified = $existingWorkDir.LastWriteTime.ToString("yyyy-MM-dd HH:mm")
    Write-Win11ISOLog "Existing working directory found: $($existingWorkDir.FullName)"
    Write-Win11ISOLog "Last modified: $modified - Skipping Steps 1-3 and resuming at Step 4."
    Write-Win11ISOLog "Click 'Clean & Reset' if you want to start over with a new ISO."

    [System.Windows.MessageBox]::Show(
        "A previous WinUtil ISO working directory was found:`n`n$($existingWorkDir.FullName)`n`n(Last modified: $modified)`n`nStep 4 (output options) has been restored so you can save the already-modified image.`n`nClick 'Clean & Reset' in Step 4 if you want to start over.",
        "Existing Work Found", "OK", "Info")
}

function Invoke-WinUtilISOCleanAndReset {
    $workDir = $sync["Win11ISOWorkDir"]

    if ($workDir -and (Test-Path $workDir)) {
        $confirm = [System.Windows.MessageBox]::Show(
            "This will delete the temporary working directory:`n`n$workDir`n`nAnd reset the interface back to the start.`n`nContinue?",
            "Clean & Reset", "YesNo", "Warning")
        if ($confirm -ne "Yes") { return }
    }

    $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",    $sync)
    $runspace.SessionStateProxy.SetVariable("workDir", $workDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
            Add-Content -Path (Join-Path $workDir "WinUtil_Win11ISO.log") -Value "[$ts] $msg"
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            if ($workDir) {
                $mountDir = Join-Path $workDir "wim_mount"
                try {
                    $mountedImages = Get-WindowsImage -Mounted |
                                     Where-Object { $_.Path -like "$workDir*" }
                    if ($mountedImages) {
                        foreach ($img in $mountedImages) {
                            Log "Dismounting WIM at: $($img.Path) (discarding changes)..."
                            SetProgress "Dismounting WIM image..." 3
                            Dismount-WindowsImage -Path $img.Path -Discard
                            Log "WIM dismounted successfully."
                        }
                    } elseif (Test-Path $mountDir) {
                        Log "No mounted WIM reported by Get-WindowsImage. Running DISM /Cleanup-Wim as a precaution..."
                        SetProgress "Running DISM cleanup..." 3
                        & dism /English /Cleanup-Wim | ForEach-Object { Log $_ }
                    }
                } catch {
                    Log "Warning: could not dismount WIM cleanly. Attempting DISM /Cleanup-Wim fallback: $_"
                    try { & dism /English /Cleanup-Wim | ForEach-Object { Log $_ } }
                    catch { Log "Warning: DISM /Cleanup-Wim also failed: $_" }
                }
            }

            if ($workDir -and (Test-Path $workDir)) {
                Log "Scanning files to delete in: $workDir"
                SetProgress "Scanning files..." 5

                $allFiles = @(Get-ChildItem -Path $workDir -File -Recurse -Force)
                $allDirs  = @(Get-ChildItem -Path $workDir -Directory -Recurse -Force |
                    Sort-Object { $_.FullName.Length } -Descending)
                $total   = $allFiles.Count
                $deleted = 0

                Log "Found $total files to delete."

                foreach ($f in $allFiles) {
                    try { Remove-Item -Path $f.FullName -Force } catch { Log "WARNING: could not delete $($f.FullName): $_" }
                    $deleted++
                    if ($deleted % 100 -eq 0 -or $deleted -eq $total) {
                        $pct = [math]::Round(($deleted / [Math]::Max($total, 1)) * 85) + 5
                        SetProgress "Deleting files in $($f.Directory.Name)... ($deleted / $total)" $pct
                    }
                }

                foreach ($d in $allDirs) {
                    try { Remove-Item -Path $d.FullName -Force } catch { Log "WARNING: could not delete $($d.FullName): $_" }
                }

                try { Remove-Item -Path $workDir -Recurse -Force } catch { Log "WARNING: could not delete temp directory ${workDir}: $_" }

                if (Test-Path $workDir) {
                    Log "WARNING: some items could not be deleted in $workDir"
                } else {
                    Log "Temp directory deleted successfully."
                }
            } else {
                Log "No temp directory found - resetting UI."
            }

            SetProgress "Resetting UI..." 95
            Log "Resetting interface..."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["Win11ISOWorkDir"]     = $null
                $sync["Win11ISOContentsDir"] = $null
                $sync["Win11ISOImagePath"]   = $null
                $sync["Win11ISODriveLetter"] = $null
                $sync["Win11ISOWimPath"]     = $null
                $sync["Win11ISOImageInfo"]   = $null
                $sync["Win11ISOUSBDisks"]    = $null

                $sync["WPFWin11ISOPath"].Text                   = "No ISO selected..."
                $sync["WPFWin11ISOFileInfo"].Visibility          = "Collapsed"
                $sync["WPFWin11ISOVerifyResultPanel"].Visibility = "Collapsed"
                $sync["WPFWin11ISOOptionUSB"].Visibility         = "Collapsed"
                $sync["WPFWin11ISOOutputSection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOModifySection"].Visibility     = "Collapsed"
                $sync["WPFWin11ISOMountSection"].Visibility      = "Collapsed"
                $sync["WPFWin11ISOSelectSection"].Visibility     = "Visible"
                $sync["WPFWin11ISOModifyButton"].IsEnabled       = $true
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled   = $true

                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0

                $sync["WPFWin11ISOStatusLog"].Text   = "Ready. Please select a Windows 11 ISO to begin."
            })
        } catch {
            Log "ERROR during Clean & Reset: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOCleanResetButton"].IsEnabled = $true
            })
        } finally {
            $sync["Win11ISOProcessRunning"] = $false
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOExport {
    $contentsDir = $sync["Win11ISOContentsDir"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show(
            "No modified ISO content found.  Please complete Steps 1-3 first.",
            "Not Ready", "OK", "Warning")
        return
    }

    Add-Type -AssemblyName System.Windows.Forms

    $dlg = [System.Windows.Forms.SaveFileDialog]::new()
    $dlg.Title            = "Save Modified Windows 11 ISO"
    $dlg.Filter           = "ISO files (*.iso)|*.iso"
    $dlg.FileName         = "Win11_Modified_$(Get-Date -Format 'yyyyMMdd').iso"
    $dlg.InitialDirectory = [System.Environment]::GetFolderPath("Desktop")

    if ($dlg.ShowDialog() -ne [System.Windows.Forms.DialogResult]::OK) { return }

    $outputISO = $dlg.FileName

    # Locate oscdimg.exe (Windows ADK or winget per-user install)
    $oscdimg = Get-ChildItem "C:\Program Files (x86)\Windows Kits" -Recurse -Filter "oscdimg.exe" |
               Select-Object -First 1 -ExpandProperty FullName
    if (-not $oscdimg) {
        $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                   Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                   Select-Object -First 1 -ExpandProperty FullName
    }

    if (-not $oscdimg) {
        Write-Win11ISOLog "oscdimg.exe not found. Attempting to install via winget..."
        try {
            # First ensure winget is installed and operational
            Install-WinUtilWinget

            $winget = Get-Command winget
            $result = & $winget install -e --id Microsoft.OSCDIMG --accept-package-agreements --accept-source-agreements
            Write-Win11ISOLog "winget output: $result"
            $oscdimg = Get-ChildItem "$env:LOCALAPPDATA\Microsoft\WinGet\Packages" -Recurse -Filter "oscdimg.exe" |
                       Where-Object { $_.FullName -match 'Microsoft\.OSCDIMG' } |
                       Select-Object -First 1 -ExpandProperty FullName
        } catch {
            Write-Win11ISOLog "winget not available or install failed: $_"
        }

        if (-not $oscdimg) {
            Write-Win11ISOLog "oscdimg.exe still not found after install attempt."
            [System.Windows.MessageBox]::Show(
                "oscdimg.exe could not be found or installed automatically.`n`nPlease install it manually:`n  winget install -e --id Microsoft.OSCDIMG`n`nOr install the Windows ADK from:`nhttps://learn.microsoft.com/windows-hardware/get-started/adk-install",
                "oscdimg Not Found", "OK", "Warning")
            return
        }
        Write-Win11ISOLog "oscdimg.exe installed successfully."
    }

    $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)
    $runspace.SessionStateProxy.SetVariable("outputISO",   $outputISO)
    $runspace.SessionStateProxy.SetVariable("oscdimg",     $oscdimg)

    $win11ISOLogFuncDef = "function Write-Win11ISOLog {`n" + ${function:Write-Win11ISOLog}.ToString() + "`n}"
    $runspace.SessionStateProxy.SetVariable("win11ISOLogFuncDef", $win11ISOLogFuncDef)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({
        . ([scriptblock]::Create($win11ISOLogFuncDef))

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        try {
            Write-Win11ISOLog "Exporting to ISO: $outputISO"
            SetProgress "Building ISO..." 10

            $bootData    = "2#p0,e,b`"$contentsDir\boot\etfsboot.com`"#pEF,e,b`"$contentsDir\efi\microsoft\boot\efisys.bin`""
            $oscdimgArgs = @("-m", "-o", "-u2", "-udfver102", "-bootdata:$bootData", "-l`"CTOS_MODIFIED`"", "`"$contentsDir`"", "`"$outputISO`"")

            Write-Win11ISOLog "Running oscdimg..."

            $psi = [System.Diagnostics.ProcessStartInfo]::new()
            $psi.FileName               = $oscdimg
            $psi.Arguments              = $oscdimgArgs -join " "
            $psi.RedirectStandardOutput = $true
            $psi.RedirectStandardError  = $true
            $psi.UseShellExecute        = $false
            $psi.CreateNoWindow         = $true

            $proc = [System.Diagnostics.Process]::new()
            $proc.StartInfo = $psi
            $proc.Start()

            # Stream stdout line-by-line as oscdimg runs
            while (-not $proc.StandardOutput.EndOfStream) {
                $line = $proc.StandardOutput.ReadLine()
                if ($line.Trim()) { Write-Win11ISOLog $line }
            }

            $proc.WaitForExit()

            # Flush any stderr after process exits
            $stderr = $proc.StandardError.ReadToEnd()
            foreach ($line in ($stderr -split "`r?`n")) {
                if ($line.Trim()) { Write-Win11ISOLog "[stderr]$line" }
            }

            if ($proc.ExitCode -eq 0) {
                SetProgress "ISO exported" 100
                Write-Win11ISOLog "ISO exported successfully: $outputISO"
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show("ISO exported successfully!`n`n$outputISO", "Export Complete", "OK", "Info")
                })
            } else {
                Write-Win11ISOLog "oscdimg exited with code $($proc.ExitCode)."
                $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                    [System.Windows.MessageBox]::Show(
                        "oscdimg exited with code $($proc.ExitCode).`nCheck the status log for details.",
                        "Export Error", "OK", "Error")
                })
            }
        } catch {
            Write-Win11ISOLog "ERROR during ISO export: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("ISO export failed:`n`n$_", "Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOChooseISOButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

function Invoke-WinUtilISOScript {
    <#
    .SYNOPSIS
        Applies WinUtil modifications to a mounted Windows 11 install.wim image.

    .DESCRIPTION
        Removes AppX bloatware and OneDrive, optionally injects all drivers exported from
        the running system into install.wim and boot.wim (controlled by the
        -InjectCurrentSystemDrivers switch), applies offline registry tweaks (hardware
        bypass, privacy, OOBE, telemetry, update suppression), deletes CEIP/WU
        scheduled-task definition files, and optionally writes autounattend.xml to the ISO
        root and removes the support\ folder from the ISO contents directory.

        All setup scripts embedded in the autounattend.xml <Extensions><File> nodes are
        written directly into the WIM at their target paths under C:\Windows\Setup\Scripts\
        to ensure they survive Windows Setup stripping unrecognised-namespace XML elements
        from the Panther copy of the answer file.

        Mounting/dismounting the WIM is the caller's responsibility (e.g. Invoke-WinUtilISO).

    .PARAMETER ScratchDir
        Mandatory. Full path to the directory where the Windows image is currently mounted.

    .PARAMETER ISOContentsDir
        Optional. Root directory of the extracted ISO contents. When supplied,
        autounattend.xml is written here and the support\ folder is removed.

    .PARAMETER AutoUnattendXml
        Optional. Full XML content for autounattend.xml. If empty, the OOBE bypass
        file is skipped and a warning is logged.

    .PARAMETER InjectCurrentSystemDrivers
        Optional. When $true, exports all drivers from the running system and injects
        them into install.wim and boot.wim index 2 (Windows Setup PE).
        Defaults to $false.

    .PARAMETER InstallEditionId
        Optional. Windows edition ID for the selected image, for example Professional
        or Core. Used to write sources\ei.cfg so setup does not fall back to an
        embedded firmware product key for a different edition.

    .PARAMETER InstallImageIndex
        Optional. Image index that setup should install from the final install.wim.
        Win11 Creator exports the selected edition to a single-image WIM, so this
        defaults to 1.

    .PARAMETER Log
        Optional ScriptBlock for progress/status logging. Receives a single [string] argument.

    .EXAMPLE
        Invoke-WinUtilISOScript -ScratchDir "C:\Temp\wim_mount"

    .EXAMPLE
        Invoke-WinUtilISOScript `
            -ScratchDir      $mountDir `
            -ISOContentsDir  $isoRoot `
            -AutoUnattendXml (Get-Content .\tools\autounattend.xml -Raw) `
            -Log             { param($m) Write-Host $m }

    .NOTES
        Author  : Chris Titus @christitustech
        GitHub  : https://github.com/ChrisTitusTech
    #>
    param (
        [Parameter(Mandatory)][string]$ScratchDir,
        [string]$ISOContentsDir = "",
        [string]$AutoUnattendXml = "",
        [bool]$InjectCurrentSystemDrivers = $false,
        [string]$InstallEditionId = "",
        [int]$InstallImageIndex = 1,
        [scriptblock]$Log = { param($m) Write-Output $m }
    )
    function Set-ISOScriptReg {
        param ([string]$Path, [string]$Name, [string]$Type, [string]$Value)
        try {
            & reg add $Path /v $Name /t $Type /d $Value /f
            & $Log "Set registry value: $Path\$Name"
        } catch {
            & $Log "Error setting registry value: $_"
        }
    }

    function Remove-ISOScriptReg {
        param ([string]$path)
        try {
            & reg delete $path /f
            & $Log "Removed registry key: $path"
        } catch {
            & $Log "Error removing registry key: $_"
        }
    }

    function Add-DriversToImage {
        param ([string]$MountPath, [string]$DriverDir, [string]$Label = "image", [scriptblock]$Logger)
        & dism /English "/image:$MountPath" /Add-Driver "/Driver:$DriverDir" /Recurse |
            ForEach-Object { & $Logger "  dism[$Label]: $_" }
    }

    function Invoke-BootWimInject {
        param ([string]$BootWimPath, [string]$DriverDir, [scriptblock]$Logger)
        Set-ItemProperty -Path $BootWimPath -Name IsReadOnly -Value $false
        $mountDir = Join-Path $env:TEMP "WinUtil_BootMount_$(Get-Random)"
        New-Item -Path $mountDir -ItemType Directory -Force
        try {
            & $Logger "Mounting boot.wim (index 2) for driver injection..."
            Mount-WindowsImage -ImagePath $BootWimPath -Index 2 -Path $mountDir
            Add-DriversToImage -MountPath $mountDir -DriverDir $DriverDir -Label "boot" -Logger $Logger
            & $Logger "Saving boot.wim..."
            Dismount-WindowsImage -Path $mountDir -Save
            & $Logger "boot.wim driver injection complete."
        } catch {
            & $Logger "Warning: boot.wim driver injection failed: $_"
            try { Dismount-WindowsImage -Path $mountDir -Discard } catch { & $Logger "Warning: could not discard boot.wim mount: $_" }
        } finally {
            Remove-Item -Path $mountDir -Recurse -Force
        }
    }

    function Get-WinUtilISOScriptChildElement {
        param (
            [Parameter(Mandatory)][System.Xml.XmlElement]$Parent,
            [Parameter(Mandatory)][string]$Name,
            [Parameter(Mandatory)][string]$NamespaceUri
        )

        foreach ($childNode in $Parent.ChildNodes) {
            if ($childNode.NodeType -eq [System.Xml.XmlNodeType]::Element -and
                $childNode.LocalName -eq $Name -and
                $childNode.NamespaceURI -eq $NamespaceUri) {
                return [System.Xml.XmlElement]$childNode
            }
        }

        $childElement = $Parent.OwnerDocument.CreateElement($Name, $NamespaceUri)
        [void]$Parent.AppendChild($childElement)
        return $childElement
    }

    function ConvertTo-WinUtilISOAnswerFile {
        param (
            [Parameter(Mandatory)][string]$XmlContent,
            [int]$ImageIndex = 1
        )

        if ($ImageIndex -lt 1) { $ImageIndex = 1 }

        $unattendNs = "urn:schemas-microsoft-com:unattend"
        $wcmNs = "http://schemas.microsoft.com/WMIConfig/2002/State"

        $xmlDoc = [xml]::new()
        $xmlDoc.PreserveWhitespace = $true
        $xmlDoc.LoadXml($XmlContent)

        if ($xmlDoc.DocumentElement.NamespaceURI -ne $unattendNs) {
            throw "Unexpected autounattend.xml namespace: $($xmlDoc.DocumentElement.NamespaceURI)"
        }

        if (-not $xmlDoc.DocumentElement.HasAttribute("xmlns:wcm")) {
            $xmlDoc.DocumentElement.SetAttribute("wcm", "http://www.w3.org/2000/xmlns/", $wcmNs)
        }

        $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
        $nsMgr.AddNamespace("u", $unattendNs)

        $windowsPESettings = $xmlDoc.SelectSingleNode('/u:unattend/u:settings[@pass="windowsPE"]', $nsMgr)
        if (-not $windowsPESettings) {
            $windowsPESettings = $xmlDoc.CreateElement("settings", $unattendNs)
            $windowsPESettings.SetAttribute("pass", "windowsPE")
            [void]$xmlDoc.DocumentElement.PrependChild($windowsPESettings)
        }

        $setupComponent = $windowsPESettings.SelectSingleNode('u:component[@name="Microsoft-Windows-Setup"]', $nsMgr)
        if (-not $setupComponent) {
            $setupComponent = $xmlDoc.CreateElement("component", $unattendNs)
            $setupComponent.SetAttribute("name", "Microsoft-Windows-Setup")
            $setupComponent.SetAttribute("processorArchitecture", "amd64")
            $setupComponent.SetAttribute("publicKeyToken", "31bf3856ad364e35")
            $setupComponent.SetAttribute("language", "neutral")
            $setupComponent.SetAttribute("versionScope", "nonSxS")
            [void]$windowsPESettings.AppendChild($setupComponent)
        }

        $productKeyNodes = @($setupComponent.SelectNodes("u:UserData/u:ProductKey", $nsMgr))
        foreach ($productKeyNode in $productKeyNodes) {
            $keyNode = $productKeyNode.SelectSingleNode("u:Key", $nsMgr)
            $keyValue = if ($keyNode) { $keyNode.InnerText.Trim() } else { "" }

            if ([string]::IsNullOrWhiteSpace($keyValue) -or $keyValue -eq "00000-00000-00000-00000-00000") {
                [void]$productKeyNode.ParentNode.RemoveChild($productKeyNode)
            }
        }

        $imageInstall = Get-WinUtilISOScriptChildElement -Parent $setupComponent -Name "ImageInstall" -NamespaceUri $unattendNs
        $osImage = Get-WinUtilISOScriptChildElement -Parent $imageInstall -Name "OSImage" -NamespaceUri $unattendNs
        $installFrom = Get-WinUtilISOScriptChildElement -Parent $osImage -Name "InstallFrom" -NamespaceUri $unattendNs

        $existingMetadataNodes = @($installFrom.SelectNodes("u:MetaData", $nsMgr))
        foreach ($metadataNode in $existingMetadataNodes) {
            [void]$installFrom.RemoveChild($metadataNode)
        }

        $metadata = $xmlDoc.CreateElement("MetaData", $unattendNs)
        $actionAttribute = $xmlDoc.CreateAttribute("wcm", "action", $wcmNs)
        $actionAttribute.Value = "add"
        [void]$metadata.Attributes.Append($actionAttribute)

        $keyElement = $xmlDoc.CreateElement("Key", $unattendNs)
        $keyElement.InnerText = "/IMAGE/INDEX"
        [void]$metadata.AppendChild($keyElement)

        $valueElement = $xmlDoc.CreateElement("Value", $unattendNs)
        $valueElement.InnerText = [string]$ImageIndex
        [void]$metadata.AppendChild($valueElement)

        [void]$installFrom.AppendChild($metadata)

        return $xmlDoc.OuterXml
    }

    function Write-WinUtilISOEditionConfig {
        param (
            [Parameter(Mandatory)][string]$ContentRoot,
            [string]$EditionId,
            [scriptblock]$Logger
        )

        if (-not (Test-Path $ContentRoot)) {
            return
        }

        $sourcesDir = Join-Path $ContentRoot "sources"
        New-Item -Path $sourcesDir -ItemType Directory -Force | Out-Null

        $pidPath = Join-Path $sourcesDir "PID.txt"
        if (Test-Path $pidPath) {
            Remove-Item -Path $pidPath -Force
            & $Logger "Removed sources\PID.txt so setup will not force a stale or mismatched product key."
        }

        if ([string]::IsNullOrWhiteSpace($EditionId)) {
            & $Logger "Warning: selected edition ID is unknown - skipping sources\ei.cfg fallback."
            return
        }

        $eiCfgPath = Join-Path $sourcesDir "ei.cfg"
        $eiCfg = @"
[EditionID]
$EditionId
[Channel]
Retail
[VL]
0
"@.Trim()

        Set-Content -Path $eiCfgPath -Value $eiCfg -Encoding ASCII -Force
        & $Logger "Written sources\ei.cfg for EditionID '$EditionId'."
    }

    # -- 1. Remove provisioned AppX packages ----------------------------------
    & $Log "Removing provisioned AppX packages..."

    $packages = & dism /English "/image:$ScratchDir" /Get-ProvisionedAppxPackages |
        ForEach-Object { if ($_ -match 'PackageName : (.*)') { $matches[1] } }

    $packagePrefixes = @(
        'Clipchamp.Clipchamp',
        'Microsoft.BingNews',
        'Microsoft.BingSearch',
        'Microsoft.BingWeather',
        'Microsoft.GetHelp',
        'Microsoft.MicrosoftOfficeHub',
        'Microsoft.MicrosoftSolitaireCollection',
        'Microsoft.MicrosoftStickyNotes',
        'Microsoft.OutlookForWindows',
        'Microsoft.Paint',
        'Microsoft.PowerAutomateDesktop',
        'Microsoft.StartExperiencesApp',
        'Microsoft.Todos',
        'Microsoft.Windows.DevHome',
        'Microsoft.WindowsFeedbackHub',
        'Microsoft.WindowsSoundRecorder',
        'Microsoft.ZuneMusic',
        'MicrosoftCorporationII.QuickAssist',
        'MSTeams'
    )

    $packages | Where-Object { $pkg = $_; $packagePrefixes | Where-Object { $pkg -like "*$_*" } } |
        ForEach-Object { & dism /English "/image:$ScratchDir" /Remove-ProvisionedAppxPackage "/PackageName:$_" }

    # -- 2. Inject current system drivers (optional) ---------------------------
    if ($InjectCurrentSystemDrivers) {
        & $Log "Exporting all drivers from running system..."
        $driverExportRoot = Join-Path $env:TEMP "WinUtil_DriverExport_$(Get-Random)"
        New-Item -Path $driverExportRoot -ItemType Directory -Force
        try {
            Export-WindowsDriver -Online -Destination $driverExportRoot

            & $Log "Injecting current system drivers into install.wim..."
            Add-DriversToImage -MountPath $ScratchDir -DriverDir $driverExportRoot -Label "install" -Logger $Log
            & $Log "install.wim driver injection complete."

            if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
                $bootWim = Join-Path $ISOContentsDir "sources\boot.wim"
                if (Test-Path $bootWim) {
                    & $Log "Injecting current system drivers into boot.wim..."
                    Invoke-BootWimInject -BootWimPath $bootWim -DriverDir $driverExportRoot -Logger $Log
                } else {
                    & $Log "Warning: boot.wim not found - skipping boot.wim driver injection."
                }
            }
        } catch {
            & $Log "Error during driver export/injection: $_"
        } finally {
            Remove-Item -Path $driverExportRoot -Recurse -Force
        }
    } else {
        & $Log "Driver injection skipped."
    }

    # -- 3. Registry tweaks ----------------------------------------------------
    & $Log "Loading offline registry hives..."
    reg load HKLM\zCOMPONENTS "$ScratchDir\Windows\System32\config\COMPONENTS"
    reg load HKLM\zDEFAULT    "$ScratchDir\Windows\System32\config\default"
    reg load HKLM\zNTUSER     "$ScratchDir\Users\Default\ntuser.dat"
    reg load HKLM\zSOFTWARE   "$ScratchDir\Windows\System32\config\SOFTWARE"
    reg load HKLM\zSYSTEM     "$ScratchDir\Windows\System32\config\SYSTEM"

    & $Log "Bypassing system requirements..."
    Set-ISOScriptReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zDEFAULT\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV1' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Control Panel\UnsupportedHardwareNotificationCache' -Name 'SV2' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassCPUCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassRAMCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassSecureBootCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassStorageCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\LabConfig' -Name 'BypassTPMCheck' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\Setup\MoSetup' -Name 'AllowUpgradesWithUnsupportedTPMOrCPU' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling sponsored apps..."
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'OemPreInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SilentInstalledAppsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableWindowsConsumerFeatures' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'ContentDeliveryAllowed' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\PolicyManager\current\device\Start' -Name 'ConfigureStartPins' -Type 'REG_SZ' -Value '{"pinnedList": [{}]}'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'FeatureManagementEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'PreInstalledAppsEverEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SoftLandingEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContentEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-310093Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338388Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338389Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-338393Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353694Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SubscribedContent-353696Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager' -Name 'SystemPaneSuggestionsEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\PushToInstall' -Name 'DisablePushToInstall' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\MRT' -Name 'DontOfferThroughWUAU' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\Subscriptions'
    Remove-ISOScriptReg 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\ContentDeliveryManager\SuggestedApps'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableConsumerAccountStateContent' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\CloudContent' -Name 'DisableCloudOptimizedContent' -Type 'REG_DWORD' -Value '1'

    & $Log "Enabling local accounts on OOBE..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\OOBE' -Name 'BypassNRO' -Type 'REG_DWORD' -Value '1'

    if ($AutoUnattendXml) {
        $preparedAutoUnattendXml = $AutoUnattendXml
        try {
            $preparedAutoUnattendXml = ConvertTo-WinUtilISOAnswerFile -XmlContent $AutoUnattendXml -ImageIndex $InstallImageIndex
            & $Log "Prepared autounattend.xml to install image index $InstallImageIndex without forcing a product key."
        } catch {
            & $Log "Warning: could not prepare autounattend.xml image selection: $_"
        }

        try {
            $xmlDoc = [xml]::new()
            $xmlDoc.LoadXml($preparedAutoUnattendXml)

            $nsMgr = New-Object System.Xml.XmlNamespaceManager($xmlDoc.NameTable)
            $nsMgr.AddNamespace("sg", "https://schneegans.de/windows/unattend-generator/")

            $fileNodes = $xmlDoc.SelectNodes("//sg:File", $nsMgr)
            if ($fileNodes -and $fileNodes.Count -gt 0) {
                foreach ($fileNode in $fileNodes) {
                    $absPath  = $fileNode.GetAttribute("path")
                    $relPath  = $absPath -replace '^[A-Za-z]:[/\\]', ''
                    $destPath = Join-Path $ScratchDir $relPath
                    New-Item -Path (Split-Path $destPath -Parent) -ItemType Directory -Force

                    $ext = [IO.Path]::GetExtension($destPath).ToLower()
                    $encoding = switch ($ext) {
                        { $_ -in '.ps1', '.xml' }        { [System.Text.Encoding]::UTF8 }
                        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new($false, $true) }
                        default                          { [System.Text.Encoding]::Default }
                    }
                    [System.IO.File]::WriteAllBytes($destPath, ($encoding.GetPreamble() + $encoding.GetBytes($fileNode.InnerText.Trim())))
                    & $Log "Pre-staged setup script: $relPath"
                }
            } else {
                & $Log "Warning: no <Extensions><File> nodes found in autounattend.xml - setup scripts not pre-staged."
            }
        } catch {
            & $Log "Warning: could not pre-stage setup scripts from autounattend.xml: $_"
        }

        if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
            $isoDest = Join-Path $ISOContentsDir "autounattend.xml"
            Set-Content -Path $isoDest -Value $preparedAutoUnattendXml -Encoding UTF8 -Force
            & $Log "Written autounattend.xml to ISO root ($isoDest)."
        }
    } else {
        & $Log "Warning: autounattend.xml content is empty - skipping OOBE bypass file."
    }

    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        Write-WinUtilISOEditionConfig -ContentRoot $ISOContentsDir -EditionId $InstallEditionId -Logger $Log
    }

    & $Log "Disabling reserved storage..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\ReserveManager' -Name 'ShippedWithReserves' -Type 'REG_DWORD' -Value '0'

    & $Log "Disabling BitLocker device encryption..."
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Control\BitLocker' -Name 'PreventDeviceEncryption' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling Chat icon..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Chat' -Name 'ChatIcon' -Type 'REG_DWORD' -Value '3'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'TaskbarMn' -Type 'REG_DWORD' -Value '0'

    & $Log "Disabling OneDrive folder backup..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\OneDrive' -Name 'DisableFileSyncNGSC' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling telemetry..."
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\AdvertisingInfo' -Name 'Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Windows\CurrentVersion\Privacy' -Name 'TailoredExperiencesWithDiagnosticDataEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Speech_OneCore\Settings\OnlineSpeechPrivacy' -Name 'HasAccepted' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Input\TIPC' -Name 'Enabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitInkCollection' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization' -Name 'RestrictImplicitTextCollection' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\InputPersonalization\TrainedDataStore' -Name 'HarvestContacts' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zNTUSER\Software\Microsoft\Personalization\Settings' -Name 'AcceptedPrivacyPolicy' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\DataCollection' -Name 'AllowTelemetry' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\dmwappushservice' -Name 'Start' -Type 'REG_DWORD' -Value '4'

    & $Log "Preventing installation of DevHome and Outlook..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\OutlookUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler\DevHomeUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\OutlookUpdate'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\DevHomeUpdate'

    & $Log "Disabling Copilot..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsCopilot' -Name 'TurnOffWindowsCopilot' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Edge' -Name 'HubsSidebarEnabled' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Explorer' -Name 'DisableSearchBoxSuggestions' -Type 'REG_DWORD' -Value '1'

    & $Log "Disabling Windows Update during OOBE (re-enabled on first logon via FirstLogon.ps1)..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'NoAutoUpdate' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'AUOptions' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU' -Name 'UseWUServer' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'DisableWindowsUpdateAccess' -Type 'REG_DWORD' -Value '1'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUServer' -Type 'REG_SZ' -Value 'http://localhost:8080'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Name 'WUStatusServer' -Type 'REG_SZ' -Value 'http://localhost:8080'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate' -Name 'workCompleted' -Type 'REG_DWORD' -Value '1'
    Remove-ISOScriptReg 'HKLM\zSOFTWARE\Microsoft\WindowsUpdate\Orchestrator\UScheduler_Oobe\WindowsUpdate'
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config' -Name 'DODownloadMode' -Type 'REG_DWORD' -Value '0'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\BITS' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\wuauserv' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\UsoSvc' -Name 'Start' -Type 'REG_DWORD' -Value '4'
    Set-ISOScriptReg -Path 'HKLM\zSYSTEM\ControlSet001\Services\WaaSMedicSvc' -Name 'Start' -Type 'REG_DWORD' -Value '4'

    & $Log "Preventing installation of Teams..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Teams' -Name 'DisableInstallation' -Type 'REG_DWORD' -Value '1'

    & $Log "Preventing installation of new Outlook..."
    Set-ISOScriptReg -Path 'HKLM\zSOFTWARE\Policies\Microsoft\Windows\Windows Mail' -Name 'PreventRun' -Type 'REG_DWORD' -Value '1'

    & $Log "Unloading offline registry hives..."
    reg unload HKLM\zCOMPONENTS
    reg unload HKLM\zDEFAULT
    reg unload HKLM\zNTUSER
    reg unload HKLM\zSOFTWARE
    reg unload HKLM\zSYSTEM

    # -- 4. Delete scheduled task definition files -----------------------------
    & $Log "Deleting scheduled task definition files..."
    $tasksPath = "$ScratchDir\Windows\System32\Tasks"
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\Microsoft Compatibility Appraiser" -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Customer Experience Improvement Program"                  -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Application Experience\ProgramDataUpdater"               -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Chkdsk\Proxy"                                            -Force
    Remove-Item "$tasksPath\Microsoft\Windows\Windows Error Reporting\QueueReporting"                  -Force
    Remove-Item "$tasksPath\Microsoft\Windows\InstallService"                                          -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateOrchestrator"                                      -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\UpdateAssistant"                                         -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WaaSMedic"                                               -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\Windows\WindowsUpdate"                                           -Recurse -Force
    Remove-Item "$tasksPath\Microsoft\WindowsUpdate"                                                   -Recurse -Force
    & $Log "Scheduled task files deleted."

    # -- 5. Remove ISO support folder -----------------------------------------
    if ($ISOContentsDir -and (Test-Path $ISOContentsDir)) {
        & $Log "Removing ISO support\ folder..."
        Remove-Item -Path (Join-Path $ISOContentsDir "support") -Recurse -Force
        & $Log "ISO support\ folder removed."
    }
}

function Invoke-WinUtilISORefreshUSBDrives {
    $combo    = $sync["WPFWin11ISOUSBDriveComboBox"]
    $removable = @(Get-Disk | Where-Object { $_.BusType -eq "USB" } | Sort-Object Number)

    $combo.Items.Clear()

    if ($removable.Count -eq 0) {
        $combo.Items.Add("No USB drives detected.")
        $combo.SelectedIndex = 0
        $sync["Win11ISOUSBDisks"] = @()
        Write-Win11ISOLog "No USB drives detected."
        return
    }

    foreach ($disk in $removable) {
        $sizeGB = [math]::Round($disk.Size / 1GB, 1)
        $combo.Items.Add("Disk $($disk.Number): $($disk.FriendlyName)  [$sizeGB GB] - $($disk.PartitionStyle)")
    }
    $combo.SelectedIndex = 0
    Write-Win11ISOLog "Found $($removable.Count) USB drive(s)."
    $sync["Win11ISOUSBDisks"] = $removable
}

function Invoke-WinUtilISOWriteUSB {
    $contentsDir = $sync["Win11ISOContentsDir"]
    $usbDisks    = $sync["Win11ISOUSBDisks"]

    if (-not $contentsDir -or -not (Test-Path $contentsDir)) {
        [System.Windows.MessageBox]::Show("No modified ISO content found. Please complete Steps 1-3 first.", "Not Ready", "OK", "Warning")
        return
    }

    $combo = $sync["WPFWin11ISOUSBDriveComboBox"]
    $selectedIndex = $combo.SelectedIndex
    $selectedItemText = [string]$combo.SelectedItem
    $usbDisks = @($usbDisks)

    $targetDisk = $null
    if ($selectedIndex -ge 0 -and $selectedIndex -lt $usbDisks.Count) {
        $targetDisk = $usbDisks[$selectedIndex]
    } elseif ($selectedItemText -match 'Disk\s+(\d+):') {
        $selectedDiskNum = [int]$matches[1]
        $targetDisk = $usbDisks | Where-Object { $_.Number -eq $selectedDiskNum } | Select-Object -First 1
    }

    if (-not $targetDisk) {
        [System.Windows.MessageBox]::Show("Please select a USB drive from the dropdown.", "No Drive Selected", "OK", "Warning")
        return
    }

    $diskNum    = $targetDisk.Number
    $sizeGB     = [math]::Round($targetDisk.Size / 1GB, 1)

    $confirm = [System.Windows.MessageBox]::Show(
        "ALL data on Disk $diskNum ($($targetDisk.FriendlyName), $sizeGB GB) will be PERMANENTLY ERASED.`n`nAre you sure you want to continue?",
        "Confirm USB Erase", "YesNo", "Warning")

    if ($confirm -ne "Yes") {
        Write-Win11ISOLog "USB write cancelled by user."
        return
    }

    $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $false
    $sync["Win11ISOProcessRunning"] = $true
    Write-Win11ISOLog "Starting USB write to Disk $diskNum..."

    $runspace = [Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
    $runspace.ApartmentState = "STA"
    $runspace.ThreadOptions  = "ReuseThread"
    $runspace.Open()
    $runspace.SessionStateProxy.SetVariable("sync",        $sync)
    $runspace.SessionStateProxy.SetVariable("diskNum",     $diskNum)
    $runspace.SessionStateProxy.SetVariable("contentsDir", $contentsDir)

    $script = [Management.Automation.PowerShell]::Create()
    $script.Runspace = $runspace
    $script.AddScript({

        function Log($msg) {
            $ts = (Get-Date).ToString("HH:mm:ss")
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFWin11ISOStatusLog"].Text += "`n[$ts] $msg"
                $sync["WPFWin11ISOStatusLog"].CaretIndex = $sync["WPFWin11ISOStatusLog"].Text.Length
                $sync["WPFWin11ISOStatusLog"].ScrollToEnd()
            })
        }

        function SetProgress($label, $pct) {
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Visible"
                $sync["WPFTweaksProgressLabel"].Text      = $label
                $sync["WPFTweaksProgressLabel"].ToolTip   = $label
                $sync["WPFTweaksProgressValue"].Value     = [Math]::Max($pct, 5)
            })
        }

        function Get-FreeDriveLetter {
            $used = (Get-PSDrive -PSProvider FileSystem).Name
            foreach ($c in [char[]](68..90)) {
                if ($used -notcontains [string]$c) { return $c }
            }
            return $null
        }

        try {
            SetProgress "Formatting USB drive..." 10

            # Phase 1: Clean disk via diskpart (retry once if the drive is not yet ready)
            $dpFile1 = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
            "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1 -Encoding ASCII
            Log "Running diskpart clean on Disk $diskNum..."
            $dpCleanOut = diskpart /s $dpFile1
            $dpCleanOut | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile1 -Force

            if (($dpCleanOut -join ' ') -match 'device is not ready') {
                Log "Disk $diskNum was not ready; waiting 5 seconds and retrying clean..."
                Start-Sleep -Seconds 5
                Update-Disk -Number $diskNum
                $dpFile1b = Join-Path $env:TEMP "winutil_diskpart_$(Get-Random).txt"
                "select disk $diskNum`nclean`nexit" | Set-Content -Path $dpFile1b -Encoding ASCII
                diskpart /s $dpFile1b | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
                Remove-Item $dpFile1b -Force
            }

            # Phase 2: Initialize as GPT
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum
            $diskObj = Get-Disk -Number $diskNum
            if ($diskObj.PartitionStyle -eq 'RAW') {
                Initialize-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum initialized as GPT."
            } else {
                Set-Disk -Number $diskNum -PartitionStyle GPT
                Log "Disk $diskNum converted to GPT (was $($diskObj.PartitionStyle))."
            }

            # Phase 3: Create FAT32 partition via diskpart, then format with Format-Volume
            # (diskpart's 'format' command can fail with "no volume selected" on fresh/never-formatted drives)
            $volLabel = "W11-" + (Get-Date).ToString('yyMMdd')
            $dpFile2  = Join-Path $env:TEMP "winutil_diskpart2_$(Get-Random).txt"
            $maxFat32PartitionMB = 32768
            $diskSizeMB = [int][Math]::Floor((Get-Disk -Number $diskNum).Size / 1MB)
            $createPartitionCommand = "create partition primary"
            if ($diskSizeMB -gt $maxFat32PartitionMB) {
                $createPartitionCommand = "create partition primary size=$maxFat32PartitionMB"
                Log "Disk $diskNum is $diskSizeMB MB; creating FAT32 partition capped at $maxFat32PartitionMB MB (32 GB)."
            }

            @(
                "select disk $diskNum"
                $createPartitionCommand
                "exit"
            ) | Set-Content -Path $dpFile2 -Encoding ASCII
            Log "Creating partitions on Disk $diskNum..."
            diskpart /s $dpFile2 | Where-Object { $_ -match '\S' } | ForEach-Object { Log "  diskpart: $_" }
            Remove-Item $dpFile2 -Force

            SetProgress "Formatting USB partition..." 25
            Start-Sleep -Seconds 3
            Update-Disk -Number $diskNum

            $partitions = Get-Partition -DiskNumber $diskNum
            Log "Partitions on Disk $diskNum after creation: $($partitions.Count)"
            foreach ($p in $partitions) {
                Log "  Partition $($p.PartitionNumber)  Type=$($p.Type)  Letter=$($p.DriveLetter)  Size=$([math]::Round($p.Size/1MB))MB"
            }

            $winpePart = $partitions | Where-Object { $_.Type -eq "Basic" } | Select-Object -Last 1
            if (-not $winpePart) {
                throw "Could not find the Basic partition on Disk $diskNum after creation."
            }

            # Format using Format-Volume (reliable on fresh drives; diskpart format fails
            # with 'no volume selected' when the partition has never been formatted before)
            Log "Formatting Partition $($winpePart.PartitionNumber) as FAT32 (label: $volLabel)..."
            Get-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber |
                Format-Volume -FileSystem FAT32 -NewFileSystemLabel $volLabel -Force -Confirm:$false
            Log "Partition $($winpePart.PartitionNumber) formatted as FAT32."

            SetProgress "Assigning drive letters..." 30
            Start-Sleep -Seconds 2
            Update-Disk -Number $diskNum

            try { Remove-PartitionAccessPath -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -AccessPath "$($winpePart.DriveLetter):" } catch { Log "Warning: could not remove existing partition access path: $_" }
            $usbLetter = Get-FreeDriveLetter
            if (-not $usbLetter) { throw "No free drive letters (D-Z) available to assign to the USB data partition." }
            Set-Partition -DiskNumber $diskNum -PartitionNumber $winpePart.PartitionNumber -NewDriveLetter $usbLetter
            Log "Assigned drive letter $usbLetter to WINPE partition (Partition $($winpePart.PartitionNumber))."
            Start-Sleep -Seconds 2

            $usbDrive = "${usbLetter}:"
            $retries = 0
            while (-not (Test-Path $usbDrive) -and $retries -lt 6) {
                $retries++
                Log "Waiting for $usbDrive to become accessible (attempt $retries/6)..."
                Start-Sleep -Seconds 2
            }
            if (-not (Test-Path $usbDrive)) { throw "Drive $usbDrive is not accessible after letter assignment." }
            Log "USB data partition: $usbDrive"

            $contentSizeBytes = (Get-ChildItem -LiteralPath $contentsDir -File -Recurse -Force | Measure-Object -Property Length -Sum).Sum
            if (-not $contentSizeBytes) { $contentSizeBytes = 0 }
            $usbVolume = Get-Volume -DriveLetter $usbLetter
            $partitionCapacityBytes = [int64]$usbVolume.Size
            $partitionFreeBytes = [int64]$usbVolume.SizeRemaining

            $contentSizeGB = [math]::Round($contentSizeBytes / 1GB, 2)
            $partitionCapacityGB = [math]::Round($partitionCapacityBytes / 1GB, 2)
            $partitionFreeGB = [math]::Round($partitionFreeBytes / 1GB, 2)

            Log "Source content size: $contentSizeGB GB. USB partition capacity: $partitionCapacityGB GB, free: $partitionFreeGB GB."

            if ($contentSizeBytes -gt $partitionCapacityBytes) {
                throw "ISO content ($contentSizeGB GB) is larger than the USB partition capacity ($partitionCapacityGB GB). Use a larger USB drive or reduce image size."
            }

            if ($contentSizeBytes -gt $partitionFreeBytes) {
                throw "Insufficient free space on USB partition. Required: $contentSizeGB GB, available: $partitionFreeGB GB."
            }

            SetProgress "Copying Windows 11 files to USB..." 45

            # Copy files; split install.wim if > 4 GB (FAT32 limit)
            $installWim = Join-Path $contentsDir "sources\install.wim"
            if (Test-Path $installWim) {
                $wimSizeMB = [math]::Round((Get-Item $installWim).Length / 1MB)
                if ($wimSizeMB -gt 3800) {
                    Log "install.wim is $wimSizeMB MB - splitting for FAT32 compatibility... This will take several minutes."
                    $splitDest = Join-Path $usbDrive "sources\install.swm"
                    New-Item -ItemType Directory -Path (Split-Path $splitDest) -Force
                    Split-WindowsImage -ImagePath $installWim -SplitImagePath $splitDest -FileSize 3800 -CheckIntegrity
                    Log "install.wim split complete."
                    Log "Copying remaining files to USB..."
                    & robocopy $contentsDir $usbDrive /E /XF install.wim /NFL /NDL /NJH /NJS
                } else {
                    & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
                }
            } else {
                & robocopy $contentsDir $usbDrive /E /NFL /NDL /NJH /NJS
            }

            SetProgress "Finalising USB drive..." 90
            Log "Files copied to USB."
            SetProgress "USB write complete" 100
            Log "USB drive is ready for use."

            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show(
                    "USB drive created successfully!`n`nYou can now boot from this drive to install Windows 11.",
                    "USB Ready", "OK", "Info")
            })
        } catch {
            Log "ERROR during USB write: $_"
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                [System.Windows.MessageBox]::Show("USB write failed:`n`n$_", "USB Write Error", "OK", "Error")
            })
        } finally {
            Start-Sleep -Milliseconds 800
            $sync["Win11ISOProcessRunning"] = $false
            $sync["WPFWin11ISOStatusLog"].Dispatcher.Invoke([action]{
                $sync["WPFTweaksProgressBar"].Visibility = "Collapsed"
                $sync["WPFTweaksProgressLabel"].Text      = ""
                $sync["WPFTweaksProgressLabel"].ToolTip   = ""
                $sync["WPFTweaksProgressValue"].Value     = 0
                $sync["WPFWin11ISOWriteUSBButton"].IsEnabled = $true
            })
        }
    })

    $script.BeginInvoke()
}

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

function Invoke-WinUtilSSHServer {
    <#
    .SYNOPSIS
        Enables OpenSSH server to remote into your windows device
    #>

    # Install the OpenSSH Server feature if not already installed
    if ((Get-WindowsCapability -Name OpenSSH.Server -Online).State -ne "Installed") {
        Write-Host "正在启用 OpenSSH 服务器...这需要较长时间。"
        Add-WindowsCapability -Name OpenSSH.Server -Online
    }

    Write-Host "正在启动服务"

    Set-Service -Name sshd -StartupType Automatic
    Start-Service -Name sshd

    Set-Service -Name ssh-agent -StartupType Automatic
    Start-Service -Name ssh-agent

    #Adding Firewall rule for port 22
    Write-Host "正在设置防火墙规则"
    if (-not ((Get-NetFirewallRule -Name 'sshd').Enabled)) {
        New-NetFirewallRule -Name sshd -DisplayName 'OpenSSH Server (sshd)' -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "OpenSSH 服务器防火墙规则已创建并启用。"
    }

    # Check for the authorized_keys file
    $sshFolderPath = "$Home\.ssh"
    $authorizedKeysPath = "$sshFolderPath\authorized_keys"

    if (-not (Test-Path -Path $sshFolderPath)) {
        Write-Host "正在创建 ssh 目录..."
        New-Item -Path $sshFolderPath -ItemType Directory -Force
    }

    if (-not (Test-Path -Path $authorizedKeysPath)) {
        Write-Host "正在创建 authorized_keys 文件..."
        New-Item -Path $authorizedKeysPath -ItemType File -Force
        Write-Host "authorized_keys file created at $authorizedKeysPath."
    }

    Write-Host "正在配置 sshd_config 以使用标准的 authorized_keys 行为..."
    $sshdConfigPath = "C:\ProgramData\ssh\sshd_config"

    $configContent = Get-Content -Path $sshdConfigPath -Raw

    $updatedContent = $configContent -replace '(?m)^(Match Group administrators)$', '# $1'
    $updatedContent = $updatedContent -replace '(?m)^(\s+AuthorizedKeysFile __PROGRAMDATA__/ssh/administrators_authorized_keys)$', '# $1'

    if ($updatedContent -ne $configContent) {
        Set-Content -Path $sshdConfigPath -Value $updatedContent -Force
        Write-Host "已在 sshd_config 中注释掉管理员特定的 SSH 密钥配置"
        Restart-Service -Name sshd -Force
    }

    Write-Host "OpenSSH 服务器已成功启用。"
    Write-Host "配置文件位于 C:\ProgramData\ssh\sshd_config"
    Write-Host "将您的公钥添加到此文件 -> $authorizedKeysPath"
}

function Invoke-WinUtilScript {
    <#

    .SYNOPSIS
        Invokes the provided scriptblock. Intended for things that can't be handled with the other functions.

    .PARAMETER Name
        The name of the scriptblock being invoked

    .PARAMETER scriptblock
        The scriptblock to be invoked

    .EXAMPLE
        $Scriptblock = [scriptblock]::Create({"Write-output 'Hello World'"})
        Invoke-WinUtilScript -ScriptBlock $scriptblock -Name "Hello World"

    #>
    param (
        $Name,
        [scriptblock]$scriptblock
    )

    try {
        Write-Host "正在运行 $Name 的脚本"
        Write-WinUtilLog -Component "Script" -Message "Running script for $Name"
        Invoke-Command $scriptblock -ErrorAction Stop
        Write-WinUtilLog -Component "Script" -Message "Completed script for $Name"
    } catch [System.Management.Automation.CommandNotFoundException] {
        Write-Warning "The specified command was not found."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Command not found while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Management.Automation.RuntimeException] {
        Write-Warning "A runtime exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Runtime exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.Security.SecurityException] {
        Write-Warning "A security exception occurred."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Security exception while running script for $Name`: $($PSItem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
        Write-Warning "Access denied. You do not have permission to perform this operation."
        Write-Warning $PSItem.Exception.message
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Access denied while running script for $Name`: $($PSItem.Exception.Message)"
    } catch {
        # Generic catch block to handle any other type of exception
        Write-Warning "Unable to run script for $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Script" -Message "Unhandled exception while running script for $Name`: $($psitem.Exception.Message)"
    }

}

Function Invoke-WinUtilSponsors {
    $sponsors = ([regex]::Matches(([regex]::Match((Invoke-RestMethod https://github.com/sponsors/ChrisTitusTech),'(?s)(?<=Current sponsors).*?(?=Past sponsors)')).Value,'(?<=alt="@)[^"]+')).Value | Where-Object {$_ -ne "ChrisTitusTech"}
    return $sponsors
}

function Invoke-WinUtilTweaks {
    <#

    .SYNOPSIS
        Invokes the function associated with each provided checkbox

    .PARAMETER CheckBox
        The checkbox to invoke

    .PARAMETER undo
        Indicates whether to undo the operation contained in the checkbox

    .PARAMETER KeepServiceStartup
        Indicates whether to override the startup of a service with the one given from WinUtil,
        or to keep the startup of said service, if it was changed by the user, or another program, from its default value.
    #>

    param(
        $CheckBox,
        $undo = $false,
        $KeepServiceStartup = $true
    )

    $action = if ($undo) { "Undo" } else { "Apply" }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak: $CheckBox"

    if ($undo) {
        $Values = @{
            Registry = "OriginalValue"
            Service = "OriginalType"
            ScriptType = "UndoScript"
        }

    } else {
        $Values = @{
            Registry = "Value"
            Service = "StartupType"
            OriginalService = "OriginalType"
            ScriptType = "InvokeScript"
        }
    }
    if ($sync.configs.tweaks.$CheckBox.service) {
        $sync.configs.tweaks.$CheckBox.service | ForEach-Object {
            $changeservice = $true

        # The check for !($undo) is required, without it the script will throw an error for accessing unavailable member, which's the 'OriginalService' Property
            if ($KeepServiceStartup -AND !($undo)) {
                try {
                    # Check if the service exists
                    $service = Get-Service -Name $psitem.Name -ErrorAction Stop
                    if(!($service.StartType.ToString() -eq $psitem.$($values.OriginalService))) {
                        $changeservice = $false
                    }
                } catch [System.ServiceProcess.ServiceNotFoundException] {
                    Write-Warning "Service $($psitem.Name) was not found."
                }
            }

            if ($changeservice) {
                Set-WinUtilService -Name $psitem.Name -StartupType $psitem.$($values.Service)
            }
        }
    }
    if ($sync.configs.tweaks.$CheckBox.registry) {
        $sync.configs.tweaks.$CheckBox.registry | ForEach-Object {
            Set-WinUtilRegistry -Name $psitem.Name -Path $psitem.Path -Type $psitem.Type -Value $psitem.$($values.registry)
        }
    }
    if ($sync.configs.tweaks.$CheckBox.$($values.ScriptType)) {
        $sync.configs.tweaks.$CheckBox.$($values.ScriptType) | ForEach-Object {
            $Scriptblock = [scriptblock]::Create($psitem)
            Invoke-WinUtilScript -ScriptBlock $scriptblock -Name $CheckBox
        }
    }

    if (!$undo) {
        if($sync.configs.tweaks.$CheckBox.appx) {
            $sync.configs.tweaks.$CheckBox.appx | ForEach-Object {
                Remove-WinUtilAPPX -Name $psitem
            }
            Remove-WinUtilProvisionedAPPX -PackageList $sync.configs.tweaks.$CheckBox.appx
        }
    }
    Write-WinUtilLog -Component "Tweaks" -Message "$action tweak completed: $CheckBox"
}

function Invoke-WinUtilUninstallPSProfile {

    if (Test-Path ($Profile + ".bak")) {
        Move-Item -Path ($Profile + ".bak") -Destination $Profile
    } else {
        Remove-Item -Path $Profile
    }

    Write-Host "已成功卸载 CTT PowerShell 配置文件。" -ForegroundColor Green
}

function Invoke-WinutilThemeChange {
    <#
    .SYNOPSIS
        Toggles between light and dark themes for a Windows utility application.

    .DESCRIPTION
        This function toggles the theme of the user interface between 'Light' and 'Dark' modes,
        modifying various UI elements such as colors, margins, corner radii, font families, etc.
        If the '-init' switch is used, it initializes the theme based on the system's current dark mode setting.

    .EXAMPLE
        Invoke-WinutilThemeChange
        # Toggles the theme between 'Light' and 'Dark'.


    #>
    param (
        [string]$theme = "Auto"
    )

    function Set-WinutilTheme {
        <#
        .SYNOPSIS
            Applies the specified theme to the application's user interface.

        .DESCRIPTION
            This internal function applies the given theme by setting the relevant properties
            like colors, font families, corner radii, etc., in the UI. It uses the
            'Set-ThemeResourceProperty' helper function to modify the application's resources.

        .PARAMETER currentTheme
            The name of the theme to be applied. Common values are "Light", "Dark", or "shared".
        #>
        param (
            [string]$currentTheme
        )

        function Set-ThemeResourceProperty {
            <#
            .SYNOPSIS
                Sets a specific UI property in the application's resources.

            .DESCRIPTION
                This helper function sets a property (e.g., color, margin, corner radius) in the
                application's resources, based on the provided type and value. It includes
                error handling to manage potential issues while setting a property.

            .PARAMETER Name
                The name of the resource property to modify (e.g., "MainBackgroundColor", "ButtonBackgroundMouseoverColor").

            .PARAMETER Value
                The value to assign to the resource property (e.g., "#FFFFFF" for a color).

            .PARAMETER Type
                The type of the resource, such as "ColorBrush", "CornerRadius", "GridLength", or "FontFamily".
            #>
            param($Name, $Value, $Type)
            try {
                # Set the resource property based on its type
                $sync.Form.Resources[$Name] = switch ($Type) {
                    "ColorBrush" { [Windows.Media.SolidColorBrush]::new($Value) }
                    "Color" {
                        # Convert hex string to RGB values
                        $hexColor = $Value.TrimStart("#")
                        $r = [Convert]::ToInt32($hexColor.Substring(0,2), 16)
                        $g = [Convert]::ToInt32($hexColor.Substring(2,2), 16)
                        $b = [Convert]::ToInt32($hexColor.Substring(4,2), 16)
                        [Windows.Media.Color]::FromRgb($r, $g, $b)
                    }
                    "CornerRadius" { [System.Windows.CornerRadius]::new($Value) }
                    "GridLength" { [System.Windows.GridLength]::new($Value) }
                    "Thickness" {
                        # Parse the Thickness value (supports 1, 2, or 4 inputs)
                        $values = $Value -split ","
                        switch ($values.Count) {
                            1 { [System.Windows.Thickness]::new([double]$values[0]) }
                            2 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1]) }
                            4 { [System.Windows.Thickness]::new([double]$values[0], [double]$values[1], [double]$values[2], [double]$values[3]) }
                        }
                    }
                    "FontFamily" { [Windows.Media.FontFamily]::new($Value) }
                    "Double" { [double]$Value }
                    default { $Value }
                }
            }
            catch {
                # Log a warning if there's an issue setting the property
                Write-Warning "Failed to set property $($Name): $_"
            }
        }

        # Retrieve all theme properties from the theme configuration
        $themeProperties = $sync.configs.themes.$currentTheme.PSObject.Properties
        foreach ($themeProperty in $themeProperties) {
            # Apply properties that deal with colors
            if ($themeProperty.Name -like "*color*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "ColorBrush"
                # For certain color properties, also set complementary values (e.g., BorderColor -> CBorderColor) This is required because e.g DropShadowEffect requires a <Color> and not a <SolidColorBrush> object
                if ($themeProperty.Name -in @("BorderColor", "ButtonBackgroundMouseoverColor")) {
                    Set-ThemeResourceProperty -Name "C$($themeProperty.Name)" -Value $themeProperty.Value -Type "Color"
                }
            }
            # Apply corner radius properties
            elseif ($themeProperty.Name -like "*Radius*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "CornerRadius"
            }
            # Apply row height properties
            elseif ($themeProperty.Name -like "*RowHeight*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "GridLength"
            }
            # Apply thickness or margin properties
            elseif (($themeProperty.Name -like "*Thickness*") -or ($themeProperty.Name -like "*margin")) {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Thickness"
            }
            # Apply font family properties
            elseif ($themeProperty.Name -like "*FontFamily*") {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "FontFamily"
            }
            # Apply any other properties as doubles (numerical values)
            else {
                Set-ThemeResourceProperty -Name $themeProperty.Name -Value $themeProperty.Value -Type "Double"
            }
        }
    }

    $sync.preferences.theme = $theme
    Set-WinutilTheme -currentTheme "shared"

    switch ($sync.preferences.theme) {
        "Auto" {
            $systemUsesDarkMode = Get-WinUtilToggleStatus WPFToggleDarkMode
            if ($systemUsesDarkMode) {
                $theme = "Dark"
            }
            else{
                $theme = "Light"
            }

            Set-WinutilTheme -currentTheme $theme
            $themeButtonIcon = [char]0xF08C
        }
        "Dark" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE708
           }
        "Light" {
            Set-WinutilTheme -currentTheme $sync.preferences.theme
            $themeButtonIcon = [char]0xE706
        }
    }

    # Reapply font scaling if it was previously set (theme change resets shared resources)
    if ($sync.ContainsKey("FontScaleFactor") -and $sync.FontScaleFactor -ne 1.0) {
        Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScaleFactor
    }

    # Update the theme selector button with the appropriate icon
    $ThemeButton = $sync.Form.FindName("ThemeButton")
    $ThemeButton.Content = [string]$themeButtonIcon
}

function Remove-WinUtilAPPX {
    <#

    .SYNOPSIS
        Removes all APPX packages that match the given name

    .PARAMETER Name
        The name of the APPX package to remove

    .EXAMPLE
        Remove-WinUtilAPPX -Name "Microsoft.Microsoft3DViewer"

    #>
    param (
        $Name
    )

    Write-Host "正在移除 $Name"
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX package pattern: $Name"

    # We explicitly loop through packages instead of using the pipeline because PowerShell 7 pipeline binding
    # for Remove-AppxPackage fails silently, and Get-AppxPackage -AllUsers returns duplicate objects for each user profile.
    $pkgs = Get-AppxPackage "*$Name*" -AllUsers | Sort-Object -Property PackageFullName -Unique
    if ($null -ne $pkgs) {
        foreach ($pkg in $pkgs) {
            try {
                Remove-AppxPackage -Package $pkg.PackageFullName -AllUsers -ErrorAction Stop
            }
            catch {
                Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message "Failed to remove AppX package $($pkg.PackageFullName): $($_.Exception.Message)"
            }
        }
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX removal completed for package pattern: $Name"
}

function Remove-WinUtilProvisionedAPPX {
    <#

    .SYNOPSIS
        Removes all AppX provisioned packages that match the given names

    .PARAMETER PackageList
        An array of names of the APPX packages to remove

    .EXAMPLE
        Remove-WinUtilProvisionedAPPX -PackageList @("Microsoft.Microsoft3DViewer", "Microsoft.WindowsCalculator")

    #>
    param (
        [string[]]$PackageList
    )

    if ($null -eq $PackageList -or $PackageList.Count -eq 0) {
        return
    }

    Write-Host "`nRemoving provisioned packages..."
    Write-WinUtilLog -Component "AppX" -Message "Removing AppX provisioned packages: $($PackageList -join ', ')"

    # DISM cmdlets like Get-AppxProvisionedPackage often fail with "Class not registered" or hang in PowerShell 7.
    # We shell out to Windows PowerShell 5.1 (powershell.exe) to reliably remove the provisioned packages.
    $ps5Command = {
        $pkgs = $args
        $provisionedPackages = Get-AppxProvisionedPackage -Online -ErrorAction SilentlyContinue
        $failures = [System.Collections.Generic.List[string]]::new()

        foreach ($Package in $pkgs) {
            $provs = $provisionedPackages |
                Where-Object DisplayName -Like "*$Package*"

            if ($null -ne $provs) {
                foreach ($prov in $provs) {
                    try {
                        Remove-AppxProvisionedPackage -Online -PackageName $prov.PackageName -ErrorAction Stop | Out-Null
                    }
                    catch {
                        $failures.Add("Failed to remove provisioned AppX package $($prov.PackageName): $($_.Exception.Message)")
                    }
                }
            }
        }

        if ($failures.Count -gt 0) {
            throw ($failures -join [Environment]::NewLine)
        }
    }

    $removalOutput = powershell.exe -NoProfile -NonInteractive -Command $ps5Command -args $PackageList 2>&1
    if ($LASTEXITCODE -ne 0 -or $null -ne $removalOutput) {
        $failureDetails = ($removalOutput | Out-String).Trim()
        $errorMessage = "AppX provisioned package removal failed: $failureDetails"
        Write-WinUtilLog -Level "ERROR" -Component "AppX" -Message $errorMessage
        throw $errorMessage
    }

    Write-WinUtilLog -Component "AppX" -Message "AppX provisioned package removal completed."
}

function Reset-WPFCheckBoxes {
    <#

    .SYNOPSIS
        Set winutil checkboxs to match $sync.selected values.
        Should only need to be run if $sync.selected updated outside of UI (i.e. presets or import)

    .PARAMETER doToggles
        Whether or not to set UI toggles. WARNING: they will trigger if altered

    .PARAMETER checkboxfilterpattern
        The Pattern to use when filtering through CheckBoxes, defaults to "**"
        Used to make reset blazingly fast.
    #>

    param (
        [Parameter(position=0)]
        [bool]$doToggles = $false,

        [Parameter(position=1)]
        [string]$checkboxfilterpattern = "**"
    )

    $CheckBoxesToCheck = $sync.selectedApps + $sync.selectedTweaks + $sync.selectedFeatures + $sync.selectedAppx
    $CheckBoxes = foreach ($syncEntry in $sync.GetEnumerator()) {
        if ($syncEntry.Value -is [System.Windows.Controls.CheckBox] -and $syncEntry.Name -notlike "WPFToggle*" -and $syncEntry.Name -like $checkboxfilterpattern) {
            $syncEntry
        }
    }

    foreach ($CheckBox in $CheckBoxes) {
        $checkboxName = $CheckBox.Key
        if (-not $CheckBoxesToCheck) {
            $sync.$checkBoxName.IsChecked = $false
            continue
        }

        # Check if the checkbox name exists in the flattened JSON hashtable
        if ($CheckBoxesToCheck -contains $checkboxName) {
            # If it exists, set IsChecked to true
            $sync.$checkboxName.IsChecked = $true
        } else {
            # If it doesn't exist, set IsChecked to false
            $sync.$checkboxName.IsChecked = $false
        }
    }

    # Update Installs tab UI values
    $count = $sync.SelectedApps.Count
    $sync.WPFselectedAppsButton.Content = "已选应用： $count"
    # On every change, remove all entries inside the Popup Menu. This is done, so we can keep the alphabetical order even if elements are selected in a random way
    $sync.selectedAppsstackPanel.Children.Clear()
    $sync.selectedApps | Foreach-Object { Add-SelectedAppsMenuItem -name $($sync.configs.applicationsHashtable.$_.Content) -key $_ }

    if($doToggles) {
        # Restore toggle switch states from imported config.
        # Only act on toggles that are explicitly listed in the import - toggles absent
        # from the export file were not part of the saved config and should keep whatever
        # state the live system already has (set during UI initialisation via Get-WinUtilToggleStatus).
        $importedToggles = $sync.selectedToggles
        $allToggles = $sync.GetEnumerator() | Where-Object { $_.Key -like "WPFToggle*" -and $_.Value -is [System.Windows.Controls.CheckBox] }
        foreach ($toggle in $allToggles) {
            if ($importedToggles -contains $toggle.Key) {
                $sync[$toggle.Key].IsChecked = $true
            }
            # Toggles not present in the import are intentionally left untouched;
            # their current UI state already reflects the real system state.
        }
    }
}

function Save-WinUtilFile {
    <#
    .SYNOPSIS
        Downloads a file and reports transfer progress.
    #>
    param(
        [Parameter(Mandatory)]
        [uri]$Uri,

        [Parameter(Mandatory)]
        [string]$DestinationPath,

        [Parameter(Mandatory)]
        [scriptblock]$ProgressCallback
    )

    $response = $null
    $responseStream = $null
    $outputStream = $null

    try {
        $request = [System.Net.WebRequest]::Create($Uri)
        $response = $request.GetResponse()
        $totalBytes = $response.ContentLength
        $responseStream = $response.GetResponseStream()
        $outputStream = [System.IO.File]::Create($DestinationPath)
        $buffer = New-Object byte[] 81920
        $downloadedBytes = 0L
        $lastPercent = -1

        while (($bytesRead = $responseStream.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $outputStream.Write($buffer, 0, $bytesRead)
            $downloadedBytes += $bytesRead

            if ($totalBytes -gt 0) {
                $percent = [Math]::Min(100, [int](($downloadedBytes / $totalBytes) * 100))
                if ($percent -ne $lastPercent) {
                    & $ProgressCallback $percent
                    $lastPercent = $percent
                }
            }
        }

        if ($lastPercent -ne 100) {
            & $ProgressCallback 100
        }
    }
    finally {
        if ($null -ne $outputStream) {
            $outputStream.Dispose()
        }
        if ($null -ne $responseStream) {
            $responseStream.Dispose()
        }
        if ($null -ne $response) {
            $response.Dispose()
        }
    }
}

function Set-WinUtilAppCategoryFilter {
    <#
        .SYNOPSIS
            Applies an exact application category filter from an Install tab search chip.

        .PARAMETER Category
            The application category to show. An empty value clears the filter.
    #>
    param(
        [Parameter(Mandatory = $false)]
        [string]$Category = ""
    )

    $sync.SearchBar.Tag = $Category
    $sync.SearchBar.Text = $Category
    Find-AppsByNameOrDescription -SearchString $Category -Category $Category
}

function Set-WinUtilDNS {
    <#

    .SYNOPSIS
        Sets the DNS of all interfaces that are in the "Up" state. It will lookup the values from the DNS.Json file

    .PARAMETER DNSProvider
        The DNS provider to set the DNS server to

    .EXAMPLE
        Set-WinUtilDNS -DNSProvider "google"

    #>
    param($DNSProvider)

    if($DNSProvider -eq "Default") {
        Write-WinUtilLog -Component "DNS" -Message "DNS provider is Default; no DNS changes applied."
        return
    }

    try {
        $Adapters = Get-NetAdapter | Where-Object {$_.Status -eq "Up"}
        Write-Host "正在确保以下接口的 DNS 设置为 ${DNSProvider}:"
        Write-Host $($Adapters | Out-String)
        Write-WinUtilLog -Component "DNS" -Message "Setting DNS provider to $DNSProvider for $(@($Adapters).Count) active adapter(s)."

        if($DNSProvider -ne "DHCP") {
            $dns = $sync.configs.dns.$DNSProvider
            if($null -eq $dns) {
                Write-Warning "DNS provider $DNSProvider was not found in configuration."
                Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "DNS provider $DNSProvider was not found in configuration."
                return
            }
        }

        Foreach ($Adapter in $Adapters) {
            if($DNSProvider -eq "DHCP") {
                Write-WinUtilLog -Component "DNS" -Message "Resetting DNS to DHCP on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex))."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ResetServerAddresses
                netsh interface ip set dnsservers name="$($Adapter.Name)" source=dhcp
                netsh interface ipv6 set dnsservers name="$($Adapter.Name)" source=dhcp
            } else {
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv4 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary), $($dns.Secondary)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary, $dns.Secondary)
                Write-WinUtilLog -Component "DNS" -Message "Setting IPv6 DNS on adapter $($Adapter.Name) (ifIndex: $($Adapter.ifIndex)) to $($dns.Primary6), $($dns.Secondary6)."
                Set-DnsClientServerAddress -InterfaceIndex $Adapter.ifIndex -ServerAddresses ($dns.Primary6, $dns.Secondary6)
            }
        }
        Write-WinUtilLog -Component "DNS" -Message "DNS provider change completed: $DNSProvider"
    } catch {
        Write-Warning "Unable to set DNS Provider due to an unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "DNS" -Message "Unable to set DNS provider $DNSProvider`: $($psitem.Exception.Message)"
    }
}

function Set-WinUtilRegistry {
    <#

    .SYNOPSIS
        Modifies the registry based on the given inputs

    .PARAMETER Name
        The name of the key to modify

    .PARAMETER Path
        The path to the key

    .PARAMETER Type
        The type of value to set the key to

    .PARAMETER Value
        The value to set the key to

    .EXAMPLE
        Set-WinUtilRegistry -Name "PublishUserActivities" -Path "HKLM:\SOFTWARE\Policies\Microsoft\Windows\System" -Type "DWord" -Value "0"

    #>
    param (
        $Name,
        $Path,
        $Type,
        $Value
    )

    try {
        if(!(Test-Path 'HKU:\')) {New-PSDrive -PSProvider Registry -Name HKU -Root HKEY_USERS}

        If (!(Test-Path $Path)) {
            Write-Host "$Path was not found. Creating..."
            Write-WinUtilLog -Component "Registry" -Message "Creating registry path: $Path"
            New-Item -Path $Path -Force -ErrorAction Stop | Out-Null
        }

        if ($Value -ne "<RemoveEntry>") {
            Write-Host "设置 $Path\$Name 为 $Value"
            Write-WinUtilLog -Component "Registry" -Message "Setting $Path\$Name ($Type) to $Value"
            Set-ItemProperty -Path $Path -Name $Name -Type $Type -Value $Value -Force -ErrorAction Stop | Out-Null
        }
        else{
            Write-Host "移除 $Path\$Name"
            Write-WinUtilLog -Component "Registry" -Message "Removing $Path\$Name"
            Remove-ItemProperty -Path $Path -Name $Name -Force -ErrorAction Stop | Out-Null
        }
    } catch [System.Security.SecurityException] {
        Write-Warning "Unable to set $Path\$Name to $Value due to a Security Exception."
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Security exception while changing $Path\$Name to $Value`: $($psitem.Exception.Message)"
    } catch [System.Management.Automation.ItemNotFoundException] {
        Write-Warning $psitem.Exception.ErrorRecord
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Registry item not found while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch [System.UnauthorizedAccessException] {
       Write-Warning $psitem.Exception.Message
       Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unauthorized while changing $Path\$Name`: $($psitem.Exception.Message)"
    } catch {
        Write-Warning "Unable to set $Name due to unhandled exception."
        Write-Warning $psitem.Exception.StackTrace
        Write-WinUtilLog -Level "ERROR" -Component "Registry" -Message "Unhandled exception while changing $Path\$Name`: $($psitem.Exception.Message)"
    }
}

Function Set-WinUtilService {
    <#

    .SYNOPSIS
        Changes the startup type of the given service

    .PARAMETER Name
        The name of the service to modify

    .PARAMETER StartupType
        The startup type to set the service to

    .EXAMPLE
        Set-WinUtilService -Name "HomeGroupListener" -StartupType "Manual"

    #>
    param (
        $Name,
        $StartupType
    )
    try {
        Write-Host "正在将服务 $Name 设置为 $StartupType"
        Write-WinUtilLog -Component "Service" -Message "Setting service $Name startup type to $StartupType"

        # Check if the service exists
        $service = Get-Service -Name $Name -ErrorAction Stop

        if (($service.PSObject.Properties.Name -contains "StartType") -and ([string]$service.StartType -eq [string]$StartupType) ) {
            Write-Host "服务 $Name 已经设置为 $StartupType"
            Write-WinUtilLog -Component "Service" -Message "Service $Name startup type is already $StartupType; no change needed."
            return
        }

        # Service exists, proceed with changing properties -- while handling auto delayed start for PWSH 5
        if (($PSVersionTable.PSVersion.Major -lt 7) -and ($StartupType -eq "AutomaticDelayedStart")) {
            sc.exe config $Name start=delayed-auto
        } else {
            $service | Set-Service -StartupType $StartupType -ErrorAction Stop
        }
        Write-WinUtilLog -Component "Service" -Message "Service $Name startup type set to $StartupType"
    } catch {
        if ($_.FullyQualifiedErrorId -like "NoServiceFoundForGivenName,*") {
            Write-Warning "Service $Name was not found."
            Write-WinUtilLog -Level "WARN" -Component "Service" -Message "Service $Name was not found."
        } else {
            Write-Warning "Unable to set $Name due to unhandled exception."
            Write-Warning $_.Exception.Message
            Write-WinUtilLog -Level "ERROR" -Component "Service" -Message "Unable to set service $Name to $StartupType`: $($_.Exception.Message)"
        }
    }

}

function Set-WinUtilTaskbaritem {
    <#

    .SYNOPSIS
        Modifies the Taskbaritem of the WPF Form

    .PARAMETER value
        Value can be between 0 and 1, 0 being no progress done yet and 1 being fully completed
        Value does not affect item without setting the state to 'Normal', 'Error' or 'Paused'
        Set-WinUtilTaskbaritem -value 0.5

    .PARAMETER state
        State can be 'None' > No progress, 'Indeterminate' > inf. loading gray, 'Normal' > Gray, 'Error' > Red, 'Paused' > Yellow
        no value needed:
        - Set-WinUtilTaskbaritem -state "None"
        - Set-WinUtilTaskbaritem -state "Indeterminate"
        value needed:
        - Set-WinUtilTaskbaritem -state "Error"
        - Set-WinUtilTaskbaritem -state "Normal"
        - Set-WinUtilTaskbaritem -state "Paused"

    .PARAMETER overlay
        Overlay icon to display on the taskbar item, there are the presets 'None', 'logo' and 'checkmark' or you can specify a path/link to an image file.
        CTT logo preset:
        - Set-WinUtilTaskbaritem -overlay "logo"
        Checkmark preset:
        - Set-WinUtilTaskbaritem -overlay "checkmark"
        Warning preset:
        - Set-WinUtilTaskbaritem -overlay "warning"
        No overlay:
        - Set-WinUtilTaskbaritem -overlay "None"
        Custom icon (needs to be supported by WPF):
        - Set-WinUtilTaskbaritem -overlay "C:\path\to\icon.png"

    .PARAMETER description
        Description to display on the taskbar item preview
        Set-WinUtilTaskbaritem -description "This is a description"
    #>
    param (
        [string]$state,
        [double]$value,
        [string]$overlay,
        [string]$description
    )

    if ($value) {
        $sync["Form"].taskbarItemInfo.ProgressValue = $value
    }

    if ($state) {
        switch ($state) {
            'None' { $sync["Form"].taskbarItemInfo.ProgressState = "None" }
            'Indeterminate' { $sync["Form"].taskbarItemInfo.ProgressState = "Indeterminate" }
            'Normal' { $sync["Form"].taskbarItemInfo.ProgressState = "Normal" }
            'Error' { $sync["Form"].taskbarItemInfo.ProgressState = "Error" }
            'Paused' { $sync["Form"].taskbarItemInfo.ProgressState = "Paused" }
            default { throw "[Set-WinUtilTaskbarItem] Invalid state" }
        }
    }

    if ($overlay) {
        switch ($overlay) {
            'logo' {
                if (-not $sync["logorender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["logorender"]
            }
            'checkmark' {
                if (-not $sync["checkmarkrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["checkmarkrender"]
            }
            'warning' {
                if (-not $sync["warningrender"]) {
                    Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true
                }
                $sync["Form"].taskbarItemInfo.Overlay = $sync["warningrender"]
            }
            'None' {
                $sync["Form"].taskbarItemInfo.Overlay = $null
            }
            default {
                if (Test-Path $overlay) {
                    $sync["Form"].taskbarItemInfo.Overlay = $overlay
                }
            }
        }
    }

    if ($description) {
        $sync["Form"].taskbarItemInfo.Description = $description
    }
}

function Set-WinUtilTweaksProgressIndicator {
    <#
    .SYNOPSIS
        Shows, updates, or hides the window-level progress indicator used by long-running
        workflows such as app management, Tweaks, AppX management, and Win11 Creator.
        It lives outside the TabControl, so it stays visible no matter which tab is active.
    .PARAMETER Visible
        Whether the indicator should be shown or hidden.
    .PARAMETER Label
        The text to display above the progress bar.
    .PARAMETER Percent
        The percentage of the progress bar that should be filled (0-100).
    #>
    param(
        [bool]$Visible,
        [string]$Label,
        [ValidateRange(0,100)]
        [int]$Percent
    )

    $indicatorVisible = if ($Visible) { [Windows.Visibility]::Visible } else { [Windows.Visibility]::Collapsed }
    $indicatorLabel = $Label
    $hasLabel = $PSBoundParameters.ContainsKey('Label')
    $hasPercent = $PSBoundParameters.ContainsKey('Percent')

    Invoke-WPFUIThread -ScriptBlock {
        $sync.WPFTweaksProgressBar.Visibility = $indicatorVisible
        if ($hasLabel) {
            $sync.WPFTweaksProgressLabel.Text = $indicatorLabel
        }
        if ($hasPercent) {
            $sync.WPFTweaksProgressValue.Value = $Percent
        }
    }
}

function Show-CustomDialog {
    <#
    .SYNOPSIS
    Displays a custom dialog box with an image, heading, message, and an OK button.

    .DESCRIPTION
    This function creates a custom dialog box with the specified message and additional elements such as an image, heading, and an OK button. The dialog box is designed with a green border, rounded corners, and a black background.

    .PARAMETER Title
    The Title to use for the dialog window's Title Bar, this will not be visible by the user, as window styling is set to None.

    .PARAMETER Message
    The message to be displayed in the dialog box.

    .PARAMETER Width
    The width of the custom dialog window.

    .PARAMETER Height
    The height of the custom dialog window.

    .PARAMETER FontSize
    The Font Size of message shown inside custom dialog window.

    .PARAMETER HeaderFontSize
    The Font Size for the Header of custom dialog window.

    .PARAMETER LogoSize
    The Size of the Logo used inside the custom dialog window.

    .PARAMETER ForegroundColor
    The Foreground Color of dialog window title & message.

    .PARAMETER BackgroundColor
    The Background Color of dialog window.

    .PARAMETER BorderColor
    The Color for dialog window border.

    .PARAMETER ButtonBackgroundColor
    The Background Color for Buttons in dialog window.

    .PARAMETER ButtonForegroundColor
    The Foreground Color for Buttons in dialog window.

    .PARAMETER ShadowColor
    The Color used when creating the Drop-down Shadow effect for dialog window.

    .PARAMETER LogoColor
    The Color of WinUtil Text found next to WinUtil's Logo inside dialog window.

    .PARAMETER LinkForegroundColor
    The Foreground Color for Links inside dialog window.

    .PARAMETER LinkHoverForegroundColor
    The Foreground Color for Links when the mouse pointer hovers over them inside dialog window.

    .PARAMETER EnableScroll
    A flag indicating whether to enable scrolling if the content exceeds the window size.

    .EXAMPLE
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels.
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    .EXAMPLE
    $foregroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $backgroundColor = New-Object System.Windows.Media.SolidColorBrush("#1e1e1e")
    $linkForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#0088e5")
    $linkHoverForegroundColor = New-Object System.Windows.Media.SolidColorBrush("#005289")
    Show-CustomDialog -Title "My Custom Dialog" -Message "This is a custom dialog with a message and an image above." -Width 300 -Height 200 -ForegroundColor $foregroundColor -BackgroundColor $backgroundColor -LinkForegroundColor $linkForegroundColor -LinkHoverForegroundColor $linkHoverForegroundColor

    Makes a new Custom Dialog with the title 'My Custom Dialog' and a message 'This is a custom dialog with a message and an image above.', with dimensions of 300 by 200 pixels, with a link foreground (and general foreground) colors of '#0088e5', background color of '#1e1e1e', and Link Color on Hover of '005289', all of which are in Hexadecimal (the '#' Symbol is required by SolidColorBrush Constructor).
    Other styling options are grabbed from '$sync.Form.Resources' global variable.

    #>
    param(
        [string]$Title,
        [string]$Message,
        [int]$Width = $sync.Form.Resources.CustomDialogWidth,
        [int]$Height = $sync.Form.Resources.CustomDialogHeight,

        [System.Windows.Media.FontFamily]$FontFamily = $sync.Form.Resources.FontFamily,
        [int]$FontSize = $sync.Form.Resources.CustomDialogFontSize,
        [int]$HeaderFontSize = $sync.Form.Resources.CustomDialogFontSizeHeader,
        [int]$LogoSize = $sync.Form.Resources.CustomDialogLogoSize,

        [System.Windows.Media.Color]$ShadowColor = "#AAAAAAAA",
        [System.Windows.Media.SolidColorBrush]$LogoColor = $sync.Form.Resources.LabelboxForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BorderColor = $sync.Form.Resources.BorderColor,
        [System.Windows.Media.SolidColorBrush]$ForegroundColor = $sync.Form.Resources.MainForegroundColor,
        [System.Windows.Media.SolidColorBrush]$BackgroundColor = $sync.Form.Resources.MainBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonForegroundColor = $sync.Form.Resources.ButtonInstallForegroundColor,
        [System.Windows.Media.SolidColorBrush]$ButtonBackgroundColor = $sync.Form.Resources.ButtonInstallBackgroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkForegroundColor = $sync.Form.Resources.LinkForegroundColor,
        [System.Windows.Media.SolidColorBrush]$LinkHoverForegroundColor = $sync.Form.Resources.LinkHoverForegroundColor,

        [bool]$EnableScroll = $false
    )

    # Create a custom dialog window
    $dialog = New-Object Windows.Window
    $dialog.Title = $Title
    $dialog.Height = $Height
    $dialog.Width = $Width
    $dialog.Margin = New-Object Windows.Thickness(10)  # Add margin to the entire dialog box
    $dialog.WindowStyle = [Windows.WindowStyle]::None  # Remove title bar and window controls
    $dialog.ResizeMode = [Windows.ResizeMode]::NoResize  # Disable resizing
    $dialog.WindowStartupLocation = [Windows.WindowStartupLocation]::CenterScreen  # Center the window
    $dialog.Foreground = $ForegroundColor
    $dialog.Background = $BackgroundColor
    $dialog.FontFamily = $FontFamily
    $dialog.FontSize = $FontSize

    # Create a Border for the green edge with rounded corners
    $border = New-Object Windows.Controls.Border
    $border.BorderBrush = $BorderColor
    $border.BorderThickness = New-Object Windows.Thickness(1)  # Adjust border thickness as needed
    $border.CornerRadius = New-Object Windows.CornerRadius(10)  # Adjust the radius for rounded corners

    # Create a drop shadow effect
    $dropShadow = New-Object Windows.Media.Effects.DropShadowEffect
    $dropShadow.Color = $shadowColor
    $dropShadow.Direction = 270
    $dropShadow.ShadowDepth = 5
    $dropShadow.BlurRadius = 10

    # Apply drop shadow effect to the border
    $dialog.Effect = $dropShadow

    $dialog.Content = $border

    # Create a grid for layout inside the Border
    $grid = New-Object Windows.Controls.Grid
    $border.Child = $grid

    # Uncomment the following line to show gridlines
    #$grid.ShowGridLines = $true

    # Add the following line to set the background color of the grid
    $grid.Background = [Windows.Media.Brushes]::Transparent
    # Add the following line to make the Grid stretch
    $grid.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $grid.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Add the following line to make the Border stretch
    $border.HorizontalAlignment = [Windows.HorizontalAlignment]::Stretch
    $border.VerticalAlignment = [Windows.VerticalAlignment]::Stretch

    # Set up Row Definitions
    $row0 = New-Object Windows.Controls.RowDefinition
    $row0.Height = [Windows.GridLength]::Auto

    $row1 = New-Object Windows.Controls.RowDefinition
    $row1.Height = [Windows.GridLength]::new(1, [Windows.GridUnitType]::Star)

    $row2 = New-Object Windows.Controls.RowDefinition
    $row2.Height = [Windows.GridLength]::Auto

    # Add Row Definitions to Grid
    $grid.RowDefinitions.Add($row0)
    $grid.RowDefinitions.Add($row1)
    $grid.RowDefinitions.Add($row2)

    # Add StackPanel for horizontal layout with margins
    $stackPanel = New-Object Windows.Controls.StackPanel
    $stackPanel.Margin = New-Object Windows.Thickness(10)  # Add margins around the stack panel
    $stackPanel.Orientation = [Windows.Controls.Orientation]::Horizontal
    $stackPanel.HorizontalAlignment = [Windows.HorizontalAlignment]::Left  # Align to the left
    $stackPanel.VerticalAlignment = [Windows.VerticalAlignment]::Top  # Align to the top

    $grid.Children.Add($stackPanel)
    [Windows.Controls.Grid]::SetRow($stackPanel, 0)  # Set the row to the second row (0-based index)

    # Add SVG path to the stack panel
    $stackPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size $LogoSize))

    # Add "Winutil" text
    $winutilTextBlock = New-Object Windows.Controls.TextBlock
    $winutilTextBlock.Text = "WinUtil"
    $winutilTextBlock.FontSize = $HeaderFontSize
    $winutilTextBlock.Foreground = $LogoColor
    $winutilTextBlock.Margin = New-Object Windows.Thickness(10, 10, 10, 5)  # Add margins around the text block
    $stackPanel.Children.Add($winutilTextBlock)
    # Add TextBlock for information with text wrapping and margins
    $messageTextBlock = New-Object Windows.Controls.TextBlock
    $messageTextBlock.FontSize = $FontSize
    $messageTextBlock.TextWrapping = [Windows.TextWrapping]::Wrap  # Enable text wrapping
    $messageTextBlock.HorizontalAlignment = [Windows.HorizontalAlignment]::Left
    $messageTextBlock.VerticalAlignment = [Windows.VerticalAlignment]::Top
    $messageTextBlock.Margin = New-Object Windows.Thickness(10)  # Add margins around the text block

    # Define the Regex to find hyperlinks formatted as HTML <a> tags
    $regex = [regex]::new('<a href="([^"]+)">([^<]+)</a>')
    $lastPos = 0
    $linkHoverBrush = $LinkHoverForegroundColor

    # Iterate through each match and add regular text and hyperlinks
    foreach ($match in $regex.Matches($Message)) {
        # Add the text before the hyperlink, if any
        $textBefore = $Message.Substring($lastPos, $match.Index - $lastPos)
        if ($textBefore.Length -gt 0) {
            $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textBefore)))
        }

        # Create and add the hyperlink
        $hyperlink = New-Object Windows.Documents.Hyperlink
        $hyperlink.NavigateUri = New-Object System.Uri($match.Groups[1].Value)
        $hyperlink.Inlines.Add($match.Groups[2].Value)
        $hyperlink.TextDecorations = [Windows.TextDecorations]::None  # Remove underline
        $hyperlink.Foreground = $LinkForegroundColor

        $hyperlink.Add_Click({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            Start-Process $eventSender.NavigateUri.AbsoluteUri
        })
        $hyperlink.Add_MouseEnter({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $linkHoverBrush
            $eventSender.FontSize = ($FontSize + ($FontSize / 4))
            $eventSender.FontWeight = "SemiBold"
        })
        $hyperlink.Add_MouseLeave({
            param($eventSender, $routedEvent)
            $null = $routedEvent
            $eventSender.Foreground = $LinkForegroundColor
            $eventSender.FontSize = $FontSize
            $eventSender.FontWeight = "Normal"
        })

        $messageTextBlock.Inlines.Add($hyperlink)

        # Update the last position
        $lastPos = $match.Index + $match.Length
    }

    # Add any remaining text after the last hyperlink
    if ($lastPos -lt $Message.Length) {
        $textAfter = $Message.Substring($lastPos)
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($textAfter)))
    }

    # If no matches, add the entire message as a run
    if ($regex.Matches($Message).Count -eq 0) {
        $messageTextBlock.Inlines.Add((New-Object Windows.Documents.Run($Message)))
    }

    # Create a ScrollViewer if EnableScroll is true
    if ($EnableScroll) {
        $scrollViewer = New-Object System.Windows.Controls.ScrollViewer
        $scrollViewer.VerticalScrollBarVisibility = 'Auto'
        $scrollViewer.HorizontalScrollBarVisibility = 'Disabled'
        $scrollViewer.Content = $messageTextBlock
        $grid.Children.Add($scrollViewer)
        [Windows.Controls.Grid]::SetRow($scrollViewer, 1)  # Set the row to the second row (0-based index)
    } else {
        $grid.Children.Add($messageTextBlock)
        [Windows.Controls.Grid]::SetRow($messageTextBlock, 1)  # Set the row to the second row (0-based index)
    }

    # Add OK button
    $okButton = New-Object Windows.Controls.Button
    $okButton.Content = "OK"
    $okButton.FontSize = $FontSize
    $okButton.Width = 80
    $okButton.Height = 30
    $okButton.HorizontalAlignment = [Windows.HorizontalAlignment]::Center
    $okButton.VerticalAlignment = [Windows.VerticalAlignment]::Bottom
    $okButton.Margin = New-Object Windows.Thickness(0, 0, 0, 10)
    $okButton.Background = $buttonBackgroundColor
    $okButton.Foreground = $buttonForegroundColor
    $okButton.BorderBrush = $BorderColor
    $okButton.Add_Click({
        $dialog.Close()
    })
    $grid.Children.Add($okButton)
    [Windows.Controls.Grid]::SetRow($okButton, 2)  # Set the row to the third row (0-based index)

    # Handle Escape key press to close the dialog
    $dialog.Add_KeyDown({
        if ($_.Key -eq 'Escape') {
            $dialog.Close()
        }
    })

    # Set the OK button as the default button (activated on Enter)
    $okButton.IsDefault = $true

    # Show the custom dialog
    $dialog.ShowDialog()
}

function Show-WinUtilMessage {
    <#
    .SYNOPSIS
        Shows a WinUtil message box and returns the selected result.
    #>
    param (
        [string]$Message,
        [string]$Title = "Winutil",
        $Button = "OK",
        $Icon = "Information"
    )

    [System.Windows.MessageBox]::Show($Message, $Title, $Button, $Icon)
}

function Invoke-WinUtilInstallAppRenderBatch {
    param(
        [Parameter(Mandatory = $true)]
        $CategoryBatch
    )

    foreach ($appKey in $CategoryBatch.AppKeys) {
        $sync.$appKey = Initialize-InstallAppEntry -TargetElement $CategoryBatch.TargetElement -AppKey $appKey
    }

    if ($sync.tabManager.currentTab -eq 0 -and $sync.SearchBar -and -not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text)) {
        Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
    }
}

function Complete-WinUtilInstallAppRendering {
    $sync.InstallAppEntriesRendered = $true
}

function Invoke-WinUtilInstallAppRenderNextBatch {
    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    if ($sync.InstallAppRenderQueue.Count -gt 0) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    Complete-WinUtilInstallAppRendering
}

function Start-WinUtilInstallAppRendering {
    if ($null -eq $sync.InstallAppRenderQueue) {
        return
    }

    $sync.InstallAppEntriesRendered = $false

    if ($sync.Form -and $sync.Form.Dispatcher) {
        $sync.Form.Dispatcher.BeginInvoke(
            [System.Windows.Threading.DispatcherPriority]::Background,
            [action]{ Invoke-WinUtilInstallAppRenderNextBatch }
        ) | Out-Null
        return
    }

    while ($sync.InstallAppRenderQueue.Count -gt 0) {
        $categoryBatch = $sync.InstallAppRenderQueue.Dequeue()
        Invoke-WinUtilInstallAppRenderBatch -CategoryBatch $categoryBatch
    }

    Complete-WinUtilInstallAppRendering
}

function Test-WinUtilPackageManager {
    <#

    .SYNOPSIS
        Checks if WinGet and/or Choco are installed

    .PARAMETER winget
        Check if WinGet is installed

    .PARAMETER choco
        Check if Chocolatey is installed

    #>

    Param(
        [System.Management.Automation.SwitchParameter]$winget,
        [System.Management.Automation.SwitchParameter]$choco
    )

    if ($winget) {
        if (Get-Command winget -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---        WinGet is installed          ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---      WinGet is not installed        ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    if ($choco) {
        if (Get-Command choco -ErrorAction SilentlyContinue) {
            Write-Host "===========================================" -ForegroundColor Green
            Write-Host "---      Chocolatey is installed        ---" -ForegroundColor Green
            Write-Host "===========================================" -ForegroundColor Green
            $status = "installed"
        } else {
            Write-Host "===========================================" -ForegroundColor Red
            Write-Host "---    Chocolatey is not installed      ---" -ForegroundColor Red
            Write-Host "===========================================" -ForegroundColor Red
            $status = "not-installed"
        }
    }

    return $status
}

function Update-WinUtilSelections ($flatJson) {
    foreach ($cbkey in $flatJson) {

        $listName = switch -Regex ($cbkey) {
            '^WPFInstall' { 'selectedApps' }
            '^WPFTweaks'  { 'selectedTweaks' }
            '^WPFToggle'  { 'selectedToggles' }
            '^WPFFeature' { 'selectedFeatures' }
            '^WPFAppx'    { 'selectedAppx' }
        }

        $sync.$listName.Add($cbkey)
    }
}

function Write-WinUtilLog {
    <#

    .SYNOPSIS
        Writes a timestamped WinUtil log entry to the active session log.

    .PARAMETER Message
        The message to write.

    .PARAMETER Level
        The severity level for the log entry.

    .PARAMETER Component
        The WinUtil component producing the log entry.

    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet("INFO", "WARN", "ERROR", "DEBUG")]
        [string]$Level = "INFO",

        [string]$Component = "WinUtil"
    )

    try {
        $logPath = $null
        $transcriptPath = $null
        if ($null -ne $sync -and $sync.ContainsKey("logPath")) {
            $logPath = $sync.logPath
        }

        if ($null -ne $sync -and $sync.ContainsKey("transcriptPath")) {
            $transcriptPath = $sync.transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($transcriptPath)) {
            $logPath = $transcriptPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and $null -ne $sync -and $sync.ContainsKey("winutildir")) {
            $logDirectory = Join-Path $sync.winutildir "logs"
            $logPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            $sync.logPath = $logPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath) -and -not [string]::IsNullOrWhiteSpace($env:LocalAppData)) {
            if ([string]::IsNullOrWhiteSpace($script:WinUtilLogPath)) {
                $logDirectory = Join-Path (Join-Path $env:LocalAppData "winutil") "logs"
                $script:WinUtilLogPath = Join-Path $logDirectory "winutil_$(Get-Date -Format "yyyy-MM-dd_HH-mm-ss").log"
            }
            $logPath = $script:WinUtilLogPath
        }

        if ([string]::IsNullOrWhiteSpace($logPath)) {
            return
        }

        $logDirectory = Split-Path -Path $logPath -Parent
        if (-not (Test-Path $logDirectory)) {
            New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        }

        $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss.fff"
        $line = "[$timestamp] [$Level] [$Component] $Message"

        if (-not [string]::IsNullOrWhiteSpace($transcriptPath) -and $logPath -eq $transcriptPath) {
            Write-Host $line
            return
        }

        try {
            Add-Content -Path $logPath -Value $line -Encoding UTF8 -ErrorAction Stop
        } catch [System.IO.IOException] {
            Write-Host $line
        }
    } catch {
        Write-Warning "Unable to write WinUtil log entry: $($_.Exception.Message)"
    }
}

$sync.configs = @{}

$sync.configs.applications = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJXUEZJbnN0YWxsMXBhc3N3b3JkIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiMXBhc3N3b3JkIiwKICAgICJjb250ZW50IjogIjFQYXNzd29yZCDlr4bnoIHnrqHnkIblmagiLAogICAgImRlc2NyaXB0aW9uIjogIjFQYXNzd29yZCDmmK/kuIDmrL7lr4bnoIHnrqHnkIblmajvvIzlj6/ku6XlronlhajlnLDlrZjlgqjlkoznrqHnkIbmgqjnmoTlr4bnoIHjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly8xcGFzc3dvcmQuY29tLyIsCiAgICAid2luZ2V0IjogIkFnaWxlQml0cy4xUGFzc3dvcmQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGw3emlwIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiN3ppcCIsCiAgICAiY29udGVudCI6ICI3LVppcCDljovnvKnlt6XlhbciLAogICAgImRlc2NyaXB0aW9uIjogIjctWmlwIOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOWOi+e8qeW3peWFt++8jOaUr+aMgeWkmuenjeWOi+e8qeagvOW8j++8jOaPkOS+m+mrmOWOi+e8qeavlO+8jOaYr+aWh+S7tuWOi+e8qeeahOeDremXqOmAieaLqeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy43LXppcC5vcmcvIiwKICAgICJ3aW5nZXQiOiAiN3ppcC43emlwIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxhZG9iZSI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogImFkb2JlcmVhZGVyIiwKICAgICJjb250ZW50IjogIkFkb2JlIEFjcm9iYXQgUmVhZGVyIFBERumYheivu+WZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiQWRvYmUgQWNyb2JhdCBSZWFkZXIg5piv5LiA5qy+5YWN6LS555qEIFBERiDpmIXor7vlmajvvIzmj5Dkvpvmn6XnnIvjgIHmiZPljbDlkozms6jph4ogUERGIOaWh+aho+eahOWfuuacrOWKn+iDveOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5hZG9iZS5jb20vYWNyb2JhdC9wZGYtcmVhZGVyLmh0bWwiLAogICAgIndpbmdldCI6ICJBZG9iZS5BY3JvYmF0LlJlYWRlci42NC1iaXQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxhZHZhbmNlZGlwIjogewogICAgImNhdGVnb3J5IjogIuS4k+S4muW3peWFtyIsCiAgICAiY2hvY28iOiAiYWR2YW5jZWQtaXAtc2Nhbm5lciIsCiAgICAiY29udGVudCI6ICJBZHZhbmNlZCBJUCBTY2FubmVyIOe9kee7nOaJq+aPjyIsCiAgICAiZGVzY3JpcHRpb24iOiAiQWR2YW5jZWQgSVAgU2Nhbm5lciDmmK/kuIDmrL7lv6vpgJ/mmJPnlKjnmoTnvZHnu5zmiavmj4/lt6XlhbfvvIznlKjkuo7liIbmnpDlsYDln5/nvZHlubbmj5Dkvpvov57mjqXorr7lpIfnmoTkv6Hmga/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuYWR2YW5jZWQtaXAtc2Nhbm5lci5jb20vIiwKICAgICJ3aW5nZXQiOiAiRmFtYXRlY2guQWR2YW5jZWRJUFNjYW5uZXIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxhaW1wIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAiYWltcCIsCiAgICAiY29udGVudCI6ICJBSU1QIOmfs+S5kOaSreaUvuWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiQUlNUCDmmK/kuIDmrL7lip/og73kuLDlr4znmoTpn7PkuZDmkq3mlL7lmajvvIzmlK/mjIHlpJrnp43pn7PpopHmoLzlvI/jgIHmkq3mlL7liJfooajlkozlj6/lrprliLbnmoTnlKjmiLfnlYzpnaLjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuYWltcC5ydS8iLAogICAgIndpbmdldCI6ICJBSU1QLkFJTVAiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxhbmdyeWlwc2Nhbm5lciI6IHsKICAgICJjYXRlZ29yeSI6ICLkuJPkuJrlt6XlhbciLAogICAgImNob2NvIjogImFuZ3J5aXAiLAogICAgImNvbnRlbnQiOiAiQW5ncnkgSVAgU2Nhbm5lciBJUOaJq+aPj+WZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiQW5ncnkgSVAgU2Nhbm5lciDmmK/kuIDmrL7lvIDmupDot6jlubPlj7DnmoTnvZHnu5zmiavmj4/lmajvvIznlKjkuo7miavmj48gSVAg5Zyw5Z2A5ZKM56uv5Y+j77yM5o+Q5L6b572R57uc6L+e5o6l5L+h5oGv44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vYW5ncnlpcC5vcmcvIiwKICAgICJ3aW5nZXQiOiAiYW5ncnl6aWJlci5BbmdyeUlQU2Nhbm5lciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYW55ZGVzayI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImFueWRlc2siLAogICAgImNvbnRlbnQiOiAiQW55RGVzayDov5znqIvmoYzpnaIiLAogICAgImRlc2NyaXB0aW9uIjogIkFueURlc2sg5piv5LiA5qy+6L+c56iL5qGM6Z2i6L2v5Lu277yM5L2/55So5oi36IO95aSf6L+c56iL6K6/6Zeu5ZKM5o6n5Yi26K6h566X5py677yM5Lul5b+r6YCf6L+e5o6l5ZKM5L2O5bu26L+f6JGX56ew44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vYW55ZGVzay5jb20vIiwKICAgICJ3aW5nZXQiOiAiQW55RGVzay5BbnlEZXNrIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsYXVkYWNpdHkiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJhdWRhY2l0eSIsCiAgICAiY29udGVudCI6ICJBdWRhY2l0eSDpn7PpopHnvJbovpEiLAogICAgImRlc2NyaXB0aW9uIjogIkF1ZGFjaXR5IOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOmfs+mikee8lui+kei9r+S7tu+8jOS7peWFtuW8uuWkp+eahOW9lemfs+WSjOe8lui+keWKn+iDveiAjOmXu+WQjeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5hdWRhY2l0eXRlYW0ub3JnLyIsCiAgICAid2luZ2V0IjogIkF1ZGFjaXR5LkF1ZGFjaXR5IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxhdXRvcnVucyI6IHsKICAgICJjYXRlZ29yeSI6ICLlvq7ova/lt6XlhbciLAogICAgImNob2NvIjogImF1dG9ydW5zIiwKICAgICJjb250ZW50IjogIkF1dG9ydW5zIOWQr+WKqOmhueeuoeeQhiIsCiAgICAiZGVzY3JpcHRpb24iOiAi5q2k5bel5YW35pi+56S65ZOq5Lqb56iL5bqP6YWN572u5Li65Zyo57O757uf5ZCv5Yqo5oiW55m75b2V5pe26L+Q6KGM44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vbGVhcm4ubWljcm9zb2Z0LmNvbS9lbi11cy9zeXNpbnRlcm5hbHMvZG93bmxvYWRzL2F1dG9ydW5zIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LlN5c2ludGVybmFscy5BdXRvcnVucyIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHJkY21hbiI6IHsKICAgICJjYXRlZ29yeSI6ICLlvq7ova/lt6XlhbciLAogICAgImNob2NvIjogInJkY21hbiIsCiAgICAiY29udGVudCI6ICJSRENNYW4g6L+c56iL5qGM6Z2i566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJSRENNYW4g566h55CG5aSa5Liq6L+c56iL5qGM6Z2i6L+e5o6l77yM6YCC55So5LqO6ZyA6KaB5a6a5pyf6K6/6Zeu5q+P5Y+w5py65Zmo55qE5pyN5Yqh5Zmo5a6e6aqM5a6k44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vbGVhcm4ubWljcm9zb2Z0LmNvbS9lbi11cy9zeXNpbnRlcm5hbHMvZG93bmxvYWRzL3JkY21hbiIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5TeXNpbnRlcm5hbHMuUkRDTWFuIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsYXV0b2hvdGtleSI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImF1dG9ob3RrZXkiLAogICAgImNvbnRlbnQiOiAiQXV0b0hvdGtleSDoh6rliqjohJrmnKwiLAogICAgImRlc2NyaXB0aW9uIjogIkF1dG9Ib3RrZXkg5piv5LiA5qy+IFdpbmRvd3Mg6ISa5pys6K+t6KiA77yM5YWB6K6455So5oi35Yib5bu66Ieq5a6a5LmJ6Ieq5Yqo5YyW6ISa5pys5ZKM5a6P44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmF1dG9ob3RrZXkuY29tLyIsCiAgICAid2luZ2V0IjogIkF1dG9Ib3RrZXkuQXV0b0hvdGtleSIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYml0d2FyZGVuIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiYml0d2FyZGVuIiwKICAgICJjb250ZW50IjogIkJpdHdhcmRlbiDlr4bnoIHnrqHnkIYiLAogICAgImRlc2NyaXB0aW9uIjogIkJpdHdhcmRlbiDmmK/kuIDmrL7lvIDmupDlr4bnoIHnrqHnkIbop6PlhrPmlrnmoYjvvIzlnKjlpJrorr7lpIfpl7TlronlhajlrZjlgqjlkoznrqHnkIblr4bnoIHjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9iaXR3YXJkZW4uY29tLyIsCiAgICAid2luZ2V0IjogIkJpdHdhcmRlbi5CaXR3YXJkZW4iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGJsZW5kZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJibGVuZGVyIiwKICAgICJjb250ZW50IjogIkJsZW5kZXIgM0Qg5Zu+5b2iIiwKICAgICJkZXNjcmlwdGlvbiI6ICJCbGVuZGVyIOaYr+S4gOasvuWKn+iDveW8uuWkp+eahOW8gOa6kCAzRCDliJvkvZzlpZfku7bvvIzmj5Dkvpvlu7rmqKHjgIHpm5XliLvjgIHliqjnlLvlkozmuLLmn5Plt6XlhbfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuYmxlbmRlci5vcmcvIiwKICAgICJ3aW5nZXQiOiAiQmxlbmRlckZvdW5kYXRpb24uQmxlbmRlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYnJhdmUiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5rWP6KeI5ZmoIiwKICAgICJjaG9jbyI6ICJicmF2ZSIsCiAgICAiY29udGVudCI6ICJCcmF2ZSDmtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIkJyYXZlIOaYr+S4gOasvuazqOmHjemakOengeeahOe9kemhtea1j+iniOWZqO+8jOWPr+aLpuaIquW5v+WRiuWSjOi3n+i4quWZqO+8jOaPkOS+m+abtOW/q+abtOWuieWFqOeahOa1j+iniOS9k+mqjOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5icmF2ZS5jb20iLAogICAgIndpbmdldCI6ICJCcmF2ZS5CcmF2ZSIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYnVsa2NyYXB1bmluc3RhbGxlciI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImJ1bGstY3JhcC11bmluc3RhbGxlciIsCiAgICAiY29udGVudCI6ICJCdWxrIENyYXAgVW5pbnN0YWxsZXIg5om56YeP5Y246L29IiwKICAgICJkZXNjcmlwdGlvbiI6ICJCdWxrIENyYXAgVW5pbnN0YWxsZXIg5piv5LiA5qy+5YWN6LS55byA5rqQIFdpbmRvd3Mg5Y246L295bel5YW377yM5biu5Yqp55So5oi35om56YeP5Y246L2956iL5bqP44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmJjdW5pbnN0YWxsZXIuY29tLyIsCiAgICAid2luZ2V0IjogIktsb2NtYW4uQnVsa0NyYXBVbmluc3RhbGxlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYmx1cmF1dG9jbGlja2VyIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAibmEiLAogICAgImNvbnRlbnQiOiAiQmx1ckF1dG9DbGlja2VyIOiHquWKqOeCueWHu+WZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAi5LiA5qy+5YW35pyJ6auY57qn5Yqf6IO95LiU5oCn6IO95LyY5LqO5ZCM57G75Lqn5ZOB55qE6Ieq5Yqo54K55Ye75Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vYmx1cjAwOS52ZXJjZWwuYXBwL3Byb2plY3RzL2JsdXItYXV0b2NsaWNrZXIvIiwKICAgICJ3aW5nZXQiOiAiQmx1cjAwOS5CbHVyQXV0b0NsaWNrZXIiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGNhbGlicmUiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJjYWxpYnJlIiwKICAgICJjb250ZW50IjogIkNhbGlicmUg55S15a2Q5Lmm566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJDYWxpYnJlIOaYr+S4gOasvuWKn+iDveW8uuWkp+S4lOaYk+S6juS9v+eUqOeahOeUteWtkOS5pueuoeeQhuWZqOOAgemYheivu+WZqOWSjOi9rOaNouWZqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2NhbGlicmUtZWJvb2suY29tLyIsCiAgICAid2luZ2V0IjogImNhbGlicmUuY2FsaWJyZSIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsY2VtdSI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogImNlbXUiLAogICAgImNvbnRlbnQiOiAiQ2VtdSBXaWkgVSDmqKHmi5/lmagiLAogICAgImRlc2NyaXB0aW9uIjogIkNlbXUg5piv5LiA5qy+6auY5bqm5a6e6aqM5oCn55qEIFdpaSBVIOaooeaLn+WZqOi9r+S7tuOAgiIsCiAgICAibGluayI6ICJodHRwczovL2NlbXUuaW5mby8iLAogICAgIndpbmdldCI6ICJDZW11LkNlbXUiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGNoYXRncHQiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJuYSIsCiAgICAiY29udGVudCI6ICJDaGF0R1BUIOahjOmdoueJiCIsCiAgICAiZGVzY3JpcHRpb24iOiAiQ2hhdEdQVCDlrpjmlrkgV2luZG93cyDmoYzpnaLlupTnlKjvvIzpgJrov4cgTWljcm9zb2Z0IFN0b3JlIOWIhuWPkeOAgiIsCiAgICAibGluayI6ICJodHRwczovL2FwcHMubWljcm9zb2Z0LmNvbS9kZXRhaWwvOW50MXIxYzJoaDdqIiwKICAgICJ3aW5nZXQiOiAibXNzdG9yZTo5TlQxUjFDMkhIN0oiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxjaGF0dGVyaW5vIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAiY2hhdHRlcmlubyIsCiAgICAiY29udGVudCI6ICJDaGF0dGVyaW5vIFR3aXRjaCDogYrlpKkiLAogICAgImRlc2NyaXB0aW9uIjogIkNoYXR0ZXJpbm8g5piv5LiA5qy+IFR3aXRjaCDogYrlpKnlrqLmiLfnq6/vvIzmj5DkvpvnroDmtIHlj6/lrprliLbnmoTnlYzpnaLjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuY2hhdHRlcmluby5jb20vIiwKICAgICJ3aW5nZXQiOiAiQ2hhdHRlcmlub1RlYW0uQ2hhdHRlcmlubyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsY2hyb21lIjogewogICAgImNhdGVnb3J5IjogIua1j+iniOWZqCIsCiAgICAiY2hvY28iOiAiZ29vZ2xlY2hyb21lIiwKICAgICJjb250ZW50IjogIkNocm9tZSDmtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIkdvb2dsZSBDaHJvbWUg5piv5LiA5qy+5bm/5rOb5L2/55So55qE572R6aG15rWP6KeI5Zmo77yM5Lul6YCf5bqm44CB566A5rSB5ZKM5LiOIEdvb2dsZSDmnI3liqHpm4bmiJDogIzpl7vlkI3jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuZ29vZ2xlLmNvbS9jaHJvbWUvIiwKICAgICJ3aW5nZXQiOiAiR29vZ2xlLkNocm9tZSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGNocm9taXVtIjogewogICAgImNhdGVnb3J5IjogIua1j+iniOWZqCIsCiAgICAiY2hvY28iOiAiY2hyb21pdW0iLAogICAgImNvbnRlbnQiOiAiQ2hyb21pdW0g5rWP6KeI5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJDaHJvbWl1bSDmmK/kvZzkuLrljIXmi6wgQ2hyb21lIOWcqOWGheeahOWkmuenjea1j+iniOWZqOWfuuehgOeahOW8gOa6kOmhueebruOAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vSGliYmlraS9jaHJvbWl1bS13aW42NCIsCiAgICAid2luZ2V0IjogIkhpYmJpa2kuQ2hyb21pdW0iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGNpbmViZW5jaHIyMyI6IHsKICAgICJjYXRlZ29yeSI6ICLkuJPkuJrlt6XlhbciLAogICAgImNob2NvIjogIm5hIiwKICAgICJjb250ZW50IjogIkNpbmViZW5jaCBSMjMg5oCn6IO95rWL6K+VIiwKICAgICJkZXNjcmlwdGlvbiI6ICJDaW5lYmVuY2ggUjIzIOaYr+S4gOasvui3qOezu+e7n+avlOi+gyBDUFUg5riy5p+T5oCn6IO955qE5Z+65YeG5rWL6K+V5bel5YW344CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lm1heG9uLm5ldC9lbi9jaW5lYmVuY2giLAogICAgIndpbmdldCI6ICJNYXhvbi5DaW5lYmVuY2hSMjMiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxjbGF1ZGUiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJjbGF1ZGUiLAogICAgImNvbnRlbnQiOiAiQ2xhdWRlIOahjOmdoueJiCIsCiAgICAiZGVzY3JpcHRpb24iOiAiQW50aHJvcGljIOeahCBDbGF1ZGUg5qGM6Z2i5bqU55So56iL5bqP77yM55So5LqO5LiT5rOo55qEIEFJIOi+heWKqeW3peS9nOWSjOiBiuWkqeOAgiIsCiAgICAibGluayI6ICJodHRwczovL2NsYXVkZS5haS9kb3dubG9hZCIsCiAgICAid2luZ2V0IjogIkFudGhyb3BpYy5DbGF1ZGUiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxjbGF1ZGUtY29kZSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogImNsYXVkZS1jb2RlIiwKICAgICJjb250ZW50IjogIkNsYXVkZSBDb2RlIOe8lueoi+WKqeaJiyIsCiAgICAiZGVzY3JpcHRpb24iOiAiQW50aHJvcGljIOeahOS7o+eQhue8lueoi+W3peWFt++8jOmAgueUqOS6jue7iOerr+WSjCBJREUg5byA5Y+R5bel5L2c5rWB44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vY29kZS5jbGF1ZGUuY29tLyIsCiAgICAid2luZ2V0IjogIkFudGhyb3BpYy5DbGF1ZGVDb2RlIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsY21ha2UiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJjbWFrZSIsCiAgICAiY29udGVudCI6ICJDTWFrZSDmnoTlu7rlt6XlhbciLAogICAgImRlc2NyaXB0aW9uIjogIkNNYWtlIOaYr+S4gOasvuW8gOa6kOi3qOW5s+WPsOeahOW3peWFt+mbhu+8jOeUqOS6juaehOW7uuOAgea1i+ivleWSjOaJk+WMhei9r+S7tuOAgiIsCiAgICAibGluayI6ICJodHRwczovL2NtYWtlLm9yZy8iLAogICAgIndpbmdldCI6ICJLaXR3YXJlLkNNYWtlIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxjb2RleCI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogImNvZGV4IiwKICAgICJjb250ZW50IjogIkNvZGV4IENMSSDnvJbnqIvku6PnkIYiLAogICAgImRlc2NyaXB0aW9uIjogIkNvZGV4IENMSSDmmK8gT3BlbkFJIOeahOe8lueoi+S7o+eQhu+8jOWcqOaCqOeahOe7iOerr+S4reacrOWcsOi/kOihjOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2RldmVsb3BlcnMub3BlbmFpLmNvbS9jb2RleC9jbGkiLAogICAgIndpbmdldCI6ICJPcGVuQUkuQ29kZXgiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGNwdXoiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJjcHUteiIsCiAgICAiY29udGVudCI6ICJDUFUtWiDnoazku7bmo4DmtYsiLAogICAgImRlc2NyaXB0aW9uIjogIkNQVS1aIOaYr+S4gOasviBXaW5kb3dzIOezu+e7n+ebkeaOp+WSjOiviuaWreW3peWFt++8jOaPkOS+m+ehrOS7tue7hOS7tueahOivpue7huS/oeaBr+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5jcHVpZC5jb20vc29mdHdhcmVzL2NwdS16Lmh0bWwiLAogICAgIndpbmdldCI6ICJDUFVJRC5DUFUtWiIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGNyeXN0YWxkaXNraW5mbyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImNyeXN0YWxkaXNraW5mbyIsCiAgICAiY29udGVudCI6ICJDcnlzdGFsRGlza0luZm8g56OB55uY5qOA5rWLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJDcnlzdGFsRGlza0luZm8g5piv5LiA5qy+56OB55uY5YGl5bq355uR5o6n5bel5YW377yM5o+Q5L6b56Gs55uY54q25oCB5ZKM5oCn6IO95L+h5oGv44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vY3J5c3RhbG1hcmsuaW5mby9lbi9zb2Z0d2FyZS9jcnlzdGFsZGlza2luZm8vIiwKICAgICJ3aW5nZXQiOiAiQ3J5c3RhbERld1dvcmxkLkNyeXN0YWxEaXNrSW5mbyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsY3J5c3RhbGRpc2ttYXJrIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiY3J5c3RhbGRpc2ttYXJrIiwKICAgICJjb250ZW50IjogIkNyeXN0YWxEaXNrTWFyayDno4Hnm5jmtYvor5UiLAogICAgImRlc2NyaXB0aW9uIjogIkNyeXN0YWxEaXNrTWFyayDmmK/kuIDmrL7no4Hnm5jln7rlh4bmtYvor5Xlt6XlhbfvvIzmtYvph4/lrZjlgqjorr7lpIfnmoTor7vlhpnpgJ/luqbjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9jcnlzdGFsbWFyay5pbmZvL2VuL3NvZnR3YXJlL2NyeXN0YWxkaXNrbWFyay8iLAogICAgIndpbmdldCI6ICJDcnlzdGFsRGV3V29ybGQuQ3J5c3RhbERpc2tNYXJrIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxjdXJzb3IiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJjdXJzb3JpZGUiLAogICAgImNvbnRlbnQiOiAiQ3Vyc29yIEFJ57yW6L6R5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJBSSDpqbHliqjnmoTku6PnoIHnvJbovpHlmago5Z+65LqOIFZTIENvZGUp77yM5YW35pyJ5Luj55CG57yW56iL5Yqf6IO95ZKM6ZuG5oiQIEFJIOi+heWKqeOAgiIsCiAgICAibGluayI6ICJodHRwczovL2N1cnNvci5jb20vIiwKICAgICJ3aW5nZXQiOiAiQW55c3BoZXJlLkN1cnNvciIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGRkdSI6IHsKICAgICJjYXRlZ29yeSI6ICLkuJPkuJrlt6XlhbciLAogICAgImNob2NvIjogImRkdSIsCiAgICAiY29udGVudCI6ICJEaXNwbGF5IERyaXZlciBVbmluc3RhbGxlciDmmL7ljaHpqbHliqjljbjovb0iLAogICAgImRlc2NyaXB0aW9uIjogIkRpc3BsYXkgRHJpdmVyIFVuaW5zdGFsbGVyIChERFUpIOaYr+S4gOasvuWujOWFqOWNuOi9veaYvuWNoempseWKqOeoi+W6j+eahOW3peWFt+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy53YWduYXJkc29mdC5jb20vZGlzcGxheS1kcml2ZXItdW5pbnN0YWxsZXItRERVLSIsCiAgICAid2luZ2V0IjogIldhZ25hcmRzb2Z0LkRpc3BsYXlEcml2ZXJVbmluc3RhbGxlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZGlzY29yZCI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogImRpc2NvcmQiLAogICAgImNvbnRlbnQiOiAiRGlzY29yZCDpgJrorq/lubPlj7AiLAogICAgImRlc2NyaXB0aW9uIjogIkRpc2NvcmQg5piv5LiA5qy+5rWB6KGM55qE6YCa6K6v5bmz5Y+w77yM5o+Q5L6b6K+t6Z+z44CB6KeG6aKR5ZKM5paH5a2X6IGK5aSp44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZGlzY29yZC5jb20vIiwKICAgICJ3aW5nZXQiOiAiRGlzY29yZC5EaXNjb3JkIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsZGlzbXRvb2xzIjogewogICAgImNhdGVnb3J5IjogIuW+rui9r+W3peWFtyIsCiAgICAiY2hvY28iOiAiZGlzbXRvb2xzIiwKICAgICJjb250ZW50IjogIkRJU01Ub29scyDplZzlg4/lt6XlhbciLAogICAgImRlc2NyaXB0aW9uIjogIkRJU01Ub29scyDmmK/kuIDmrL7lv6vpgJ/lj6/lrprliLbnmoQgRElTTSDlt6XlhbcgR1VJ77yM5pSv5oyBIFdpbmRvd3MgNyDlj4rku6XkuIrniYjmnKznmoTmmKDlg4/lpITnkIbjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL0NvZGluZ1dvbmRlcnMvRElTTVRvb2xzIiwKICAgICJ3aW5nZXQiOiAiQ29kaW5nV29uZGVyc1NvZnR3YXJlLkRJU01Ub29scy5TdGFibGUiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG50bGl0ZSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvq7ova/lt6XlhbciLAogICAgImNob2NvIjogIm50bGl0ZS1mcmVlIiwKICAgICJjb250ZW50IjogIk5UTGl0ZSDns7vnu5/nsr7nroAiLAogICAgImRlc2NyaXB0aW9uIjogIumbhuaIkOabtOaWsOOAgempseWKqOeoi+W6j++8jOiHquWKqOWMliBXaW5kb3dzIOWSjOW6lOeUqOeoi+W6j+iuvue9ru+8jOWKoOmAnyBXaW5kb3dzIOmDqOe9sua1geeoi+OAgiIsCiAgICAibGluayI6ICJodHRwczovL250bGl0ZS5jb20iLAogICAgIndpbmdldCI6ICJObGl0ZXNvZnQuTlRMaXRlIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsZG9yaW9uIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAiZG9yaW9uIiwKICAgICJjb250ZW50IjogIkRvcmlvbiDovbvph49EaXNjb3JkIiwKICAgICJkZXNjcmlwdGlvbiI6ICLovbvph4/nuqcgRGlzY29yZCDmm7/ku6PlrqLmiLfnq6/vvIzljaDnlKjmm7TlsI/jgIHlkK/liqjmm7Tlv6vvvIzmlK/mjIHkuLvpopjlkozmj5Lku7bvvIEiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL1NwaWtlSEQvRG9yaW9uIiwKICAgICJ3aW5nZXQiOiAiU3Bpa2VIRC5Eb3Jpb24iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGRvdG5ldDYiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJkb3RuZXQtNi4wLXJ1bnRpbWUiLAogICAgImNvbnRlbnQiOiAiLk5FVCDmoYzpnaLov5DooYzml7YgNiIsCiAgICAiZGVzY3JpcHRpb24iOiAiLk5FVCDmoYzpnaLov5DooYzml7YgNiDmmK/ov5DooYzkvb/nlKggLk5FVCA2IOW8gOWPkeeahOW6lOeUqOeoi+W6j+aJgOmcgOeahOi/kOihjOaXtueOr+Wig+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2RvdG5ldC5taWNyb3NvZnQuY29tL2Rvd25sb2FkL2RvdG5ldC82LjAiLAogICAgIndpbmdldCI6ICJNaWNyb3NvZnQuRG90TmV0LkRlc2t0b3BSdW50aW1lLjYiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGRvdG5ldDgiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJkb3RuZXQtOC4wLXJ1bnRpbWUiLAogICAgImNvbnRlbnQiOiAiLk5FVCDmoYzpnaLov5DooYzml7YgOCIsCiAgICAiZGVzY3JpcHRpb24iOiAiLk5FVCDmoYzpnaLov5DooYzml7YgOCDmmK/ov5DooYzkvb/nlKggLk5FVCA4IOW8gOWPkeeahOW6lOeUqOeoi+W6j+aJgOmcgOeahOi/kOihjOaXtueOr+Wig+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2RvdG5ldC5taWNyb3NvZnQuY29tL2Rvd25sb2FkL2RvdG5ldC84LjAiLAogICAgIndpbmdldCI6ICJNaWNyb3NvZnQuRG90TmV0LkRlc2t0b3BSdW50aW1lLjgiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGRvdG5ldDkiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJkb3RuZXQtOS4wLXJ1bnRpbWUiLAogICAgImNvbnRlbnQiOiAiLk5FVCDmoYzpnaLov5DooYzml7YgOSIsCiAgICAiZGVzY3JpcHRpb24iOiAiLk5FVCDmoYzpnaLov5DooYzml7YgOSDmmK/ov5DooYzkvb/nlKggLk5FVCA5IOW8gOWPkeeahOW6lOeUqOeoi+W6j+aJgOmcgOeahOi/kOihjOaXtueOr+Wig+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2RvdG5ldC5taWNyb3NvZnQuY29tL2Rvd25sb2FkL2RvdG5ldC85LjAiLAogICAgIndpbmdldCI6ICJNaWNyb3NvZnQuRG90TmV0LkRlc2t0b3BSdW50aW1lLjkiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGRvdG5ldDEwIjogewogICAgImNhdGVnb3J5IjogIuW+rui9r+W3peWFtyIsCiAgICAiY2hvY28iOiAiZG90bmV0LTEwLjAtcnVudGltZSIsCiAgICAiY29udGVudCI6ICIuTkVUIOahjOmdoui/kOihjOaXtiAxMCIsCiAgICAiZGVzY3JpcHRpb24iOiAiLk5FVCDmoYzpnaLov5DooYzml7YgMTAg5piv6L+Q6KGM5L2/55SoIC5ORVQgMTAg5byA5Y+R55qE5bqU55So56iL5bqP5omA6ZyA55qE6L+Q6KGM5pe2546v5aKD44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZG90bmV0Lm1pY3Jvc29mdC5jb20vZG93bmxvYWQvZG90bmV0LzEwLjAiLAogICAgIndpbmdldCI6ICJNaWNyb3NvZnQuRG90TmV0LkRlc2t0b3BSdW50aW1lLjEwIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxkcm9wYm94IjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiZHJvcGJveCIsCiAgICAiY29udGVudCI6ICJEcm9wYm94IOS6keWtmOWCqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiRHJvcGJveCDmmK/kuIDmrL7kupHlrZjlgqjlrqLmiLfnq6/vvIznlKjkuo7lkIzmraXmlofku7bjgIHlhbHkuqvlhoXlrrnlubblnKjlpJrorr7lpIfpl7Tkv53mjIHmlofmoaPlj6/nlKjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuZHJvcGJveC5jb20vZGVza3RvcCIsCiAgICAid2luZ2V0IjogIkRyb3Bib3guRHJvcGJveCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGVhYXBwIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAiZWEtYXBwIiwKICAgICJjb250ZW50IjogIkVBIEFwcCDmuLjmiI/lubPlj7AiLAogICAgImRlc2NyaXB0aW9uIjogIkVBIEFwcCDmmK/orr/pl67lkozmuLjnjqkgRWxlY3Ryb25pYyBBcnRzIOa4uOaIj+eahOW5s+WPsOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5lYS5jb20vZWEtYXBwIiwKICAgICJ3aW5nZXQiOiAiRWxlY3Ryb25pY0FydHMuRUFEZXNrdG9wIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsZWFydHJ1bXBldCI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogImVhcnRydW1wZXQiLAogICAgImNvbnRlbnQiOiAiRWFyVHJ1bXBldCDpn7PpopHmjqfliLYiLAogICAgImRlc2NyaXB0aW9uIjogIkVhclRydW1wZXQg5piv5LiA5qy+IFdpbmRvd3Mg6Z+z6aKR5o6n5Yi25bqU55So77yM5o+Q5L6b566A5Y2V55u06KeC55qE55WM6Z2i5p2l566h55CG5aOw6Z+z6K6+572u44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZWFydHJ1bXBldC5hcHAvIiwKICAgICJ3aW5nZXQiOiAiRmlsZS1OZXctUHJvamVjdC5FYXJUcnVtcGV0IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxlZGdlIjogewogICAgImNhdGVnb3J5IjogIua1j+iniOWZqCIsCiAgICAiY2hvY28iOiAibWljcm9zb2Z0LWVkZ2UiLAogICAgImNvbnRlbnQiOiAiRWRnZSDmtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIk1pY3Jvc29mdCBFZGdlIOaYr+S4gOasvuWfuuS6jiBDaHJvbWl1bSDnmoTnjrDku6PnvZHpobXmtY/op4jlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cubWljcm9zb2Z0LmNvbS9lZGdlIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LkVkZ2UiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxlbnRlYXV0aCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImVudGUtYXV0aCIsCiAgICAiY29udGVudCI6ICJFbnRlIEF1dGgg6aqM6K+B5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJFbnRlIEF1dGgg5piv5LiA5qy+5YWN6LS544CB6Leo5bmz5Y+w44CB56uv5Yiw56uv5Yqg5a+G55qE6aqM6K+B5Zmo5bqU55So44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZW50ZS5pby9hdXRoLyIsCiAgICAid2luZ2V0IjogImVudGUtaW8uYXV0aC1kZXNrdG9wIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxlcGljZ2FtZXMiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5ri45oiPIiwKICAgICJjaG9jbyI6ICJlcGljZ2FtZXNsYXVuY2hlciIsCiAgICAiY29udGVudCI6ICJFcGljIEdhbWVzIOWQr+WKqOWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiRXBpYyBHYW1lcyBMYXVuY2hlciDmmK/orr/pl67lkozmuLjnjqkgRXBpYyBHYW1lcyDllYblupfmuLjmiI/nmoTlrqLmiLfnq6/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuZXBpY2dhbWVzLmNvbS9zdG9yZS9lbi1VUy8iLAogICAgIndpbmdldCI6ICJFcGljR2FtZXMuRXBpY0dhbWVzTGF1bmNoZXIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxmaWxlcyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImZpbGVzIiwKICAgICJjb250ZW50IjogIkZpbGVzIOaWh+S7tueuoeeQhuWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAi5pu/5Luj5oCn5paH5Lu26LWE5rqQ566h55CG5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9maWxlcy1jb21tdW5pdHkvRmlsZXMiLAogICAgIndpbmdldCI6ICJGaWxlc0NvbW11bml0eS5GaWxlcyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZmlyZWZveCI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogImZpcmVmb3giLAogICAgImNvbnRlbnQiOiAiRmlyZWZveCDmtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIk1vemlsbGEgRmlyZWZveCDmmK/kuIDmrL7lvIDmupDnvZHpobXmtY/op4jlmajvvIzku6XlhbblrprliLbpgInpobnjgIHpmpDnp4Hlip/og73lkozmianlsZXogIzpl7vlkI3jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cubW96aWxsYS5vcmcvZW4tVVMvZmlyZWZveC9uZXcvIiwKICAgICJ3aW5nZXQiOiAiTW96aWxsYS5GaXJlZm94IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxmaXJlZm94ZXNyIjogewogICAgImNhdGVnb3J5IjogIua1j+iniOWZqCIsCiAgICAiY2hvY28iOiAiRmlyZWZveEVTUiIsCiAgICAiY29udGVudCI6ICJGaXJlZm94IEVTUiDplb/mnJ/mlK/mjIHniYgiLAogICAgImRlc2NyaXB0aW9uIjogIk1vemlsbGEgRmlyZWZveCDmmK/lvIDmupDnvZHpobXmtY/op4jlmajvvIxFU1LvvIjmianlsZXmlK/mjIHniYjvvInmr48gNDIg5ZGo5pS25Yiw5LiA5qyh5Li76KaB5pu05paw44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lm1vemlsbGEub3JnL2VuLVVTL2ZpcmVmb3gvZW50ZXJwcmlzZS8iLAogICAgIndpbmdldCI6ICJNb3ppbGxhLkZpcmVmb3guRVNSIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxmbG9vcnAiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5rWP6KeI5ZmoIiwKICAgICJjaG9jbyI6ICJmbG9vcnAiLAogICAgImNvbnRlbnQiOiAiRmxvb3JwIOa1j+iniOWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiRmxvb3JwIOaYr+S4gOasvuW8gOa6kOe9kemhtea1j+iniOWZqOmhueebru+8jOaXqOWcqOaPkOS+m+eugOWNleW/q+mAn+eahOa1j+iniOS9k+mqjOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2Zsb29ycC5hcHAvIiwKICAgICJ3aW5nZXQiOiAiQWJsYXplLkZsb29ycCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZmx1eCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImZsdXgiLAogICAgImNvbnRlbnQiOiAiRi5sdXgg5oqk55y86LCD6ImyIiwKICAgICJkZXNjcmlwdGlvbiI6ICJGLmx1eCDosIPmlbTlsY/luZXoibLmuKnvvIzlh4/lsJHlpJzpl7Tkvb/nlKjml7bnmoTnnLznnZvnlrLlirPjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9qdXN0Z2V0Zmx1eC5jb20vIiwKICAgICJ3aW5nZXQiOiAiZmx1eC5mbHV4IiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsZ2Vmb3JjZW5vdyI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogIm52aWRpYS1nZWZvcmNlLW5vdyIsCiAgICAiY29udGVudCI6ICJHZUZvcmNlIE5PVyDkupHmuLjmiI8iLAogICAgImRlc2NyaXB0aW9uIjogIkdlRm9yY2UgTk9XIOaYr+S4gOasvuS6kea4uOaIj+acjeWKoe+8jOWPr+iuqeaCqOWcqOiuvuWkh+S4iueOqemrmOWTgei0qOeahCBQQyDmuLjmiI/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cubnZpZGlhLmNvbS9lbi11cy9nZWZvcmNlLW5vdy8iLAogICAgIndpbmdldCI6ICJOdmlkaWEuR2VGb3JjZU5vdyIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGdpbXAiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJnaW1wIiwKICAgICJjb250ZW50IjogIkdJTVAg5Zu+5YOP57yW6L6RIiwKICAgICJkZXNjcmlwdGlvbiI6ICJHSU1QIOaYr+S4gOasvuWkmuWKn+iDveW8gOa6kOWFieagheWbvuW9oue8lui+keWZqO+8jOeUqOS6jueFp+eJh+S/rumlsOOAgeWbvuWDj+e8lui+keWSjOWbvuWDj+WQiOaIkOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5naW1wLm9yZy8iLAogICAgIndpbmdldCI6ICJHSU1QLkdJTVAuMyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZ2l0IjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAiZ2l0IiwKICAgICJjb250ZW50IjogIkdpdCDniYjmnKzmjqfliLYiLAogICAgImRlc2NyaXB0aW9uIjogIkdpdCDmmK/kuIDmrL7liIbluIPlvI/niYjmnKzmjqfliLbns7vnu5/vvIzlub/ms5vnlKjkuo7ova/ku7blvIDlj5HkuK3ot5/ouKrmupDku6PnoIHnmoTmm7TmlLnjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXQtc2NtLmNvbS8iLAogICAgIndpbmdldCI6ICJHaXQuR2l0IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxnaXRodWJkZXNrdG9wIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAiZ2l0O2dpdGh1Yi1kZXNrdG9wIiwKICAgICJjb250ZW50IjogIkdpdEh1YiBEZXNrdG9wIOahjOmdouerryIsCiAgICAiZGVzY3JpcHRpb24iOiAiR2l0SHViIERlc2t0b3Ag5piv5LiA5qy+5Y+v6KeG5YyWIEdpdCDlrqLmiLfnq6/vvIzpgJrov4fmmJPnlKjnmoTnlYzpnaLnroDljJYgR2l0SHViIOS7k+W6k+eahOWNj+S9nOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2Rlc2t0b3AuZ2l0aHViLmNvbS8iLAogICAgIndpbmdldCI6ICJHaXRIdWIuR2l0SHViRGVza3RvcCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZ29nIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAiZ29nZ2FsYXh5IiwKICAgICJjb250ZW50IjogIkdPRyBHYWxheHkg5ri45oiP5bmz5Y+wIiwKICAgICJkZXNjcmlwdGlvbiI6ICJHT0cgR2FsYXh5IOaYr+S4gOasvua4uOaIj+WuouaIt+err++8jOaPkOS+m+aXoCBEUk0g5ri45oiP44CB6ZmE5Yqg5YaF5a65562J44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmdvZy5jb20vZ2FsYXh5IiwKICAgICJ3aW5nZXQiOiAiR09HLkdhbGF4eSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGdvbGFuZyI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogImdvbGFuZyIsCiAgICAiY29udGVudCI6ICJHbyDnvJbnqIvor63oqIAiLAogICAgImRlc2NyaXB0aW9uIjogIkdv77yI5Y+I56ewIEdvbGFuZ++8ieaYr+S4gOenjemdmeaAgeexu+Wei+OAgee8luivkeWei+e8lueoi+ivreiogOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2dvLmRldi8iLAogICAgIndpbmdldCI6ICJHb0xhbmcuR28iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGdvb2dsZWRyaXZlIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiZ29vZ2xlZHJpdmUiLAogICAgImNvbnRlbnQiOiAiR29vZ2xlIERyaXZlIOS6keebmCIsCiAgICAiZGVzY3JpcHRpb24iOiAi6Leo6K6+5aSH5paH5Lu25ZCM5q2l77yM5YWo6YOo5YWz6IGU5Yiw5oKo55qEIEdvb2dsZSDluJDmiLfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuZ29vZ2xlLmNvbS9kcml2ZS8iLAogICAgIndpbmdldCI6ICJHb29nbGUuR29vZ2xlRHJpdmUiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxncHV6IjogewogICAgImNhdGVnb3J5IjogIuS4k+S4muW3peWFtyIsCiAgICAiY2hvY28iOiAiZ3B1LXoiLAogICAgImNvbnRlbnQiOiAiR1BVLVog5pi+5Y2h5qOA5rWLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJHUFUtWiDmj5DkvpvlhbPkuo7mgqjnmoTmmL7ljaHlkowgR1BVIOeahOivpue7huS/oeaBr+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy50ZWNocG93ZXJ1cC5jb20vZ3B1ei8iLAogICAgIndpbmdldCI6ICJUZWNoUG93ZXJVcC5HUFUtWiIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGdzdWRvIjogewogICAgImNhdGVnb3J5IjogIuS4k+S4muW3peWFtyIsCiAgICAiY2hvY28iOiAiZ3N1ZG8iLAogICAgImNvbnRlbnQiOiAiZ3N1ZG8g5o+Q5p2D5bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJnc3VkbyDmmK8gV2luZG93cyDkuIvnmoQgc3VkbyDmm7/ku6Plk4HvvIzlhYHorrjlnKjlvZPliY3mjqfliLblj7Dnqpflj6PkuK3mj5DljYfmnYPpmZDov5DooYzlkb3ku6TjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL2dlcmFyZG9nL2dzdWRvIiwKICAgICJ3aW5nZXQiOiAiZ2VyYXJkb2cuZ3N1ZG8iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGhlbGl1bSI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogImhlbGl1bSIsCiAgICAiY29udGVudCI6ICJIZWxpdW0g5rWP6KeI5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICLnp4Hlr4bjgIHlv6vpgJ/jgIHor5rlrp7nmoTnvZHpobXmtY/op4jlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL2ltcHV0bmV0L2hlbGl1bS8iLAogICAgIndpbmdldCI6ICJJbXB1dE5ldC5IZWxpdW0iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGh1Z28iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJodWdvLWV4dGVuZGVkIiwKICAgICJjb250ZW50IjogIkh1Z28g572R56uZ5p6E5bu6IiwKICAgICJkZXNjcmlwdGlvbiI6ICLkuJbnlYzkuIrmnIDlv6vpgJ/nmoTnvZHnq5nmnoTlu7rmoYbmnrbjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL2dvaHVnb2lvL2h1Z28vIiwKICAgICJ3aW5nZXQiOiAiSHVnby5IdWdvLkV4dGVuZGVkIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxoYW5kYnJha2UiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJoYW5kYnJha2UiLAogICAgImNvbnRlbnQiOiAiSGFuZEJyYWtlIOinhumikei9rOaNoiIsCiAgICAiZGVzY3JpcHRpb24iOiAiSGFuZEJyYWtlIOaYr+S4gOasvuW8gOa6kOinhumikei9rOeggeWZqO+8jOWPr+WwhuWHoOS5juaJgOacieagvOW8j+eahOinhumikei9rOaNouS4uuW5v+azm+aUr+aMgeeahOe8luino+eggeWZqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2hhbmRicmFrZS5mci8iLAogICAgIndpbmdldCI6ICJIYW5kQnJha2UuSGFuZEJyYWtlIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxoZXJvaWNsYXVuY2hlciI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogImhlcm9pYy1nYW1lcy1sYXVuY2hlciIsCiAgICAiY29udGVudCI6ICJIZXJvaWMgR2FtZXMgTGF1bmNoZXIg5ri45oiP5ZCv5Yqo5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJIZXJvaWMgR2FtZXMgTGF1bmNoZXIg5pivIEVwaWMgR2FtZXMgU3RvcmUg55qE5byA5rqQ5pu/5Luj5ri45oiP5ZCv5Yqo5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vaGVyb2ljZ2FtZXNsYXVuY2hlci5jb20vIiwKICAgICJ3aW5nZXQiOiAiSGVyb2ljR2FtZXNMYXVuY2hlci5IZXJvaWNHYW1lc0xhdW5jaGVyIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxod2luZm8iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJod2luZm8iLAogICAgImNvbnRlbnQiOiAiSFdpTkZPIOehrOS7tuajgOa1iyIsCiAgICAiZGVzY3JpcHRpb24iOiAiSFdpTkZPIOaPkOS+m+WFqOmdoueahCBXaW5kb3dzIOehrOS7tuS/oeaBr+WSjOiviuaWreWKn+iDveOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5od2luZm8uY29tLyIsCiAgICAid2luZ2V0IjogIlJFQUxpWC5IV2lORk8iLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxod21vbml0b3IiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJod21vbml0b3IiLAogICAgImNvbnRlbnQiOiAiSFdNb25pdG9yIOehrOS7tuebkeaOpyIsCiAgICAiZGVzY3JpcHRpb24iOiAiSFdNb25pdG9yIOaYr+S4gOasvuehrOS7tuebkeaOp+eoi+W6j++8jOivu+WPliBQQyDns7vnu5/nmoTkuLvopoHlgaXlurfkvKDmhJ/lmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuY3B1aWQuY29tL3NvZnR3YXJlcy9od21vbml0b3IuaHRtbCIsCiAgICAid2luZ2V0IjogIkNQVUlELkhXTW9uaXRvciIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGltYWdlZ2xhc3MiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJpbWFnZWdsYXNzIiwKICAgICJjb250ZW50IjogIkltYWdlR2xhc3Mg5Zu+54mH5p+l55yL5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJJbWFnZUdsYXNzIOaYr+S4gOasvuWkmuWKn+iDveWbvueJh+afpeeci+WZqO+8jOaUr+aMgeWkmuenjeWbvueJh+agvOW8j+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2ltYWdlZ2xhc3Mub3JnLyIsCiAgICAid2luZ2V0IjogIkR1b25nRGlldVBoYXAuSW1hZ2VHbGFzcyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsaW50ZXJuZXRkb3dubG9hZG1hbmFnZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJpbnRlcm5ldC1kb3dubG9hZC1tYW5hZ2VyIiwKICAgICJjb250ZW50IjogIklETSDkuIvovb3nrqHnkIblmagiLAogICAgImRlc2NyaXB0aW9uIjogIkludGVybmV0IERvd25sb2FkIE1hbmFnZXIg5piv5LiA5qy+55So5LqO5Yqg6YCf44CB57ut5Lyg5ZKM6K6h5YiS5paH5Lu25LiL6L2955qE5LiL6L29566h55CG5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmludGVybmV0ZG93bmxvYWRtYW5hZ2VyLmNvbS8iLAogICAgIndpbmdldCI6ICJUb25lYy5JbnRlcm5ldERvd25sb2FkTWFuYWdlciIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGlyZmFudmlldyI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogImlyZmFudmlldyIsCiAgICAiY29udGVudCI6ICJJcmZhblZpZXcg5Zu+54mH5p+l55yLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJJcmZhblZpZXcg5piv5LiA5qy+6L276YeP44CB5b+r6YCf44CB5YWN6LS555qE5Zu+54mH5p+l55yL5Zmo5ZKM57yW6L6R5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vaXJmYW52aWV3LmNvbS8iLAogICAgIndpbmdldCI6ICJJcmZhblNraWxqYW4uSXJmYW5WaWV3IiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsaXRjaCI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogIml0Y2giLAogICAgImNvbnRlbnQiOiAiSXRjaC5pbyDmuLjmiI/lubPlj7AiLAogICAgImRlc2NyaXB0aW9uIjogIkl0Y2guaW8g5piv54us56uL5ri45oiP5ZKM5Yib5oSP6aG555uu55qE5pWw5a2X5YiG5Y+R5bmz5Y+w44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vaXRjaC5pby8iLAogICAgIndpbmdldCI6ICJJdGNoSW8uSXRjaCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsaXR1bmVzIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAiaXR1bmVzIiwKICAgICJjb250ZW50IjogImlUdW5lcyDlqpLkvZPnrqHnkIYiLAogICAgImRlc2NyaXB0aW9uIjogImlUdW5lcyDmmK8gQXBwbGUg5YWs5Y+45byA5Y+R55qE5aqS5L2T5pKt5pS+5Zmo44CB5aqS5L2T5bqT5ZKM5Zyo57q/5bm/5pKt5bqU55So44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmFwcGxlLmNvbS9pdHVuZXMvIiwKICAgICJ3aW5nZXQiOiAiQXBwbGUuaVR1bmVzIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsamF2YTgiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJjb3JyZXR0bzhqZGsiLAogICAgImNvbnRlbnQiOiAiQW1hem9uIENvcnJldHRvIDggKExUUykgSkRLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJBbWF6b24gQ29ycmV0dG8g5piv5LiA5qy+5YWN6LS544CB5aSa5bmz5Y+w44CB55Sf5Lqn5bCx57uq55qEIE9wZW5KREsg5Y+R6KGM54mI44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vYXdzLmFtYXpvbi5jb20vY29ycmV0dG8iLAogICAgIndpbmdldCI6ICJBbWF6b24uQ29ycmV0dG8uOC5KREsiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGphdmEyMSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogImNvcnJldHRvMjFqZGsiLAogICAgImNvbnRlbnQiOiAiQW1hem9uIENvcnJldHRvIDIxIChMVFMpIEpESyIsCiAgICAiZGVzY3JpcHRpb24iOiAiQW1hem9uIENvcnJldHRvIOaYr+S4gOasvuWFjei0ueOAgeWkmuW5s+WPsOOAgeeUn+S6p+Wwsee7queahCBPcGVuSkRLIOWPkeihjOeJiOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2F3cy5hbWF6b24uY29tL2NvcnJldHRvIiwKICAgICJ3aW5nZXQiOiAiQW1hem9uLkNvcnJldHRvLjIxLkpESyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsamF2YTI1IjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAiY29ycmV0dG8yNWpkayIsCiAgICAiY29udGVudCI6ICJBbWF6b24gQ29ycmV0dG8gMjUgKExUUykgSkRLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJBbWF6b24gQ29ycmV0dG8g5piv5LiA5qy+5YWN6LS544CB5aSa5bmz5Y+w44CB55Sf5Lqn5bCx57uq55qEIE9wZW5KREsg5Y+R6KGM54mI44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vYXdzLmFtYXpvbi5jb20vY29ycmV0dG8iLAogICAgIndpbmdldCI6ICJBbWF6b24uQ29ycmV0dG8uMjUuSkRLIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxqZWxseWZpbm1lZGlhcGxheWVyIjogewogICAgImNhdGVnb3J5IjogIuiHquaJmOeuoeW3peWFtyIsCiAgICAiY2hvY28iOiAiamVsbHlmaW4tbWVkaWEtcGxheWVyIiwKICAgICJjb250ZW50IjogIkplbGx5ZmluIOWqkuS9k+aSreaUvuWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiSmVsbHlmaW4gTWVkaWEgUGxheWVyIOaYryBKZWxseWZpbiDlqpLkvZPmnI3liqHlmajnmoTlrqLmiLfnq6/lupTnlKjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL2plbGx5ZmluL2plbGx5ZmluLW1lZGlhLXBsYXllciIsCiAgICAid2luZ2V0IjogIkplbGx5ZmluLkplbGx5ZmluTWVkaWFQbGF5ZXIiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGplbGx5Zmluc2VydmVyIjogewogICAgImNhdGVnb3J5IjogIuiHquaJmOeuoeW3peWFtyIsCiAgICAiY2hvY28iOiAiamVsbHlmaW4iLAogICAgImNvbnRlbnQiOiAiSmVsbHlmaW4g5pyN5Yqh5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJKZWxseWZpbiBTZXJ2ZXIg5piv5LiA5qy+5byA5rqQ5aqS5L2T5pyN5Yqh5Zmo6L2v5Lu277yM6K6p5oKo5pW055CG5ZKM5rWB5byP5Lyg6L6T5oKo55qE5aqS5L2T5bqT44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vamVsbHlmaW4ub3JnLyIsCiAgICAid2luZ2V0IjogIkplbGx5ZmluLlNlcnZlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsamV0YnJhaW5zIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAiamV0YnJhaW5zdG9vbGJveCIsCiAgICAiY29udGVudCI6ICJKZXRCcmFpbnMgVG9vbGJveCDlt6Xlhbfpm4YiLAogICAgImRlc2NyaXB0aW9uIjogIkpldEJyYWlucyBUb29sYm94IOaYr+eUqOS6jui9u+advuWuieijheWSjOeuoeeQhiBKZXRCcmFpbnMg5byA5Y+R6ICF5bel5YW355qE5bmz5Y+w44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmpldGJyYWlucy5jb20vdG9vbGJveC8iLAogICAgIndpbmdldCI6ICJKZXRCcmFpbnMuVG9vbGJveCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbGpwZWd2aWV3IjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAianBlZ3ZpZXciLAogICAgImNvbnRlbnQiOiAiSlBFR1ZpZXcg5Zu+54mH5p+l55yLIiwKICAgICJkZXNjcmlwdGlvbiI6ICJKUEVHVmlldyDmmK/kuIDmrL7nsr7nroDjgIHlv6vpgJ/kuJTpq5jluqblj6/phY3nva7nmoTlm77niYfmn6XnnIsv57yW6L6R5Zmo77yM5pSv5oyB5aSa56eN5Zu+54mH5qC85byP44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9zeWxpa2MvanBlZ3ZpZXciLAogICAgIndpbmdldCI6ICJzeWxpa2MuSlBFR1ZpZXciLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGtlZXBhc3N4YyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogImtlZXBhc3N4YyIsCiAgICAiY29udGVudCI6ICJLZWVQYXNzWEMg5a+G56CB566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJLZWVQYXNzWEMg5piv5LiA5qy+546w5Luj44CB5a6J5YWo44CB5byA5rqQ55qE5a+G56CB566h55CG5ZmoIiwKICAgICJsaW5rIjogImh0dHBzOi8va2VlcGFzc3hjLm9yZy8iLAogICAgIndpbmdldCI6ICJLZWVQYXNzWENUZWFtLktlZVBhc3NYQyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsa2xpdGUiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJrLWxpdGVjb2RlY3BhY2stc3RhbmRhcmQiLAogICAgImNvbnRlbnQiOiAiSy1MaXRlIOino+eggeWMheagh+WHhueJiCIsCiAgICAiZGVzY3JpcHRpb24iOiAiSy1MaXRlIENvZGVjIFBhY2sg5qCH5YeG54mI5piv6Z+z6aKR5ZKM6KeG6aKR57yW6Kej56CB5Zmo5Y+K55u45YWz5bel5YW355qE6ZuG5ZCI44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmNvZGVjZ3VpZGUuY29tLyIsCiAgICAid2luZ2V0IjogIkNvZGVjR3VpZGUuSy1MaXRlQ29kZWNQYWNrLlN0YW5kYXJkIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsa29kaSI6IHsKICAgICJjYXRlZ29yeSI6ICLoh6rmiZjnrqHlt6XlhbciLAogICAgImNob2NvIjogImtvZGkiLAogICAgImNvbnRlbnQiOiAiS29kaSDlqpLkvZPkuK3lv4MiLAogICAgImRlc2NyaXB0aW9uIjogIktvZGkg5piv5LiA5qy+5byA5rqQ5aqS5L2T5Lit5b+D5bqU55So77yM5Y+v5pKt5pS+5ZKM5p+l55yL5aSn5aSa5pWw6KeG6aKR44CB6Z+z5LmQ44CB5pKt5a6i5ZKM5YW25LuW5pWw5a2X5aqS5L2T5paH5Lu244CCIiwKICAgICJsaW5rIjogImh0dHBzOi8va29kaS50di8iLAogICAgIndpbmdldCI6ICJYQk1DRm91bmRhdGlvbi5Lb2RpIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxsYXp5Z2l0IjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAibGF6eWdpdCIsCiAgICAiY29udGVudCI6ICJMYXp5Z2l0IEdpdOe7iOerr1VJIiwKICAgICJkZXNjcmlwdGlvbiI6ICLpgILnlKjkuo4gR2l0IOWRveS7pOeahOeugOa0gee7iOerr+eVjOmdouOAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vamVzc2VkdWZmaWVsZC9sYXp5Z2l0LyIsCiAgICAid2luZ2V0IjogIkplc3NlRHVmZmllbGQubGF6eWdpdCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbGlicmVvZmZpY2UiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJsaWJyZW9mZmljZS1mcmVzaCIsCiAgICAiY29udGVudCI6ICJMaWJyZU9mZmljZSDlip7lhazlpZfku7YiLAogICAgImRlc2NyaXB0aW9uIjogIkxpYnJlT2ZmaWNlIOaYr+S4gOasvuWKn+iDveW8uuWkp+S4lOWFjei0ueeahOWKnuWFrOWll+S7tu+8jOS4juWFtuS7luS4u+imgeWKnuWFrOWll+S7tuWFvOWuueOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5saWJyZW9mZmljZS5vcmcvIiwKICAgICJ3aW5nZXQiOiAiVGhlRG9jdW1lbnRGb3VuZGF0aW9uLkxpYnJlT2ZmaWNlIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxsaWJyZXdvbGYiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5rWP6KeI5ZmoIiwKICAgICJjaG9jbyI6ICJsaWJyZXdvbGYiLAogICAgImNvbnRlbnQiOiAiTGlicmVXb2xmIOmakOengea1j+iniOWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiTGlicmVXb2xmIOaYr+S4gOasvuWfuuS6jiBGaXJlZm94IOazqOmHjemakOengeeahOe9kemhtea1j+iniOWZqO+8jOWFt+aciemineWklueahOmakOengeWSjOWuieWFqOWinuW8uuWKn+iDveOAgiIsCiAgICAibGluayI6ICJodHRwczovL2xpYnJld29sZi1jb21tdW5pdHkuZ2l0bGFiLmlvLyIsCiAgICAid2luZ2V0IjogIkxpYnJlV29sZi5MaWJyZVdvbGYiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbGxvY2Fsc2VuZCI6IHsKICAgICJjYXRlZ29yeSI6ICLoh6rmiZjnrqHlt6XlhbciLAogICAgImNob2NvIjogImxvY2Fsc2VuZC5pbnN0YWxsIiwKICAgICJjb250ZW50IjogIkxvY2FsU2VuZCDmlofku7bkvKDovpMiLAogICAgImRlc2NyaXB0aW9uIjogIuS4gOasvuW8gOa6kOeahOi3qOW5s+WPsCBBaXJEcm9wIOabv+S7o+WTgeOAgiIsCiAgICAibGluayI6ICJodHRwczovL2xvY2Fsc2VuZC5vcmcvIiwKICAgICJ3aW5nZXQiOiAiTG9jYWxTZW5kLkxvY2FsU2VuZCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbXBjLXF0IjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAibWVkaWFpbmZvIiwKICAgICJjb250ZW50IjogIm1wYy1xdCDlqpLkvZPmkq3mlL7lmagiLAogICAgImRlc2NyaXB0aW9uIjogIk1lZGlhIFBsYXllciBDbGFzc2ljIFF1dGUgVGhlYXRlciDlqpLkvZPmkq3mlL7lmagiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL21wYy1xdC9tcGMtcXQiLAogICAgIndpbmdldCI6ICJtcGMtcXQubXBjLXF0IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxtYXRyaXgiOiB7CiAgICAiY2F0ZWdvcnkiOiAi6YCa6K6v5bel5YW3IiwKICAgICJjaG9jbyI6ICJlbGVtZW50LWRlc2t0b3AiLAogICAgImNvbnRlbnQiOiAiRWxlbWVudCDljbPml7bpgJrorq8iLAogICAgImRlc2NyaXB0aW9uIjogIkVsZW1lbnQg5pivIE1hdHJpeCDnmoTlrqLmiLfnq6/vvIxNYXRyaXgg5piv5LiA5Liq5a6J5YWo44CB5Y675Lit5b+D5YyW6YCa6K6v55qE5byA5pS+572R57uc44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZWxlbWVudC5pby8iLAogICAgIndpbmdldCI6ICJFbGVtZW50LkVsZW1lbnQiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG1pbml0b29scGFydGl0aW9ud2l6YXJkIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAibWluaXRvb2xwYXJ0aXRpb253aXphcmQiLAogICAgImNvbnRlbnQiOiAiTWluaVRvb2wg5YiG5Yy65bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICLlhajpnaLnmoTlhY3otLnliIbljLrnrqHnkIblmajvvIzlj6/miafooYwgV2luZG93cyDmnKzouqvml6Dms5XlrozmiJDnmoTpq5jnuqfmk43kvZzjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cucGFydGl0aW9ud2l6YXJkLmNvbS8iLAogICAgIndpbmdldCI6ICJNaW5pVG9vbC5QYXJ0aXRpb25XaXphcmQuRnJlZSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbG1vZHJpbnRoIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAibW9kcmludGgtYXBwIiwKICAgICJjb250ZW50IjogIk1vZHJpbnRoIE1pbmVjcmFmdCDmqKHnu4TnrqHnkIYiLAogICAgImRlc2NyaXB0aW9uIjogIk1vZHJpbnRoIEFwcCDmmK/nlKjkuo7nrqHnkIYgTWluZWNyYWZ0IOaooee7hOWSjOaVtOWQiOWMheeahOahjOmdouW6lOeUqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL21vZHJpbnRoLmNvbS9hcHAiLAogICAgIndpbmdldCI6ICJNb2RyaW50aC5Nb2RyaW50aEFwcCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbW9vbmxpZ2h0IjogewogICAgImNhdGVnb3J5IjogIuiHquaJmOeuoeW3peWFtyIsCiAgICAiY2hvY28iOiAibW9vbmxpZ2h0LXF0IiwKICAgICJjb250ZW50IjogIk1vb25saWdodCDmuLjmiI/kuLLmtYEiLAogICAgImRlc2NyaXB0aW9uIjogIk1vb25saWdodC9HYW1lU3RyZWFtIOWuouaIt+err+WFgeiuuOaCqOmAmui/h+acrOWcsOe9kee7nOWwhiBQQyDmuLjmiI/kuLLmtYHliLDlhbbku5borr7lpIfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9tb29ubGlnaHQtc3RyZWFtLm9yZy8iLAogICAgIndpbmdldCI6ICJNb29ubGlnaHRHYW1lU3RyZWFtaW5nUHJvamVjdC5Nb29ubGlnaHQiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG1wY2hjIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAibXBjLWhjLWNsc2lkMiIsCiAgICAiY29udGVudCI6ICJNUEMtSEMg5aqS5L2T5pKt5pS+5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJNZWRpYSBQbGF5ZXIgQ2xhc3NpYyAtIEhvbWUgQ2luZW1hIChNUEMtSEMpIOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOinhumikeaSreaUvuWZqCIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vY2xzaWQyL21wYy1oYy8iLAogICAgIndpbmdldCI6ICJjbHNpZDIubXBjLWhjIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxtc2VkZ2VyZWRpcmVjdCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIm1zZWRnZXJlZGlyZWN0IiwKICAgICJjb250ZW50IjogIk1TRWRnZVJlZGlyZWN0IOmHjeWumuWQkeW3peWFtyIsCiAgICAiZGVzY3JpcHRpb24iOiAi5bCG5paw6Ze744CB5pCc57Si44CB5bCP5bel5YW344CB5aSp5rCU562J6YeN5a6a5ZCR5Yiw6buY6K6k5rWP6KeI5Zmo55qE5bel5YW344CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9yY21hZWhsL01TRWRnZVJlZGlyZWN0IiwKICAgICJ3aW5nZXQiOiAicmNtYWVobC5NU0VkZ2VSZWRpcmVjdCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbXNpYWZ0ZXJidXJuZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJtc2lhZnRlcmJ1cm5lciIsCiAgICAiY29udGVudCI6ICJNU0kgQWZ0ZXJidXJuZXIg6LaF6aKR5bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJNU0kgQWZ0ZXJidXJuZXIg5piv5LiA5qy+5pi+5Y2h6LaF6aKR5bel5YW377yM5YW35pyJ6auY57qn5Yqf6IO944CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lm1zaS5jb20vTGFuZGluZy9hZnRlcmJ1cm5lciIsCiAgICAid2luZ2V0IjogIkd1cnUzRC5BZnRlcmJ1cm5lciIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbG11bGx2YWR2cG4iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJtdWxsdmFkLWFwcCIsCiAgICAiY29udGVudCI6ICJNdWxsdmFkIFZQTiIsCiAgICAiZGVzY3JpcHRpb24iOiAi6L+Z5pivIE11bGx2YWQgVlBOIOacjeWKoeeahCBWUE4g5a6i5oi356uv6L2v5Lu244CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9tdWxsdmFkL211bGx2YWR2cG4tYXBwIiwKICAgICJ3aW5nZXQiOiAiTXVsbHZhZFZQTi5NdWxsdmFkVlBOIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxtdWxsdmFkYnJvd3NlciI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogIm5hIiwKICAgICJjb250ZW50IjogIk11bGx2YWQg6ZqQ56eB5rWP6KeI5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJNdWxsdmFkIEJyb3dzZXIg5piv5LiA5qy+5rOo6YeN6ZqQ56eB55qE572R6aG15rWP6KeI5Zmo77yM5LiOIFRvciDpobnnm67lkIjkvZzlvIDlj5HjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9tdWxsdmFkLm5ldC9icm93c2VyIiwKICAgICJ3aW5nZXQiOiAiTXVsbHZhZFZQTi5NdWxsdmFkQnJvd3NlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbm9tYWNzIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAibm9tYWNzIiwKICAgICJjb250ZW50IjogIm5vbWFjcyDlm77niYfmn6XnnIvlmagiLAogICAgImRlc2NyaXB0aW9uIjogIm5vbWFjcyDmmK/kuIDmrL7lhY3otLnlvIDmupDlpJrlubPlj7Dlm77niYfmn6XnnIvlmajvvIzmlK/mjIHmiYDmnInluLjop4Hlm77niYfmoLzlvI/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9ub21hY3Mub3JnLyIsCiAgICAid2luZ2V0IjogIm5vbWFjcy5ub21hY3MiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG5hbmF6aXAiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJuYW5hemlwIiwKICAgICJjb250ZW50IjogIk5hbmFaaXAg5Y6L57yp5bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJOYW5hWmlwIOaYr+S4gOasvuW/q+mAn+mrmOaViOeahOaWh+S7tuWOi+e8qeWSjOino+WOi+e8qeW3peWFt+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vTTJUZWFtL05hbmFaaXAiLAogICAgIndpbmdldCI6ICJNMlRlYW0uTmFuYVppcCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbmV0YmlyZCI6IHsKICAgICJjYXRlZ29yeSI6ICLoh6rmiZjnrqHlt6XlhbciLAogICAgImNob2NvIjogIm5ldGJpcmQiLAogICAgImNvbnRlbnQiOiAiTmV0QmlyZCDnvZHnu5zlt6XlhbciLAogICAgImRlc2NyaXB0aW9uIjogIk5ldEJpcmQg5piv5LiOIFRhaWxTY2FsZSDnm7jlvZPnmoTlvIDmupDmm7/ku6Plk4HvvIzlj6/ov57mjqXliLDoh6rmiZjnrqHmnI3liqHlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9uZXRiaXJkLmlvLyIsCiAgICAid2luZ2V0IjogIk5ldGJpcmQuTmV0YmlyZCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbmFwczIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJuYXBzMiIsCiAgICAiY29udGVudCI6ICJOQVBTMiDmlofmoaPmiavmj48iLAogICAgImRlc2NyaXB0aW9uIjogIk5BUFMyIOaYr+S4gOasvueugOWMluWIm+W7uueUteWtkOaWh+aho+a1geeoi+eahOaWh+aho+aJq+aPj+W6lOeUqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5uYXBzMi5jb20vIiwKICAgICJ3aW5nZXQiOiAiQ3lhbmZpc2guTkFQUzIiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG5lb3ZpbSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogIm5lb3ZpbSIsCiAgICAiY29udGVudCI6ICJOZW92aW0g5paH5pys57yW6L6R5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJOZW92aW0g5piv5LiA5qy+6auY5bqm5Y+v5omp5bGV55qE5paH5pys57yW6L6R5Zmo77yM5piv5a+55Y6f5aeLIFZpbSDnvJbovpHlmajnmoTmlLnov5vjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9uZW92aW0uaW8vIiwKICAgICJ3aW5nZXQiOiAiTmVvdmltLk5lb3ZpbSIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbmV4dGNsb3VkZGVza3RvcCI6IHsKICAgICJjYXRlZ29yeSI6ICLoh6rmiZjnrqHlt6XlhbciLAogICAgImNob2NvIjogIm5leHRjbG91ZC1jbGllbnQiLAogICAgImNvbnRlbnQiOiAiTmV4dGNsb3VkIOahjOmdouWuouaIt+erryIsCiAgICAiZGVzY3JpcHRpb24iOiAiTmV4dGNsb3VkIERlc2t0b3Ag5pivIE5leHRjbG91ZCDmlofku7blkIzmraXlkozlhbHkuqvlubPlj7DnmoTlrpjmlrnmoYzpnaLlrqLmiLfnq6/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9uZXh0Y2xvdWQuY29tL2luc3RhbGwvI2luc3RhbGwtY2xpZW50cyIsCiAgICAid2luZ2V0IjogIk5leHRjbG91ZC5OZXh0Y2xvdWREZXNrdG9wIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxubWFwIjogewogICAgImNhdGVnb3J5IjogIuS4k+S4muW3peWFtyIsCiAgICAiY2hvY28iOiAibm1hcCIsCiAgICAiY29udGVudCI6ICJObWFwIOe9kee7nOaJq+aPjyIsCiAgICAiZGVzY3JpcHRpb24iOiAiTm1hcCAoTmV0d29yayBNYXBwZXIpIGlzIGFuIG9wZW4tc291cmNlIHRvb2wgZm9yIG5ldHdvcmsgZXhwbG9yYXRpb24gYW5kIHNlY3VyaXR5IGF1ZGl0aW5nLiBJdCBkaXNjb3ZlcnMgZGV2aWNlcyBvbiBhIG5ldHdvcmsgYW5kIHByb3ZpZGVzIGluZm9ybWF0aW9uIGFib3V0IHRoZWlyIHBvcnRzIGFuZCBzZXJ2aWNlcy4iLAogICAgImxpbmsiOiAiaHR0cHM6Ly9ubWFwLm9yZy8iLAogICAgIndpbmdldCI6ICJJbnNlY3VyZS5ObWFwIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxub2RlanMiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJub2RlanMiLAogICAgImNvbnRlbnQiOiAiTm9kZS5qcyIsCiAgICAiZGVzY3JpcHRpb24iOiAiTm9kZS5qcyDmmK/ln7rkuo4gQ2hyb21lIFY4IOW8leaTjueahCBKYXZhU2NyaXB0IOi/kOihjOaXtuOAgiIsCiAgICAibGluayI6ICJodHRwczovL25vZGVqcy5vcmcvIiwKICAgICJ3aW5nZXQiOiAiT3BlbkpTLk5vZGVKUyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbm9kZWpzbHRzIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAibm9kZWpzLWx0cyIsCiAgICAiY29udGVudCI6ICJOb2RlLmpzIExUUyDplb/mnJ/mlK/mjIHniYgiLAogICAgImRlc2NyaXB0aW9uIjogIk5vZGUuanMgTFRTIOaPkOS+m+mVv+acn+aUr+aMgeeJiOacrO+8jOeUqOS6jueos+WumuWPr+mdoOeahOacjeWKoeWZqOerryBKYXZhU2NyaXB0IOW8gOWPkeOAgiIsCiAgICAibGluayI6ICJodHRwczovL25vZGVqcy5vcmcvIiwKICAgICJ3aW5nZXQiOiAiT3BlbkpTLk5vZGVKUy5MVFMiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHBucG0iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjb250ZW50IjogInBucG0g5YyF566h55CG5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJwbnBtIOaYr+S4gOasvuW/q+mAn+S4lOiKguecgeejgeebmOepuumXtOeahCBKYXZhU2NyaXB0IOWSjCBOb2RlLmpzIOWMheeuoeeQhuWZqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3BucG0uaW8vIiwKICAgICJ3aW5nZXQiOiAicG5wbS5wbnBtIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxub3RlcGFkcGx1cyI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogIm5vdGVwYWRwbHVzcGx1cyIsCiAgICAiY29udGVudCI6ICJOb3RlcGFkKysg5paH5pys57yW6L6R5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJOb3RlcGFkKysg5piv5LiA5qy+5YWN6LS55byA5rqQ5Luj56CB57yW6L6R5Zmo77yM5piv6K6w5LqL5pys55qE5pu/5Luj5ZOB77yM5pSv5oyB5aSa56eN6K+t6KiA44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vbm90ZXBhZC1wbHVzLXBsdXMub3JnLyIsCiAgICAid2luZ2V0IjogIk5vdGVwYWQrKy5Ob3RlcGFkKysiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG51Z2V0IjogewogICAgImNhdGVnb3J5IjogIuW+rui9r+W3peWFtyIsCiAgICAiY2hvY28iOiAibnVnZXQuY29tbWFuZGxpbmUiLAogICAgImNvbnRlbnQiOiAiTnVHZXQg5YyF566h55CG5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJOdUdldCDmmK8gLk5FVCDmoYbmnrbnmoTljIXnrqHnkIblmajvvIzkvb/lvIDlj5HkurrlkZjog73lpJ/nrqHnkIblkozlhbHkuqsgLk5FVCDlupTnlKjkuK3nmoTlupPjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cubnVnZXQub3JnLyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5OdUdldCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbnZjbGVhbiI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIm5hIiwKICAgICJjb250ZW50IjogIk5WQ2xlYW5zdGFsbCDmmL7ljaHpqbHliqjlrprliLYiLAogICAgImRlc2NyaXB0aW9uIjogIk5WQ2xlYW5zdGFsbCDmmK/kuIDmrL7lrprliLYgTlZJRElBIOmpseWKqOWuieijheeahOW3peWFt+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy50ZWNocG93ZXJ1cC5jb20vbnZjbGVhbnN0YWxsLyIsCiAgICAid2luZ2V0IjogIlRlY2hQb3dlclVwLk5WQ2xlYW5zdGFsbCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbG9icyI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogIm9icy1zdHVkaW8iLAogICAgImNvbnRlbnQiOiAiT0JTIFN0dWRpbyDnm7Tmkq3lvZXlsY8iLAogICAgImRlc2NyaXB0aW9uIjogIk9CUyBTdHVkaW8g5piv5LiA5qy+5YWN6LS55byA5rqQ55qE6KeG6aKR5b2V5Yi25ZKM55u05pKt5o6o5rWB6L2v5Lu2IiwKICAgICJsaW5rIjogImh0dHBzOi8vb2JzcHJvamVjdC5jb20vIiwKICAgICJ3aW5nZXQiOiAiT0JTUHJvamVjdC5PQlNTdHVkaW8iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbG9ic2lkaWFuIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAib2JzaWRpYW4iLAogICAgImNvbnRlbnQiOiAiT2JzaWRpYW4g55+l6K+G566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJPYnNpZGlhbiDmmK/kuIDmrL7lip/og73lvLrlpKfnmoTnrJTorrDlkoznn6Xor4bnrqHnkIblupTnlKjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9vYnNpZGlhbi5tZC8iLAogICAgIndpbmdldCI6ICJPYnNpZGlhbi5PYnNpZGlhbiIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbG9uZWRyaXZlIjogewogICAgImNhdGVnb3J5IjogIuW+rui9r+W3peWFtyIsCiAgICAiY2hvY28iOiAib25lZHJpdmUiLAogICAgImNvbnRlbnQiOiAiT25lRHJpdmUg5LqR5a2Y5YKoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJPbmVEcml2ZSDmmK8gTWljcm9zb2Z0IOaPkOS+m+eahOS6keWtmOWCqOacjeWKoe+8jOWFgeiuuOeUqOaIt+WuieWFqOWcsOi3qOiuvuWkh+WtmOWCqOWSjOWFseS6q+aWh+S7tuOAgiIsCiAgICAibGluayI6ICJodHRwczovL29uZWRyaXZlLmxpdmUuY29tLyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5PbmVEcml2ZSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbG9ubHlvZmZpY2UiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJvbmx5b2ZmaWNlIiwKICAgICJjb250ZW50IjogIk9OTFlPRkZJQ0Ug5qGM6Z2i5Yqe5YWsIiwKICAgICJkZXNjcmlwdGlvbiI6ICJPTkxZT0ZGSUNFIERlc2t0b3Ag5piv5LiA5qy+5YWo6Z2i55qE5Yqe5YWs5aWX5Lu277yM55So5LqO5paH5qGj57yW6L6R5ZKM5Y2P5L2c44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lm9ubHlvZmZpY2UuY29tL2Rlc2t0b3AuYXNweCIsCiAgICAid2luZ2V0IjogIk9OTFlPRkZJQ0UuRGVza3RvcEVkaXRvcnMiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbE9QQXV0b0NsaWNrZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJhdXRvY2xpY2tlciIsCiAgICAiY29udGVudCI6ICJPUEF1dG9DbGlja2VyIOiHquWKqOeCueWHuyIsCiAgICAiZGVzY3JpcHRpb24iOiAi5Yqf6IO96b2Q5YWo55qE6Ieq5Yqo54K55Ye75Zmo77yM5pSv5oyB5Yqo5oCB5YWJ5qCH5L2N572u5oiW6aKE6K6+5L2N572u5Lik56eN6Ieq5Yqo54K55Ye75qih5byP44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lm9wYXV0b2NsaWNrZXIuY29tIiwKICAgICJ3aW5nZXQiOiAiT1BBdXRvQ2xpY2tlci5PUEF1dG9DbGlja2VyIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsb3BlbnJnYiI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIm9wZW5yZ2IiLAogICAgImNvbnRlbnQiOiAiT3BlblJHQiBSR0Lnga/lhYnmjqfliLYiLAogICAgImRlc2NyaXB0aW9uIjogIk9wZW5SR0Ig5piv5LiA5qy+5byA5rqQIFJHQiDnga/lhYnmjqfliLbova/ku7bjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9vcGVucmdiLm9yZy8iLAogICAgIndpbmdldCI6ICJPcGVuUkdCLk9wZW5SR0IiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbE9wZW5WUE4iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJvcGVudnBuLWNvbm5lY3QiLAogICAgImNvbnRlbnQiOiAiT3BlblZQTiBDb25uZWN0IOWuouaIt+erryIsCiAgICAiZGVzY3JpcHRpb24iOiAiT3BlblZQTiBDb25uZWN0IOaYr+S4gOasviBWUE4g5a6i5oi356uv77yM5Y+v6K6p5L2g5a6J5YWo6L+e5o6l5YiwIFZQTiDmnI3liqHlmagiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9vcGVudnBuLm5ldC8iLAogICAgIndpbmdldCI6ICJPcGVuVlBOVGVjaG5vbG9naWVzLk9wZW5WUE5Db25uZWN0IiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsT1ZpcnR1YWxCb3giOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJ2aXJ0dWFsYm94IiwKICAgICJjb250ZW50IjogIk9yYWNsZSBWaXJ0dWFsQm94IOiZmuaLn+acuiIsCiAgICAiZGVzY3JpcHRpb24iOiAiT3JhY2xlIFZpcnR1YWxCb3gg5piv5LiA5qy+5Yqf6IO95by65aSn5LiU5YWN6LS55byA5rqQ55qE6Jma5ouf5YyW5bel5YW344CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LnZpcnR1YWxib3gub3JnLyIsCiAgICAid2luZ2V0IjogIk9yYWNsZS5WaXJ0dWFsQm94IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxwb2xpY3lwbHVzIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAibmEiLAogICAgImNvbnRlbnQiOiAiUG9saWN5IFBsdXMg57uE562W55Wl57yW6L6RIiwKICAgICJkZXNjcmlwdGlvbiI6ICLmnKzlnLDnu4TnrZbnlaXnvJbovpHlmajlop7lvLrniYjvvIzpgILnlKjkuo7miYDmnIkgV2luZG93cyDniYjmnKzjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL0ZsZWV4MjU1L1BvbGljeVBsdXMiLAogICAgIndpbmdldCI6ICJGbGVleDI1NS5Qb2xpY3lQbHVzIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxwcm9jZXNzZXhwbG9yZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJwcm9jZXhwIiwKICAgICJjb250ZW50IjogIlByb2Nlc3MgRXhwbG9yZXIg6L+b56iL566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQcm9jZXNzIEV4cGxvcmVyIOaYr+S7u+WKoeeuoeeQhuWZqOWSjOezu+e7n+ebkeinhuWZqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2xlYXJuLm1pY3Jvc29mdC5jb20vc3lzaW50ZXJuYWxzL2Rvd25sb2Fkcy9wcm9jZXNzLWV4cGxvcmVyIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LlN5c2ludGVybmFscy5Qcm9jZXNzRXhwbG9yZXIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxQYWludGRvdG5ldCI6IHsKICAgICJjYXRlZ29yeSI6ICLlpJrlqpLkvZPlt6XlhbciLAogICAgImNob2NvIjogInBhaW50Lm5ldCIsCiAgICAiY29udGVudCI6ICJQYWludC5ORVQg5Zu+5YOP57yW6L6RIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQYWludC5ORVQg5piv5LiA5qy+5YWN6LS555qEIFdpbmRvd3Mg5Zu+5YOP54Wn54mH57yW6L6R6L2v5Lu2IiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmdldHBhaW50Lm5ldC8iLAogICAgIndpbmdldCI6ICJkb3RQRE4uUGFpbnREb3ROZXQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxwYXJzZWMiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJwYXJzZWMiLAogICAgImNvbnRlbnQiOiAiUGFyc2VjIOi/nOeoi+ahjOmdoiIsCiAgICAiZGVzY3JpcHRpb24iOiAiUGFyc2VjIOaYr+S4gOasvuS9juW7tui/n+OAgemrmOi0qOmHj+eahOi/nOeoi+ahjOmdouWFseS6q+W6lOeUqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3BhcnNlYy5hcHAvIiwKICAgICJ3aW5nZXQiOiAiUGFyc2VjLlBhcnNlYyIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHBlYXppcCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInBlYXppcCIsCiAgICAiY29udGVudCI6ICJQZWFaaXAg5Y6L57yp5bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJQZWFaaXAg5piv5LiA5qy+5YWN6LS55byA5rqQ5paH5Lu25Y6L57yp5bel5YW377yM5pSv5oyB5aSa56eN5Y6L57yp5qC85byP5bm25o+Q5L6b5Yqg5a+G5Yqf6IO944CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vcGVhemlwLmdpdGh1Yi5pby8iLAogICAgIndpbmdldCI6ICJHaW9yZ2lvdGFuaS5QZWF6aXAiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHBsYXluaXRlIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAicGxheW5pdGUiLAogICAgImNvbnRlbnQiOiAiUGxheW5pdGUg5ri45oiP5bqT566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQbGF5bml0ZSDmmK/kuIDmrL7lvIDmupDmuLjmiI/lupPnrqHnkIblmajvvIznm67moIfmmK/kuLrmgqjnmoTmiYDmnInmuLjmiI/mj5Dkvpvnu5/kuIDnlYzpnaLjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9wbGF5bml0ZS5saW5rLyIsCiAgICAid2luZ2V0IjogIlBsYXluaXRlLlBsYXluaXRlIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxwbGV4IjogewogICAgImNhdGVnb3J5IjogIuiHquaJmOeuoeW3peWFtyIsCiAgICAiY2hvY28iOiAicGxleG1lZGlhc2VydmVyIiwKICAgICJjb250ZW50IjogIlBsZXgg5aqS5L2T5pyN5Yqh5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQbGV4IE1lZGlhIFNlcnZlciDmmK/kuIDmrL7lqpLkvZPmnI3liqHlmajova/ku7bvvIzlj6/orqnkvaDnrqHnkIblkozmtYHlvI/kvKDovpPlqpLkvZPmlofku7YiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cucGxleC50di95b3VyLW1lZGlhLyIsCiAgICAid2luZ2V0IjogIlBsZXguUGxleE1lZGlhU2VydmVyIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxscGxleGRlc2t0b3AiOiB7CiAgICAiY2F0ZWdvcnkiOiAi6Ieq5omY566h5bel5YW3IiwKICAgICJjaG9jbyI6ICJwbGV4IiwKICAgICJjb250ZW50IjogIlBsZXgg5qGM6Z2i5a6i5oi356uvIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQbGV4IE1lZGlhIFNlcnZlciDmmK/kuIDmrL7lqpLkvZPmnI3liqHlmajova/ku7bvvIzlj6/orqnkvaDnrqHnkIblkozmtYHlvI/kvKDovpPlqpLkvZPmlofku7YiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cucGxleC50diIsCiAgICAid2luZ2V0IjogIlBsZXguUGxleCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHBvc2giOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJvaC1teS1wb3NoIiwKICAgICJjb250ZW50IjogIk9oIE15IFBvc2gg57uI56uv576O5YyWIiwKICAgICJkZXNjcmlwdGlvbiI6ICJPaCBNeSBQb3NoIOaYr+S4gOasvui3qOW5s+WPsOeahCBTaGVsbCDmj5DnpLrnrKbkuLvpopjlvJXmk47jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9vaG15cG9zaC5kZXYvIiwKICAgICJ3aW5nZXQiOiAiSmFuRGVEb2JiZWxlZXIuT2hNeVBvc2giLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHBvd2Vyc2hlbGwiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJwb3dlcnNoZWxsLWNvcmUiLAogICAgImNvbnRlbnQiOiAiUG93ZXJTaGVsbCIsCiAgICAiZGVzY3JpcHRpb24iOiAiUG93ZXJTaGVsbCDmmK/lvq7ova/nmoToh6rliqjljJbku7vliqHmoYbmnrblkozohJrmnKzor63oqIAiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL1Bvd2VyU2hlbGwvUG93ZXJTaGVsbCIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5Qb3dlclNoZWxsIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxwb3dlcnRveXMiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJwb3dlcnRveXMiLAogICAgImNvbnRlbnQiOiAiUG93ZXJUb3lzIOaViOeOh+W3peWFtyIsCiAgICAiZGVzY3JpcHRpb24iOiAiUG93ZXJUb3lzIOaYr+S4gOWll+mdouWQkemrmOe6p+eUqOaIt+eahOaViOeOh+W3peWFt++8jOWMheaLrCBGYW5jeVpvbmVz44CBUG93ZXJSZW5hbWUg562J5Yqf6IO944CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9taWNyb3NvZnQvUG93ZXJUb3lzIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LlBvd2VyVG95cyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscHJpc21sYXVuY2hlciI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogInByaXNtbGF1bmNoZXIiLAogICAgImNvbnRlbnQiOiAiUHJpc20gTGF1bmNoZXIgTWluZWNyYWZ05ZCv5Yqo5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQcmlzbSBMYXVuY2hlciDmmK/kuIDmrL7lvIDmupAgTWluZWNyYWZ0IOWQr+WKqOWZqO+8jOaUr+aMgeeuoeeQhuWkmuS4quWunuS+i+OAgeW4kOaIt+WSjOaooee7hOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3ByaXNtbGF1bmNoZXIub3JnLyIsCiAgICAid2luZ2V0IjogIlByaXNtTGF1bmNoZXIuUHJpc21MYXVuY2hlciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscHJvY2Vzc2xhc3NvIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAicGxhc3NvIiwKICAgICJjb250ZW50IjogIlByb2Nlc3MgTGFzc28g6L+b56iL5LyY5YyWIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQcm9jZXNzIExhc3NvIOaYr+S4gOasvuezu+e7n+S8mOWMluWSjOiHquWKqOWMluW3peWFt++8jOWPr+S8mOWMliBDUFUg5L2/55So546HIiwKICAgICJsaW5rIjogImh0dHBzOi8vYml0c3VtLmNvbS8iLAogICAgIndpbmdldCI6ICJCaXRTdW0uUHJvY2Vzc0xhc3NvIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxscHJvdG9uYXV0aCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInByb3RvbmF1dGgiLAogICAgImNvbnRlbnQiOiAiUHJvdG9uIOmqjOivgeWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiUHJvdG9uIOeahOWPjOWboOe0oOiupOivgeW6lOeUqO+8jOeUqOS6juWuieWFqOWQjOatpeWSjOWkh+S7vSAyRkEg6aqM6K+B56CB44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vcHJvdG9uLm1lL2F1dGhlbnRpY2F0b3IiLAogICAgIndpbmdldCI6ICJQcm90b24uUHJvdG9uQXV0aGVudGljYXRvciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscHJvdG9ubWFpbCI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogInByb3Rvbm1haWwiLAogICAgImNvbnRlbnQiOiAiUHJvdG9uIE1haWwg5Yqg5a+G6YKu566xIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQcm90b24gTWFpbCDmmK8gUHJvdG9uIOeahOerr+WIsOerr+WKoOWvhueUteWtkOmCruS7tuacjeWKoeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3Byb3Rvbi5tZS9tYWlsIiwKICAgICJ3aW5nZXQiOiAiUHJvdG9uLlByb3Rvbk1haWwiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHByb3RvbmRyaXZlIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAicHJvdG9uZHJpdmUiLAogICAgImNvbnRlbnQiOiAiUHJvdG9uIERyaXZlIOWKoOWvhuS6keebmCIsCiAgICAiZGVzY3JpcHRpb24iOiAiUHJvdG9uIERyaXZlIOaYr+err+WIsOerr+WKoOWvhueahOeRnuWjq+aWh+S7tuS/nemZqeW6k+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3Byb3Rvbi5tZS9kcml2ZSIsCiAgICAid2luZ2V0IjogIlByb3Rvbi5Qcm90b25Ecml2ZSIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscHJvdG9ucGFzcyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInByb3RvbnBhc3MiLAogICAgImNvbnRlbnQiOiAiUHJvdG9uIFBhc3Mg5a+G56CB566h55CGIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQcm90b24gUGFzcyDmmK/kuIDmrL7ln7rkuo7kupHnmoTlr4bnoIHnrqHnkIblmajvvIzlhbfmnInnq6/liLDnq6/liqDlr4blip/og73jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9wcm90b24ubWUvcGFzcyIsCiAgICAid2luZ2V0IjogIlByb3Rvbi5Qcm90b25QYXNzIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxwcm90b252cG4iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJwcm90b252cG4iLAogICAgImNvbnRlbnQiOiAiUHJvdG9uIFZQTiIsCiAgICAiZGVzY3JpcHRpb24iOiAiUHJvdG9uIFZQTiDmmK/ml6Dml6Xlv5cgVlBOIOacjeWKoe+8jOS/neaKpOaCqOeahOWcqOe6v+makOengeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3Byb3RvbnZwbi5jb20vIiwKICAgICJ3aW5nZXQiOiAiUHJvdG9uLlByb3RvblZQTiIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscHJvY2Vzc21vbml0b3IiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJwcm9jZXhwIiwKICAgICJjb250ZW50IjogIlByb2Nlc3MgTW9uaXRvciDov5vnqIvnm5HmjqciLAogICAgImRlc2NyaXB0aW9uIjogIlN5c0ludGVybmFscyBQcm9jZXNzIE1vbml0b3Ig5piv5LiA5qy+6auY57qn55uR5o6n5bel5YW377yM5a6e5pe25pi+56S657O757uf5ZKM6L+b56iL5rS75Yqo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZG9jcy5taWNyb3NvZnQuY29tL2VuLXVzL3N5c2ludGVybmFscy9kb3dubG9hZHMvcHJvY21vbiIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5TeXNpbnRlcm5hbHMuUHJvY2Vzc01vbml0b3IiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxwdXR0eSI6IHsKICAgICJjYXRlZ29yeSI6ICLkuJPkuJrlt6XlhbciLAogICAgImNob2NvIjogInB1dHR5IiwKICAgICJjb250ZW50IjogIlB1VFRZIOi/nOeoi+i/nuaOpSIsCiAgICAiZGVzY3JpcHRpb24iOiAiUHVUVFkg5piv5LiA5qy+5YWN6LS55byA5rqQ55qE57uI56uv5Lu/55yf5Zmo44CB5Liy6KGM5o6n5Yi25Y+w5ZKM572R57uc5paH5Lu25Lyg6L6T5bel5YW3IiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmNoaWFyay5ncmVlbmVuZC5vcmcudWsvfnNndGF0aGFtL3B1dHR5LyIsCiAgICAid2luZ2V0IjogIlB1VFRZLlB1VFRZIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxweXRob24zIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAicHl0aG9uIiwKICAgICJjb250ZW50IjogIlB5dGhvbiAzIiwKICAgICJkZXNjcmlwdGlvbiI6ICJQeXRob24g5piv5LiA56eN6YCa55So57yW56iL6K+t6KiA77yM55So5LqOIFdlYiDlvIDlj5HjgIHmlbDmja7liIbmnpDjgIHkurrlt6Xmmbrog73nrYnpoobln5/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cucHl0aG9uLm9yZy8iLAogICAgIndpbmdldCI6ICJQeXRob24uUHl0aG9uLjMuMTQiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHFiaXR0b3JyZW50IjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAicWJpdHRvcnJlbnQiLAogICAgImNvbnRlbnQiOiAicUJpdHRvcnJlbnQg5LiL6L295bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJxQml0dG9ycmVudCDmmK/kuIDmrL7lhY3otLnlvIDmupDnmoQgQml0VG9ycmVudCDlrqLmiLfnq68iLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cucWJpdHRvcnJlbnQub3JnLyIsCiAgICAid2luZ2V0IjogInFCaXR0b3JyZW50LnFCaXR0b3JyZW50IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxxdG94IjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAicXRveCIsCiAgICAiY29udGVudCI6ICJRVG94IOWuieWFqOmAmuiuryIsCiAgICAiZGVzY3JpcHRpb24iOiAiUVRveCDmmK/kuIDmrL7lhY3otLnlvIDmupDpgJrorq/lupTnlKjvvIzorr7orqHkuIrkvJjlhYjogIPomZHnlKjmiLfpmpDnp4HlkozlronlhajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9xdG94LmdpdGh1Yi5pby8iLAogICAgIndpbmdldCI6ICJUb3gucVRveCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscmV2byI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInJldm8tdW5pbnN0YWxsZXIiLAogICAgImNvbnRlbnQiOiAiUmV2byBVbmluc3RhbGxlciDljbjovb3lt6XlhbciLAogICAgImRlc2NyaXB0aW9uIjogIlJldm8gVW5pbnN0YWxsZXIg5piv5LiA5qy+6auY57qn5Y246L295bel5YW377yM5biu5Yqp5oKo5Yig6Zmk5LiN6ZyA6KaB55qE6L2v5Lu25bm25riF55CG57O757uf44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LnJldm91bmluc3RhbGxlci5jb20vIiwKICAgICJ3aW5nZXQiOiAiUmV2b1VuaW5zdGFsbGVyLlJldm9Vbmluc3RhbGxlciIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbFdpc2VQcm9ncmFtVW5pbnN0YWxsZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJuYSIsCiAgICAiY29udGVudCI6ICJXaXNlIFByb2dyYW0gVW5pbnN0YWxsZXIg5Y246L295bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJXaXNlIFByb2dyYW0gVW5pbnN0YWxsZXIg5piv5Y246L29IFdpbmRvd3Mg56iL5bqP55qE5a6M576O6Kej5Yaz5pa55qGI44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lndpc2VjbGVhbmVyLmNvbS93aXNlLXByb2dyYW0tdW5pbnN0YWxsZXIuaHRtbCIsCiAgICAid2luZ2V0IjogIldpc2VDbGVhbmVyLldpc2VQcm9ncmFtVW5pbnN0YWxsZXIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxydWZ1cyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInJ1ZnVzIiwKICAgICJjb250ZW50IjogIlJ1ZnVzIOWQr+WKqOebmOWItuS9nCIsCiAgICAiZGVzY3JpcHRpb24iOiAiUnVmdXMg5piv5LiA5qy+5biu5Yqp5qC85byP5YyW5ZKM5Yib5bu65Y+v5ZCv5YqoIFVTQiDpqbHliqjlmajnmoTlt6XlhbfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9ydWZ1cy5pZS8iLAogICAgIndpbmdldCI6ICJSdWZ1cy5SdWZ1cyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxscnVzdGxhbmciOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJydXN0IiwKICAgICJjb250ZW50IjogIlJ1c3Qg57yW56iL6K+t6KiAIiwKICAgICJkZXNjcmlwdGlvbiI6ICJSdXN0IOaYr+S4gOenjeS4k+S4uuWuieWFqOWSjOaAp+iDveiuvuiuoeeahOe8lueoi+ivreiogO+8jOWwpOWFtuazqOmHjeezu+e7n+e8lueoi+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5ydXN0LWxhbmcub3JnLyIsCiAgICAid2luZ2V0IjogIlJ1c3RsYW5nLlJ1c3QuTVNWQyIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsc2RpbyI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInNkaW8iLAogICAgImNvbnRlbnQiOiAiU25hcHB5IERyaXZlciBJbnN0YWxsZXIg6amx5Yqo5pu05pawIiwKICAgICJkZXNjcmlwdGlvbiI6ICJTbmFwcHkgRHJpdmVyIEluc3RhbGxlciBPcmlnaW4g5piv5LiA5qy+5YWN6LS55byA5rqQ6amx5Yqo5pu05paw5bel5YW344CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmdsZW5uLmRlbGFob3kuY29tL3NuYXBweS1kcml2ZXItaW5zdGFsbGVyLW9yaWdpbi8iLAogICAgIndpbmdldCI6ICJHbGVubkRlbGFob3kuU25hcHB5RHJpdmVySW5zdGFsbGVyT3JpZ2luIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxzaGFyZXgiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5aSa5aqS5L2T5bel5YW3IiwKICAgICJjaG9jbyI6ICJzaGFyZXgiLAogICAgImNvbnRlbnQiOiAiU2hhcmVYIOaIquWbvuW3peWFtyIsCiAgICAiZGVzY3JpcHRpb24iOiAiU2hhcmVYIOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOWxj+W5leaIquWbvuWSjOaWh+S7tuWFseS6q+W3peWFtyIsCiAgICAibGluayI6ICJodHRwczovL2dldHNoYXJleC5jb20vIiwKICAgICJ3aW5nZXQiOiAiU2hhcmVYLlNoYXJlWCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsbmlsZXNvZnRTaGVsbCI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIm5pbGVzb2Z0LXNoZWxsIiwKICAgICJjb250ZW50IjogIk5pbGVzb2Z0IFNoZWxsIOWPs+mUruiPnOWNlSIsCiAgICAiZGVzY3JpcHRpb24iOiAiU2hlbGwg5piv5LiA5qy+IFdpbmRvd3Mg5Y+z6ZSu6I+c5Y2V5omp5bGV5bel5YW377yM5re75Yqg6aKd5aSW5Yqf6IO95ZKM6Ieq5a6a5LmJ6YCJ6aG544CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vbmlsZXNvZnQub3JnLyIsCiAgICAid2luZ2V0IjogIk5pbGVzb2Z0LlNoZWxsIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsc3lzdGVtaW5mb3JtZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJzeXN0ZW1pbmZvcm1lciIsCiAgICAiY29udGVudCI6ICJTeXN0ZW0gSW5mb3JtZXIg57O757uf55uR5o6nIiwKICAgICJkZXNjcmlwdGlvbiI6ICLkuIDmrL7lhY3otLnjgIHlvLrlpKfjgIHlpJrnlKjpgJTnmoTlt6XlhbfvvIzluK7liqnmgqjnm5Hmjqfns7vnu5/otYTmupDjgIHosIPor5Xova/ku7blkozmo4DmtYvmgbbmhI/ova/ku7bjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9zeXN0ZW1pbmZvcm1lci5jb20vIiwKICAgICJ3aW5nZXQiOiAiV2luc2lkZXJTUy5TeXN0ZW1JbmZvcm1lciIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsc2lnbmFsIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAic2lnbmFsIiwKICAgICJjb250ZW50IjogIlNpZ25hbCDliqDlr4bpgJrorq8iLAogICAgImRlc2NyaXB0aW9uIjogIlNpZ25hbCDmmK/kuIDmrL7ms6jph43pmpDnp4HnmoTpgJrorq/lupTnlKjvvIzmj5Dkvpvnq6/liLDnq6/liqDlr4bku6Xnoa7kv53lronlhajlkoznp4Hlr4bnmoTpgJrkv6HjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9zaWduYWwub3JnLyIsCiAgICAid2luZ2V0IjogIk9wZW5XaGlzcGVyU3lzdGVtcy5TaWduYWwiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHNpZ25hbHJnYiI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIm5hIiwKICAgICJjb250ZW50IjogIlNpZ25hbFJHQiBSR0LmjqfliLYiLAogICAgImRlc2NyaXB0aW9uIjogIlNpZ25hbFJHQiDorqnmgqjpgJrov4fkuIDkuKrlhY3otLnlupTnlKjnqIvluo/mjqfliLblkozlkIzmraXmgqjllpzniLHnmoQgUkdCIOiuvuWkh+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5zaWduYWxyZ2IuY29tLyIsCiAgICAid2luZ2V0IjogIldoaXJsd2luZEZYLlNpZ25hbFJnYiIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHNpbXBsZXdhbGwiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJzaW1wbGV3YWxsIiwKICAgICJjb250ZW50IjogIlNpbXBsZXdhbGwg6Ziy54Gr5aKZIiwKICAgICJkZXNjcmlwdGlvbiI6ICJTaW1wbGV3YWxsIOaYr+S4gOasvuWFjei0ueW8gOa6kCBXaW5kb3dzIOmYsueBq+WimeW6lOeUqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vaGVucnlwcC9zaW1wbGV3YWxsIiwKICAgICJ3aW5nZXQiOiAiSGVucnkrKy5zaW1wbGV3YWxsIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxzbGFjayI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogInNsYWNrIiwKICAgICJjb250ZW50IjogIlNsYWNrIOWboumYn+WNj+S9nCIsCiAgICAiZGVzY3JpcHRpb24iOiAiU2xhY2sg5piv6L+e5o6l5Zui6Zif5bm26YCa6L+H6aKR6YGT44CB5raI5oGv5ZKM5paH5Lu25YWx5Lqr5L+D6L+b5rKf6YCa55qE5Y2P5L2c5Lit5b+D44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vc2xhY2suY29tLyIsCiAgICAid2luZ2V0IjogIlNsYWNrVGVjaG5vbG9naWVzLlNsYWNrIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsc3RhcnRhbGxiYWNrIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiU3RhcnRBbGxCYWNrIiwKICAgICJjb250ZW50IjogIlN0YXJ0QWxsQmFjayDlvIDlp4voj5zljZXmgaLlpI0iLAogICAgImRlc2NyaXB0aW9uIjogIlN0YXJ0QWxsQmFjayDmgaLlpI3lubbmlLnov5sgV2luZG93cyDku7vliqHmoI/jgIHlvIDlp4voj5zljZXjgIHmlofku7botYTmupDnrqHnkIblmajlkowgU2hlbGwgVUkg6KGM5Li644CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LnN0YXJ0YWxsYmFjay5jb20vIiwKICAgICJ3aW5nZXQiOiAiU3RhcnRJc0JhY2suU3RhcnRBbGxCYWNrIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsc3RlYW0iOiB7CiAgICAiY2F0ZWdvcnkiOiAi5ri45oiPIiwKICAgICJjaG9jbyI6ICJzdGVhbS1jbGllbnQiLAogICAgImNvbnRlbnQiOiAiU3RlYW0g5ri45oiP5bmz5Y+wIiwKICAgICJkZXNjcmlwdGlvbiI6ICJTdGVhbSDmmK/otK3kubDlkozmuLjnjqnop4bpopHmuLjmiI/nmoTmlbDlrZfliIblj5HlubPlj7DjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9zdG9yZS5zdGVhbXBvd2VyZWQuY29tL2Fib3V0LyIsCiAgICAid2luZ2V0IjogIlZhbHZlLlN0ZWFtIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsc3VibGltZXRleHQiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJzdWJsaW1ldGV4dDQiLAogICAgImNvbnRlbnQiOiAiU3VibGltZSBUZXh0IOaWh+acrOe8lui+keWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiU3VibGltZSBUZXh0IOaYr+S4gOasvueUqOS6juS7o+eggeOAgeagh+iusOWSjOaVo+aWh+eahOeyvuiJr+aWh+acrOe8lui+keWZqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5zdWJsaW1ldGV4dC5jb20vIiwKICAgICJ3aW5nZXQiOiAiU3VibGltZUhRLlN1YmxpbWVUZXh0LjQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxzdW5zaGluZSI6IHsKICAgICJjYXRlZ29yeSI6ICLoh6rmiZjnrqHlt6XlhbciLAogICAgImNob2NvIjogInN1bnNoaW5lIiwKICAgICJjb250ZW50IjogIlN1bnNoaW5lIOa4uOaIj+S4sua1geacjeWKoeWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiU3Vuc2hpbmUg5piv5LiA5qy+5ri45oiP5Liy5rWB5pyN5Yqh5Zmo77yM5YWB6K645ZyoIEFuZHJvaWQg6K6+5aSH5LiK6L+c56iL546pIFBDIOa4uOaIj+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vTGl6YXJkQnl0ZS9TdW5zaGluZSIsCiAgICAid2luZ2V0IjogIkxpemFyZEJ5dGUuU3Vuc2hpbmUiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHRjcHZpZXciOiB7CiAgICAiY2F0ZWdvcnkiOiAi5b6u6L2v5bel5YW3IiwKICAgICJjaG9jbyI6ICJ0Y3B2aWV3IiwKICAgICJjb250ZW50IjogIlRDUFZpZXcg572R57uc55uR5o6nIiwKICAgICJkZXNjcmlwdGlvbiI6ICJTeXNJbnRlcm5hbHMgVENQVmlldyDmmK/kuIDmrL7nvZHnu5znm5Hmjqflt6XlhbfvvIzmmL7npLrmiYDmnIkgVENQIOWSjCBVRFAg56uv54K555qE6K+m57uG5YiX6KGo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZG9jcy5taWNyb3NvZnQuY29tL2VuLXVzL3N5c2ludGVybmFscy9kb3dubG9hZHMvdGNwdmlldyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5TeXNpbnRlcm5hbHMuVENQVmlldyIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHRlYW1zIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAibWljcm9zb2Z0LXRlYW1zIiwKICAgICJjb250ZW50IjogIlRlYW1zIOWboumYn+WNj+S9nCIsCiAgICAiZGVzY3JpcHRpb24iOiAiTWljcm9zb2Z0IFRlYW1zIOaYr+S4jiBPZmZpY2UgMzY1IOmbhuaIkOeahOWNj+S9nOW5s+WPsOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5taWNyb3NvZnQuY29tL2VuLXVzL21pY3Jvc29mdC10ZWFtcy9ncm91cC1jaGF0LXNvZnR3YXJlIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LlRlYW1zIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdGVhbXZpZXdlciI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogInRlYW12aWV3ZXI5IiwKICAgICJjb250ZW50IjogIlRlYW1WaWV3ZXIg6L+c56iL5Y2P5YqpIiwKICAgICJkZXNjcmlwdGlvbiI6ICJUZWFtVmlld2VyIOaYr+S4gOasvua1geihjOeahOi/nOeoi+iuv+mXruWSjOaUr+aMgei9r+S7tuOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy50ZWFtdmlld2VyLmNvbS8iLAogICAgIndpbmdldCI6ICJUZWFtVmlld2VyLlRlYW1WaWV3ZXIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGx0ZWFtc3BlYWszIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAidGVhbXNwZWFrIiwKICAgICJjb250ZW50IjogIlRlYW1TcGVhayAzIOivremfs+mAmuiuryIsCiAgICAiZGVzY3JpcHRpb24iOiAiVEVBTVNQRUFLLiBZT1VSIFRFQU0uIFlPVVIgUlVMRVMuIFVzZSBjcnlzdGFsIGNsZWFyIHNvdW5kIHRvIGNvbW11bmljYXRlIHdpdGggeW91ciB0ZWFtbWF0ZXMgY3Jvc3MtcGxhdGZvcm0gd2l0aCBtaWxpdGFyeS1ncmFkZSBzZWN1cml0eSwgbGFnLWZyZWUgcGVyZm9ybWFuY2UgJiB1bnBhcmFsbGVsZWQgcmVsaWFiaWxpdHkgYW5kIHVwdGltZS4iLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cudGVhbXNwZWFrLmNvbS8iLAogICAgIndpbmdldCI6ICJUZWFtU3BlYWtTeXN0ZW1zLlRlYW1TcGVha0NsaWVudCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHRlbGVncmFtIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAidGVsZWdyYW0iLAogICAgImNvbnRlbnQiOiAiVGVsZWdyYW0g5Y2z5pe26YCa6K6vIiwKICAgICJkZXNjcmlwdGlvbiI6ICJUZWxlZ3JhbSDmmK/kuIDmrL7ln7rkuo7kupHnmoTljbPml7bpgJrorq/lupTnlKjvvIzku6XlhbblronlhajmgKfjgIHpgJ/luqblkoznroDmtIHmgKfogIzpl7vlkI3jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly90ZWxlZ3JhbS5vcmcvIiwKICAgICJ3aW5nZXQiOiAiVGVsZWdyYW0uVGVsZWdyYW1EZXNrdG9wIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx0ZXJtaW5hbCI6IHsKICAgICJjYXRlZ29yeSI6ICLlvq7ova/lt6XlhbciLAogICAgImNob2NvIjogIm1pY3Jvc29mdC13aW5kb3dzLXRlcm1pbmFsIiwKICAgICJjb250ZW50IjogIldpbmRvd3MgVGVybWluYWwg57uI56uvIiwKICAgICJkZXNjcmlwdGlvbiI6ICJXaW5kb3dzIFRlcm1pbmFsIOaYr+S4gOasvueOsOS7o+OAgeW/q+mAn+OAgemrmOaViOeahOe7iOerr+W6lOeUqOeoi+W6jyIsCiAgICAibGluayI6ICJodHRwczovL2FrYS5tcy90ZXJtaW5hbCIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5XaW5kb3dzVGVybWluYWwiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHRodW5kZXJiaXJkIjogewogICAgImNhdGVnb3J5IjogIumAmuiur+W3peWFtyIsCiAgICAiY2hvY28iOiAidGh1bmRlcmJpcmQiLAogICAgImNvbnRlbnQiOiAiVGh1bmRlcmJpcmQg6YKu5Lu25a6i5oi356uvIiwKICAgICJkZXNjcmlwdGlvbiI6ICJNb3ppbGxhIFRodW5kZXJiaXJkIOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOeUteWtkOmCruS7tuOAgeaWsOmXu+WSjOiBiuWkqeWuouaIt+err+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy50aHVuZGVyYmlyZC5uZXQvIiwKICAgICJ3aW5nZXQiOiAiTW96aWxsYS5UaHVuZGVyYmlyZCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsYmV0dGVyYmlyZCI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogImJldHRlcmJpcmQiLAogICAgImNvbnRlbnQiOiAiQmV0dGVyYmlyZCDpgq7ku7blrqLmiLfnq68o5LyY5YyW54mIKSIsCiAgICAiZGVzY3JpcHRpb24iOiAiQmV0dGVyYmlyZCDmmK8gTW96aWxsYSBUaHVuZGVyYmlyZCDnmoTliIbmlK/vvIzlhbfmnInpop3lpJblip/og73lkozplJnor6/kv67lpI3jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cuYmV0dGVyYmlyZC5ldS8iLAogICAgIndpbmdldCI6ICJCZXR0ZXJiaXJkLkJldHRlcmJpcmQiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHRvciI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogInRvci1icm93c2VyIiwKICAgICJjb250ZW50IjogIlRvciDljL/lkI3mtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIlRvciDmtY/op4jlmajkuJPkuLrljL/lkI3nvZHpobXmtY/op4jogIzorr7orqHvvIzliKnnlKggVG9yIOe9kee7nOS/neaKpOeUqOaIt+makOengeWSjOWuieWFqOOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy50b3Jwcm9qZWN0Lm9yZy8iLAogICAgIndpbmdldCI6ICJUb3JQcm9qZWN0LlRvckJyb3dzZXIiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHRvdGFsY29tbWFuZGVyIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiVG90YWxDb21tYW5kZXIiLAogICAgImNvbnRlbnQiOiAiVG90YWwgQ29tbWFuZGVyIOaWh+S7tueuoeeQhiIsCiAgICAiZGVzY3JpcHRpb24iOiAiVG90YWwgQ29tbWFuZGVyIOaYr+S4gOasviBXaW5kb3dzIOaWh+S7tueuoeeQhuWZqO+8jOaPkOS+m+W8uuWkp+ebtOingueahOaWh+S7tueuoeeQhueVjOmdouOAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy5naGlzbGVyLmNvbS8iLAogICAgIndpbmdldCI6ICJHaGlzbGVyLlRvdGFsQ29tbWFuZGVyIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdHJlZXNpemUiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJ0cmVlc2l6ZWZyZWUiLAogICAgImNvbnRlbnQiOiAiVHJlZVNpemUgRnJlZSDno4Hnm5jliIbmnpAiLAogICAgImRlc2NyaXB0aW9uIjogIlRyZWVTaXplIEZyZWUg5piv5LiA5qy+56OB55uY56m66Ze0566h55CG5Zmo77yM5biu5Yqp5oKo5YiG5p6Q5ZKM5Y+v6KeG5YyW6amx5Yqo5Zmo5LiK55qE56m66Ze05L2/55So5oOF5Ya144CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LmphbS1zb2Z0d2FyZS5jb20vdHJlZXNpemVfZnJlZS8iLAogICAgIndpbmdldCI6ICJKQU1Tb2Z0d2FyZS5UcmVlU2l6ZS5GcmVlIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdHRhc2tiYXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJ0cmFuc2x1Y2VudHRiIiwKICAgICJjb250ZW50IjogIlRyYW5zbHVjZW50VEIg5Lu75Yqh5qCP6YCP5piOIiwKICAgICJkZXNjcmlwdGlvbiI6ICJUcmFuc2x1Y2VudFRCIOaYr+S4gOasvuWFgeiuuOaCqOiHquWumuS5iSBXaW5kb3dzIOS7u+WKoeagj+mAj+aYjuW6pueahOW3peWFt+OAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vVHJhbnNsdWNlbnRUQi9UcmFuc2x1Y2VudFRCIiwKICAgICJ3aW5nZXQiOiAiQ2hhcmxlc01pbGV0dGUuVHJhbnNsdWNlbnRUQiIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsdWJpc29mdCI6IHsKICAgICJjYXRlZ29yeSI6ICLmuLjmiI8iLAogICAgImNob2NvIjogInViaXNvZnQtY29ubmVjdCIsCiAgICAiY29udGVudCI6ICJVYmlzb2Z0IENvbm5lY3Qg5ri45oiP5bmz5Y+wIiwKICAgICJkZXNjcmlwdGlvbiI6ICJVYmlzb2Z0IENvbm5lY3Qg5piv6IKy56Kn55qE5pWw5a2X5Y+R6KGM5ZKM5Zyo57q/5aSa5Lq65ri45oiP5bmz5Y+wIiwKICAgICJsaW5rIjogImh0dHBzOi8vdWJpc29mdGNvbm5lY3QuY29tLyIsCiAgICAid2luZ2V0IjogIlViaXNvZnQuQ29ubmVjdCIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHVuZ29vZ2xlZCI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogInVuZ29vZ2xlZC1jaHJvbWl1bSIsCiAgICAiY29udGVudCI6ICJVbmdvb2dsZWQgQ2hyb21pdW0g5peg6LC35q2M54mIIiwKICAgICJkZXNjcmlwdGlvbiI6ICJVbmdvb2dsZWQgQ2hyb21pdW0g5piv5LiN5ZCrIEdvb2dsZSDpm4bmiJDnmoQgQ2hyb21pdW0g54mI5pys44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9FbG9zdG9uL3VuZ29vZ2xlZC1jaHJvbWl1bSIsCiAgICAid2luZ2V0IjogImVsb3N0b24udW5nb29nbGVkLWNocm9taXVtIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx1bml0eSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogInVuaXR5aHViIiwKICAgICJjb250ZW50IjogIlVuaXR5IOa4uOaIj+W8leaTjiIsCiAgICAiZGVzY3JpcHRpb24iOiAiVW5pdHkg5piv5LiA5qy+5by65aSn55qE5ri45oiP5byA5Y+R5bmz5Y+w77yM55So5LqO5Yib5bu6IDJE44CBM0TjgIHlop7lvLrnjrDlrp7lkozomZrmi5/njrDlrp7muLjmiI/jgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly91bml0eS5jb20vIiwKICAgICJ3aW5nZXQiOiAiVW5pdHkuVW5pdHlIdWIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGxldmVyeXRoaW5nIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiZXZlcnl0aGluZyIsCiAgICAiY29udGVudCI6ICJFdmVyeXRoaW5nIOaWh+S7tuaQnOe0oiIsCiAgICAiZGVzY3JpcHRpb24iOiAiRXZlcnl0aGluZyDmmK/kuIDmrL7mnoHpgJ/mlofku7bmkJzntKLlt6XlhbfvvIzlj6/nnqzpl7TlrprkvY3mlofku7blkozmlofku7blpLkiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cudm9pZHRvb2xzLmNvbS8iLAogICAgIndpbmdldCI6ICJ2b2lkdG9vbHMuRXZlcnl0aGluZyIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHZjMjAxNV8zMiI6IHsKICAgICJjYXRlZ29yeSI6ICLlvq7ova/lt6XlhbciLAogICAgImNob2NvIjogInZjcmVkaXN0MjAxNSIsCiAgICAiY29udGVudCI6ICJWaXN1YWwgQysrIDIwMTUtMjAyMiAzMuS9jei/kOihjOW6kyIsCiAgICAiZGVzY3JpcHRpb24iOiAiVmlzdWFsIEMrKyAyMDE1LTIwMjIgMzLkvY3lj6/lho3lj5HooYzljIXvvIzlronoo4Xov5DooYwgMzIg5L2N5bqU55So5omA6ZyA55qE6L+Q6KGM5pe257uE5Lu244CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vc3VwcG9ydC5taWNyb3NvZnQuY29tL2VuLXVzL2hlbHAvMjk3NzAwMy90aGUtbGF0ZXN0LXN1cHBvcnRlZC12aXN1YWwtYy1kb3dubG9hZHMiLAogICAgIndpbmdldCI6ICJNaWNyb3NvZnQuVkNSZWRpc3QuMjAxNSsueDg2IiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdmMyMDE1XzY0IjogewogICAgImNhdGVnb3J5IjogIuW+rui9r+W3peWFtyIsCiAgICAiY2hvY28iOiAidmNyZWRpc3QyMDE1IiwKICAgICJjb250ZW50IjogIlZpc3VhbCBDKysgMjAxNS0yMDIyIDY05L2N6L+Q6KGM5bqTIiwKICAgICJkZXNjcmlwdGlvbiI6ICJWaXN1YWwgQysrIDIwMTUtMjAyMiA2NOS9jeWPr+WGjeWPkeihjOWMhe+8jOWuieijhei/kOihjCA2NCDkvY3lupTnlKjmiYDpnIDnmoTov5DooYzml7bnu4Tku7bjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9zdXBwb3J0Lm1pY3Jvc29mdC5jb20vZW4tdXMvaGVscC8yOTc3MDAzL3RoZS1sYXRlc3Qtc3VwcG9ydGVkLXZpc3VhbC1jLWRvd25sb2FkcyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5WQ1JlZGlzdC4yMDE1Ky54NjQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGx2ZW50b3kiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJ2ZW50b3kiLAogICAgImNvbnRlbnQiOiAiVmVudG95IOWQr+WKqOebmOWItuS9nCIsCiAgICAiZGVzY3JpcHRpb24iOiAiVmVudG95IOaYr+S4gOasvuW8gOa6kOeahOWQr+WKqCBVIOebmOWItuS9nOW3peWFtyIsCiAgICAibGluayI6ICJodHRwczovL3d3dy52ZW50b3kubmV0LyIsCiAgICAid2luZ2V0IjogIlZlbnRveS5WZW50b3kiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHZlc2t0b3AiOiB7CiAgICAiY2F0ZWdvcnkiOiAi6YCa6K6v5bel5YW3IiwKICAgICJjaG9jbyI6ICJuYSIsCiAgICAiY29udGVudCI6ICJWZXNrdG9wIERpc2NvcmTlrqLmiLfnq68iLAogICAgImRlc2NyaXB0aW9uIjogIuWfuuS6jiBFbGVjdHJvbiDnmoTot6jlubPlj7DmoYzpnaLlupTnlKjvvIzpooToo4UgVmVuY29yZO+8jOaPkOS+m+abtOa1geeVheeahCBEaXNjb3JkIOS9k+mqjOOAgiIsCiAgICAibGluayI6ICJodHRwczovL2dpdGh1Yi5jb20vVmVuY29yZC9WZXNrdG9wIiwKICAgICJ3aW5nZXQiOiAiVmVuY29yZC5WZXNrdG9wIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx2aWJlciI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogInZpYmVyIiwKICAgICJjb250ZW50IjogIlZpYmVyIOWNs+aXtumAmuiuryIsCiAgICAiZGVzY3JpcHRpb24iOiAiVmliZXIg5piv5LiA5qy+5YWN6LS55raI5oGv5ZKM6YCa6K+d5bqU55So77yM5YW35pyJ576k6IGK44CB6KeG6aKR6YCa6K+d562J5Yqf6IO944CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3LnZpYmVyLmNvbS8iLAogICAgIndpbmdldCI6ICJSYWt1dGVuLlZpYmVyIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdmlzdWFsc3R1ZGlvMjAyMiI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogInZpc3VhbHN0dWRpbzIwMjJjb21tdW5pdHkiLAogICAgImNvbnRlbnQiOiAiVmlzdWFsIFN0dWRpbyAyMDIyIiwKICAgICJkZXNjcmlwdGlvbiI6ICJWaXN1YWwgU3R1ZGlvIDIwMjIg5piv55So5LqO5p6E5bu644CB6LCD6K+V5ZKM6YOo572y5bqU55So56iL5bqP55qE6ZuG5oiQ5byA5Y+R546v5aKDIChJREUp44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vdmlzdWFsc3R1ZGlvLm1pY3Jvc29mdC5jb20vIiwKICAgICJ3aW5nZXQiOiAiTWljcm9zb2Z0LlZpc3VhbFN0dWRpby4yMDIyLkNvbW11bml0eSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbHZpc3VhbHN0dWRpbzIwMjYiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJ2aXN1YWxzdHVkaW8yMDI2Y29tbXVuaXR5IiwKICAgICJjb250ZW50IjogIlZpc3VhbCBTdHVkaW8gMjAyNiIsCiAgICAiZGVzY3JpcHRpb24iOiAiVmlzdWFsIFN0dWRpbyAyMDI2IOaYr+eUqOS6juaehOW7uuOAgeiwg+ivleWSjOmDqOe9suW6lOeUqOeoi+W6j+eahOmbhuaIkOW8gOWPkeeOr+WigyAoSURFKeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3Zpc3VhbHN0dWRpby5taWNyb3NvZnQuY29tLyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5WaXN1YWxTdHVkaW8uQ29tbXVuaXR5IiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdml2YWxkaSI6IHsKICAgICJjYXRlZ29yeSI6ICLmtY/op4jlmagiLAogICAgImNob2NvIjogInZpdmFsZGkiLAogICAgImNvbnRlbnQiOiAiVml2YWxkaSDmtY/op4jlmagiLAogICAgImRlc2NyaXB0aW9uIjogIlZpdmFsZGkg5piv5LiA5qy+6auY5bqm5Y+v5a6a5Yi255qE572R6aG15rWP6KeI5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vdml2YWxkaS5jb20vIiwKICAgICJ3aW5nZXQiOiAiVml2YWxkaS5WaXZhbGRpIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdmxjIjogewogICAgImNhdGVnb3J5IjogIuWkmuWqkuS9k+W3peWFtyIsCiAgICAiY2hvY28iOiAidmxjIiwKICAgICJjb250ZW50IjogIlZMQyDop4bpopHmkq3mlL7lmagiLAogICAgImRlc2NyaXB0aW9uIjogIlZMQyDlqpLkvZPmkq3mlL7lmajmmK/kuIDmrL7lhY3otLnlvIDmupDnmoTlpJrlqpLkvZPmkq3mlL7lmagiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cudmlkZW9sYW4ub3JnL3ZsYy8iLAogICAgIndpbmdldCI6ICJWaWRlb0xBTi5WTEMiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHZyZGVza3RvcHN0cmVhbWVyIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAibmEiLAogICAgImNvbnRlbnQiOiAiVmlydHVhbCBEZXNrdG9wIFN0cmVhbWVyIFZS5Liy5rWBIiwKICAgICJkZXNjcmlwdGlvbiI6ICJWaXJ0dWFsIERlc2t0b3AgU3RyZWFtZXIg5piv5LiA5qy+5bCG5qGM6Z2i5bGP5bmV5Liy5rWB5YiwIFZSIOiuvuWkh+eahOW3peWFt+OAgiIsCiAgICAibGluayI6ICJodHRwczovL3d3dy52cmRlc2t0b3AubmV0LyIsCiAgICAid2luZ2V0IjogIlZpcnR1YWxEZXNrdG9wLlN0cmVhbWVyIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdnNjb2RlIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAidnNjb2RlIiwKICAgICJjb250ZW50IjogIlZTIENvZGUg5Luj56CB57yW6L6R5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJWaXN1YWwgU3R1ZGlvIENvZGUg5piv5LiA5qy+5YWN6LS55byA5rqQ55qE5Luj56CB57yW6L6R5Zmo77yM5pSv5oyB5aSa56eN57yW56iL6K+t6KiA44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vY29kZS52aXN1YWxzdHVkaW8uY29tLyIsCiAgICAid2luZ2V0IjogIk1pY3Jvc29mdC5WaXN1YWxTdHVkaW9Db2RlIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx2c2NvZGl1bSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogInZzY29kaXVtIiwKICAgICJjb250ZW50IjogIlZTIENvZGl1bSDlvIDmupDniYgiLAogICAgImRlc2NyaXB0aW9uIjogIlZTQ29kaXVtIOaYr+ekvuWMuumpseWKqOeahOOAgeiHqueUseiuuOWPr+eahCBNaWNyb3NvZnQgVlMgQ29kZSDkuozov5vliLblj5HooYzniYjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly92c2NvZGl1bS5jb20vIiwKICAgICJ3aW5nZXQiOiAiVlNDb2RpdW0uVlNDb2RpdW0iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHdhdGVyZm94IjogewogICAgImNhdGVnb3J5IjogIua1j+iniOWZqCIsCiAgICAiY2hvY28iOiAid2F0ZXJmb3giLAogICAgImNvbnRlbnQiOiAiV2F0ZXJmb3gg6ZqQ56eB5rWP6KeI5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJXYXRlcmZveCDmmK/kuIDmrL7ln7rkuo4gRmlyZWZveCDnmoTlv6vpgJ/pmpDnp4HmtY/op4jlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cud2F0ZXJmb3gubmV0LyIsCiAgICAid2luZ2V0IjogIldhdGVyZm94LldhdGVyZm94IiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx3aGF0c2FwcCI6IHsKICAgICJjYXRlZ29yeSI6ICLpgJrorq/lt6XlhbciLAogICAgImNob2NvIjogIm5hIiwKICAgICJjb250ZW50IjogIldoYXRzQXBwIOahjOmdoueJiCIsCiAgICAiZGVzY3JpcHRpb24iOiAiV2hhdHNBcHAgRGVza3RvcCDmmK8gTWV0YSDnmoTlrpjmlrkgV2luZG93cyDmoYzpnaLmtojmga/lupTnlKjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9hcHBzLm1pY3Jvc29mdC5jb20vZGV0YWlsLzlua3NxZ3A3ZjJuaCIsCiAgICAid2luZ2V0IjogIm1zc3RvcmU6OU5LU1FHUDdGMk5IIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsd2luZ2V0dWkiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJ3aW5nZXR1aSIsCiAgICAiY29udGVudCI6ICJVbmlHZXRVSSDljIXnrqHnkIZHVUkiLAogICAgImRlc2NyaXB0aW9uIjogIlVuaUdldFVJIOaYryBXaW5HZXTjgIFDaG9jb2xhdGV5IOWSjOWFtuS7liBXaW5kb3dzIENMSSDljIXnrqHnkIblmajnmoTlm77lvaLnlYzpnaLjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9kZXZvbHV0aW9ucy5uZXQvdW5pZ2V0dWkvIiwKICAgICJ3aW5nZXQiOiAiRGV2b2x1dGlvbnMuVW5pR2V0VUkiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHdpbnJhciI6IHsKICAgICJjYXRlZ29yeSI6ICLlt6XlhbfnsbsiLAogICAgImNob2NvIjogIndpbnJhciIsCiAgICAiY29udGVudCI6ICJXaW5SQVIg5Y6L57yp5bel5YW3IiwKICAgICJkZXNjcmlwdGlvbiI6ICJXaW5SQVIg5piv5LiA5qy+5Yqf6IO95by65aSn55qE5Y6L57yp5paH5Lu2566h55CG5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vd3d3Lndpbi1yYXIuY29tLyIsCiAgICAid2luZ2V0IjogIlJBUkxhYi5XaW5SQVIiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGx3aW5zY3AiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJ3aW5zY3AiLAogICAgImNvbnRlbnQiOiAiV2luU0NQIOaWh+S7tuS8oOi+kyIsCiAgICAiZGVzY3JpcHRpb24iOiAiV2luU0NQIOaYr+S4gOasvua1geihjOeahOW8gOa6kCBTRlRQL0ZUUC9TQ1Ag5a6i5oi356uvIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2luc2NwLm5ldC8iLAogICAgIndpbmdldCI6ICJXaW5TQ1AuV2luU0NQIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx3aXJlZ3VhcmQiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJ3aXJlZ3VhcmQiLAogICAgImNvbnRlbnQiOiAiV2lyZUd1YXJkIFZQTiIsCiAgICAiZGVzY3JpcHRpb24iOiAiV2lyZUd1YXJkIOaYr+S4gOasvuW/q+mAn+OAgeeOsOS7o+eahCBWUE7vvIjomZrmi5/kuJPnlKjnvZHnu5zvvIkiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cud2lyZWd1YXJkLmNvbS8iLAogICAgIndpbmdldCI6ICJXaXJlR3VhcmQuV2lyZUd1YXJkIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx3aXJlc2hhcmsiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5LiT5Lia5bel5YW3IiwKICAgICJjaG9jbyI6ICJ3aXJlc2hhcmsiLAogICAgImNvbnRlbnQiOiAiV2lyZXNoYXJrIOe9kee7nOWIhuaekCIsCiAgICAiZGVzY3JpcHRpb24iOiAiV2lyZXNoYXJrIOaYr+S4gOasvuW5v+azm+S9v+eUqOeahOW8gOa6kOe9kee7nOWNj+iuruWIhuaekOW3peWFtyIsCiAgICAibGluayI6ICJodHRwczovL3d3dy53aXJlc2hhcmsub3JnLyIsCiAgICAid2luZ2V0IjogIldpcmVzaGFya0ZvdW5kYXRpb24uV2lyZXNoYXJrIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGx3aXp0cmVlIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAid2l6dHJlZSIsCiAgICAiY29udGVudCI6ICJXaXpUcmVlIOejgeebmOWIhuaekCIsCiAgICAiZGVzY3JpcHRpb24iOiAiV2l6VHJlZSDmmK/kuIDmrL7lv6vpgJ/nmoTno4Hnm5jnqbrpl7TliIbmnpDlt6XlhbciLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aXp0cmVlZnJlZS5jb20vIiwKICAgICJ3aW5nZXQiOiAiQW50aWJvZHlTb2Z0d2FyZS5XaXpUcmVlIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxseGVoZWRpdG9yIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiSHhEIiwKICAgICJjb250ZW50IjogIkh4RCDljYHlha3ov5vliLbnvJbovpHlmagiLAogICAgImRlc2NyaXB0aW9uIjogIkh4RCDmmK/kuIDmrL7lhY3otLnnmoTljYHlha3ov5vliLbnvJbovpHlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9taC1uZXh1cy5kZS9lbi9oeGQvIiwKICAgICJ3aW5nZXQiOiAiTUhOZXh1cy5IeEQiLAogICAgImZvc3MiOiBmYWxzZQogIH0sCiAgIldQRkluc3RhbGx5YXJuIjogewogICAgImNhdGVnb3J5IjogIuW8gOWPkeW3peWFtyIsCiAgICAiY2hvY28iOiAieWFybiIsCiAgICAiY29udGVudCI6ICJZYXJuIOWMheeuoeeQhuWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiWWFybiDmmK/kuIDmrL7lv6vpgJ/jgIHlj6/pnaDjgIHlronlhajnmoQgSmF2YVNjcmlwdCDpobnnm67kvp3otZbnrqHnkIblt6XlhbfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly95YXJucGtnLmNvbS8iLAogICAgIndpbmdldCI6ICJZYXJuLllhcm4iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHpvb20iOiB7CiAgICAiY2F0ZWdvcnkiOiAi6YCa6K6v5bel5YW3IiwKICAgICJjaG9jbyI6ICJ6b29tIiwKICAgICJjb250ZW50IjogIlpvb20g6KeG6aKR5Lya6K6uIiwKICAgICJkZXNjcmlwdGlvbiI6ICJab29tIOaYr+S4gOasvua1geihjOeahOinhumikeS8muiuruWSjOe9kee7nOS8muiuruacjeWKoeOAgiIsCiAgICAibGluayI6ICJodHRwczovL3pvb20udXMvIiwKICAgICJ3aW5nZXQiOiAiWm9vbS5ab29tIiwKICAgICJmb3NzIjogZmFsc2UKICB9LAogICJXUEZJbnN0YWxsdXYiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJ1diIsCiAgICAiY29udGVudCI6ICJ1diBQeXRob27ljIXnrqHnkIblmagiLAogICAgImRlc2NyaXB0aW9uIjogInV2IOaYr+S4gOasvueUqCBSdXN0IOe8luWGmeeahOW/q+mAnyBQeXRob24g5YyF5ZKM6aG555uu566h55CG5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZG9jcy5hc3RyYWwuc2gvdXYvZ2V0dGluZy1zdGFydGVkL2luc3RhbGxhdGlvbi8iLAogICAgIndpbmdldCI6ICJhc3RyYWwtc2gudXYiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbHRpZ2h0dm5jIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiVGlnaHRWTkMiLAogICAgImNvbnRlbnQiOiAiVGlnaHRWTkMg6L+c56iL5qGM6Z2iIiwKICAgICJkZXNjcmlwdGlvbiI6ICJUaWdodFZOQyDmmK/kuIDmrL7lhY3otLnlvIDmupDnmoTov5znqIvmoYzpnaLova/ku7YiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cudGlnaHR2bmMuY29tLyIsCiAgICAid2luZ2V0IjogIkdsYXZTb2Z0LlRpZ2h0Vk5DIiwKICAgICJmb3NzIjogdHJ1ZQogIH0sCiAgIldQRkluc3RhbGxnbGF6ZXdtIjogewogICAgImNhdGVnb3J5IjogIuW3peWFt+exuyIsCiAgICAiY2hvY28iOiAiZ2xhemV3bSIsCiAgICAiY29udGVudCI6ICJHbGF6ZVdNIOW5s+mTuueql+WPo+euoeeQhuWZqCIsCiAgICAiZGVzY3JpcHRpb24iOiAiR2xhemVXTSDmmK/kuIDmrL7lj5cgaTMg5ZKMIFBvbHliYXIg5ZCv5Y+R55qEIFdpbmRvd3Mg5bmz6ZO656qX5Y+j566h55CG5Zmo44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vZ2l0aHViLmNvbS9nbHpyLWlvL2dsYXpld20iLAogICAgIndpbmdldCI6ICJnbHpyLWlvLmdsYXpld20iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbE92ZXJ3b2xmIjogewogICAgImNhdGVnb3J5IjogIua4uOaIjyIsCiAgICAiY2hvY28iOiAib3ZlcndvbGYiLAogICAgImNvbnRlbnQiOiAiT3ZlcndvbGYg5ri45oiP5o+S5Lu25bmz5Y+wIiwKICAgICJkZXNjcmlwdGlvbiI6ICLmtYHooYznmoTmuLjmiI/opobnm5blsYLlkozovoXliqnlupTnlKjlubPlj7DvvIzlub/ms5vooqvmuLjmiI/njqnlrrbkvb/nlKjjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93d3cub3ZlcndvbGYuY29tL2FwcC9vdmVyd29sZi1jdXJzZWZvcmdlIiwKICAgICJ3aW5nZXQiOiAiT3ZlcndvbGYuQ3Vyc2VGb3JnZSIsCiAgICAiZm9zcyI6IGZhbHNlCiAgfSwKICAiV1BGSW5zdGFsbE9GR0IiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJvZmdiIiwKICAgICJjb250ZW50IjogIk9GR0IgV2luZG93c+W5v+WRiuenu+mZpCIsCiAgICAiZGVzY3JpcHRpb24iOiAi5LuOIFdpbmRvd3MgMTEg5ZCE5aSE56e76Zmk5bm/5ZGK55qEIEdVSSDlt6XlhbfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL3hNNGRkeS9PRkdCIiwKICAgICJ3aW5nZXQiOiAieE00ZGR5Lk9GR0IiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbFplbkJyb3dzZXIiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5rWP6KeI5ZmoIiwKICAgICJjaG9jbyI6ICJ6ZW4tYnJvd3NlciIsCiAgICAiY29udGVudCI6ICJaZW4g5rWP6KeI5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICLln7rkuo4gRmlyZWZveCDmnoTlu7rnmoTnjrDku6PjgIHms6jph43pmpDnp4HjgIHmgKfog73pqbHliqjnmoTmtY/op4jlmajjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly96ZW4tYnJvd3Nlci5hcHAvIiwKICAgICJ3aW5nZXQiOiAiWmVuLVRlYW0uWmVuLUJyb3dzZXIiLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbFplZCI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogInplZCIsCiAgICAiY29udGVudCI6ICJaZWQg5Luj56CB57yW6L6R5ZmoIiwKICAgICJkZXNjcmlwdGlvbiI6ICJaZWQg5piv5LiA5qy+546w5Luj6auY5oCn6IO95Luj56CB57yW6L6R5Zmo77yM5LuO5aS06K6+6K6h5Lul6L+95rGC6YCf5bqm5ZKM5Y2P5L2c44CCIiwKICAgICJsaW5rIjogImh0dHBzOi8vemVkLmRldi8iLAogICAgIndpbmdldCI6ICJaZWRJbmR1c3RyaWVzLlplZCIsCiAgICAiZm9zcyI6IHRydWUKICB9LAogICJXUEZJbnN0YWxsZGVza2Zsb3ciOiB7CiAgICAiY2F0ZWdvcnkiOiAi5bel5YW357G7IiwKICAgICJjaG9jbyI6ICJkZXNrZmxvdyIsCiAgICAiY29udGVudCI6ICJEZXNrZmxvdyDplK7pvKDlhbHkuqsiLAogICAgImRlc2NyaXB0aW9uIjogIkRlc2tmbG93IOaYr+S4gOasvuWFjei0ueW8gOa6kOeahOi9r+S7tiBLVk3vvIzorqnmgqjlnKjlpJrlj7DorqHnrpfmnLrkuYvpl7TlhbHkuqvplK7nm5jlkozpvKDmoIfjgIIiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL2Rlc2tmbG93L2Rlc2tmbG93IiwKICAgICJ3aW5nZXQiOiAiRGVza2Zsb3cuRGVza2Zsb3ciLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbFJ1YnkiOiB7CiAgICAiY2F0ZWdvcnkiOiAi5byA5Y+R5bel5YW3IiwKICAgICJjaG9jbyI6ICJydWJ5IiwKICAgICJ3aW5nZXQiOiAiUnVieUluc3RhbGxlclRlYW0uUnVieS40LjAiLAogICAgImRlc2NyaXB0aW9uIjogIuWMheWQqyBNU1lTMiDlronoo4XnmoQgUnVieSDor63oqIDmiafooYznjq/looPjgIIiLAogICAgImNvbnRlbnQiOiAiUnVieSDnvJbnqIvor63oqIAiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9ydWJ5aW5zdGFsbGVyLm9yZy8iLAogICAgImZvc3MiOiB0cnVlCiAgfSwKICAiV1BGSW5zdGFsbEx1YSI6IHsKICAgICJjYXRlZ29yeSI6ICLlvIDlj5Hlt6XlhbciLAogICAgImNob2NvIjogImx1YSIsCiAgICAid2luZ2V0IjogInJqcGNvbXB1dGluZy5sdWFmb3J3aW5kb3dzIiwKICAgICJkZXNjcmlwdGlvbiI6ICJMdWEg6ISa5pys6K+t6KiA55qE55S15rGg6b2Q5YWo546v5aKD77yI5ZCr5L6d6LWW5bqT77yJIiwKICAgICJjb250ZW50IjogIkx1YSDohJrmnKzor63oqIAiLAogICAgImxpbmsiOiAiaHR0cHM6Ly9naXRodWIuY29tL3JqcGNvbXB1dGluZy9sdWFmb3J3aW5kb3dzIiwKICAgICJmb3NzIjogdHJ1ZQogIH0KfQ==')) | ConvertFrom-Json

$sync.configs.appnavigation = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJXUEZJbnN0YWxsIjogewogICAgIkNvbnRlbnQiOiAi5a6J6KOFL+WNh+e6p+W6lOeUqCIsCiAgICAiQ2F0ZWdvcnkiOiAi5pON5L2cIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiT3JkZXIiOiAiMSIsCiAgICAiRGVzY3JpcHRpb24iOiAi5a6J6KOF5oiW5Y2H57qn5omA6YCJ5bqU55SoIgogIH0sCiAgIldQRlVuaW5zdGFsbCI6IHsKICAgICJDb250ZW50IjogIuWNuOi9veW6lOeUqCIsCiAgICAiQ2F0ZWdvcnkiOiAi5pON5L2cIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiT3JkZXIiOiAiMiIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Y246L295omA6YCJ5bqU55SoIgogIH0sCiAgIldQRkluc3RhbGxVcGdyYWRlIjogewogICAgIkNvbnRlbnQiOiAi5Y2H57qn5omA5pyJ5bqU55SoIiwKICAgICJDYXRlZ29yeSI6ICLmk43kvZwiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJPcmRlciI6ICIzIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlsIbmiYDmnInlupTnlKjljYfnuqfliLDmnIDmlrDniYjmnKwiCiAgfSwKICAiV2luZ2V0UmFkaW9CdXR0b24iOiB7CiAgICAiQ29udGVudCI6ICJXaW5HZXQg5YyF566h55CG5ZmoIiwKICAgICJDYXRlZ29yeSI6ICLljIXnrqHnkIblmagiLAogICAgIlR5cGUiOiAiUmFkaW9CdXR0b24iLAogICAgIkdyb3VwTmFtZSI6ICJQYWNrYWdlTWFuYWdlckdyb3VwIiwKICAgICJDaGVja2VkIjogdHJ1ZSwKICAgICJPcmRlciI6ICIxIiwKICAgICJEZXNjcmlwdGlvbiI6ICLkvb/nlKggV2luR2V0IOi/m+ihjOWMheeuoeeQhiIKICB9LAogICJDaG9jb1JhZGlvQnV0dG9uIjogewogICAgIkNvbnRlbnQiOiAiQ2hvY29sYXRleSDljIXnrqHnkIblmagiLAogICAgIkNhdGVnb3J5IjogIuWMheeuoeeQhuWZqCIsCiAgICAiVHlwZSI6ICJSYWRpb0J1dHRvbiIsCiAgICAiR3JvdXBOYW1lIjogIlBhY2thZ2VNYW5hZ2VyR3JvdXAiLAogICAgIkNoZWNrZWQiOiBmYWxzZSwKICAgICJPcmRlciI6ICIyIiwKICAgICJEZXNjcmlwdGlvbiI6ICLkvb/nlKggQ2hvY29sYXRleSDov5vooYzljIXnrqHnkIYiCiAgfSwKICAiV1BGQ29sbGFwc2VBbGxDYXRlZ29yaWVzIjogewogICAgIkNvbnRlbnQiOiAi5oqY5Y+g5omA5pyJ5YiG57G7IiwKICAgICJDYXRlZ29yeSI6ICLpgInmi6kiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJPcmRlciI6ICIxIiwKICAgICJEZXNjcmlwdGlvbiI6ICLmipjlj6DmiYDmnInlupTnlKjliIbnsbsiCiAgfSwKICAiV1BGRXhwYW5kQWxsQ2F0ZWdvcmllcyI6IHsKICAgICJDb250ZW50IjogIuWxleW8gOaJgOacieWIhuexuyIsCiAgICAiQ2F0ZWdvcnkiOiAi6YCJ5oupIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiT3JkZXIiOiAiMiIsCiAgICAiRGVzY3JpcHRpb24iOiAi5bGV5byA5omA5pyJ5bqU55So5YiG57G7IgogIH0sCiAgIldQRkNsZWFySW5zdGFsbFNlbGVjdGlvbiI6IHsKICAgICJDb250ZW50IjogIua4hemZpOmAieaLqSIsCiAgICAiQ2F0ZWdvcnkiOiAi6YCJ5oupIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiT3JkZXIiOiAiMyIsCiAgICAiRGVzY3JpcHRpb24iOiAi5riF6Zmk5bqU55So6YCJ5oupIgogIH0sCiAgIldQRkdldEluc3RhbGxlZCI6IHsKICAgICJDb250ZW50IjogIuaYvuekuuW3suWuieijheW6lOeUqCIsCiAgICAiQ2F0ZWdvcnkiOiAi6YCJ5oupIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiT3JkZXIiOiAiNCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5pi+56S65bey5a6J6KOF55qE5bqU55SoIgogIH0sCiAgIldQRnNlbGVjdGVkQXBwc0J1dHRvbiI6IHsKICAgICJDb250ZW50IjogIuW3sumAieW6lOeUqO+8mjAiLAogICAgIkNhdGVnb3J5IjogIumAieaLqSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIk9yZGVyIjogIjUiLAogICAgIkRlc2NyaXB0aW9uIjogIuaYvuekuuW3sumAieeahOW6lOeUqCIKICB9LAogICJXUEZJbnN0YWxsRk9TU0luZm8iOiB7CiAgICAiQ29udGVudCI6ICLlhY3otLnlvIDmupDova/ku7YiLAogICAgIkNhdGVnb3J5IjogIumAieaLqSIsCiAgICAiVHlwZSI6ICJOb3RlIiwKICAgICJPcmRlciI6ICIwIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlhbPkuo7lupTnlKjmnaHnm67kuIogI0ZPU1Mg5qCH562+55qE5L+h5oGvIgogIH0KfQ==')) | ConvertFrom-Json

$sync.configs.appx = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJXUEZBcHB4TWljcm9zb2Z0X1dpbmRvd3NGZWVkYmFja0h1YiI6IHsKICAgICJDYXRlZ29yeSI6ICLlvq7ova/lupTnlKgiLAogICAgIkNvbnRlbnQiOiAi5Y+N6aaI5Lit5b+DIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlhYHorrjnlKjmiLfnm7TmjqXlkJEgTWljcm9zb2Z0IOaPkOS6pOmUmeivr+aKpeWRiuOAgeWKn+iDveW7uuiuruWSjOiviuaWreaVsOaNruOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5XaW5kb3dzRmVlZGJhY2tIdWIiLAogICAgIlN0b3JlSWQiOiAiOU5CTEdHSDRSMzJOIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfR2V0SGVscCI6IHsKICAgICJDYXRlZ29yeSI6ICLlvq7ova/lupTnlKgiLAogICAgIkNvbnRlbnQiOiAi6I635Y+W5biu5YqpIiwKICAgICJEZXNjcmlwdGlvbiI6ICLmj5Dkvpvoh6rliqjmlYXpmpzmjpLpmaTmjIfljZfjgIHmlK/mjIHmlofmoaPlkoznm7TmjqUgTWljcm9zb2Z0IOWuouaIt+WNj+WKqeOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5HZXRIZWxwIiwKICAgICJTdG9yZUlkIjogIjlQS0RaQk1WMUgzVCIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X091dGxvb2tGb3JXaW5kb3dzIjogewogICAgIkNhdGVnb3J5IjogIuW+rui9r+W6lOeUqCIsCiAgICAiQ29udGVudCI6ICJXaW5kb3dzIOeJiCBPdXRsb29rIiwKICAgICJEZXNjcmlwdGlvbiI6ICLmj5DkvpvnjrDku6PnlLXlrZDpgq7ku7bnrqHnkIbjgIHml6XljoblronmjpLlkozogZTns7vkurrnu4Tnu4flip/og73jgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuT3V0bG9va0ZvcldpbmRvd3MiLAogICAgIlN0b3JlSWQiOiAiOU5SWDYzMjA5UjdCIgogIH0sCiAgIldQRkFwcHhNU1RlYW1zIjogewogICAgIkNhdGVnb3J5IjogIuW+rui9r+W6lOeUqCIsCiAgICAiQ29udGVudCI6ICJNaWNyb3NvZnQgVGVhbXMiLAogICAgIkRlc2NyaXB0aW9uIjogIuS/g+i/m+WNs+aXtua2iOaBr+OAgeinhumikeS8muiuruOAgeaWh+S7tuWFseS6q+WSjOW3peS9nOWMuuWNj+S9nOOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1TVGVhbXMiLAogICAgIlN0b3JlSWQiOiAiWFA4QlQ4RFcyOTBNUFEiCiAgfSwKICAiV1BGQXBweENsaXBjaGFtcF9DbGlwY2hhbXAiOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5bel5YW35LiO5pWI546HIiwKICAgICJDb250ZW50IjogIkNsaXBjaGFtcCDop4bpopHnvJbovpHlmagiLAogICAgIkRlc2NyaXB0aW9uIjogIuaPkOS+m+eUqOaIt+WPi+WlveeahOinhumikee8lui+keWZqO+8jOWMheWQq+WGhee9ruaooeadv+OAgeaViOaenOWSjOaXtumXtOe6v+e8lui+keW3peWFt+OAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIkNsaXBjaGFtcC5DbGlwY2hhbXAiLAogICAgIlN0b3JlSWQiOiAiOVAxSjhTN0NDV1dUIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfTWljcm9zb2Z0T2ZmaWNlSHViIjogewogICAgIkNhdGVnb3J5IjogIuW+rui9r+W6lOeUqCIsCiAgICAiQ29udGVudCI6ICJNaWNyb3NvZnQgMzY1IiwKICAgICJEZXNjcmlwdGlvbiI6ICLkvZzkuLrorr/pl67kupHnq68gTWljcm9zb2Z0IDM2NSDlupTnlKjlkozmnIDov5HmlofmoaPnmoTpm4bkuK3lkK/liqjlmajlkozku6rooajmnb/jgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuTWljcm9zb2Z0T2ZmaWNlSHViIiwKICAgICJTdG9yZUlkIjogIjlXWkROQ1JEMjlWOSIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1p1bmVNdXNpYyI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi5aqS5L2T5pKt5pS+5ZmoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLmkq3mlL7mnKzlnLDpn7PpopHlkozop4bpopHmlofku7bvvIzlhbfmnInnjrDku6Pmkq3mlL7liJfooajnrqHnkIblkozmipXlsITlip/og73jgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuWnVuZU11c2ljIiwKICAgICJTdG9yZUlkIjogIjlXWkROQ1JGSjNQVCIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X0JpbmdTZWFyY2giOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5b+F5bqU5LiO572R57uc5pyN5YqhIiwKICAgICJDb250ZW50IjogIuW/heW6lOaQnOe0oiIsCiAgICAiRGVzY3JpcHRpb24iOiAi5bCGIE1pY3Jvc29mdCBCaW5nIOaQnOe0ouWKn+iDveWSjOe9kee7nOacjeWKoeebtOaOpembhuaIkOWIsOaTjeS9nOezu+e7n+S4reOAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5CaW5nU2VhcmNoIiwKICAgICJTdG9yZUlkIjogIjlOWkJGNEdUMDQwQyIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0Q29ycG9yYXRpb25JSV9RdWlja0Fzc2lzdCI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi5b+r6YCf5Y2P5YqpIiwKICAgICJEZXNjcmlwdGlvbiI6ICLpgJrov4fkupLogZTnvZHov57mjqXlkK/nlKjlronlhajnmoTov5znqIvmioDmnK/mlK/mjIHlkozlsY/luZXlhbHkuqvjgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnRDb3Jwb3JhdGlvbklJLlF1aWNrQXNzaXN0IiwKICAgICJTdG9yZUlkIjogIjlQN0JQNVZOV0tYNSIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1dpbmRvd3NEZXZIb21lIjogewogICAgIkNhdGVnb3J5IjogIuW8gOWPkeiAheW3peWFtyIsCiAgICAiQ29udGVudCI6ICLlvIDlj5HkurrlkZjkuLvpobUiLAogICAgIkRlc2NyaXB0aW9uIjogIuS4uui9r+S7tuW8gOWPkeS6uuWRmOaPkOS+m+eOr+Wig+iuvue9ruOAgeS7o+eggeS7k+W6k+WQjOatpeWSjOehrOS7tuWwj+W3peWFt+eahOS4k+eUqOS7quihqOadv+OAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5XaW5kb3dzLkRldkhvbWUiLAogICAgIlN0b3JlSWQiOiAiOU44TUhUUEhOR1ZWIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfV2luZG93c0Nyb3NzRGV2aWNlIjogewogICAgIkNhdGVnb3J5IjogIuW+rui9r+eUn+aAgeezu+e7nyIsCiAgICAiQ29udGVudCI6ICLnp7vliqjorr7lpIciLAogICAgIkRlc2NyaXB0aW9uIjogIueuoeeQhuS4jumFjeWvueenu+WKqOiuvuWkh+eahOezu+e7n+e6p+WQjuWPsOi/nuaOpSIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdFdpbmRvd3MuQ3Jvc3NEZXZpY2UiLAogICAgIlN0b3JlSWQiOiAiOU5UWEdLUThQN04wIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfVG9kb3MiOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5bel5YW35LiO5pWI546HIiwKICAgICJDb250ZW50IjogIuW+heWKnuS6i+mhuSIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Yib5bu644CB6Lef6Liq5ZKM5ZCM5q2l5Liq5Lq65Lu75Yqh44CB5pm66IO95YiX6KGo5ZKM5q+P5pel5o+Q6YaS44CCIiwKICAgICJQYW5lbCI6ICIwIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LlRvZG9zIiwKICAgICJTdG9yZUlkIjogIjlOQkxHR0g1UjU1OCIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1Bvd2VyQXV0b21hdGVEZXNrdG9wIjogewogICAgIkNhdGVnb3J5IjogIuW8gOWPkeiAheW3peWFtyIsCiAgICAiQ29udGVudCI6ICJQb3dlciBBdXRvbWF0ZSIsCiAgICAiRGVzY3JpcHRpb24iOiAi5L2/55So5L2O5Luj56CB5Y+v6KeG5YyW6ISa5pys6Ieq5Yqo5omn6KGM6YeN5aSN5oCn5bel5L2c5rWB5ZKM5qGM6Z2i5Lu75Yqh44CCIiwKICAgICJQYW5lbCI6ICIxIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LlBvd2VyQXV0b21hdGVEZXNrdG9wIiwKICAgICJTdG9yZUlkIjogIjlORlRDSDZKN0ZIViIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1lvdXJQaG9uZSI6IHsKICAgICJDYXRlZ29yeSI6ICLlvq7ova/nlJ/mgIHns7vnu58iLAogICAgIkNvbnRlbnQiOiAi5omL5py66L+e5o6lIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlsIbnn63kv6HjgIHmiYvmnLrpgJrnn6XjgIHnhafniYflkozpgJror53ku47np7vliqjorr7lpIflkIzmraXliLDmoYzpnaLjgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuWW91clBob25lIiwKICAgICJTdG9yZUlkIjogIjlOTVBKOTlWSkJXViIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X01pY3Jvc29mdFN0aWNreU5vdGVzIjogewogICAgIkNhdGVnb3J5IjogIuW3peWFt+S4juaViOeOhyIsCiAgICAiQ29udGVudCI6ICLkvr/nrLoiLAogICAgIkRlc2NyaXB0aW9uIjogIuWcqOahjOmdouS4iuWIm+W7uuW/q+mAn+a1ruWKqOaWh+acrOeslOiusO+8jOW5tuiHquWKqOi3qOiuvuWkh+WQjOatpeOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5NaWNyb3NvZnRTdGlja3lOb3RlcyIsCiAgICAiU3RvcmVJZCI6ICI5TkJMR0dINFFHSFciCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9XaW5kb3dzU291bmRSZWNvcmRlciI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi5b2V6Z+z5py6IiwKICAgICJEZXNjcmlwdGlvbiI6ICLkvb/nlKjnroDljZXnmoTpuqblhYvpo47osIPoioLmjqfku7blvZXliLblkozkv67liarlrp7ml7bpn7PpopHovpPlhaXjgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuV2luZG93c1NvdW5kUmVjb3JkZXIiLAogICAgIlN0b3JlSWQiOiAiOVdaRE5DUkZIV0tOIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfV2luZG93c0FsYXJtcyI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi5pe26ZKfIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlhbfmnInkuJbnlYzml7bpkp/jgIHpl7npkp/jgIHlgJLorqHml7bjgIHnp5LooajlkozkuJPms6jkvJror53ot5/ouKrlip/og73jgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuV2luZG93c0FsYXJtcyIsCiAgICAiU3RvcmVJZCI6ICI5V1pETkNSRkozUFIiCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9QYWludCI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi55S75Zu+IiwKICAgICJEZXNjcmlwdGlvbiI6ICLmj5DkvpvlhoXnva7nmoTmlbDlrZfntKDmj4/jgIHln7rmnKzlm77lg4/nvJbovpHlkozlg4/ntKDnuqflm77lvaLmk43kvZzlt6XlhbfjgIIiLAogICAgIlBhbmVsIjogIjAiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuUGFpbnQiLAogICAgIlN0b3JlSWQiOiAiOVBDRlM1QjZUNzJIIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfV2luZG93c05vdGVwYWQiOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5bel5YW35LiO5pWI546HIiwKICAgICJDb250ZW50IjogIuiusOS6i+acrCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5o+Q5L6b6L276YeP57qn5paH5pys57yW6L6R5Zmo77yM5pSv5oyB5aSa5qCH562+6aG15aSE55CG57qv5paH5pys5paH5Lu25ZKM5Luj56CB54mH5q6144CCIiwKICAgICJQYW5lbCI6ICIwIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LldpbmRvd3NOb3RlcGFkIiwKICAgICJTdG9yZUlkIjogIjlNU01MUkg2TFpGMyIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1NjcmVlblNrZXRjaCI6IHsKICAgICJDYXRlZ29yeSI6ICLlt6XlhbfkuI7mlYjnjociLAogICAgIkNvbnRlbnQiOiAi5oiq5Zu+5bel5YW3IiwKICAgICJEZXNjcmlwdGlvbiI6ICLmjZXojrfmiKrlm77miJblsY/luZXlvZXliLbvvIzlhbfmnInlhoXnva7moIforrDjgIHlm77lg4/oo4HliarlkozlhYnlrablrZfnrKbor4bliKsgKE9DUikg5Yqf6IO944CCIiwKICAgICJQYW5lbCI6ICIwIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LlNjcmVlblNrZXRjaCIsCiAgICAiU3RvcmVJZCI6ICI5TVo5NUtMOE1SMEwiCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9Db3BpbG90IjogewogICAgIkNhdGVnb3J5IjogIuW/heW6lOS4jue9kee7nOacjeWKoSIsCiAgICAiQ29udGVudCI6ICJDb3BpbG90IiwKICAgICJEZXNjcmlwdGlvbiI6ICLlkK/liqggTWljcm9zb2Z0IEFJIOS8tOS+o++8jOaPkOS+m+S4iuS4i+aWh+etlOahiOOAgeWIm+aEj+WGmeS9nOi+heWKqeWSjOaZuuiDvee9kemhteaQnOe0ouOAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5Db3BpbG90IiwKICAgICJTdG9yZUlkIjogIjlOSFQ5UkIyRjRIRCIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1dpbmRvd3NDYWxjdWxhdG9yIjogewogICAgIkNhdGVnb3J5IjogIuW3peWFt+S4juaViOeOhyIsCiAgICAiQ29udGVudCI6ICLorqHnrpflmagiLAogICAgIkRlc2NyaXB0aW9uIjogIuaJp+ihjOagh+WHhueul+acr+OAgeenkeWtpui/kOeul+OAgee8lueoi+iuoeeul+WSjOWNleS9jei9rOaNouOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5XaW5kb3dzQ2FsY3VsYXRvciIsCiAgICAiU3RvcmVJZCI6ICI5V1pETkNSRkhWTjUiCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9XaW5kb3dzQ2FtZXJhIjogewogICAgIkNhdGVnb3J5IjogIuW3peWFt+S4juaViOeOhyIsCiAgICAiQ29udGVudCI6ICLnm7jmnLoiLAogICAgIkRlc2NyaXB0aW9uIjogIumAmui/h+i/nuaOpeeahOaRhOWDj+WktOaIluaIkOWDj+ehrOS7tuaNleiOt+eFp+eJh+WSjOW9leWItuinhumikeaWh+S7tuOAgiIsCiAgICAiUGFuZWwiOiAiMCIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5XaW5kb3dzQ2FtZXJhIiwKICAgICJTdG9yZUlkIjogIjlXWkROQ1JGSkJCRyIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1dpbmRvd3NQaG90b3MiOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5bel5YW35LiO5pWI546HIiwKICAgICJDb250ZW50IjogIuebuOWGjCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5pW055CG44CB5p+l55yL5ZKM6KOB5Ymq5pys5Zyw5Zu+5YOP77yM5YW35pyJ5Z+65pys6aKc6Imy6LCD5pW05ZKM55u45YaM5Yib5bu65bel5YW344CCIiwKICAgICJQYW5lbCI6ICIwIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LldpbmRvd3MuUGhvdG9zIiwKICAgICJTdG9yZUlkIjogIjlXWkROQ1JGSkJINCIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X0JpbmdOZXdzIjogewogICAgIkNhdGVnb3J5IjogIuW/heW6lOS4jue9kee7nOacjeWKoSIsCiAgICAiQ29udGVudCI6ICLmlrDpl7siLAogICAgIkRlc2NyaXB0aW9uIjogIuiBmuWQiOeqgeWPkeaWsOmXu+agh+mimOOAgeS4quaAp+WMluaWh+eroOaOqOmAgeWSjOS4lueVjOaXtuS6i+OAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5CaW5nTmV3cyIsCiAgICAiU3RvcmVJZCI6ICI5V1pETkNSRkhWRlciCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9CaW5nV2VhdGhlciI6IHsKICAgICJDYXRlZ29yeSI6ICLlv4XlupTkuI7nvZHnu5zmnI3liqEiLAogICAgIkNvbnRlbnQiOiAi5aSp5rCUIiwKICAgICJEZXNjcmlwdGlvbiI6ICLmmL7npLrmnKzlnLDlrp7ml7blpKnmsJTot5/ouKrjgIHpm7fovr7lnLDlm77lkozljoblj7LmsJTosaHpooTmiqXjgIIiLAogICAgIlBhbmVsIjogIjEiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuQmluZ1dlYXRoZXIiLAogICAgIlN0b3JlSWQiOiAiOVdaRE5DUkZKM1EyIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfR2FtaW5nQXBwIjogewogICAgIkNhdGVnb3J5IjogIlhib3jkuI7muLjmiI8iLAogICAgIkNvbnRlbnQiOiAiWGJveCDlupTnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuS9nOS4uuS4u+imgea4uOaIj+W6k+euoeeQhuWZqOOAgeekvuS6pOekvuWMuueVjOmdouWSjCBQQyBHYW1lIFBhc3Mg5Luq6KGo5p2/44CCIiwKICAgICJQYW5lbCI6ICIxIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LkdhbWluZ0FwcCIsCiAgICAiU3RvcmVJZCI6ICI5TVYwQjVIWlZLOVoiCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9YYm94R2FtaW5nT3ZlcmxheSI6IHsKICAgICJDYXRlZ29yeSI6ICJYYm945LiO5ri45oiPIiwKICAgICJDb250ZW50IjogIlhib3ggR2FtZSBCYXIiLAogICAgIkRlc2NyaXB0aW9uIjogIuaPkOS+m+WPr+iHquWumuS5ieeahOa4uOaIj+WGheeKtuaAgeWwj+W3peWFt+OAgemfs+mikeW5s+ihoea7keWdl+OAgeezu+e7n+ebkeaOp+W3peWFt+WSjOa4uOaIj+W9leWItuOAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5YYm94R2FtaW5nT3ZlcmxheSIsCiAgICAiU3RvcmVJZCI6ICI5TlpLUFNUU05XNFAiCiAgfSwKICAiV1BGQXBweE1pY3Jvc29mdF9YYm94SWRlbnRpdHlQcm92aWRlciI6IHsKICAgICJDYXRlZ29yeSI6ICJYYm945LiO5ri45oiPIiwKICAgICJDb250ZW50IjogIlhib3gg6Lqr5Lu95o+Q5L6b56iL5bqPIiwKICAgICJEZXNjcmlwdGlvbiI6ICLnrqHnkIYgWGJveCDnvZHnu5znlKjmiLforqTor4HlkozlkI7lj7DotKbmiLforr/pl64iLAogICAgIlBhbmVsIjogIjEiLAogICAgIlBhY2thZ2VJZCI6ICJNaWNyb3NvZnQuWGJveElkZW50aXR5UHJvdmlkZXIiLAogICAgIlN0b3JlSWQiOiAiOVdaRE5DUkQxSEtXIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfWGJveFNwZWVjaFRvVGV4dE92ZXJsYXkiOiB7CiAgICAiQ2F0ZWdvcnkiOiAiWGJveOS4jua4uOaIjyIsCiAgICAiQ29udGVudCI6ICJYYm94IOivremfs+i9rOaWh+Wtl+imhuebliIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Li65ri45oiP6IGK5aSp572R57uc5o+Q5L6b57O757uf57qn5a6e5pe26L6F5Yqp5a2X5bmV5ZKM6K+t6Z+z6L2s5paH5a2X57+76K+R44CCIiwKICAgICJQYW5lbCI6ICIxIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0Llhib3hTcGVlY2hUb1RleHRPdmVybGF5IgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfWGJveF9UQ1VJIjogewogICAgIkNhdGVnb3J5IjogIlhib3jkuI7muLjmiI8iLAogICAgIkNvbnRlbnQiOiAiWGJveCBUQ1VJIiwKICAgICJEZXNjcmlwdGlvbiI6ICLkuLogWGJveCDmj5DkvpvmoLjlv4PotKbmiLfov57mjqUgVUkg5qih5Z2XIiwKICAgICJQYW5lbCI6ICIxIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0Llhib3guVENVSSIKICB9LAogICJXUEZBcHB4TWljcm9zb2Z0X1N0YXJ0RXhwZXJpZW5jZXNBcHAiOiB7CiAgICAiQ2F0ZWdvcnkiOiAi5b+F5bqU5LiO572R57uc5pyN5YqhIiwKICAgICJDb250ZW50IjogIuW8gOWni+S9k+mqjOW6lOeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi6amx5YqoIFdpbmRvd3Mg5bCP57uE5Lu26Z2i5p2/77yM5o+Q5L6b5paw6Ze744CB5aSp5rCU44CB5L2T6IKy5ZKM6LSi57uP5YaF5a6555qE5Liq5oCn5YyW5o6o6YCB44CCIiwKICAgICJQYW5lbCI6ICIxIiwKICAgICJQYWNrYWdlSWQiOiAiTWljcm9zb2Z0LlN0YXJ0RXhwZXJpZW5jZXNBcHAiLAogICAgIlN0b3JlSWQiOiAiOVBDMUg5Vk4xOENNIgogIH0sCiAgIldQRkFwcHhNaWNyb3NvZnRfTWljcm9zb2Z0U29saXRhaXJlQ29sbGVjdGlvbiI6IHsKICAgICJDYXRlZ29yeSI6ICJYYm945LiO5ri45oiPIiwKICAgICJDb250ZW50IjogIue6uOeJjOa4uOaIj+WQiOmbhiIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YyF5ZCr5YaF572u57q454mM5ri45oiP5qih5byP77yM5YyF5ousIEtsb25kaWtl44CBU3BpZGVy44CBRnJlZUNlbGzjgIFQeXJhbWlkIOWSjCBUcmlQZWFrc+OAgiIsCiAgICAiUGFuZWwiOiAiMSIsCiAgICAiUGFja2FnZUlkIjogIk1pY3Jvc29mdC5NaWNyb3NvZnRTb2xpdGFpcmVDb2xsZWN0aW9uIgogIH0KfQ==')) | ConvertFrom-Json

$sync.configs.dns = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJHb29nbGUiOiB7CiAgICAiUHJpbWFyeSI6ICI4LjguOC44IiwKICAgICJTZWNvbmRhcnkiOiAiOC44LjQuNCIsCiAgICAiUHJpbWFyeTYiOiAiMjAwMTo0ODYwOjQ4NjA6Ojg4ODgiLAogICAgIlNlY29uZGFyeTYiOiAiMjAwMTo0ODYwOjQ4NjA6Ojg4NDQiCiAgfSwKICAiQ2xvdWRmbGFyZSI6IHsKICAgICJQcmltYXJ5IjogIjEuMS4xLjEiLAogICAgIlNlY29uZGFyeSI6ICIxLjAuMC4xIiwKICAgICJQcmltYXJ5NiI6ICIyNjA2OjQ3MDA6NDcwMDo6MTExMSIsCiAgICAiU2Vjb25kYXJ5NiI6ICIyNjA2OjQ3MDA6NDcwMDo6MTAwMSIKICB9LAogICJDbG91ZGZsYXJlX01hbHdhcmUiOiB7CiAgICAiUHJpbWFyeSI6ICIxLjEuMS4yIiwKICAgICJTZWNvbmRhcnkiOiAiMS4wLjAuMiIsCiAgICAiUHJpbWFyeTYiOiAiMjYwNjo0NzAwOjQ3MDA6OjExMTIiLAogICAgIlNlY29uZGFyeTYiOiAiMjYwNjo0NzAwOjQ3MDA6OjEwMDIiCiAgfSwKICAiQ2xvdWRmbGFyZV9NYWx3YXJlX0FkdWx0IjogewogICAgIlByaW1hcnkiOiAiMS4xLjEuMyIsCiAgICAiU2Vjb25kYXJ5IjogIjEuMC4wLjMiLAogICAgIlByaW1hcnk2IjogIjI2MDY6NDcwMDo0NzAwOjoxMTEzIiwKICAgICJTZWNvbmRhcnk2IjogIjI2MDY6NDcwMDo0NzAwOjoxMDAzIgogIH0sCiAgIk9wZW5fRE5TIjogewogICAgIlByaW1hcnkiOiAiMjA4LjY3LjIyMi4yMjIiLAogICAgIlNlY29uZGFyeSI6ICIyMDguNjcuMjIwLjIyMCIsCiAgICAiUHJpbWFyeTYiOiAiMjYyMDoxMTk6MzU6OjM1IiwKICAgICJTZWNvbmRhcnk2IjogIjI2MjA6MTE5OjUzOjo1MyIKICB9LAogICJRdWFkOSI6IHsKICAgICJQcmltYXJ5IjogIjkuOS45LjkiLAogICAgIlNlY29uZGFyeSI6ICIxNDkuMTEyLjExMi4xMTIiLAogICAgIlByaW1hcnk2IjogIjI2MjA6ZmU6OmZlIiwKICAgICJTZWNvbmRhcnk2IjogIjI2MjA6ZmU6OjkiCiAgfSwKICAiQWRHdWFyZF9BZHNfVHJhY2tlcnMiOiB7CiAgICAiUHJpbWFyeSI6ICI5NC4xNDAuMTQuMTQiLAogICAgIlNlY29uZGFyeSI6ICI5NC4xNDAuMTUuMTUiLAogICAgIlByaW1hcnk2IjogIjJhMTA6NTBjMDo6YWQxOmZmIiwKICAgICJTZWNvbmRhcnk2IjogIjJhMTA6NTBjMDo6YWQyOmZmIgogIH0sCiAgIkFkR3VhcmRfQWRzX1RyYWNrZXJzX01hbHdhcmVfQWR1bHQiOiB7CiAgICAiUHJpbWFyeSI6ICI5NC4xNDAuMTQuMTUiLAogICAgIlNlY29uZGFyeSI6ICI5NC4xNDAuMTUuMTYiLAogICAgIlByaW1hcnk2IjogIjJhMTA6NTBjMDo6YmFkMTpmZiIsCiAgICAiU2Vjb25kYXJ5NiI6ICIyYTEwOjUwYzA6OmJhZDI6ZmYiCiAgfQp9')) | ConvertFrom-Json

$sync.configs.feature = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJXUEZGZWF0dXJlc2RvdG5ldCI6IHsKICAgICJDb250ZW50IjogIi5ORVQgRnJhbWV3b3JrICgy44CBM+OAgTQg54mIKSAtIOWQr+eUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAiLk5FVCDlkowgLk5FVCBGcmFtZXdvcmsg5piv5LiA5Liq5byA5Y+R6ICF5bmz5Y+w77yM55Sx5bel5YW344CB57yW56iL6K+t6KiA5ZKM5bqT57uE5oiQ44CCIiwKICAgICJjYXRlZ29yeSI6ICLlip/og70iLAogICAgInBhbmVsIjogIjEiLAogICAgImZlYXR1cmUiOiBbCiAgICAgICJOZXRGeDQtQWR2U3J2cyIsCiAgICAgICJOZXRGeDMiCiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFtdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9mZWF0dXJlcy9kb3RuZXQiCiAgfSwKICAiV1BGRml4ZXNOVFBQb29sIjogewogICAgIkNvbnRlbnQiOiAiTlRQIOacjeWKoeWZqCAtIOWQr+eUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5bCG6buY6K6kIFdpbmRvd3MgTlRQIOacjeWKoeWZqOabv+aNouS4uiBwb29sLm50cC5vcmfvvIzku6Xmj5Dpq5jml7bpl7TlkIzmraXnmoTlh4bnoa7mgKflkozlj6/pnaDmgKfjgIIiLAogICAgImNhdGVnb3J5IjogIuS/ruWkjSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRkZpeGVzTlRQUG9vbCIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2ZpeGVzL250cHBvb2wiCiAgfSwKICAiV1BGRmVhdHVyZXNoeXBlcnYiOiB7CiAgICAiQ29udGVudCI6ICJIeXBlci1WIC0g5ZCv55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICJIeXBlci1WIOaYryBNaWNyb3NvZnQg5byA5Y+R55qE56Gs5Lu26Jma5ouf5YyW5Lqn5ZOB77yM5YWB6K6455So5oi35Yib5bu65ZKM566h55CG6Jma5ouf5py644CCIiwKICAgICJjYXRlZ29yeSI6ICLlip/og70iLAogICAgInBhbmVsIjogIjEiLAogICAgImZlYXR1cmUiOiBbCiAgICAgICJNaWNyb3NvZnQtSHlwZXItVi1BbGwiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9mZWF0dXJlcy9oeXBlcnYiCiAgfSwKICAiV1BGRmVhdHVyZXNsZWdhY3ltZWRpYSI6IHsKICAgICJDb250ZW50IjogIuaXp+eJiOWqkuS9k+e7hOS7tiAoV01Q44CBRGlyZWN0UGxheSkgLSDlkK/nlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuWQr+eUqOadpeiHquaXp+eJiCBXaW5kb3dzIOeahOaXp+eJiOeoi+W6j+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Yqf6IO9IiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJmZWF0dXJlIjogWwogICAgICAiV2luZG93c01lZGlhUGxheWVyIiwKICAgICAgIk1lZGlhUGxheWJhY2siLAogICAgICAiRGlyZWN0UGxheSIsCiAgICAgICJMZWdhY3lDb21wb25lbnRzIgogICAgXSwKICAgICJJbnZva2VTY3JpcHQiOiBbXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZmVhdHVyZXMvbGVnYWN5bWVkaWEiCiAgfSwKICAiV1BGRmVhdHVyZXdzbCI6IHsKICAgICJDb250ZW50IjogIldpbmRvd3MgTGludXgg5a2Q57O757ufIChXU0wpIC0g5ZCv55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICJXaW5kb3dzIExpbnV4IOWtkOezu+e7n+aYryBXaW5kb3dzIOeahOWPr+mAieWKn+iDve+8jOWFgeiuuCBMaW51eCDnqIvluo/lnKggV2luZG93cyDkuIrljp/nlJ/ov5DooYzjgIIiLAogICAgImNhdGVnb3J5IjogIuWKn+iDvSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiZmVhdHVyZSI6IFsKICAgICAgIlZpcnR1YWxNYWNoaW5lUGxhdGZvcm0iLAogICAgICAiTWljcm9zb2Z0LVdpbmRvd3MtU3Vic3lzdGVtLUxpbnV4IgogICAgXSwKICAgICJJbnZva2VTY3JpcHQiOiBbXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZmVhdHVyZXMvd3NsIgogIH0sCiAgIldQRkZlYXR1cmVuZnMiOiB7CiAgICAiQ29udGVudCI6ICLnvZHnu5zmlofku7bns7vnu58gKE5GUykgLSDlkK/nlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIue9kee7nOaWh+S7tuezu+e7nyAoTkZTKSDmmK/kuIDnp43lnKjnvZHnu5zkuK3lrZjlgqjmlofku7bnmoTmnLrliLbjgIIiLAogICAgImNhdGVnb3J5IjogIuWKn+iDvSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiZmVhdHVyZSI6IFsKICAgICAgIlNlcnZpY2VzRm9yTkZTLUNsaWVudE9ubHkiLAogICAgICAiQ2xpZW50Rm9yTkZTLUluZnJhc3RydWN0dXJlIiwKICAgICAgIk5GUy1BZG1pbmlzdHJhdGlvbiIKICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAibmZzYWRtaW4gY2xpZW50IHN0b3AiLAogICAgICAiU2V0LUl0ZW1Qcm9wZXJ0eSAtUGF0aCAnSEtMTTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXENsaWVudEZvck5GU1xcQ3VycmVudFZlcnNpb25cXERlZmF1bHQnIC1OYW1lICdBbm9ueW1vdXNVSUQnIC1UeXBlIERXb3JkIC1WYWx1ZSAwIiwKICAgICAgIlNldC1JdGVtUHJvcGVydHkgLVBhdGggJ0hLTE06XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxDbGllbnRGb3JORlNcXEN1cnJlbnRWZXJzaW9uXFxEZWZhdWx0JyAtTmFtZSAnQW5vbnltb3VzR0lEJyAtVHlwZSBEV29yZCAtVmFsdWUgMCIsCiAgICAgICJuZnNhZG1pbiBjbGllbnQgc3RhcnQiLAogICAgICAibmZzYWRtaW4gY2xpZW50IGxvY2FsaG9zdCBjb25maWcgZmlsZWFjY2Vzcz03NTUgU2VjRmxhdm9ycz0rc3lzIC1rcmI1IC1rcmI1aSIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2ZlYXR1cmVzL25mcyIKICB9LAogICJXUEZGZWF0dXJlUmVnQmFja3VwIjogewogICAgIkNvbnRlbnQiOiAi5rOo5YaM6KGo5aSH5Lu9ICjmr4/ml6Xlh4zmmaggMTI6MzAg5Lu75YqhKSAtIOWQr+eUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5ZCv55So5q+P5pel5rOo5YaM6KGo5aSH5Lu977yM5q2k5Yqf6IO95ZyoIFdpbmRvd3MgMTAgMTgwMyDkuK3ooqsgTWljcm9zb2Z0IOemgeeUqOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Yqf6IO9IiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJmZWF0dXJlIjogW10sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgTmV3LUl0ZW1Qcm9wZXJ0eSAtUGF0aCAnSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXENvbnRyb2xcXFNlc3Npb24gTWFuYWdlclxcQ29uZmlndXJhdGlvbiBNYW5hZ2VyJyAtTmFtZSAnRW5hYmxlUGVyaW9kaWNCYWNrdXAnIC1UeXBlIERXb3JkIC1WYWx1ZSAxIC1Gb3JjZSAgICAgIE5ldy1JdGVtUHJvcGVydHkgLVBhdGggJ0hLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxTZXNzaW9uIE1hbmFnZXJcXENvbmZpZ3VyYXRpb24gTWFuYWdlcicgLU5hbWUgJ0JhY2t1cENvdW50JyAtVHlwZSBEV29yZCAtVmFsdWUgMiAtRm9yY2UgICAgICAkYWN0aW9uID0gTmV3LVNjaGVkdWxlZFRhc2tBY3Rpb24gLUV4ZWN1dGUgJ3NjaHRhc2tzJyAtQXJndW1lbnQgJy9ydW4gL2kgL3RuIFwiXFxNaWNyb3NvZnRcXFdpbmRvd3NcXFJlZ2lzdHJ5XFxSZWdJZGxlQmFja3VwXCInICAgICAgJHRyaWdnZXIgPSBOZXctU2NoZWR1bGVkVGFza1RyaWdnZXIgLURhaWx5IC1BdCAwMDozMCAgICAgIFJlZ2lzdGVyLVNjaGVkdWxlZFRhc2sgLUFjdGlvbiAkYWN0aW9uIC1UcmlnZ2VyICR0cmlnZ2VyIC1UYXNrTmFtZSAnQXV0b1JlZ0JhY2t1cCcgLURlc2NyaXB0aW9uICdDcmVhdGUgU3lzdGVtIFJlZ2lzdHJ5IEJhY2t1cHMnIC1Vc2VyICdTeXN0ZW0nICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZmVhdHVyZXMvcmVnYmFja3VwIgogIH0sCiAgIldQRkZlYXR1cmVFbmFibGVMZWdhY3lSZWNvdmVyeSI6IHsKICAgICJDb250ZW50IjogIuaXp+eJiCBGOCDlkK/liqjmgaLlpI0gLSDlkK/nlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuWQr+eUqOmrmOe6p+WQr+WKqOmAiemhueWxj+W5le+8jOiuqeaCqOS9v+eUqOmrmOe6p+aVhemanOaOkumZpOaooeW8j+WQr+WKqCBXaW5kb3dz44CCIiwKICAgICJjYXRlZ29yeSI6ICLlip/og70iLAogICAgInBhbmVsIjogIjEiLAogICAgImZlYXR1cmUiOiBbXSwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJiY2RlZGl0IC9zZXQgYm9vdG1lbnVwb2xpY3kgbGVnYWN5IgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZmVhdHVyZXMvZW5hYmxlbGVnYWN5cmVjb3ZlcnkiCiAgfSwKICAiV1BGRmVhdHVyZURpc2FibGVMZWdhY3lSZWNvdmVyeSI6IHsKICAgICJDb250ZW50IjogIuaXp+eJiCBGOCDlkK/liqjmgaLlpI0gLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqOWFgeiuuOaCqOS9v+eUqOmrmOe6p+aVhemanOaOkumZpOaooeW8j+WQr+WKqCBXaW5kb3dzIOeahOmrmOe6p+WQr+WKqOmAiemhueWxj+W5leOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Yqf6IO9IiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJmZWF0dXJlIjogW10sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiYmNkZWRpdCAvc2V0IGJvb3RtZW51cG9saWN5IHN0YW5kYXJkIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZmVhdHVyZXMvZGlzYWJsZWxlZ2FjeXJlY292ZXJ5IgogIH0sCiAgIldQRkZlYXR1cmVzU2FuZGJveCI6IHsKICAgICJDb250ZW50IjogIldpbmRvd3Mg5rKZ55uSIC0g5ZCv55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICJXaW5kb3dzIOaymeebkuaYr+S4gOS4qui9u+mHj+e6p+iZmuaLn+acuu+8jOaPkOS+m+S4tOaXtueahOahjOmdoueOr+Wig+S7peWuieWFqOmalOemu+WcsOi/kOihjOW6lOeUqOeoi+W6j+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Yqf6IO9IiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJmZWF0dXJlIjogWwogICAgICAiQ29udGFpbmVycy1EaXNwb3NhYmxlQ2xpZW50Vk0iCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9mZWF0dXJlcy9zYW5kYm94IgogIH0sCiAgIldQRkZlYXR1cmVJbnN0YWxsIjogewogICAgIkNvbnRlbnQiOiAi5a6J6KOF5Yqf6IO9IiwKICAgICJjYXRlZ29yeSI6ICLlip/og70iLAogICAgInBhbmVsIjogIjEiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJCdXR0b25XaWR0aCI6ICIzMDAiLAogICAgImZ1bmN0aW9uIjogIkludm9rZS1XUEZGZWF0dXJlSW5zdGFsbCIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2ZlYXR1cmVzL2luc3RhbGwiCiAgfSwKICAiV1BGUGFuZWxBdXRvbG9naW4iOiB7CiAgICAiQ29udGVudCI6ICLoh6rliqjnmbvlvZUgLSDov5DooYwiLAogICAgImNhdGVnb3J5IjogIuS/ruWkjSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRlBhbmVsQXV0b2xvZ2luIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZml4ZXMvYXV0b2xvZ2luIgogIH0sCiAgIldQRkZpeGVzVXBkYXRlIjogewogICAgIkNvbnRlbnQiOiAiV2luZG93cyDmm7TmlrAgLSDph43nva4iLAogICAgImNhdGVnb3J5IjogIuS/ruWkjSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRkZpeGVzVXBkYXRlIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZml4ZXMvdXBkYXRlIgogIH0sCiAgIldQRkZpeGVzTmV0d29yayI6IHsKICAgICJDb250ZW50IjogIue9kee7nCAtIOmHjee9riIsCiAgICAiY2F0ZWdvcnkiOiAi5L+u5aSNIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiQnV0dG9uV2lkdGgiOiAiMzAwIiwKICAgICJmdW5jdGlvbiI6ICJJbnZva2UtV1BGRml4ZXNOZXR3b3JrIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZml4ZXMvbmV0d29yayIKICB9LAogICJXUEZQYW5lbERJU00iOiB7CiAgICAiQ29udGVudCI6ICLns7vnu5/mjZ/lnY/miavmj48gLSDov5DooYwiLAogICAgImNhdGVnb3J5IjogIuS/ruWkjSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRlN5c3RlbVJlcGFpciIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2ZpeGVzL2Rpc20iCiAgfSwKICAiV1BGRml4ZXNXaW5nZXQiOiB7CiAgICAiQ29udGVudCI6ICJXaW5HZXQgLSDph43mlrDlronoo4UiLAogICAgImNhdGVnb3J5IjogIuS/ruWkjSIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRkZpeGVzV2luZ2V0IiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvZml4ZXMvd2luZ2V0IgogIH0sCiAgIldQRlBhbmVsQ29tcHV0ZXIiOiB7CiAgICAiQ29udGVudCI6ICLorqHnrpfmnLrnrqHnkIYiLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiY29tcG1nbXQubXNjIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvbGVnYWN5LXdpbmRvd3MtcGFuZWxzL2NvbXB1dGVyIgogIH0sCiAgIldQRlBhbmVsQ29udHJvbCI6IHsKICAgICJDb250ZW50IjogIuaOp+WItumdouadvyIsCiAgICAiY2F0ZWdvcnkiOiAi5Lyg57ufIFdpbmRvd3Mg6Z2i5p2/IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiQnV0dG9uV2lkdGgiOiAiMzAwIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJjb250cm9sIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvbGVnYWN5LXdpbmRvd3MtcGFuZWxzL2NvbnRyb2wiCiAgfSwKICAiV1BGUGFuZWxNb3VzZSI6IHsKICAgICJDb250ZW50IjogIum8oOagh+WxnuaApyIsCiAgICAiY2F0ZWdvcnkiOiAi5Lyg57ufIFdpbmRvd3Mg6Z2i5p2/IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiQnV0dG9uV2lkdGgiOiAiMzAwIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJtYWluLmNwbCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2xlZ2FjeS13aW5kb3dzLXBhbmVscy9tb3VzZSIKICB9LAogICJXUEZQYW5lbE5ldHdvcmsiOiB7CiAgICAiQ29udGVudCI6ICLnvZHnu5zov57mjqUiLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAibmNwYS5jcGwiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9sZWdhY3ktd2luZG93cy1wYW5lbHMvbmV0d29yayIKICB9LAogICJXUEZQYW5lbFBvd2VyIjogewogICAgIkNvbnRlbnQiOiAi55S15rqQ6K6+572uIiwKICAgICJjYXRlZ29yeSI6ICLkvKDnu58gV2luZG93cyDpnaLmnb8iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJCdXR0b25XaWR0aCI6ICIzMDAiLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgInBvd2VyY2ZnLmNwbCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2xlZ2FjeS13aW5kb3dzLXBhbmVscy9wb3dlciIKICB9LAogICJXUEZQYW5lbFByaW50ZXIiOiB7CiAgICAiQ29udGVudCI6ICLmiZPljbDmnLrorr7nva4iLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiU3RhcnQtUHJvY2VzcyAnc2hlbGw6Ojp7QThBOTFBNjYtM0E3RC00NDI0LThEMjQtMDRFMTgwNjk1QzdBfSciCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9sZWdhY3ktd2luZG93cy1wYW5lbHMvcHJpbnRlciIKICB9LAogICJXUEZQYW5lbFByb2dyYW1zIjogewogICAgIkNvbnRlbnQiOiAi56iL5bqP5ZKM5Yqf6IO9IiwKICAgICJjYXRlZ29yeSI6ICLkvKDnu58gV2luZG93cyDpnaLmnb8iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJCdXR0b25XaWR0aCI6ICIzMDAiLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgImFwcHdpei5jcGwiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9sZWdhY3ktd2luZG93cy1wYW5lbHMvcHJvZ3JhbXMiCiAgfSwKICAiV1BGUGFuZWxSZWdpb24iOiB7CiAgICAiQ29udGVudCI6ICLljLrln58iLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiaW50bC5jcGwiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9sZWdhY3ktd2luZG93cy1wYW5lbHMvcmVnaW9uIgogIH0sCiAgIldQRlBhbmVsU2VjdXJpdHkiOiB7CiAgICAiQ29udGVudCI6ICLlronlhajlkoznu7TmiqQiLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAid3NjdWkuY3BsIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvbGVnYWN5LXdpbmRvd3MtcGFuZWxzL3NlY3VyaXR5IgogIH0sCiAgIldQRlBhbmVsU291bmQiOiB7CiAgICAiQ29udGVudCI6ICLlo7Dpn7Porr7nva4iLAogICAgImNhdGVnb3J5IjogIuS8oOe7nyBXaW5kb3dzIOmdouadvyIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAibW1zeXMuY3BsIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvbGVnYWN5LXdpbmRvd3MtcGFuZWxzL3NvdW5kIgogIH0sCiAgIldQRlBhbmVsU3lzdGVtIjogewogICAgIkNvbnRlbnQiOiAi57O757uf5bGe5oCnIiwKICAgICJjYXRlZ29yeSI6ICLkvKDnu58gV2luZG93cyDpnaLmnb8iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJCdXR0b25XaWR0aCI6ICIzMDAiLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgInN5c2RtLmNwbCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2xlZ2FjeS13aW5kb3dzLXBhbmVscy9zeXN0ZW0iCiAgfSwKICAiV1BGUGFuZWxUaW1lZGF0ZSI6IHsKICAgICJDb250ZW50IjogIuaXtumXtOWSjOaXpeacnyIsCiAgICAiY2F0ZWdvcnkiOiAi5Lyg57ufIFdpbmRvd3Mg6Z2i5p2/IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiQnV0dG9uV2lkdGgiOiAiMzAwIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJ0aW1lZGF0ZS5jcGwiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9sZWdhY3ktd2luZG93cy1wYW5lbHMvdGltZWRhdGUiCiAgfSwKICAiV1BGUGFuZWxGaXJld2FsbCI6IHsKICAgICJDb250ZW50IjogIldpbmRvd3MgRGVmZW5kZXIg6Ziy54Gr5aKZIiwKICAgICJjYXRlZ29yeSI6ICLkvKDnu58gV2luZG93cyDpnaLmnb8iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJCdXR0b25XaWR0aCI6ICIzMDAiLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgImZpcmV3YWxsLmNwbCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL2xlZ2FjeS13aW5kb3dzLXBhbmVscy9maXJld2FsbCIKICB9LAogICJXUEZQYW5lbFJlc3RvcmUiOiB7CiAgICAiQ29udGVudCI6ICJXaW5kb3dzIOi/mOWOnyIsCiAgICAiY2F0ZWdvcnkiOiAi5Lyg57ufIFdpbmRvd3Mg6Z2i5p2/IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIkJ1dHRvbiIsCiAgICAiQnV0dG9uV2lkdGgiOiAiMzAwIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJyc3RydWkuZXhlIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvbGVnYWN5LXdpbmRvd3MtcGFuZWxzL3Jlc3RvcmUiCiAgfSwKICAiV1BGV2luVXRpbEluc3RhbGxQU1Byb2ZpbGUiOiB7CiAgICAiQ29udGVudCI6ICJQb3dlclNoZWxsIOaYr+W+rui9r+eahOiHquWKqOWMluS7u+WKoeahhuaetuWSjOiEmuacrOivreiogCIsCiAgICAiY2F0ZWdvcnkiOiAiUG93ZXJTaGVsbCDphY3nva7mlofku7YgKOS7hSBQb3dlclNoZWxsIDcrKSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdpblV0aWxJbnN0YWxsUFNQcm9maWxlIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvZmVhdHVyZXMvcG93ZXJzaGVsbC1wcm9maWxlLXBvd2Vyc2hlbGwtNy0tb25seS9pbnN0YWxscHNwcm9maWxlIgogIH0sCiAgIldQRldpblV0aWxVbmluc3RhbGxQU1Byb2ZpbGUiOiB7CiAgICAiQ29udGVudCI6ICJQb3dlclNoZWxsIOaYr+W+rui9r+eahOiHquWKqOWMluS7u+WKoeahhuaetuWSjOiEmuacrOivreiogCIsCiAgICAiY2F0ZWdvcnkiOiAiUG93ZXJTaGVsbCDphY3nva7mlofku7YgKOS7hSBQb3dlclNoZWxsIDcrKSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdpblV0aWxVbmluc3RhbGxQU1Byb2ZpbGUiLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi9mZWF0dXJlcy9wb3dlcnNoZWxsLXByb2ZpbGUtcG93ZXJzaGVsbC03LS1vbmx5L3VuaW5zdGFsbHBzcHJvZmlsZSIKICB9LAogICJXUEZXaW5VdGlsU1NIU2VydmVyIjogewogICAgIkNvbnRlbnQiOiAiT3BlblNTSCDmnI3liqHlmaggLSDlkK/nlKgiLAogICAgImNhdGVnb3J5IjogIui/nOeoi+iuv+mXriIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAiZnVuY3Rpb24iOiAiSW52b2tlLVdQRlNTSFNlcnZlciIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L2ZlYXR1cmVzL3JlbW90ZS1hY2Nlc3Mvc3Noc2VydmVyIgogIH0KfQ==')) | ConvertFrom-Json

$sync.configs.preset = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJTdGFuZGFyZCI6IFsKICAgICJXUEZUd2Vha3NBY3Rpdml0eSIsCiAgICAiV1BGVHdlYWtzQ29uc3VtZXJGZWF0dXJlcyIsCiAgICAiV1BGVHdlYWtzRGlzYWJsZUV4cGxvcmVyQXV0b0Rpc2NvdmVyeSIsCiAgICAiV1BGVHdlYWtzV1BCVCIsCiAgICAiV1BGVHdlYWtzTG9jYXRpb24iLAogICAgIldQRlR3ZWFrc1NlcnZpY2VzIiwKICAgICJXUEZUd2Vha3NUZWxlbWV0cnkiLAogICAgIldQRlR3ZWFrc0RlbGl2ZXJ5T3B0aW1pemF0aW9uIiwKICAgICJXUEZUd2Vha3NEaXNrQ2xlYW51cCIsCiAgICAiV1BGVHdlYWtzRGVsZXRlVGVtcEZpbGVzIiwKICAgICJXUEZUd2Vha3NFbmRUYXNrT25UYXNrYmFyIiwKICAgICJXUEZUd2Vha3NSZXN0b3JlUG9pbnQiCiAgXSwKICAiTWluaW1hbCI6IFsKICAgICJXUEZUd2Vha3NDb25zdW1lckZlYXR1cmVzIiwKICAgICJXUEZUd2Vha3NXUEJUIiwKICAgICJXUEZUd2Vha3NTZXJ2aWNlcyIsCiAgICAiV1BGVHdlYWtzVGVsZW1ldHJ5IgogIF0sCiAgIkFkdmFuY2VkIjogWwogICAgIldQRlR3ZWFrc1Jlc3RvcmVQb2ludCIsCiAgICAiV1BGVHdlYWtzQWN0aXZpdHkiLAogICAgIldQRlR3ZWFrc0NvbnN1bWVyRmVhdHVyZXMiLAogICAgIldQRlR3ZWFrc0Rpc2FibGVFeHBsb3JlckF1dG9EaXNjb3ZlcnkiLAogICAgIldQRlR3ZWFrc1dQQlQiLAogICAgIldQRlR3ZWFrc0xvY2F0aW9uIiwKICAgICJXUEZUd2Vha3NTZXJ2aWNlcyIsCiAgICAiV1BGVHdlYWtzVGVsZW1ldHJ5IiwKICAgICJXUEZUd2Vha3NEZWxpdmVyeU9wdGltaXphdGlvbiIsCiAgICAiV1BGVHdlYWtzRGVsZXRlVGVtcEZpbGVzIiwKICAgICJXUEZUd2Vha3NFbmRUYXNrT25UYXNrYmFyIiwKICAgICJXUEZUd2Vha3NEaXNhYmxlU3RvcmVTZWFyY2giLAogICAgIldQRlR3ZWFrc1JldmVydFN0YXJ0TWVudSIsCiAgICAiV1BGVHdlYWtzV2lkZ2V0IiwKICAgICJXUEZUd2Vha3NSZW1vdmVPbmVEcml2ZSIsCiAgICAiV1BGVHdlYWtzV2luZG93c0FJIiwKICAgICJXUEZUd2Vha3NSaWdodENsaWNrTWVudSIKICBdLAogICJBcHB4RGVmYXVsdCI6IFsKICAgICJXUEZBcHB4TWljcm9zb2Z0X1dpbmRvd3NGZWVkYmFja0h1YiIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9HZXRIZWxwIiwKICAgICJXUEZBcHB4TWljcm9zb2Z0X01pY3Jvc29mdE9mZmljZUh1YiIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9XaW5kb3dzQ2FsY3VsYXRvciIsCiAgICAiV1BGQXBweENsaXBjaGFtcF9DbGlwY2hhbXAiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfV2luZG93c0FsYXJtcyIsCiAgICAiV1BGQXBweE1pY3Jvc29mdENvcnBvcmF0aW9uSUlfUXVpY2tBc3Npc3QiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfV2luZG93c1NvdW5kUmVjb3JkZXIiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfTWljcm9zb2Z0U3RpY2t5Tm90ZXMiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfVG9kb3MiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfTWljcm9zb2Z0U29saXRhaXJlQ29sbGVjdGlvbiIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9Qb3dlckF1dG9tYXRlRGVza3RvcCIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9XaW5kb3dzRGV2SG9tZSIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9CaW5nV2VhdGhlciIsCiAgICAiV1BGQXBweE1pY3Jvc29mdF9TdGFydEV4cGVyaWVuY2VzQXBwIiwKICAgICJXUEZBcHB4TWljcm9zb2Z0X0JpbmdOZXdzIiwKICAgICJXUEZBcHB4TWljcm9zb2Z0X0NvcGlsb3QiLAogICAgIldQRkFwcHhNaWNyb3NvZnRfQmluZ1NlYXJjaCIKICBdCn0=')) | ConvertFrom-Json

$sync.configs.themes = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJzaGFyZWQiOiB7CiAgICAiQXBwRW50cnlXaWR0aCI6ICIyMjAiLAogICAgIkFwcEVudHJ5Rm9udFNpemUiOiAiMTMuMiIsCiAgICAiQXBwRW50cnlJY29uU2l6ZSI6ICIyOCIsCiAgICAiQXBwRW50cnlNYXJnaW4iOiAiMyIsCiAgICAiQXBwRW50cnlCb3JkZXJUaGlja25lc3MiOiAiMSIsCiAgICAiQ3VzdG9tRGlhbG9nRm9udFNpemUiOiAiMTIiLAogICAgIkN1c3RvbURpYWxvZ0ZvbnRTaXplSGVhZGVyIjogIjE0IiwKICAgICJDdXN0b21EaWFsb2dMb2dvU2l6ZSI6ICIyNSIsCiAgICAiQ3VzdG9tRGlhbG9nV2lkdGgiOiAiNDAwIiwKICAgICJDdXN0b21EaWFsb2dIZWlnaHQiOiAiMjAwIiwKICAgICJGb250U2l6ZSI6ICIxMiIsCiAgICAiRm9udEZhbWlseSI6ICJBcmlhbCIsCiAgICAiSGVhZGVyRm9udFNpemUiOiAiMTYiLAogICAgIkhlYWRlckZvbnRGYW1pbHkiOiAiQ29uc29sYXMsIE1vbmFjbyIsCiAgICAiQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplIjogIjE0IiwKICAgICJDaGVja0JveE1hcmdpbiI6ICIxNSwwLDAsMiIsCiAgICAiVGFiQ29udGVudE1hcmdpbiI6ICI1IiwKICAgICJUYWJCdXR0b25Gb250U2l6ZSI6ICIxNCIsCiAgICAiVGFiQnV0dG9uV2lkdGgiOiAiMTEwIiwKICAgICJUYWJCdXR0b25IZWlnaHQiOiAiMjYiLAogICAgIlRhYlJvd0hlaWdodEluUGl4ZWxzIjogIjUwIiwKICAgICJUb29sVGlwV2lkdGgiOiAiMzAwIiwKICAgICJJY29uRm9udFNpemUiOiAiMTQiLAogICAgIkljb25CdXR0b25TaXplIjogIjM1IiwKICAgICJTZXR0aW5nc0ljb25Gb250U2l6ZSI6ICIxOCIsCiAgICAiQ2xvc2VJY29uRm9udFNpemUiOiAiMTIiLAogICAgIkdyb3VwQm9yZGVyQmFja2dyb3VuZENvbG9yIjogIiMyMzI2MjkiLAogICAgIkJ1dHRvbkZvbnRTaXplIjogIjEyIiwKICAgICJCdXR0b25Gb250RmFtaWx5IjogIkFyaWFsIiwKICAgICJCdXR0b25XaWR0aCI6ICIyMDAiLAogICAgIkJ1dHRvbkhlaWdodCI6ICIyNSIsCiAgICAiQ29uZmlnVGFiQnV0dG9uRm9udFNpemUiOiAiMTQiLAogICAgIkNvbmZpZ1VwZGF0ZUJ1dHRvbkZvbnRTaXplIjogIjE0IiwKICAgICJTZWFyY2hCYXJXaWR0aCI6ICIyMDAiLAogICAgIlNlYXJjaEJhckhlaWdodCI6ICIyNiIsCiAgICAiU2VhcmNoQmFyVGV4dEJveEZvbnRTaXplIjogIjEyIiwKICAgICJTZWFyY2hCYXJDbGVhckJ1dHRvbkZvbnRTaXplIjogIjE0IiwKICAgICJDaGVja2JveE1vdXNlT3ZlckNvbG9yIjogIiM5OTk5OTkiLAogICAgIkJ1dHRvbkJvcmRlclRoaWNrbmVzcyI6ICIxIiwKICAgICJCdXR0b25NYXJnaW4iOiAiMSIsCiAgICAiQnV0dG9uQ29ybmVyUmFkaXVzIjogIjIiCiAgfSwKICAiTGlnaHQiOiB7CiAgICAiQXBwSW5zdGFsbFVuc2VsZWN0ZWRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJBcHBJbnN0YWxsSGlnaGxpZ2h0ZWRDb2xvciI6ICIjQ0ZDRkNGIiwKICAgICJBcHBJbnN0YWxsU2VsZWN0ZWRDb2xvciI6ICIjQzJDMkMyIiwKICAgICJDb21ib0JveEZvcmVncm91bmRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJDb21ib0JveEJhY2tncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJMYWJlbGJveEZvcmVncm91bmRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJNYWluRm9yZWdyb3VuZENvbG9yIjogIiMyMzI2MjkiLAogICAgIk1haW5CYWNrZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiTGFiZWxCYWNrZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiTGlua0ZvcmVncm91bmRDb2xvciI6ICIjNDg0ODQ4IiwKICAgICJMaW5rSG92ZXJGb3JlZ3JvdW5kQ29sb3IiOiAiIzIzMjYyOSIsCiAgICAiU2Nyb2xsQmFyQmFja2dyb3VuZENvbG9yIjogIiM0QTRENTIiLAogICAgIlNjcm9sbEJhckhvdmVyQ29sb3IiOiAiIzVBNUQ2MiIsCiAgICAiU2Nyb2xsQmFyRHJhZ2dpbmdDb2xvciI6ICIjNkE2RDcyIiwKICAgICJQcm9ncmVzc0JhckZvcmVncm91bmRDb2xvciI6ICIjMkU3N0ZGIiwKICAgICJQcm9ncmVzc0JhckJhY2tncm91bmRDb2xvciI6ICJUcmFuc3BhcmVudCIsCiAgICAiQnV0dG9uSW5zdGFsbEJhY2tncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJCdXR0b25Ud2Vha3NCYWNrZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiQnV0dG9uQ29uZmlnQmFja2dyb3VuZENvbG9yIjogIiNGN0Y3RjciLAogICAgIkJ1dHRvblVwZGF0ZXNCYWNrZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiQnV0dG9uV2luMTFJU09CYWNrZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiQnV0dG9uQXBweEJhY2tncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJCdXR0b25JbnN0YWxsRm9yZWdyb3VuZENvbG9yIjogIiMyMzI2MjkiLAogICAgIkJ1dHRvblR3ZWFrc0ZvcmVncm91bmRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJCdXR0b25Db25maWdGb3JlZ3JvdW5kQ29sb3IiOiAiIzIzMjYyOSIsCiAgICAiQnV0dG9uVXBkYXRlc0ZvcmVncm91bmRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJCdXR0b25XaW4xMUlTT0ZvcmVncm91bmRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJCdXR0b25BcHB4Rm9yZWdyb3VuZENvbG9yIjogIiMyMzI2MjkiLAogICAgIkJ1dHRvbkJhY2tncm91bmRDb2xvciI6ICIjRjVGNUY1IiwKICAgICJCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yIjogIiMxQTFBMUEiLAogICAgIkJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvciI6ICIjQzJDMkMyIiwKICAgICJCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvciI6ICIjRjBGMEYwIiwKICAgICJCdXR0b25Gb3JlZ3JvdW5kQ29sb3IiOiAiIzIzMjYyOSIsCiAgICAiVG9nZ2xlQnV0dG9uT25Db2xvciI6ICIjMkU3N0ZGIiwKICAgICJUb2dnbGVCdXR0b25PZmZDb2xvciI6ICIjNzA3MDcwIiwKICAgICJUb29sVGlwQmFja2dyb3VuZENvbG9yIjogIiNGN0Y3RjciLAogICAgIkJvcmRlckNvbG9yIjogIiMyMzI2MjkiLAogICAgIkJvcmRlck9wYWNpdHkiOiAiMC4yIgogIH0sCiAgIkRhcmsiOiB7CiAgICAiQXBwSW5zdGFsbFVuc2VsZWN0ZWRDb2xvciI6ICIjMjMyNjI5IiwKICAgICJBcHBJbnN0YWxsSGlnaGxpZ2h0ZWRDb2xvciI6ICIjM0MzQzNDIiwKICAgICJBcHBJbnN0YWxsU2VsZWN0ZWRDb2xvciI6ICIjNEM0QzRDIiwKICAgICJDb21ib0JveEZvcmVncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJDb21ib0JveEJhY2tncm91bmRDb2xvciI6ICIjMUUzNzQ3IiwKICAgICJMYWJlbGJveEZvcmVncm91bmRDb2xvciI6ICIjNUJEQ0ZGIiwKICAgICJNYWluRm9yZWdyb3VuZENvbG9yIjogIiNGN0Y3RjciLAogICAgIk1haW5CYWNrZ3JvdW5kQ29sb3IiOiAiIzIzMjYyOSIsCiAgICAiTGFiZWxCYWNrZ3JvdW5kQ29sb3IiOiAiIzIzMjYyOSIsCiAgICAiTGlua0ZvcmVncm91bmRDb2xvciI6ICIjQUREOEU2IiwKICAgICJMaW5rSG92ZXJGb3JlZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiU2Nyb2xsQmFyQmFja2dyb3VuZENvbG9yIjogIiMyRTMxMzUiLAogICAgIlNjcm9sbEJhckhvdmVyQ29sb3IiOiAiIzNCNDI1MiIsCiAgICAiU2Nyb2xsQmFyRHJhZ2dpbmdDb2xvciI6ICIjNUU4MUFDIiwKICAgICJQcm9ncmVzc0JhckZvcmVncm91bmRDb2xvciI6ICIjNkVGRjcyIiwKICAgICJQcm9ncmVzc0JhckJhY2tncm91bmRDb2xvciI6ICJUcmFuc3BhcmVudCIsCiAgICAiQnV0dG9uSW5zdGFsbEJhY2tncm91bmRDb2xvciI6ICIjMjIyMjIyIiwKICAgICJCdXR0b25Ud2Vha3NCYWNrZ3JvdW5kQ29sb3IiOiAiIzMzMzMzMyIsCiAgICAiQnV0dG9uQ29uZmlnQmFja2dyb3VuZENvbG9yIjogIiM0NDQ0NDQiLAogICAgIkJ1dHRvblVwZGF0ZXNCYWNrZ3JvdW5kQ29sb3IiOiAiIzU1NTU1NSIsCiAgICAiQnV0dG9uV2luMTFJU09CYWNrZ3JvdW5kQ29sb3IiOiAiIzY2NjY2NiIsCiAgICAiQnV0dG9uQXBweEJhY2tncm91bmRDb2xvciI6ICIjNzc3Nzc3IiwKICAgICJCdXR0b25JbnN0YWxsRm9yZWdyb3VuZENvbG9yIjogIiNGN0Y3RjciLAogICAgIkJ1dHRvblR3ZWFrc0ZvcmVncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJCdXR0b25Db25maWdGb3JlZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiQnV0dG9uVXBkYXRlc0ZvcmVncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJCdXR0b25XaW4xMUlTT0ZvcmVncm91bmRDb2xvciI6ICIjRjdGN0Y3IiwKICAgICJCdXR0b25BcHB4Rm9yZWdyb3VuZENvbG9yIjogIiNGN0Y3RjciLAogICAgIkJ1dHRvbkJhY2tncm91bmRDb2xvciI6ICIjMUUzNzQ3IiwKICAgICJCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yIjogIiNGN0Y3RjciLAogICAgIkJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvciI6ICIjM0I0MjUyIiwKICAgICJCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvciI6ICIjNUU4MUFDIiwKICAgICJCdXR0b25Gb3JlZ3JvdW5kQ29sb3IiOiAiI0Y3RjdGNyIsCiAgICAiVG9nZ2xlQnV0dG9uT25Db2xvciI6ICIjMkU3N0ZGIiwKICAgICJUb2dnbGVCdXR0b25PZmZDb2xvciI6ICIjNzA3MDcwIiwKICAgICJUb29sVGlwQmFja2dyb3VuZENvbG9yIjogIiMyRjM3M0QiLAogICAgIkJvcmRlckNvbG9yIjogIiMyRjM3M0QiLAogICAgIkJvcmRlck9wYWNpdHkiOiAiMC4yIgogIH0KfQ==')) | ConvertFrom-Json

$sync.configs.tweaks = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('ewogICJXUEZUd2Vha3NBY3Rpdml0eSI6IHsKICAgICJDb250ZW50IjogIua0u+WKqOWOhuWPsuiusOW9lSAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5riF6Zmk5pyA6L+R55qE5paH5qGj44CB5Ymq6LS05p2/5ZKM6L+Q6KGM5Y6G5Y+y6K6w5b2V44CCIiwKICAgICJjYXRlZ29yeSI6ICLln7rmnKzkvJjljJYiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxXaW5kb3dzXFxTeXN0ZW0iLAogICAgICAgICJOYW1lIjogIkVuYWJsZUFjdGl2aXR5RmVlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxXaW5kb3dzXFxTeXN0ZW0iLAogICAgICAgICJOYW1lIjogIlB1Ymxpc2hVc2VyQWN0aXZpdGllcyIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxXaW5kb3dzXFxTeXN0ZW0iLAogICAgICAgICJOYW1lIjogIlVwbG9hZFVzZXJBY3Rpdml0aWVzIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL2FjdGl2aXR5IgogIH0sCiAgIldQRlR3ZWFrc0hpYmVyIjogewogICAgIkNvbnRlbnQiOiAi5LyR55yg5Yqf6IO9IC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLkvJHnnKDlip/og73pgILnlKjkuo7nrJTorrDmnKznlLXohJHvvIzlnKjlhbPmnLrliY3kv53lrZjlhoXlrZjlhoXlrrnjgILpgJrluLjkuI3mjqjojZDkvb/nlKjjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU3lzdGVtXFxDdXJyZW50Q29udHJvbFNldFxcQ29udHJvbFxcU2Vzc2lvbiBNYW5hZ2VyXFxQb3dlciIsCiAgICAgICAgIk5hbWUiOiAiSGliZXJuYXRlRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcRmx5b3V0TWVudVNldHRpbmdzIiwKICAgICAgICAiTmFtZSI6ICJTaG93SGliZXJuYXRlT3B0aW9uIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAicG93ZXJjZmcuZXhlIC9oaWJlcm5hdGUgb2ZmIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAicG93ZXJjZmcuZXhlIC9oaWJlcm5hdGUgb24iCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9oaWJlciIKICB9LAogICJXUEZUd2Vha3NXaWRnZXQiOiB7CiAgICAiQ29udGVudCI6ICLlsI/nu4Tku7YgLSDnp7vpmaQiLAogICAgIkRlc2NyaXB0aW9uIjogIuenu+mZpOS7u+WKoeagj+W3puS4i+inkueahOeDpuS6uuWwj+e7hOS7tuOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICAjIFNvbWV0aW1lcyBpZiB5b3UgZG9udCBzdG9wIHRoZSBXaWRnZXRzIHByb2Nlc3MgdGhlIHJlbW92YWwgbWF5IGZhaWwgICAgICBHZXQtUHJvY2VzcyAqV2lkZ2V0KiB8IFN0b3AtUHJvY2VzcyAgICAgIEdldC1BcHB4UGFja2FnZSBNaWNyb3NvZnQuV2lkZ2V0c1BsYXRmb3JtUnVudGltZSAtQWxsVXNlcnMgfCBSZW1vdmUtQXBweFBhY2thZ2UgLUFsbFVzZXJzICAgICAgR2V0LUFwcHhQYWNrYWdlIE1pY3Jvc29mdFdpbmRvd3MuQ2xpZW50LldlYkV4cGVyaWVuY2UgLUFsbFVzZXJzIHwgUmVtb3ZlLUFwcHhQYWNrYWdlIC1BbGxVc2VycyAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgLWFjdGlvbiBcInJlc3RhcnRcIiAgICAgIFdyaXRlLUhvc3QgXCJSZW1vdmVkIHdpZGdldHNcIiAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL3dpZGdldCIKICB9LAogICJXUEZUd2Vha3NSZXZlcnRTdGFydE1lbnUiOiB7CiAgICAiQ29udGVudCI6ICLlvIDlp4voj5zljZXml6fniYjluIPlsYAgLSDlkK/nlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuaBouWkjSAyNUgyIOaWsOeJiOacrOS5i+WJjeeahOaXp+W8gOWni+iPnOWNleW4g+WxgOOAguWcqOabtOaWsOeahCBXaW5kb3dzIOeJiOacrOS4iuatpOiwg+aVtOWwhuS4jei1t+S9nOeUqOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXENvbnRyb2xTZXQwMDFcXENvbnRyb2xcXEZlYXR1cmVNYW5hZ2VtZW50XFxPdmVycmlkZXNcXDhcXDMwMzYyNDE1NDgiLAogICAgICAgICJOYW1lIjogIkVuYWJsZWRTdGF0ZSIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9yZXZlcnRzdGFydG1lbnUiCiAgfSwKICAiV1BGVHdlYWtzRGlzYWJsZVN0b3JlU2VhcmNoIjogewogICAgIkNvbnRlbnQiOiAiTWljcm9zb2Z0IFN0b3JlIOaOqOiNkOaQnOe0oue7k+aenCAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Zyo5byA5aeL6I+c5Y2V5pCc57Si5bqU55So5pe25bCG5LiN5pi+56S65o6o6I2Q55qEIE1pY3Jvc29mdCBTdG9yZSDlupTnlKjjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiaWNhY2xzIFwiJEVudjpMb2NhbEFwcERhdGFcXFBhY2thZ2VzXFxNaWNyb3NvZnQuV2luZG93c1N0b3JlXzh3ZWt5YjNkOGJid2VcXExvY2FsU3RhdGVcXHN0b3JlLmRiXCIgL2RlbnkgRXZlcnlvbmU6RiIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgImljYWNscyBcIiRFbnY6TG9jYWxBcHBEYXRhXFxQYWNrYWdlc1xcTWljcm9zb2Z0LldpbmRvd3NTdG9yZV84d2VreWIzZDhiYndlXFxMb2NhbFN0YXRlXFxzdG9yZS5kYlwiIC9ncmFudCBFdmVyeW9uZTpGIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2Vzc2VudGlhbC10d2Vha3MvZGlzYWJsZXN0b3Jlc2VhcmNoIgogIH0sCiAgIldQRlR3ZWFrc0xvY2F0aW9uIjogewogICAgIkNvbnRlbnQiOiAi5L2N572u6Lef6LiqIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLnpoHnlKjkvY3nva7ot5/ouKrjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAic2VydmljZSI6IFsKICAgICAgewogICAgICAgICJOYW1lIjogImxmc3ZjIiwKICAgICAgICAiU3RhcnR1cFR5cGUiOiAiRGlzYWJsZSIsCiAgICAgICAgIk9yaWdpbmFsVHlwZSI6ICJNYW51YWwiCiAgICAgIH0KICAgIF0sCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXENhcGFiaWxpdHlBY2Nlc3NNYW5hZ2VyXFxDb25zZW50U3RvcmVcXGxvY2F0aW9uIiwKICAgICAgICAiTmFtZSI6ICJWYWx1ZSIsCiAgICAgICAgIlZhbHVlIjogIkRlbnkiLAogICAgICAgICJUeXBlIjogIlN0cmluZyIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiQWxsb3ciCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXE1pY3Jvc29mdFxcV2luZG93cyBOVFxcQ3VycmVudFZlcnNpb25cXFNlbnNvclxcT3ZlcnJpZGVzXFx7QkZBNzk0RTQtRjk2NC00RkRCLTkwRjYtNTEwNTZCRkU0QjQ0fSIsCiAgICAgICAgIk5hbWUiOiAiU2Vuc29yUGVybWlzc2lvblN0YXRlIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU1lTVEVNXFxNYXBzIiwKICAgICAgICAiTmFtZSI6ICJBdXRvVXBkYXRlRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9sb2NhdGlvbiIKICB9LAogICJXUEZUd2Vha3NTZXJ2aWNlcyI6IHsKICAgICJDb250ZW50IjogIuacjeWKoSAtIOiuvuS4uuaJi+WKqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5bCG5p+Q5Lqb5pyN5Yqh6K6+5Li65omL5Yqo5ZCv5Yqo5bm26LCD5pW05rOo5YaM6KGo5YC85Lul5Yy56YWN57O757uf5YaF5a2Y77yM5Y+v5pi+6JGX5YeP5bCRIHN2Y2hvc3QuZXhlIOi/m+eoi+aVsOmHj+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJzZXJ2aWNlIjogWwogICAgICB7CiAgICAgICAgIk5hbWUiOiAiQ3NjU2VydmljZSIsCiAgICAgICAgIlN0YXJ0dXBUeXBlIjogIkRpc2FibGVkIiwKICAgICAgICAiT3JpZ2luYWxUeXBlIjogIk1hbnVhbCIKICAgICAgfSwKICAgICAgewogICAgICAgICJOYW1lIjogIkRpYWdUcmFjayIsCiAgICAgICAgIlN0YXJ0dXBUeXBlIjogIkRpc2FibGVkIiwKICAgICAgICAiT3JpZ2luYWxUeXBlIjogIkF1dG9tYXRpYyIKICAgICAgfSwKICAgICAgewogICAgICAgICJOYW1lIjogIk1hcHNCcm9rZXIiLAogICAgICAgICJTdGFydHVwVHlwZSI6ICJNYW51YWwiLAogICAgICAgICJPcmlnaW5hbFR5cGUiOiAiQXV0b21hdGljIgogICAgICB9LAogICAgICB7CiAgICAgICAgIk5hbWUiOiAiU3RvclN2YyIsCiAgICAgICAgIlN0YXJ0dXBUeXBlIjogIk1hbnVhbCIsCiAgICAgICAgIk9yaWdpbmFsVHlwZSI6ICJBdXRvbWF0aWMiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiTmFtZSI6ICJTaGFyZWRBY2Nlc3MiLAogICAgICAgICJTdGFydHVwVHlwZSI6ICJEaXNhYmxlZCIsCiAgICAgICAgIk9yaWdpbmFsVHlwZSI6ICJBdXRvbWF0aWMiCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgJE1lbW9yeSA9IChHZXQtQ2ltSW5zdGFuY2UgV2luMzJfUGh5c2ljYWxNZW1vcnkgfCBNZWFzdXJlLU9iamVjdCBDYXBhY2l0eSAtU3VtKS5TdW0gLyAxS0IgICAgICBTZXQtSXRlbVByb3BlcnR5IC1QYXRoIFwiSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXENvbnRyb2xcIiAtTmFtZSBTdmNIb3N0U3BsaXRUaHJlc2hvbGRJbktCIC1WYWx1ZSAkTWVtb3J5ICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2Vzc2VudGlhbC10d2Vha3Mvc2VydmljZXMiCiAgfSwKICAiV1BGVHdlYWtzQnJhdmVEZWJsb2F0IjogewogICAgIkNvbnRlbnQiOiAiQnJhdmUg5rWP6KeI5ZmoIC0g57K+566AIiwKICAgICJEZXNjcmlwdGlvbiI6ICLnpoHnlKjlkITnp43ng6bkurrlip/og73vvIzlpoIgQnJhdmUgUmV3YXJkc+OAgUxlbyBBSeOAgeWKoOWvhumSseWMheWSjCBWUE7jgIIiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxCcmF2ZVNvZnR3YXJlXFxCcmF2ZSIsCiAgICAgICAgIk5hbWUiOiAiQnJhdmVSZXdhcmRzRGlzYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXEJyYXZlU29mdHdhcmVcXEJyYXZlIiwKICAgICAgICAiTmFtZSI6ICJCcmF2ZVdhbGxldERpc2FibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxCcmF2ZVNvZnR3YXJlXFxCcmF2ZSIsCiAgICAgICAgIk5hbWUiOiAiQnJhdmVWUE5EaXNhYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIkJyYXZlQUlDaGF0RW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIkJyYXZlU3RhdHNQaW5nRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIkJyYXZlTmV3c0Rpc2FibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxCcmF2ZVNvZnR3YXJlXFxCcmF2ZSIsCiAgICAgICAgIk5hbWUiOiAiQnJhdmVUYWxrRGlzYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXEJyYXZlU29mdHdhcmVcXEJyYXZlIiwKICAgICAgICAiTmFtZSI6ICJUb3JEaXNhYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIkJyYXZlUDNBRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIlVybEtleWVkQW5vbnltaXplZERhdGFDb2xsZWN0aW9uRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIlNhZmVCcm93c2luZ0V4dGVuZGVkUmVwb3J0aW5nRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcQnJhdmVTb2Z0d2FyZVxcQnJhdmUiLAogICAgICAgICJOYW1lIjogIk1ldHJpY3NSZXBvcnRpbmdFbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL2JyYXZlZGVibG9hdCIKICB9LAogICJXUEZUd2Vha3NEaXNhYmxlV2FybmluZ0ZvclVuc2lnbmVkUmRwIjogewogICAgIkNvbnRlbnQiOiAiUkRQIOacquetvuWQjeaWh+S7tuitpuWRiiAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi56aB55So5ZCv5Yqo5pyq562+5ZCNIFJEUCDmlofku7bml7bmmL7npLrnmoTorablkYrjgIIiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXFdpbmRvd3MgTlRcXFRlcm1pbmFsIFNlcnZpY2VzXFxDbGllbnQiLAogICAgICAgICJOYW1lIjogIlJlZGlyZWN0aW9uV2FybmluZ0RpYWxvZ1ZlcnNpb24iLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxUZXJtaW5hbCBTZXJ2ZXIgQ2xpZW50IiwKICAgICAgICAiTmFtZSI6ICJSZHBMYXVuY2hDb25zZW50QWNjZXB0ZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vZGlzYWJsZXdhcm5pbmdmb3J1bnNpZ25lZHJkcCIKICB9LAogICJXUEZUd2Vha3NFZGdlRGVibG9hdCI6IHsKICAgICJDb250ZW50IjogIk1pY3Jvc29mdCBFZGdlIC0g57K+566AIiwKICAgICJEZXNjcmlwdGlvbiI6ICLnpoHnlKggRWRnZSDkuK3nmoTlkITnp43pgaXmtYvpgInpobnjgIHlvLnnqpflkozlhbbku5bng6bkurrlip/og73jgIIiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2VVcGRhdGUiLAogICAgICAgICJOYW1lIjogIkNyZWF0ZURlc2t0b3BTaG9ydGN1dERlZmF1bHQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiUGVyc29uYWxpemF0aW9uUmVwb3J0aW5nRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxFZGdlXFxFeHRlbnNpb25JbnN0YWxsQmxvY2tsaXN0IiwKICAgICAgICAiTmFtZSI6ICIxIiwKICAgICAgICAiVmFsdWUiOiAib2ZlZmNnamJlZ2hwaWdwcGZta29sb2dmamFkYWZkZGkiLAogICAgICAgICJUeXBlIjogIlN0cmluZyIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiU2hvd1JlY29tbWVuZGF0aW9uc0VuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiSGlkZUZpcnN0UnVuRXhwZXJpZW5jZSIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxFZGdlIiwKICAgICAgICAiTmFtZSI6ICJVc2VyRmVlZGJhY2tBbGxvd2VkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2UiLAogICAgICAgICJOYW1lIjogIkNvbmZpZ3VyZURvTm90VHJhY2siLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiQWx0ZXJuYXRlRXJyb3JQYWdlc0VuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiRWRnZUNvbGxlY3Rpb25zRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxFZGdlIiwKICAgICAgICAiTmFtZSI6ICJFZGdlU2hvcHBpbmdBc3Npc3RhbnRFbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2UiLAogICAgICAgICJOYW1lIjogIk1pY3Jvc29mdEVkZ2VJbnNpZGVyUHJvbW90aW9uRW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxFZGdlIiwKICAgICAgICAiTmFtZSI6ICJTaG93TWljcm9zb2Z0UmV3YXJkcyIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxFZGdlIiwKICAgICAgICAiTmFtZSI6ICJXZWJXaWRnZXRBbGxvd2VkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2UiLAogICAgICAgICJOYW1lIjogIkRpYWdub3N0aWNEYXRhIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2UiLAogICAgICAgICJOYW1lIjogIkVkZ2VBc3NldERlbGl2ZXJ5U2VydmljZUVuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcRWRnZSIsCiAgICAgICAgIk5hbWUiOiAiV2FsbGV0RG9uYXRpb25FbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXEVkZ2UiLAogICAgICAgICJOYW1lIjogIkRlZmF1bHRCcm93c2VyU2V0dGluZ3NDYW1wYWlnbkVuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vZWRnZWRlYmxvYXQiCiAgfSwKICAiV1BGVHdlYWtzQ29uc3VtZXJGZWF0dXJlcyI6IHsKICAgICJDb250ZW50IjogIua2iOi0ueiAheWKn+iDvSAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YGc5q2i5o6o5bm/5bqU55So5a6J6KOF5bm25YeP5bCRIE1pY3Jvc29mdCBTdG9yZSDlhoXlrrnnmoTlupTnlKjlu7rorq7jgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXFdpbmRvd3NcXENsb3VkQ29udGVudCIsCiAgICAgICAgIk5hbWUiOiAiRGlzYWJsZVdpbmRvd3NDb25zdW1lckZlYXR1cmVzIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL2NvbnN1bWVyZmVhdHVyZXMiCiAgfSwKICAiV1BGVHdlYWtzVGVsZW1ldHJ5IjogewogICAgIkNvbnRlbnQiOiAi6YGl5rWLIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLnpoHnlKggTWljcm9zb2Z0IOmBpea1i+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcQWR2ZXJ0aXNpbmdJbmZvIiwKICAgICAgICAiTmFtZSI6ICJFbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXFByaXZhY3kiLAogICAgICAgICJOYW1lIjogIlRhaWxvcmVkRXhwZXJpZW5jZXNXaXRoRGlhZ25vc3RpY0RhdGFFbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcU3BlZWNoX09uZUNvcmVcXFNldHRpbmdzXFxPbmxpbmVTcGVlY2hQcml2YWN5IiwKICAgICAgICAiTmFtZSI6ICJIYXNBY2NlcHRlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXElucHV0XFxUSVBDIiwKICAgICAgICAiTmFtZSI6ICJFbmFibGVkIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcSW5wdXRQZXJzb25hbGl6YXRpb24iLAogICAgICAgICJOYW1lIjogIlJlc3RyaWN0SW1wbGljaXRJbmtDb2xsZWN0aW9uIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcSW5wdXRQZXJzb25hbGl6YXRpb24iLAogICAgICAgICJOYW1lIjogIlJlc3RyaWN0SW1wbGljaXRUZXh0Q29sbGVjdGlvbiIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXElucHV0UGVyc29uYWxpemF0aW9uXFxUcmFpbmVkRGF0YVN0b3JlIiwKICAgICAgICAiTmFtZSI6ICJIYXJ2ZXN0Q29udGFjdHMiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxQZXJzb25hbGl6YXRpb25cXFNldHRpbmdzIiwKICAgICAgICAiTmFtZSI6ICJBY2NlcHRlZFByaXZhY3lQb2xpY3kiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcUG9saWNpZXNcXERhdGFDb2xsZWN0aW9uIiwKICAgICAgICAiTmFtZSI6ICJBbGxvd1RlbGVtZXRyeSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIlN0YXJ0X1RyYWNrUHJvZ3MiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcV2luZG93c1xcU3lzdGVtIiwKICAgICAgICAiTmFtZSI6ICJQdWJsaXNoVXNlckFjdGl2aXRpZXMiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxTaXVmXFxSdWxlcyIsCiAgICAgICAgIk5hbWUiOiAiTnVtYmVyT2ZTSVVGSW5QZXJpb2QiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfQogICAgXSwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICAjIERpc2FibGUgRGVmZW5kZXIgQXV0byBTYW1wbGUgU3VibWlzc2lvbiAgICAgIFNldC1NcFByZWZlcmVuY2UgLVN1Ym1pdFNhbXBsZXNDb25zZW50IDIgICAgICAjIERpc2FibGUgKENvbm5lY3RlZCBVc2VyIEV4cGVyaWVuY2VzIGFuZCBUZWxlbWV0cnkpIFNlcnZpY2UgICAgICBTZXQtU2VydmljZSAtTmFtZSBkaWFndHJhY2sgLVN0YXJ0dXBUeXBlIERpc2FibGVkICAgICAgIyBEaXNhYmxlIChXaW5kb3dzIEVycm9yIFJlcG9ydGluZyBNYW5hZ2VyKSBTZXJ2aWNlICAgICAgU2V0LVNlcnZpY2UgLU5hbWUgd2VybWdyIC1TdGFydHVwVHlwZSBEaXNhYmxlZCAgICAgICMgRGlzYWJsZSBQb3dlclNoZWxsIDcgdGVsZW1ldHJ5ICAgICAgW0Vudmlyb25tZW50XTo6U2V0RW52aXJvbm1lbnRWYXJpYWJsZSgnUE9XRVJTSEVMTF9URUxFTUVUUllfT1BUT1VUJywgJzEnLCAnTWFjaGluZScpICAgICAgUmVtb3ZlLUl0ZW1Qcm9wZXJ0eSAtUGF0aCBcIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxTaXVmXFxSdWxlc1wiIC1OYW1lIFBlcmlvZEluTmFub1NlY29uZHMgICAgICAiCiAgICBdLAogICAgIlVuZG9TY3JpcHQiOiBbCiAgICAgICIgICAgICAjIEVuYWJsZSBEZWZlbmRlciBBdXRvIFNhbXBsZSBTdWJtaXNzaW9uICAgICAgU2V0LU1wUHJlZmVyZW5jZSAtU3VibWl0U2FtcGxlc0NvbnNlbnQgMSAgICAgICMgRW5hYmxlIChDb25uZWN0ZWQgVXNlciBFeHBlcmllbmNlcyBhbmQgVGVsZW1ldHJ5KSBTZXJ2aWNlICAgICAgU2V0LVNlcnZpY2UgLU5hbWUgZGlhZ3RyYWNrIC1TdGFydHVwVHlwZSBBdXRvbWF0aWMgICAgICAjIEVuYWJsZSAoV2luZG93cyBFcnJvciBSZXBvcnRpbmcgTWFuYWdlcikgU2VydmljZSAgICAgIFNldC1TZXJ2aWNlIC1OYW1lIHdlcm1nciAtU3RhcnR1cFR5cGUgQXV0b21hdGljICAgICAgIyBFbmFibGUgUG93ZXJTaGVsbCA3IHRlbGVtZXRyeSAgICAgIFtFbnZpcm9ubWVudF06OlNldEVudmlyb25tZW50VmFyaWFibGUoJ1BPV0VSU0hFTExfVEVMRU1FVFJZX09QVE9VVCcsICcnLCAnTWFjaGluZScpICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2Vzc2VudGlhbC10d2Vha3MvdGVsZW1ldHJ5IgogIH0sCiAgIldQRlR3ZWFrc0RlbGl2ZXJ5T3B0aW1pemF0aW9uIjogewogICAgIkNvbnRlbnQiOiAi5Lyg6YCS5LyY5YyWIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLpmLvmraIgV2luZG93cyDkvb/nlKjmgqjnmoTluKblrr3lkJHlhbbku5bnlLXohJHkuIrkvKDmm7TmlrDjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXFBvbGljaWVzXFxNaWNyb3NvZnRcXFdpbmRvd3NcXERlbGl2ZXJ5T3B0aW1pemF0aW9uIiwKICAgICAgICAiTmFtZSI6ICJET0Rvd25sb2FkTW9kZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9kZWxpdmVyeW9wdGltaXphdGlvbiIKICB9LAogICJXUEZUd2Vha3NSZW1vdmVFZGdlIjogewogICAgIkNvbnRlbnQiOiAiTWljcm9zb2Z0IEVkZ2UgLSDnp7vpmaQiLAogICAgIkRlc2NyaXB0aW9uIjogIumAmui/h+WIm+W7uuiZmuaLnyBNaWNyb3NvZnRFZGdlLmV4ZSDmlofku7bop6PplIHlrpjmlrnljbjovb3nqIvluo/vvIzlrp7njrDns7vnu5/nuqfnp7vpmaQgTWljcm9zb2Z0IEVkZ2UiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgJFBhdGggPSBSZXNvbHZlLVBhdGggLVBhdGggXCIkRW52OlByb2dyYW1GaWxlcyAoeDg2KVxcTWljcm9zb2Z0XFxFZGdlXFxBcHBsaWNhdGlvblxcKlxcSW5zdGFsbGVyXFxzZXR1cC5leGVcIiB8IFNlbGVjdC1PYmplY3QgLUxhc3QgMSAgICAgIGlmIChUZXN0LVBhdGggJFBhdGgpIHsgICAgICAgICAgTmV3LUl0ZW0gLVBhdGggXCIkRW52OlN5c3RlbVJvb3RcXFN5c3RlbUFwcHNcXE1pY3Jvc29mdC5NaWNyb3NvZnRFZGdlXzh3ZWt5YjNkOGJid2VcXE1pY3Jvc29mdEVkZ2UuZXhlXCIgLUZvcmNlICAgICAgICAgIFN0YXJ0LVByb2Nlc3MgLUZpbGVQYXRoICRQYXRoIC1Bcmd1bWVudExpc3QgXCItLXVuaW5zdGFsbCAtLXN5c3RlbS1sZXZlbCAtLWZvcmNlLXVuaW5zdGFsbCAtLWRlbGV0ZS1wcm9maWxlXCIgLVdhaXQgICAgICAgICAgV3JpdGUtSG9zdCBcIk1pY3Jvc29mdCBFZGdlIHdhcyByZW1vdmVkXCIgICAgICB9IGVsc2UgeyAgICAgICAgICBXcml0ZS1Ib3N0IFwiTWljcm9zb2Z0IEVkZ2UgaXMgbm90IGluc3RhbGxlZFwiICAgICAgfSAgICAgICIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIiAgICAgIFdyaXRlLUhvc3QgXCJJbnN0YWxsaW5nIE1pY3Jvc29mdCBFZGdlLi4uXCIgICAgICB3aW5nZXQgaW5zdGFsbCBNaWNyb3NvZnQuRWRnZSAtLXNvdXJjZSB3aW5nZXQgICAgICAiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9yZW1vdmVlZGdlIgogIH0sCiAgIldQRlR3ZWFrc0Rpc2FibGVCaXRMb2NrZXIiOiB7CiAgICAiQ29udGVudCI6ICJCaXRMb2NrZXIgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqCBCaXRMb2NrZXLjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiRGlzYWJsZS1CaXRMb2NrZXIgLU1vdW50UG9pbnQgJEVudjpTeXN0ZW1Ecml2ZSIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIkVuYWJsZS1CaXRMb2NrZXIgLU1vdW50UG9pbnQgJEVudjpTeXN0ZW1Ecml2ZSIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL2Rpc2FibGViaXRsb2NrZXIiCiAgfSwKICAiV1BGVHdlYWtzVVRDIjogewogICAgIkNvbnRlbnQiOiAi5pel5pyf5ZKM5pe26Ze0IC0g6K6+572u5Li6IFVUQyIsCiAgICAiRGVzY3JpcHRpb24iOiAi5a+55Y+M57O757uf5ZCv5Yqo55qE6K6h566X5py66Iez5YWz6YeN6KaB77yM5L+u5aSN5LiOIExpbnV4IOezu+e7n+eahOaXtumXtOWQjOatpemXrumimOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxUaW1lWm9uZUluZm9ybWF0aW9uIiwKICAgICAgICAiTmFtZSI6ICJSZWFsVGltZUlzVW5pdmVyc2FsIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiUVdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3V0YyIKICB9LAogICJXUEZUd2Vha3NSZW1vdmVPbmVEcml2ZSI6IHsKICAgICJDb250ZW50IjogIk1pY3Jvc29mdCBPbmVEcml2ZSAtIOenu+mZpCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5ouS57ud5Yig6ZmkIE9uZURyaXZlIOeUqOaIt+aWh+S7tueahOadg+mZkO+8jOWNuOi9veWQjuaBouWkjeWOn+Wni+adg+mZkOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICAjIERlbnkgcGVybWlzc2lvbiB0byByZW1vdmUgT25lRHJpdmUgZm9sZGVyICAgICAgaWNhY2xzICRFbnY6T25lRHJpdmUgL2RlbnkgXCJBZG1pbmlzdHJhdG9yczooRCxEQylcIiAgICAgIFdyaXRlLUhvc3QgXCJVbmluc3RhbGxpbmcgT25lRHJpdmUuLi5cIiAgICAgIFN0YXJ0LVByb2Nlc3MgLUZpbGVQYXRoIChKb2luLVBhdGggJEVudjpTeXN0ZW1Sb290IFwiU3lzdGVtMzJcXE9uZURyaXZlU2V0dXAuZXhlXCIpIC1Bcmd1bWVudExpc3QgJy91bmluc3RhbGwnIC1XYWl0ICAgICAgIyBTb21lIG9mIE9uZURyaXZlIGZpbGVzIHVzZSBleHBsb3JlciwgYW5kIE9uZURyaXZlIHVzZXMgRmlsZUNvQXV0aCAgICAgIFdyaXRlLUhvc3QgXCJSZW1vdmluZyBsZWZ0b3ZlciBPbmVEcml2ZSBGaWxlcy4uLlwiICAgICAgU3RvcC1Qcm9jZXNzIC1OYW1lIEZpbGVDb0F1dGgsRXhwbG9yZXIgICAgICBSZW1vdmUtSXRlbSBcIiRFbnY6TG9jYWxBcHBEYXRhXFxNaWNyb3NvZnRcXE9uZURyaXZlXCIgLVJlY3Vyc2UgLUZvcmNlICAgICAgUmVtb3ZlLUl0ZW0gXCIkRW52OlByb2dyYW1EYXRhXFxNaWNyb3NvZnQgT25lRHJpdmVcIiAtUmVjdXJzZSAtRm9yY2UgICAgICAjIEdyYW50IGJhY2sgcGVybWlzc2lvbiB0byBhY2Nlc3MgT25lRHJpdmUgZm9sZGVyICAgICAgaWNhY2xzICRFbnY6T25lRHJpdmUgL2dyYW50IFwiQWRtaW5pc3RyYXRvcnM6KEQsREMpXCIgICAgICBpZiAoLW5vdCAoR2V0LUNoaWxkSXRlbSAtUGF0aCAkRW52Ok9uZURyaXZlKSkgeyAgICAgICAgICBSZW1vdmUtSXRlbSAtUGF0aCAkRW52Ok9uZURyaXZlIC1SZWN1cnNlICAgICAgICAgIFtFbnZpcm9ubWVudF06OlNldEVudmlyb25tZW50VmFyaWFibGUoJ09uZURyaXZlJywgJG51bGwsICdVc2VyJykgICAgICB9ICAgICAgIyBEaXNhYmxlIE9uZVN5bmNTdmMgICAgICBTZXQtU2VydmljZSAtTmFtZSBPbmVTeW5jU3ZjIC1TdGFydHVwVHlwZSBEaXNhYmxlZCAgICAgICIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIiAgICAgIFdyaXRlLUhvc3QgXCJJbnN0YWxsaW5nIE9uZURyaXZlXCIgICAgICB3aW5nZXQgaW5zdGFsbCBNaWNyb3NvZnQuT25lZHJpdmUgLS1zb3VyY2Ugd2luZ2V0ICAgICAgIyBFbmFibGVkIE9uZVN5bmNTdmMgICAgICBTZXQtU2VydmljZSAtTmFtZSBPbmVTeW5jU3ZjIC1TdGFydHVwVHlwZSBBdXRvbWF0aWMgICAgICAiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9yZW1vdmVvbmVkcml2ZSIKICB9LAogICJXUEZUd2Vha3NSZW1vdmVIb21lQW5kR2FsbGVyeSI6IHsKICAgICJDb250ZW50IjogIuaWh+S7tui1hOa6kOeuoeeQhuWZqOS4u+mhteWSjOWbvuW6kyAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5LuO6LWE5rqQ566h55CG5Zmo5Lit56e76Zmk5Li76aG15ZKM5Zu+5bqT77yM5bm25bCG5q2k55S16ISR6K6+5Li66buY6K6k44CCIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxDbGFzc2VzXFxDTFNJRFxce2Y4NzQzMTBlLWI2YjctNDdkYy1iYzg0LWI5ZTZiMzhmNTkwM30iLAogICAgICAgICJOYW1lIjogIlN5c3RlbS5Jc1Bpbm5lZFRvTmFtZVNwYWNlVHJlZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxDbGFzc2VzXFxDTFNJRFxce2U4ODg2NWVhLTBlMWMtNGUyMC05YWE2LWVkY2QwMjEyYzg3Y30iLAogICAgICAgICJOYW1lIjogIlN5c3RlbS5Jc1Bpbm5lZFRvTmFtZVNwYWNlVHJlZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIkxhdW5jaFRvIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3JlbW92ZWhvbWVhbmRnYWxsZXJ5IgogIH0sCiAgIldQRlR3ZWFrc0Rpc3BsYXkiOiB7CiAgICAiQ29udGVudCI6ICLop4bop4nmlYjmnpwgLSDorr7nva7kuLrmnIDkvbPmgKfog70iLAogICAgIkRlc2NyaXB0aW9uIjogIuWwhuezu+e7n+WBj+Wlveiuvue9ruS4uuaAp+iDveaooeW8j+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxDb250cm9sIFBhbmVsXFxEZXNrdG9wIiwKICAgICAgICAiTmFtZSI6ICJEcmFnRnVsbFdpbmRvd3MiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJTdHJpbmciLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcQ29udHJvbCBQYW5lbFxcRGVza3RvcCIsCiAgICAgICAgIk5hbWUiOiAiTWVudVNob3dEZWxheSIsCiAgICAgICAgIlZhbHVlIjogIjIwMCIsCiAgICAgICAgIlR5cGUiOiAiU3RyaW5nIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI0MDAiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcQ29udHJvbCBQYW5lbFxcRGVza3RvcFxcV2luZG93TWV0cmljcyIsCiAgICAgICAgIk5hbWUiOiAiTWluQW5pbWF0ZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIlN0cmluZyIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxDb250cm9sIFBhbmVsXFxLZXlib2FyZCIsCiAgICAgICAgIk5hbWUiOiAiS2V5Ym9hcmREZWxheSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIkxpc3R2aWV3QWxwaGFTZWxlY3QiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcRXhwbG9yZXJcXEFkdmFuY2VkIiwKICAgICAgICAiTmFtZSI6ICJMaXN0dmlld1NoYWRvdyIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIlRhc2tiYXJBbmltYXRpb25zIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEV4cGxvcmVyXFxWaXN1YWxFZmZlY3RzIiwKICAgICAgICAiTmFtZSI6ICJWaXN1YWxGWFNldHRpbmciLAogICAgICAgICJWYWx1ZSI6ICIzIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxEV00iLAogICAgICAgICJOYW1lIjogIkVuYWJsZUFlcm9QZWVrIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEV4cGxvcmVyXFxBZHZhbmNlZCIsCiAgICAgICAgIk5hbWUiOiAiVGFza2Jhck1uIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEV4cGxvcmVyXFxBZHZhbmNlZCIsCiAgICAgICAgIk5hbWUiOiAiU2hvd1Rhc2tWaWV3QnV0dG9uIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXFNlYXJjaCIsCiAgICAgICAgIk5hbWUiOiAiU2VhcmNoYm94VGFza2Jhck1vZGUiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIKICAgICAgfQogICAgXSwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJTZXQtSXRlbVByb3BlcnR5IC1QYXRoIFwiSEtDVTpcXENvbnRyb2wgUGFuZWxcXERlc2t0b3BcIiAtTmFtZSBcIlVzZXJQcmVmZXJlbmNlc01hc2tcIiAtVHlwZSBCaW5hcnkgLVZhbHVlIChbYnl0ZVtdXSgxNDQsMTgsMywxMjgsMTYsMCwwLDApKSIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIlJlbW92ZS1JdGVtUHJvcGVydHkgLVBhdGggXCJIS0NVOlxcQ29udHJvbCBQYW5lbFxcRGVza3RvcFwiIC1OYW1lIFwiVXNlclByZWZlcmVuY2VzTWFza1wiIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vZGlzcGxheSIKICB9LAogICJXUEZUd2Vha3NSZXNlcnZlZFN0b3JhZ2UiOiB7CiAgICAiQ29udGVudCI6ICLnpoHnlKjpooTnlZnlrZjlgqgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqCBXaW5kb3dzIOmihOeVmeWtmOWCqO+8iOe6piA3LTEwIEdCIOeUqOS6juabtOaWsOWSjOS4tOaXtuaWh+S7tu+8ieOAguS7heW7uuiuruWwj+WuuemHj+ehrOebmOS9v+eUqCIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICJESVNNIC9PbmxpbmUgL1NldC1SZXNlcnZlZFN0b3JhZ2VTdGF0ZSAvU3RhdGU6RGlzYWJsZWQiCiAgICBdLAogICAgIlVuZG9TY3JpcHQiOiBbCiAgICAgICJESVNNIC9PbmxpbmUgL1NldC1SZXNlcnZlZFN0b3JhZ2VTdGF0ZSAvU3RhdGU6RW5hYmxlZCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3Jlc2VydmVkc3RvcmFnZSIKICB9LAogICJXUEZUd2Vha3NSZXN0b3JlUG9pbnQiOiB7CiAgICAiQ29udGVudCI6ICLov5jljp/ngrkgLSDliJvlu7oiLAogICAgIkRlc2NyaXB0aW9uIjogIuWcqOi/kOihjOaXtuWIm+W7uui/mOWOn+eCue+8jOS7peS+v+WcqOmcgOimgeaXtuaBouWkjSBXaW5VdGlsIOeahOS/ruaUueOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJDaGVja2VkIjogIkZhbHNlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxXaW5kb3dzIE5UXFxDdXJyZW50VmVyc2lvblxcU3lzdGVtUmVzdG9yZSIsCiAgICAgICAgIk5hbWUiOiAiU3lzdGVtUmVzdG9yZVBvaW50Q3JlYXRpb25GcmVxdWVuY3kiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMTQ0MCIKICAgICAgfQogICAgXSwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICBpZiAoLW5vdCAoR2V0LUNvbXB1dGVyUmVzdG9yZVBvaW50KSkgeyAgICAgICAgICBFbmFibGUtQ29tcHV0ZXJSZXN0b3JlIC1Ecml2ZSAkRW52OlN5c3RlbURyaXZlICAgICAgfSAgICAgIENoZWNrcG9pbnQtQ29tcHV0ZXIgLURlc2NyaXB0aW9uIFwiU3lzdGVtIFJlc3RvcmUgUG9pbnQgY3JlYXRlZCBieSBXaW5VdGlsXCIgLVJlc3RvcmVQb2ludFR5cGUgTU9ESUZZX1NFVFRJTkdTICAgICAgV3JpdGUtSG9zdCBcIlN5c3RlbSBSZXN0b3JlIFBvaW50IENyZWF0ZWQgU3VjY2Vzc2Z1bGx5XCIgLUZvcmVncm91bmRDb2xvciBHcmVlbiAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL3Jlc3RvcmVwb2ludCIKICB9LAogICJXUEZUd2Vha3NFbmRUYXNrT25UYXNrYmFyIjogewogICAgIkNvbnRlbnQiOiAi5Y+z6ZSu57uT5p2f5Lu75YqhIC0g5ZCv55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlkK/nlKjlj7PplK7ljZXlh7vku7vliqHmoI/nqIvluo/ml7bnu5PmnZ/ku7vliqHnmoTpgInpobnjgIIiLAogICAgImNhdGVnb3J5IjogIuWfuuacrOS8mOWMliIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEV4cGxvcmVyXFxBZHZhbmNlZFxcVGFza2JhckRldmVsb3BlclNldHRpbmdzIiwKICAgICAgICAiTmFtZSI6ICJUYXNrYmFyRW5kVGFzayIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9lbmR0YXNrb250YXNrYmFyIgogIH0sCiAgIldQRlR3ZWFrc1N0b3JhZ2UiOiB7CiAgICAiQ29udGVudCI6ICLlrZjlgqjmhJ/nn6UgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuWtmOWCqOaEn+efpeS8muiHquWKqOWIoOmZpOS4tOaXtuaWh+S7tuOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcU3RvcmFnZVNlbnNlXFxQYXJhbWV0ZXJzXFxTdG9yYWdlUG9saWN5IiwKICAgICAgICAiTmFtZSI6ICIwMSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9zdG9yYWdlIgogIH0sCiAgIldQRlR3ZWFrc1dpbmRvd3NBSSI6IHsKICAgICJDb250ZW50IjogIldpbmRvd3MgQUkgLSDnpoHnlKjlubbnp7vpmaQiLAogICAgIkRlc2NyaXB0aW9uIjogIuenu+mZpOW5tuemgeeUqOaJgOaciSBBSSDlip/og70v5YyF44CCIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxQb2xpY2llc1xcRXhwbG9yZXIiLAogICAgICAgICJOYW1lIjogIlNldHRpbmdzUGFnZVZpc2liaWxpdHkiLAogICAgICAgICJWYWx1ZSI6ICJoaWRlOmFpY29tcG9uZW50cyIsCiAgICAgICAgIlR5cGUiOiAiU3RyaW5nIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcV2luZG93c05vdGVwYWQiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVBSUZlYXR1cmVzIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgJEFwcHggPSAoR2V0LUFwcHhQYWNrYWdlIE1pY3Jvc29mdFdpbmRvd3MuQ2xpZW50LkNvcmVBSSkuUGFja2FnZUZ1bGxOYW1lICAgICAgJFNpZCA9IChHZXQtTG9jYWxVc2VyICRFbnY6VXNlck5hbWUpLlNpZC5WYWx1ZSAgICAgIE5ldy1JdGVtIFwiSEtMTTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxBcHB4XFxBcHB4QWxsVXNlclN0b3JlXFxFbmRPZkxpZmVcXCRTaWRcXCRBcHB4XCIgLUZvcmNlICAgICAgR2V0LUFwcHhQYWNrYWdlIC1BbGxVc2VycyBcIipDb3BpbG90KlwiIHwgUmVtb3ZlLUFwcHhQYWNrYWdlIC1BbGxVc2VycyAgICAgIHdpbmdldCB1bmluc3RhbGwgLWUgLS1uYW1lIFwiQ29waWxvdFwiIC0tc2lsZW50IC0tZm9yY2UgLS1hY2NlcHQtc291cmNlLWFncmVlbWVudHMgMj4kbnVsbCAgICAgIEdldC1BcHB4UGFja2FnZSAtQWxsVXNlcnMgTWljcm9zb2Z0Lk1pY3Jvc29mdE9mZmljZUh1YiB8IFJlbW92ZS1BcHB4UGFja2FnZSAtQWxsVXNlcnMgICAgICBpZiAoJEFwcHgpIHsgICAgICAgICAgUmVtb3ZlLUFwcHhQYWNrYWdlICRBcHB4ICAgICAgfSAgICAgIFNldC1TZXJ2aWNlIC1OYW1lIFdTQUlGYWJyaWNTdmMgLVN0YXJ0dXBUeXBlIERpc2FibGVkICAgICAgRGlzYWJsZS1XaW5kb3dzT3B0aW9uYWxGZWF0dXJlIC1GZWF0dXJlTmFtZSBSZWNhbGwgLU9ubGluZSAtTm9SZXN0YXJ0ICAgICAgV3JpdGUtSG9zdCBcIldpbmRvd3MgQUkgRGlzYWJsZWRcIiAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3dpbmRvd3NhaSIKICB9LAogICJXUEZUd2Vha3NXUEJUIjogewogICAgIkNvbnRlbnQiOiAiV2luZG93cyDlubPlj7Dkuozov5vliLbooaggKFdQQlQpIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlpoLmnpzlkK/nlKjvvIxXUEJUIOWFgeiuuOiuoeeul+acuuS+m+W6lOWVhuWcqOWQr+WKqOaXtuaJp+ihjOeoi+W6j++8jOWtmOWcqOa9nOWcqOWuieWFqOmjjumZqeOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxTZXNzaW9uIE1hbmFnZXIiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVXcGJ0RXhlY3V0aW9uIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9lc3NlbnRpYWwtdHdlYWtzL3dwYnQiCiAgfSwKICAiV1BGVHdlYWtzUHJldmVudERldmljZU1ldGFkYXRhRnJvbU5ldHdvcmsiOiB7CiAgICAiQ29udGVudCI6ICLpmLvmraLorr7lpIfphY3lpZflupTnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIumYsuatouaPkuWFpeiuvuWkh+aXtuWuieijhemineWklueahOi9r+S7tuOAguWtmOWcqOa9nOWcqOWuieWFqOmjjumZqeOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcV2luZG93c1xcRGV2aWNlIE1ldGFkYXRhIiwKICAgICAgICAiTmFtZSI6ICJQcmV2ZW50RGV2aWNlTWV0YWRhdGFGcm9tTmV0d29yayIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI8UmVtb3ZlRW50cnk+IgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9wcmV2ZW50ZGV2aWNlbWV0YWRhdGFmcm9tbmV0d29yayIKICB9LAogICJXUEZUd2Vha3NSYXplckJsb2NrIjogewogICAgIkNvbnRlbnQiOiAi6Zu36JuH6L2v5Lu26Ieq5Yqo5a6J6KOFIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICLpmLvmraLmiYDmnInpm7fom4fova/ku7bnmoTlronoo4XjgILnoazku7bml6DpnIDku7vkvZXova/ku7bljbPlj6/mraPluLjlt6XkvZzjgIIiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXERyaXZlclNlYXJjaGluZyIsCiAgICAgICAgIk5hbWUiOiAiU2VhcmNoT3JkZXJDb25maWciLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcRGV2aWNlIEluc3RhbGxlciIsCiAgICAgICAgIk5hbWUiOiAiRGlzYWJsZUNvSW5zdGFsbGVycyIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIgogICAgICB9CiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIiAgICAgICRSYXplclBhdGggPSBcIiRFbnY6U3lzdGVtUm9vdFxcSW5zdGFsbGVyXFxSYXplclwiICAgICAgaWYgKFRlc3QtUGF0aCAkUmF6ZXJQYXRoKSB7ICAgICAgICBSZW1vdmUtSXRlbSAkUmF6ZXJQYXRoXFwqIC1SZWN1cnNlIC1Gb3JjZSAgICAgIH0gZWxzZSB7ICAgICAgICBOZXctSXRlbSAtUGF0aCAkUmF6ZXJQYXRoIC1JdGVtVHlwZSBEaXJlY3RvcnkgICAgICB9ICAgICAgaWNhY2xzICRSYXplclBhdGggL2RlbnkgXCJFdmVyeW9uZTooVylcIiAgICAgICIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIiAgICAgIGljYWNscyBcIiRFbnY6U3lzdGVtUm9vdFxcSW5zdGFsbGVyXFxSYXplclwiIC9yZW1vdmU6ZCBFdmVyeW9uZSAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3JhemVyYmxvY2siCiAgfSwKICAiV1BGVHdlYWtzRGlzYWJsZU5vdGlmaWNhdGlvbnMiOiB7CiAgICAiQ29udGVudCI6ICLns7vnu5/miZjnm5jpgJrnn6Xlkozml6XljoYgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqOaJgOaciemAmuefpe+8jOWMheaLrOaXpeWOhuOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcV2luZG93c1xcRXhwbG9yZXIiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVOb3RpZmljYXRpb25DZW50ZXIiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcUHVzaE5vdGlmaWNhdGlvbnMiLAogICAgICAgICJOYW1lIjogIlRvYXN0RW5hYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9kaXNhYmxlbm90aWZpY2F0aW9ucyIKICB9LAogICJXUEZUd2Vha3NCbG9ja0Fkb2JlTmV0IjogewogICAgIkNvbnRlbnQiOiAiQWRvYmUgVVJMIOmYu+atouWIl+ihqCAtIOWQr+eUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi6YCa6L+H6YCJ5oup5oCn6Zi75q2iIEFkb2JlIOi/nuaOpeadpeWHj+WwkeS4jeW/heimgeeahOeUqOaIt+W5suaJsCIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICAkaG9zdHNVcmwgPSBJbnZva2UtUmVzdE1ldGhvZCAtVXJpIGh0dHBzOi8vZ2l0aHViLmNvbS9SdWRkZXJuYXRpb24tRGVzaWducy9BZG9iZS1VUkwtQmxvY2stTGlzdC9yYXcvcmVmcy9oZWFkcy9tYXN0ZXIvaG9zdHMgICAgICBBZGQtQ29udGVudCAtUGF0aCBcIiRFbnY6U3lzdGVtUm9vdFxcU3lzdGVtMzJcXGRyaXZlcnNcXGV0Y1xcaG9zdHNcIiAtVmFsdWUgJGhvc3RzVXJsICAgICAgaXBjb25maWcgL2ZsdXNoZG5zICAgICAgV3JpdGUtSG9zdCAnQWRkZWQgQWRvYmUgdXJsIGJsb2NrIGxpc3QgZnJvbSBob3N0IGZpbGUnICAgICAgIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAiICAgICAgU2V0LUNvbnRlbnQgXCIkRW52OlN5c3RlbVJvb3RcXFN5c3RlbTMyXFxkcml2ZXJzXFxldGNcXGhvc3RzXCIgKCAgICAgICAgICAoR2V0LUNvbnRlbnQgXCIkRW52OlN5c3RlbVJvb3RcXFN5c3RlbTMyXFxkcml2ZXJzXFxldGNcXGhvc3RzXCIpIC1qb2luIFwiYG5cIiAtcmVwbGFjZSAnKD9zKSNOZXcgVmVyLionLCAnJyAgICAgICkgICAgICBpcGNvbmZpZyAvZmx1c2hkbnMgICAgICBXcml0ZS1Ib3N0ICdSZW1vdmVkIEFkb2JlIHVybCBibG9jayBsaXN0IGZyb20gaG9zdCBmaWxlJyAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL2Jsb2NrYWRvYmVuZXQiCiAgfSwKICAiV1BGVHdlYWtzUmlnaHRDbGlja01lbnUiOiB7CiAgICAiQ29udGVudCI6ICLlj7PplK7oj5zljZXml6fniYjluIPlsYAgLSDlkK/nlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuaBouWkjeaWh+S7tui1hOa6kOeuoeeQhuWZqOS4reWPs+mUruWNleWHu+aXtueahOe7j+WFuOWPs+mUruiPnOWNleOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICBOZXctSXRlbSAtUGF0aCBcIkhLQ1U6XFxTb2Z0d2FyZVxcQ2xhc3Nlc1xcQ0xTSURcXHs4NmNhMWFhMC0zNGFhLTRlOGItYTUwOS01MGM5MDViYWUyYTJ9XCIgLU5hbWUgSW5wcm9jU2VydmVyMzIgLVZhbHVlIFwiXCIgLUZvcmNlICAgICAgU3RvcC1Qcm9jZXNzIC1OYW1lIGV4cGxvcmVyICAgICAgIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAiUmVtb3ZlLUl0ZW0gLVBhdGggXCJIS0NVOlxcU29mdHdhcmVcXENsYXNzZXNcXENMU0lEXFx7ODZjYTFhYTAtMzRhYS00ZThiLWE1MDktNTBjOTA1YmFlMmEyfVwiIC1SZWN1cnNlIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vcmlnaHRjbGlja21lbnUiCiAgfSwKICAiV1BGVHdlYWtzRGlza0NsZWFudXAiOiB7CiAgICAiQ29udGVudCI6ICLno4Hnm5jmuIXnkIYgLSDov5DooYwiLAogICAgIkRlc2NyaXB0aW9uIjogIuWcqCBDIOebmOi/kOihjOejgeebmOa4heeQhuW5tuenu+mZpOaXp+eahCBXaW5kb3dzIOabtOaWsOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICBjbGVhbm1nci5leGUgL2QgQzogL1ZFUllMT1dESVNLICAgICAgRGlzbS5leGUgL29ubGluZSAvQ2xlYW51cC1JbWFnZSAvU3RhcnRDb21wb25lbnRDbGVhbnVwIC9SZXNldEJhc2UgICAgICAiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9kaXNrY2xlYW51cCIKICB9LAogICJXUEZUd2Vha3NEZWxldGVUZW1wRmlsZXMiOiB7CiAgICAiQ29udGVudCI6ICLkuLTml7bmlofku7YgLSDnp7vpmaQiLAogICAgIkRlc2NyaXB0aW9uIjogIua4hemZpOS4tOaXtuaWh+S7tuWkueOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi5Z+65pys5LyY5YyWIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJJbnZva2VTY3JpcHQiOiBbCiAgICAgICIgICAgICBSZW1vdmUtSXRlbSAtUGF0aCBcIiRFbnY6VGVtcFxcKlwiIC1SZWN1cnNlIC1Gb3JjZSAgICAgIFJlbW92ZS1JdGVtIC1QYXRoIFwiJEVudjpTeXN0ZW1Sb290XFxUZW1wXFwqXCIgLVJlY3Vyc2UgLUZvcmNlICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2Vzc2VudGlhbC10d2Vha3MvZGVsZXRldGVtcGZpbGVzIgogIH0sCiAgIldQRlR3ZWFrc0lQdjQ2IjogewogICAgIkNvbnRlbnQiOiAiSVB2NiAtIOiuvue9riBJUHY0IOS4uummlumAiSIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Zyo5pyq6YWN572uIElQdjYg55qE56eB5pyJ572R57uc5LiK6K6+572uIElQdjQg6aaW6YCJ6aG55Y+v5bim5p2l5bu26L+f5ZKM5a6J5YWo5pa56Z2i55qE5aW95aSE44CCIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXFNlcnZpY2VzXFxUY3BpcDZcXFBhcmFtZXRlcnMiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVkQ29tcG9uZW50cyIsCiAgICAgICAgIlZhbHVlIjogIjMyIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vaXB2NDYiCiAgfSwKICAiV1BGVHdlYWtzVGVyZWRvIjogewogICAgIkNvbnRlbnQiOiAiVGVyZWRvIC0g56aB55SoIiwKICAgICJEZXNjcmlwdGlvbiI6ICJUZXJlZG8g572R57uc6Zqn6YGT5piv5LiA56eNIElQdjYg5Yqf6IO977yM5Y+v6IO95a+86Ie06aKd5aSW5bu26L+f44CCIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXFNlcnZpY2VzXFxUY3BpcDZcXFBhcmFtZXRlcnMiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVkQ29tcG9uZW50cyIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIgogICAgICB9CiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIm5ldHNoIGludGVyZmFjZSB0ZXJlZG8gc2V0IHN0YXRlIGRpc2FibGVkIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAibmV0c2ggaW50ZXJmYWNlIHRlcmVkbyBzZXQgc3RhdGUgZGVmYXVsdCIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy96LS1hZHZhbmNlZC10d2Vha3MtLS1jYXV0aW9uL3RlcmVkbyIKICB9LAogICJXUEZUd2Vha3NEaXNhYmxlSVB2NiI6IHsKICAgICJDb250ZW50IjogIklQdjYgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqCBJUHY244CCIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXFNlcnZpY2VzXFxUY3BpcDZcXFBhcmFtZXRlcnMiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVkQ29tcG9uZW50cyIsCiAgICAgICAgIlZhbHVlIjogIjI1NSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiRGlzYWJsZS1OZXRBZGFwdGVyQmluZGluZyAtTmFtZSAqIC1Db21wb25lbnRJRCBtc190Y3BpcDYiCiAgICBdLAogICAgIlVuZG9TY3JpcHQiOiBbCiAgICAgICJFbmFibGUtTmV0QWRhcHRlckJpbmRpbmcgLU5hbWUgKiAtQ29tcG9uZW50SUQgbXNfdGNwaXA2IgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vZGlzYWJsZWlwdjYiCiAgfSwKICAiV1BGVHdlYWtzRGlzYWJsZUJHYXBwcyI6IHsKICAgICJDb250ZW50IjogIuWQjuWPsOW6lOeUqCAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi56aB55So5omA5pyJIE1pY3Jvc29mdCBTdG9yZSDlupTnlKjlnKjlkI7lj7Dov5DooYzjgIIiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEJhY2tncm91bmRBY2Nlc3NBcHBsaWNhdGlvbnMiLAogICAgICAgICJOYW1lIjogIkdsb2JhbFVzZXJEaXNhYmxlZCIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9kaXNhYmxlYmdhcHBzIgogIH0sCiAgIldQRlR3ZWFrc0Rpc2FibGVGU08iOiB7CiAgICAiQ29udGVudCI6ICLlhajlsY/kvJjljJYgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIuemgeeUqOaJgOacieW6lOeUqOeahOWFqOWxj+S8mOWMluOAguazqOaEj++8mui/meWwhuemgeeUqOeLrOWNoOWFqOWxj+eahOiJsuW9qeeuoeeQhuOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6auY57qn5LyY5YyWIC0g6LCo5oWO5pON5L2cIiwKICAgICJwYW5lbCI6ICIxIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTeXN0ZW1cXEdhbWVDb25maWdTdG9yZSIsCiAgICAgICAgIk5hbWUiOiAiR2FtZURWUl9EWEdJSG9ub3JGU0VXaW5kb3dzQ29tcGF0aWJsZSIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3Mvei0tYWR2YW5jZWQtdHdlYWtzLS0tY2F1dGlvbi9kaXNhYmxlZnNvIgogIH0sCiAgIldQRlR3ZWFrc0Rpc2FibGVFeHBsb3JlckF1dG9EaXNjb3ZlcnkiOiB7CiAgICAiQ29udGVudCI6ICLmlofku7botYTmupDnrqHnkIblmajoh6rliqjmlofku7blpLnlj5HnjrAgLSDnpoHnlKgiLAogICAgIkRlc2NyaXB0aW9uIjogIldpbmRvd3Mg6LWE5rqQ566h55CG5Zmo6Ieq5Yqo5qC55o2u5YaF5a6554yc5rWL5paH5Lu25aS557G75Z6L44CC6K2m5ZGK77yB5bCG56aB55So5paH5Lu26LWE5rqQ566h55CG5Zmo5YiG57uE44CCIiwKICAgICJjYXRlZ29yeSI6ICLln7rmnKzkvJjljJYiLAogICAgInBhbmVsIjogIjEiLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIiAgICAgICMgUHJldmlvdXNseSBkZXRlY3RlZCBmb2xkZXJzICAgICAgJGJhZ3MgPSBcIkhLQ1U6XFxTb2Z0d2FyZVxcQ2xhc3Nlc1xcTG9jYWwgU2V0dGluZ3NcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXFNoZWxsXFxCYWdzXCIgICAgICAjIEZvbGRlciB0eXBlcyBsb29rdXAgdGFibGUgICAgICAkYmFnTVJVID0gXCJIS0NVOlxcU29mdHdhcmVcXENsYXNzZXNcXExvY2FsIFNldHRpbmdzXFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxTaGVsbFxcQmFnTVJVXCIgICAgICAjIEZsdXNoIEV4cGxvcmVyIHZpZXcgZGF0YWJhc2UgICAgICBSZW1vdmUtSXRlbSAtUGF0aCAkYmFncyAtUmVjdXJzZSAtRm9yY2UgICAgICBXcml0ZS1Ib3N0IFwiUmVtb3ZlZCAkYmFnc1wiICAgICAgUmVtb3ZlLUl0ZW0gLVBhdGggJGJhZ01SVSAtUmVjdXJzZSAtRm9yY2UgICAgICBXcml0ZS1Ib3N0IFwiUmVtb3ZlZCAkYmFnTVJVXCIgICAgICAjIEV2ZXJ5IGZvbGRlciAgICAgICRhbGxGb2xkZXJzID0gXCJIS0NVOlxcU29mdHdhcmVcXENsYXNzZXNcXExvY2FsIFNldHRpbmdzXFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxTaGVsbFxcQmFnc1xcQWxsRm9sZGVyc1xcU2hlbGxcIiAgICAgIGlmICghKFRlc3QtUGF0aCAkYWxsRm9sZGVycykpIHsgICAgICAgIE5ldy1JdGVtIC1QYXRoICRhbGxGb2xkZXJzIC1Gb3JjZSAgICAgICAgV3JpdGUtSG9zdCBcIkNyZWF0ZWQgJGFsbEZvbGRlcnNcIiAgICAgIH0gICAgICAjIEdlbmVyaWMgdmlldyAgICAgIE5ldy1JdGVtUHJvcGVydHkgLVBhdGggJGFsbEZvbGRlcnMgLU5hbWUgXCJGb2xkZXJUeXBlXCIgLVZhbHVlIFwiTm90U3BlY2lmaWVkXCIgLVByb3BlcnR5VHlwZSBTdHJpbmcgLUZvcmNlICAgICAgV3JpdGUtSG9zdCBcIlNldCBGb2xkZXJUeXBlIHRvIE5vdFNwZWNpZmllZFwiICAgICAgV3JpdGUtSG9zdCBQbGVhc2Ugc2lnbiBvdXQgYW5kIGJhY2sgaW4sIG9yIHJlc3RhcnQgeW91ciBjb21wdXRlciB0byBhcHBseSB0aGUgY2hhbmdlcyEgICAgICAiCiAgICBdLAogICAgIlVuZG9TY3JpcHQiOiBbCiAgICAgICIgICAgICAjIFByZXZpb3VzbHkgZGV0ZWN0ZWQgZm9sZGVycyAgICAgICRiYWdzID0gXCJIS0NVOlxcU29mdHdhcmVcXENsYXNzZXNcXExvY2FsIFNldHRpbmdzXFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxTaGVsbFxcQmFnc1wiICAgICAgIyBGb2xkZXIgdHlwZXMgbG9va3VwIHRhYmxlICAgICAgJGJhZ01SVSA9IFwiSEtDVTpcXFNvZnR3YXJlXFxDbGFzc2VzXFxMb2NhbCBTZXR0aW5nc1xcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcU2hlbGxcXEJhZ01SVVwiICAgICAgIyBGbHVzaCBFeHBsb3JlciB2aWV3IGRhdGFiYXNlICAgICAgUmVtb3ZlLUl0ZW0gLVBhdGggJGJhZ3MgLVJlY3Vyc2UgLUZvcmNlICAgICAgV3JpdGUtSG9zdCBcIlJlbW92ZWQgJGJhZ3NcIiAgICAgIFJlbW92ZS1JdGVtIC1QYXRoICRiYWdNUlUgLVJlY3Vyc2UgLUZvcmNlICAgICAgV3JpdGUtSG9zdCBcIlJlbW92ZWQgJGJhZ01SVVwiICAgICAgV3JpdGUtSG9zdCBQbGVhc2Ugc2lnbiBvdXQgYW5kIGJhY2sgaW4sIG9yIHJlc3RhcnQgeW91ciBjb21wdXRlciB0byBhcHBseSB0aGUgY2hhbmdlcyEgICAgICAiCiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvZXNzZW50aWFsLXR3ZWFrcy9kaXNhYmxlZXhwbG9yZXJhdXRvZGlzY292ZXJ5IgogIH0sCiAgIldQRlRvZ2dsZURldGFpbGVkQlNvRCI6IHsKICAgICJDb250ZW50IjogIuiTneWxj+ivpue7huaooeW8jyIsCiAgICAiRGVzY3JpcHRpb24iOiAi6JOd5bGP5pe25o+Q5L6b5pu05aSa5L+h5oGv44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxDcmFzaENvbnRyb2wiLAogICAgICAgICJOYW1lIjogIkRpc3BsYXlQYXJhbWV0ZXJzIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAiZmFsc2UiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU1lTVEVNXFxDdXJyZW50Q29udHJvbFNldFxcQ29udHJvbFxcQ3Jhc2hDb250cm9sIiwKICAgICAgICAiTmFtZSI6ICJEaXNhYmxlRW1vdGljb24iLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJmYWxzZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9kZXRhaWxlZGJzb2QiCiAgfSwKICAiV1BGVG9nZ2xlQmF0dGVyeVBlcmNlbnRhZ2UiOiB7CiAgICAiQ29udGVudCI6ICLns7vnu5/miZjnm5jnlLXmsaDnmb7liIbmr5QiLAogICAgIkRlc2NyaXB0aW9uIjogIuWcqOezu+e7n+aJmOebmOS4reeUteaxoOWbvuagh+aXgeaYvuekuuaVsOWtl+eUteaxoOeZvuWIhuavlOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXEV4cGxvcmVyXFxBZHZhbmNlZCIsCiAgICAgICAgIk5hbWUiOiAiSXNCYXR0ZXJ5UGVyY2VudGFnZUVuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJmYWxzZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9iYXR0ZXJ5cGVyY2VudGFnZSIKICB9LAogICJXUEZUb2dnbGVEYXJrTW9kZSI6IHsKICAgICJDb250ZW50IjogIldpbmRvd3Mg5rex6Imy5Li76aKYIiwKICAgICJEZXNjcmlwdGlvbiI6ICLns7vnu5/lkozlupTnlKjnmoTmt7HoibLmqKHlvI/jgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxUaGVtZXNcXFBlcnNvbmFsaXplIiwKICAgICAgICAiTmFtZSI6ICJBcHBzVXNlTGlnaHRUaGVtZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogImZhbHNlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxUaGVtZXNcXFBlcnNvbmFsaXplIiwKICAgICAgICAiTmFtZSI6ICJTeXN0ZW1Vc2VzTGlnaHRUaGVtZSIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogImZhbHNlIgogICAgICB9CiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIiAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgICAgICBpZiAoJHN5bmMuVGhlbWVCdXR0b24uQ29udGVudCAtZXEgW2NoYXJdMHhGMDhDKSB7ICAgICAgICBJbnZva2UtV2ludXRpbFRoZW1lQ2hhbmdlIC10aGVtZSBcIkF1dG9cIiAgICAgIH0gICAgICAiCiAgICBdLAogICAgIlVuZG9TY3JpcHQiOiBbCiAgICAgICIgICAgICBJbnZva2UtV2luVXRpbEV4cGxvcmVyVXBkYXRlICAgICAgaWYgKCRzeW5jLlRoZW1lQnV0dG9uLkNvbnRlbnQgLWVxIFtjaGFyXTB4RjA4QykgeyAgICAgICAgSW52b2tlLVdpbnV0aWxUaGVtZUNoYW5nZSAtdGhlbWUgXCJBdXRvXCIgICAgICB9ICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9kYXJrbW9kZSIKICB9LAogICJXUEZUb2dnbGVTaG93RXh0IjogewogICAgIkNvbnRlbnQiOiAi5paH5Lu26LWE5rqQ566h55CG5Zmo5paH5Lu25omp5bGV5ZCNIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlnKjotYTmupDnrqHnkIblmajkuK3mmL7npLrmlofku7bmianlsZXlkI3vvIguZXhl44CBLnBuZyDnrYnvvInjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIkhpZGVGaWxlRXh0IiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjEiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAiZmFsc2UiCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgSW52b2tlLVdpblV0aWxFeHBsb3JlclVwZGF0ZSAtYWN0aW9uIFwicmVzdGFydFwiICAgICAgIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAiICAgICAgSW52b2tlLVdpblV0aWxFeHBsb3JlclVwZGF0ZSAtYWN0aW9uIFwicmVzdGFydFwiICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9zaG93ZXh0IgogIH0sCiAgIldQRlRvZ2dsZUhpZGRlbkZpbGVzIjogewogICAgIkNvbnRlbnQiOiAi5paH5Lu26LWE5rqQ566h55CG5Zmo6ZqQ6JeP5paH5Lu2IiwKICAgICJEZXNjcmlwdGlvbiI6ICLlnKjotYTmupDnrqHnkIblmajkuK3mmL7npLrpmpDol4/mlofku7bjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIkhpZGRlbiIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogImZhbHNlIgogICAgICB9CiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIiAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgLWFjdGlvbiBcInJlc3RhcnRcIiAgICAgICIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIiAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgLWFjdGlvbiBcInJlc3RhcnRcIiAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvaGlkZGVuZmlsZXMiCiAgfSwKICAiV1BGVG9nZ2xlVmVyYm9zZUxvZ29uIjogewogICAgIkNvbnRlbnQiOiAi55m75b2V6K+m57uG5qih5byPIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlnKjlkK/liqgv5YWz5py65pe25pi+56S66K+m57uG5L+h5oGv44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcUG9saWNpZXNcXFN5c3RlbSIsCiAgICAgICAgIk5hbWUiOiAiVmVyYm9zZVN0YXR1cyIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogImZhbHNlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL3ZlcmJvc2Vsb2dvbiIKICB9LAogICJXUEZUb2dnbGVOZXdPdXRsb29rIjogewogICAgIkNvbnRlbnQiOiAiTWljcm9zb2Z0IE91dGxvb2sg5paw54mIIiwKICAgICJEZXNjcmlwdGlvbiI6ICLov5nlsIbnoa7kv53kvb/nlKjnu4/lhbggT3V0bG9vayDlupTnlKjnqIvluo/jgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXE9mZmljZVxcMTYuMFxcT3V0bG9va1xcUHJlZmVyZW5jZXMiLAogICAgICAgICJOYW1lIjogIlVzZU5ld091dGxvb2siLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXE9mZmljZVxcMTYuMFxcT3V0bG9va1xcT3B0aW9uc1xcR2VuZXJhbCIsCiAgICAgICAgIk5hbWUiOiAiSGlkZU5ld091dGxvb2tUb2dnbGUiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxPZmZpY2VcXDE2LjBcXE91dGxvb2tcXE9wdGlvbnNcXEdlbmVyYWwiLAogICAgICAgICJOYW1lIjogIkRvTmV3T3V0bG9va0F1dG9NaWdyYXRpb24iLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJmYWxzZSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcT2ZmaWNlXFwxNi4wXFxPdXRsb29rXFxQcmVmZXJlbmNlcyIsCiAgICAgICAgIk5hbWUiOiAiTmV3T3V0bG9va01pZ3JhdGlvblVzZXJTZXR0aW5nIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjxSZW1vdmVFbnRyeT4iLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAidHJ1ZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9uZXdvdXRsb29rIgogIH0sCiAgIldQRlRvZ2dsZVNjcm9sbGJhcnMiOiB7CiAgICAiQ29udGVudCI6ICLmu5rliqjmnaHlp4vnu4jlj6/op4EiLAogICAgIkRlc2NyaXB0aW9uIjogIuWmguaenOWQr+eUqO+8jOa7muWKqOadoeWwhuWni+e7iOWPr+ingeOAguWmguaenOemgeeUqO+8jFdpbmRvd3Mg5bCG6Ieq5Yqo6ZqQ6JeP5LiN5L2/55So55qE5rua5Yqo5p2h44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxDb250cm9sIFBhbmVsXFxBY2Nlc3NpYmlsaXR5IiwKICAgICAgICAiTmFtZSI6ICJEeW5hbWljU2Nyb2xsYmFycyIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogImZhbHNlIiwKICAgICAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvc2Nyb2xsYmFycyIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9zY3JvbGxiYXJzIgogIH0sCiAgIldQRlRvZ2dsZU11bHRpcGxhbmVPdmVybGF5IjogewogICAgIkNvbnRlbnQiOiAi5aSa5bmz6Z2i6KaG55uWIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlpJrlubPpnaLopobnm5blkIjmiJDlpJrkuKrlm77lg4/lsYLvvIzmnInml7blj6/og73lr7zoh7TmmL7ljaHpl67popjjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxNaWNyb3NvZnRcXFdpbmRvd3NcXER3bSIsCiAgICAgICAgIk5hbWUiOiAiT3ZlcmxheVRlc3RNb2RlIiwKICAgICAgICAiVmFsdWUiOiAiMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjUiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAidHJ1ZSIKICAgICAgfSwKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxHcmFwaGljc0RyaXZlcnMiLAogICAgICAgICJOYW1lIjogIkRpc2FibGVPdmVybGF5cyIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogInRydWUiCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvbXVsdGlwbGFuZW92ZXJsYXkiCiAgfSwKICAiV1BGVG9nZ2xlTW91c2VBY2NlbGVyYXRpb24iOiB7CiAgICAiQ29udGVudCI6ICLpvKDmoIfliqDpgJ8iLAogICAgIkRlc2NyaXB0aW9uIjogIuS9v+WFieagh+enu+WKqOWPl+eJqeeQhum8oOagh+enu+WKqOmAn+W6pueahOW9seWTjeOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcQ29udHJvbCBQYW5lbFxcTW91c2UiLAogICAgICAgICJOYW1lIjogIk1vdXNlU3BlZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXENvbnRyb2wgUGFuZWxcXE1vdXNlIiwKICAgICAgICAiTmFtZSI6ICJNb3VzZVRocmVzaG9sZDEiLAogICAgICAgICJWYWx1ZSI6ICI2IiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXENvbnRyb2wgUGFuZWxcXE1vdXNlIiwKICAgICAgICAiTmFtZSI6ICJNb3VzZVRocmVzaG9sZDIiLAogICAgICAgICJWYWx1ZSI6ICIxMCIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAidHJ1ZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9tb3VzZWFjY2VsZXJhdGlvbiIKICB9LAogICJXUEZUb2dnbGVOdW1Mb2NrIjogewogICAgIkNvbnRlbnQiOiAi5byA5py6IE51bSBMb2NrIOmUrueKtuaAgSIsCiAgICAiRGVzY3JpcHRpb24iOiAi5Zyo6K6h566X5py65ZCv5Yqo5pe25YiH5o2iIE51bSBMb2NrIOmUrueKtuaAgeOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS1U6XFwuRGVmYXVsdFxcQ29udHJvbCBQYW5lbFxcS2V5Ym9hcmQiLAogICAgICAgICJOYW1lIjogIkluaXRpYWxLZXlib2FyZEluZGljYXRvcnMiLAogICAgICAgICJWYWx1ZSI6ICIyIiwKICAgICAgICAiVHlwZSI6ICJTdHJpbmciLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAiZmFsc2UiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcQ29udHJvbCBQYW5lbFxcS2V5Ym9hcmQiLAogICAgICAgICJOYW1lIjogIkluaXRpYWxLZXlib2FyZEluZGljYXRvcnMiLAogICAgICAgICJWYWx1ZSI6ICIyIiwKICAgICAgICAiVHlwZSI6ICJTdHJpbmciLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAiZmFsc2UiCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvbnVtbG9jayIKICB9LAogICJXUEZUb2dnbGVXaW5kb3dTbmFwcGluZyI6IHsKICAgICJDb250ZW50IjogIueql+WPo+i0tOmdoCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YiH5o2i5ouW5Yqo56qX5Y+j5pe255qE56qX5Y+j6LS06Z2g5Yqf6IO944CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxDb250cm9sIFBhbmVsXFxEZXNrdG9wIiwKICAgICAgICAiTmFtZSI6ICJXaW5kb3dBcnJhbmdlbWVudEFjdGl2ZSIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIlN0cmluZyIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL3dpbmRvd3NuYXBwaW5nIgogIH0sCiAgIldQRlRvZ2dsZVN0YW5kYnlGaXgiOiB7CiAgICAiQ29udGVudCI6ICJTMCDnnaHnnKDnvZHnu5zov57mjqUiLAogICAgIkRlc2NyaXB0aW9uIjogIuWIh+aNoueOsOS7o+eslOiusOacrOeUteiEkeS9juWKn+iAl+epuumXsiAoUzAg552h55ygKSDmnJ/pl7TnmoTnvZHnu5zov57mjqXjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxQb3dlclxcUG93ZXJTZXR0aW5nc1xcZjE1NTc2ZTgtOThiNy00MTg2LWI5NDQtZWFmYTY2NDQwMmQ5IiwKICAgICAgICAiTmFtZSI6ICJBQ1NldHRpbmdJbmRleCIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogInRydWUiCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvc3RhbmRieWZpeCIKICB9LAogICJXUEZUb2dnbGVTM1NsZWVwIjogewogICAgIkNvbnRlbnQiOiAiUzMg5LyR55ygIiwKICAgICJEZXNjcmlwdGlvbiI6ICLlnKjnjrDku6PlvoXmnLrlkowgUzMg5LyR55yg5LmL6Ze05YiH5o2i44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTWVNURU1cXEN1cnJlbnRDb250cm9sU2V0XFxDb250cm9sXFxQb3dlciIsCiAgICAgICAgIk5hbWUiOiAiUGxhdGZvcm1Bb0FjT3ZlcnJpZGUiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJmYWxzZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9zM3NsZWVwIgogIH0sCiAgIldQRlRvZ2dsZUhpZGVTZXR0aW5nc0hvbWUiOiB7CiAgICAiQ29udGVudCI6ICLorr7nva7kuLvpobUiLAogICAgIkRlc2NyaXB0aW9uIjogIuWIh+aNoiBXaW5kb3dzIOiuvue9ruW6lOeUqOS4reeahOS4u+mhteOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXFBvbGljaWVzXFxFeHBsb3JlciIsCiAgICAgICAgIk5hbWUiOiAiU2V0dGluZ3NQYWdlVmlzaWJpbGl0eSIsCiAgICAgICAgIlZhbHVlIjogInNob3c6aG9tZSIsCiAgICAgICAgIlR5cGUiOiAiU3RyaW5nIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICJoaWRlOmhvbWUiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAidHJ1ZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9oaWRlc2V0dGluZ3Nob21lIgogIH0sCiAgIldQRlRvZ2dsZUJpbmdTZWFyY2giOiB7CiAgICAiQ29udGVudCI6ICLlvIDlp4voj5zljZXlv4XlupTmkJzntKIiLAogICAgIkRlc2NyaXB0aW9uIjogIuWIh+aNoiBXaW5kb3dzIOaQnOe0ouS4reeahOW/heW6lOe9kemhteaQnOe0oue7k+aenOOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcV2luZG93c1xcQ3VycmVudFZlcnNpb25cXFNlYXJjaCIsCiAgICAgICAgIk5hbWUiOiAiQmluZ1NlYXJjaEVuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL2JpbmdzZWFyY2giCiAgfSwKICAiV1BGVG9nZ2xlTG9naW5CbHVyIjogewogICAgIkNvbnRlbnQiOiAi55m75b2V5bGP5bmV5Lqa5YWL5Yqb5qih57OKIiwKICAgICJEZXNjcmlwdGlvbiI6ICLliIfmjaLnmbvlvZXlsY/luZXog4zmma/kuIrnmoTkuprlhYvlipvmqKHns4rmlYjmnpzjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxXaW5kb3dzXFxTeXN0ZW0iLAogICAgICAgICJOYW1lIjogIkRpc2FibGVBY3J5bGljQmFja2dyb3VuZE9uTG9nb24iLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL2xvZ2luYmx1ciIKICB9LAogICJXUEZUd2Vha3NEaXNhYmxlTG9ja3NjcmVlbiI6IHsKICAgICJDb250ZW50IjogIumUgeWumuWxj+W5lSAtIOemgeeUqCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5a6M5YWo6Lez6L+H6ZSB5a6a5bGP5bmV77yM5Zyo5ZCv5Yqo5ZKM5ZSk6YaS5pe255u05o6l6L+b5YWl55m75b2V5bGP5bmV44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLTE06XFxTT0ZUV0FSRVxcUG9saWNpZXNcXE1pY3Jvc29mdFxcV2luZG93c1xcUGVyc29uYWxpemF0aW9uIiwKICAgICAgICAiTmFtZSI6ICJOb0xvY2tTY3JlZW4iLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiPFJlbW92ZUVudHJ5PiIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9kaXNhYmxlbG9ja3NjcmVlbiIKICB9LAogICJXUEZUb2dnbGVTdGFydE1lbnVSZWNvbW1lbmRhdGlvbnMiOiB7CiAgICAiQ29udGVudCI6ICLlvIDlp4voj5zljZXmjqjojZAiLAogICAgIkRlc2NyaXB0aW9uIjogIuWIh+aNouW8gOWni+iPnOWNleS4reeahOaOqOiNkOmDqOWIhuOAguitpuWRiu+8mui/meS5n+S8muWQjOaXtuemgeeUqOmUgeWxj+S4iueahCBXaW5kb3dzIOiBmueEpuOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXE1pY3Jvc29mdFxcUG9saWN5TWFuYWdlclxcY3VycmVudFxcZGV2aWNlXFxTdGFydCIsCiAgICAgICAgIk5hbWUiOiAiSGlkZVJlY29tbWVuZGVkU2VjdGlvbiIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogInRydWUiCiAgICAgIH0sCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0xNOlxcU09GVFdBUkVcXE1pY3Jvc29mdFxcUG9saWN5TWFuYWdlclxcY3VycmVudFxcZGV2aWNlXFxFZHVjYXRpb24iLAogICAgICAgICJOYW1lIjogIklzRWR1Y2F0aW9uRW52aXJvbm1lbnQiLAogICAgICAgICJWYWx1ZSI6ICIwIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMSIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNPRlRXQVJFXFxQb2xpY2llc1xcTWljcm9zb2Z0XFxXaW5kb3dzXFxFeHBsb3JlciIsCiAgICAgICAgIk5hbWUiOiAiSGlkZVJlY29tbWVuZGVkU2VjdGlvbiIsCiAgICAgICAgIlZhbHVlIjogIjAiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIxIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogInRydWUiCiAgICAgIH0KICAgIF0sCiAgICAiSW52b2tlU2NyaXB0IjogWwogICAgICAiICAgICAgSW52b2tlLVdpblV0aWxFeHBsb3JlclVwZGF0ZSAtYWN0aW9uIFwicmVzdGFydFwiICAgICAgIgogICAgXSwKICAgICJVbmRvU2NyaXB0IjogWwogICAgICAiICAgICAgSW52b2tlLVdpblV0aWxFeHBsb3JlclVwZGF0ZSAtYWN0aW9uIFwicmVzdGFydFwiICAgICAgIgogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9zdGFydG1lbnVyZWNvbW1lbmRhdGlvbnMiCiAgfSwKICAiV1BGVG9nZ2xlU3RpY2t5S2V5cyI6IHsKICAgICJDb250ZW50IjogIueymOa7numUriIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YiH5o2i57KY5rue6ZSu5Yqf6IO977yM6K+l5Yqf6IO95Zyo5b+r6YCf54K55Ye7IFNoaWZ0IOmUruaXtua/gOa0u+OAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcQ29udHJvbCBQYW5lbFxcQWNjZXNzaWJpbGl0eVxcU3RpY2t5S2V5cyIsCiAgICAgICAgIk5hbWUiOiAiRmxhZ3MiLAogICAgICAgICJWYWx1ZSI6ICI1MDYiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICI1OCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL3N0aWNreWtleXMiCiAgfSwKICAiV1BGVG9nZ2xlVGFza2JhckFsaWdubWVudCI6IHsKICAgICJDb250ZW50IjogIuS7u+WKoeagj+WxheS4reWbvuaghyIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YiH5o2i5Lu75Yqh5qCP5Zu+5qCH5bem5a+56b2Q5oiW5bGF5Lit44CCIiwKICAgICJjYXRlZ29yeSI6ICLoh6rlrprkuYnlgY/lpb0iLAogICAgInBhbmVsIjogIjIiLAogICAgIlR5cGUiOiAiVG9nZ2xlIiwKICAgICJyZWdpc3RyeSI6IFsKICAgICAgewogICAgICAgICJQYXRoIjogIkhLQ1U6XFxTb2Z0d2FyZVxcTWljcm9zb2Z0XFxXaW5kb3dzXFxDdXJyZW50VmVyc2lvblxcRXhwbG9yZXJcXEFkdmFuY2VkIiwKICAgICAgICAiTmFtZSI6ICJUYXNrYmFyQWwiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgIkludm9rZVNjcmlwdCI6IFsKICAgICAgIiAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgLWFjdGlvbiBcInJlc3RhcnRcIiAgICAgICIKICAgIF0sCiAgICAiVW5kb1NjcmlwdCI6IFsKICAgICAgIiAgICAgIEludm9rZS1XaW5VdGlsRXhwbG9yZXJVcGRhdGUgLWFjdGlvbiBcInJlc3RhcnRcIiAgICAgICIKICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvdGFza2JhcmFsaWdubWVudCIKICB9LAogICJXUEZUb2dnbGVUYXNrYmFyU2VhcmNoIjogewogICAgIkNvbnRlbnQiOiAi5Lu75Yqh5qCP5pCc57Si5Zu+5qCHIiwKICAgICJEZXNjcmlwdGlvbiI6ICLliIfmjaLku7vliqHmoI/kuIrnmoTmkJzntKLmjInpkq7jgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxTZWFyY2giLAogICAgICAgICJOYW1lIjogIlNlYXJjaGJveFRhc2tiYXJNb2RlIiwKICAgICAgICAiVmFsdWUiOiAiMSIsCiAgICAgICAgIlR5cGUiOiAiRFdvcmQiLAogICAgICAgICJPcmlnaW5hbFZhbHVlIjogIjAiLAogICAgICAgICJEZWZhdWx0U3RhdGUiOiAidHJ1ZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy90YXNrYmFyc2VhcmNoIgogIH0sCiAgIldQRlRvZ2dsZVRhc2tWaWV3IjogewogICAgIkNvbnRlbnQiOiAi5Lu75Yqh5qCP5Lu75Yqh6KeG5Zu+5Zu+5qCHIiwKICAgICJEZXNjcmlwdGlvbiI6ICLliIfmjaLku7vliqHmoI/kuK3nmoTku7vliqHop4blm77mjInpkq7jgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXFdpbmRvd3NcXEN1cnJlbnRWZXJzaW9uXFxFeHBsb3JlclxcQWR2YW5jZWQiLAogICAgICAgICJOYW1lIjogIlNob3dUYXNrVmlld0J1dHRvbiIsCiAgICAgICAgIlZhbHVlIjogIjEiLAogICAgICAgICJUeXBlIjogIkRXb3JkIiwKICAgICAgICAiT3JpZ2luYWxWYWx1ZSI6ICIwIiwKICAgICAgICAiRGVmYXVsdFN0YXRlIjogInRydWUiCiAgICAgIH0KICAgIF0sCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9jdXN0b21pemUtcHJlZmVyZW5jZXMvdGFza3ZpZXciCiAgfSwKICAiV1BGVG9nZ2xlR2FtZU1vZGUiOiB7CiAgICAiQ29udGVudCI6ICLmuLjmiI/mqKHlvI8iLAogICAgIkRlc2NyaXB0aW9uIjogIuWIh+aNoiBXaW5kb3dzIOmAmui/h+WIhumFjeezu+e7n+i1hOa6kOe7mea4uOaIj+adpeS8mOWFiOiAg+iZkea4uOaIj+aAp+iDveOAgiIsCiAgICAiY2F0ZWdvcnkiOiAi6Ieq5a6a5LmJ5YGP5aW9IiwKICAgICJwYW5lbCI6ICIyIiwKICAgICJUeXBlIjogIlRvZ2dsZSIsCiAgICAicmVnaXN0cnkiOiBbCiAgICAgIHsKICAgICAgICAiUGF0aCI6ICJIS0NVOlxcU29mdHdhcmVcXE1pY3Jvc29mdFxcR2FtZUJhciIsCiAgICAgICAgIk5hbWUiOiAiQWxsb3dBdXRvR2FtZU1vZGUiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9LAogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtDVTpcXFNvZnR3YXJlXFxNaWNyb3NvZnRcXEdhbWVCYXIiLAogICAgICAgICJOYW1lIjogIkF1dG9HYW1lTW9kZUVuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJ0cnVlIgogICAgICB9CiAgICBdLAogICAgImxpbmsiOiAiaHR0cHM6Ly93aW51dGlsLmNocmlzdGl0dXMuY29tL2Rldi90d2Vha3MvY3VzdG9taXplLXByZWZlcmVuY2VzL2dhbWVtb2RlIgogIH0sCiAgIldQRlRvZ2dsZUxvbmdQYXRocyI6IHsKICAgICJDb250ZW50IjogIuWQr+eUqOmVv+i3r+W+hCIsCiAgICAiRGVzY3JpcHRpb24iOiAi5YiH5o2i6LWE5rqQ566h55CG5Zmo5Lit6LaF6L+HIDI2MCDkuKrlrZfnrKbnmoTmlofku7bot6/lvoTmlK/mjIHjgIIiLAogICAgImNhdGVnb3J5IjogIuiHquWumuS5ieWBj+WlvSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJUb2dnbGUiLAogICAgInJlZ2lzdHJ5IjogWwogICAgICB7CiAgICAgICAgIlBhdGgiOiAiSEtMTTpcXFNZU1RFTVxcQ3VycmVudENvbnRyb2xTZXRcXENvbnRyb2xcXEZpbGVTeXN0ZW0iLAogICAgICAgICJOYW1lIjogIkxvbmdQYXRoc0VuYWJsZWQiLAogICAgICAgICJWYWx1ZSI6ICIxIiwKICAgICAgICAiVHlwZSI6ICJEV29yZCIsCiAgICAgICAgIk9yaWdpbmFsVmFsdWUiOiAiMCIsCiAgICAgICAgIkRlZmF1bHRTdGF0ZSI6ICJmYWxzZSIKICAgICAgfQogICAgXSwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL2N1c3RvbWl6ZS1wcmVmZXJlbmNlcy9sb25ncGF0aHMiCiAgfSwKICAiV1BGT09TVWJ1dHRvbiI6IHsKICAgICJDb250ZW50IjogIk8mTyBTaHV0VXAxMCsrIC0g6L+Q6KGMIiwKICAgICJjYXRlZ29yeSI6ICLpq5jnuqfkvJjljJYgLSDosKjmhY7mk43kvZwiLAogICAgInBhbmVsIjogIjEiLAogICAgIlR5cGUiOiAiQnV0dG9uIiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vb29zdWJ1dHRvbiIKICB9LAogICJXUEZjaGFuZ2VkbnMiOiB7CiAgICAiQ29udGVudCI6ICJETlMgLSDorr7nva7kuLrvvJoiLAogICAgImNhdGVnb3J5IjogIumrmOe6p+S8mOWMliAtIOiwqOaFjuaTjeS9nCIsCiAgICAicGFuZWwiOiAiMSIsCiAgICAiVHlwZSI6ICJDb21ib2JveCIsCiAgICAiQ29tYm9JdGVtcyI6ICJEZWZhdWx0IERIQ1AgR29vZ2xlIENsb3VkZmxhcmUgQ2xvdWRmbGFyZV9NYWx3YXJlIENsb3VkZmxhcmVfTWFsd2FyZV9BZHVsdCBPcGVuX0ROUyBRdWFkOSBBZEd1YXJkX0Fkc19UcmFja2VycyBBZEd1YXJkX0Fkc19UcmFja2Vyc19NYWx3YXJlX0FkdWx0IiwKICAgICJsaW5rIjogImh0dHBzOi8vd2ludXRpbC5jaHJpc3RpdHVzLmNvbS9kZXYvdHdlYWtzL3otLWFkdmFuY2VkLXR3ZWFrcy0tLWNhdXRpb24vY2hhbmdlZG5zIgogIH0sCiAgIldQRkFkZFVsdFBlcmYiOiB7CiAgICAiQ29udGVudCI6ICLljZPotormgKfog73mlrnmoYggLSDlkK/nlKgiLAogICAgImNhdGVnb3J5IjogIuaAp+iDveiuoeWIkiAtIOS4jemAgueUqOS6jueslOiusOacrOeUteiEkSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9wZXJmb3JtYW5jZS1wbGFucy0tLW5vdC1mb3ItbGFwdG9wcy9hZGR1bHRwZXJmIgogIH0sCiAgIldQRlJlbW92ZVVsdFBlcmYiOiB7CiAgICAiQ29udGVudCI6ICLljZPotormgKfog73mlrnmoYggLSDnpoHnlKgiLAogICAgImNhdGVnb3J5IjogIuaAp+iDveiuoeWIkiAtIOS4jemAgueUqOS6jueslOiusOacrOeUteiEkSIsCiAgICAicGFuZWwiOiAiMiIsCiAgICAiVHlwZSI6ICJCdXR0b24iLAogICAgIkJ1dHRvbldpZHRoIjogIjMwMCIsCiAgICAibGluayI6ICJodHRwczovL3dpbnV0aWwuY2hyaXN0aXR1cy5jb20vZGV2L3R3ZWFrcy9wZXJmb3JtYW5jZS1wbGFucy0tLW5vdC1mb3ItbGFwdG9wcy9yZW1vdmV1bHRwZXJmIgogIH0KfQ==')) | ConvertFrom-Json

$inputXML = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('PFdpbmRvdwogICAgICAgIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL3dpbmZ4LzIwMDYveGFtbC9wcmVzZW50YXRpb24iCiAgICAgICAgeG1sbnM6eD0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS93aW5meC8yMDA2L3hhbWwiCiAgICAgICAgeG1sbnM6ZD0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9leHByZXNzaW9uL2JsZW5kLzIwMDgiCiAgICAgICAgeG1sbnM6bWM9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy9tYXJrdXAtY29tcGF0aWJpbGl0eS8yMDA2IgogICAgICAgIHhtbG5zOmxvY2FsPSJjbHItbmFtZXNwYWNlOldpblV0aWxpdHkiCiAgICAgICAgV2luZG93U3RhcnR1cExvY2F0aW9uPSJDZW50ZXJTY3JlZW4iCiAgICAgICAgVXNlTGF5b3V0Um91bmRpbmc9IlRydWUiCiAgICAgICAgV2luZG93U3R5bGU9IlNpbmdsZUJvcmRlcldpbmRvdyIKICAgICAgICBXaWR0aD0iQXV0byIKICAgICAgICBIZWlnaHQ9IkF1dG8iCiAgICAgICAgTWluV2lkdGg9IjgwMCIKICAgICAgICBNaW5IZWlnaHQ9IjYwMCIKICAgICAgICBUaXRsZT0iV2luVXRpbCI+CiAgICA8V2luZG93Q2hyb21lLldpbmRvd0Nocm9tZT4KICAgICAgICA8V2luZG93Q2hyb21lIENhcHRpb25IZWlnaHQ9IjAiIENvcm5lclJhZGl1cz0iMTAiLz4KICAgIDwvV2luZG93Q2hyb21lLldpbmRvd0Nocm9tZT4KICAgIDxXaW5kb3cuUmVzb3VyY2VzPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IlRvb2xUaXAiPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvb2xUaXBCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJCcnVzaCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWF4V2lkdGgiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvb2xUaXBXaWR0aH0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8IS0tIFRoaXMgQ29udGVudFRlbXBsYXRlIGVuc3VyZXMgdGhhdCB0aGUgY29udGVudCBvZiB0aGUgVG9vbFRpcCB3cmFwcyB0ZXh0IHByb3Blcmx5IGZvciBiZXR0ZXIgcmVhZGFiaWxpdHkgLS0+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ29udGVudFRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgQ29udGVudD0ie1RlbXBsYXRlQmluZGluZyBDb250ZW50fSI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyLlJlc291cmNlcz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJUZXh0QmxvY2siPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRleHRXcmFwcGluZyIgVmFsdWU9IldyYXAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udGVudFByZXNlbnRlci5SZXNvdXJjZXM+CiAgICAgICAgICAgICAgICAgICAgPC9Db250ZW50UHJlc2VudGVyPgogICAgICAgICAgICAgICAgPC9EYXRhVGVtcGxhdGU+CiAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgIDwvU2V0dGVyPgogICAgPC9TdHlsZT4KCiAgICA8U3R5bGUgVGFyZ2V0VHlwZT0ie3g6VHlwZSBNZW51SXRlbX0iPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iNSwyLDUsMiIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlclRoaWNrbmVzcyIgVmFsdWU9IjAiLz4KICAgIDwvU3R5bGU+CgogICAgPCEtLVNjcm9sbGJhciBUaHVtYnMtLT4KICAgIDxTdHlsZSB4OktleT0iU2Nyb2xsVGh1bWJzIiBUYXJnZXRUeXBlPSJ7eDpUeXBlIFRodW1ifSI+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJ7eDpUeXBlIFRodW1ifSI+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iR3JpZCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSZWN0YW5nbGUgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iIEZpbGw9IlRyYW5zcGFyZW50IiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IlJlY3RhbmdsZTEiIENvcm5lclJhZGl1cz0iNSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IiAvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iVGFnIiBWYWx1ZT0iSG9yaXpvbnRhbCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlJlY3RhbmdsZTEiIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlJlY3RhbmdsZTEiIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSI3IiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgoKICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJUZXh0QmxvY2siIHg6S2V5PSJIb3ZlclRleHRCbG9ja1N0eWxlIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMaW5rRm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RGVjb3JhdGlvbnMiIFZhbHVlPSJVbmRlcmxpbmUiIC8+CiAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExpbmtIb3ZlckZvcmVncm91bmRDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RGVjb3JhdGlvbnMiIFZhbHVlPSJVbmRlcmxpbmUiIC8+CiAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgIDwvU3R5bGU+CiAgICA8U3R5bGUgeDpLZXk9IkFwcEVudHJ5Qm9yZGVyU3R5bGUiIFRhcmdldFR5cGU9IkJvcmRlciI+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJHcmF5Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyVGhpY2tuZXNzIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeUJvcmRlclRoaWNrbmVzc30iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb3JuZXJSYWRpdXMiIFZhbHVlPSI1Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjYsNCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IldpZHRoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeVdpZHRofSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQWxpZ25tZW50IiBWYWx1ZT0iVG9wIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeU1hcmdpbn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQXBwSW5zdGFsbFVuc2VsZWN0ZWRDb2xvcn0iLz4KICAgIDwvU3R5bGU+CiAgICA8U3R5bGUgeDpLZXk9IkFwcEVudHJ5Q2hlY2tib3hTdHlsZSIgVGFyZ2V0VHlwZT0iQ2hlY2tCb3giPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ikhvcml6b250YWxBbGlnbm1lbnQiIFZhbHVlPSJMZWZ0Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQ2hlY2tCb3giPgogICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyIENvbnRlbnQ9IntUZW1wbGF0ZUJpbmRpbmcgQ29udGVudH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0Ii8+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgogICAgPFN0eWxlIHg6S2V5PSJBcHBFbnRyeU5hbWVTdHlsZSIgVGFyZ2V0VHlwZT0iVGV4dEJsb2NrIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQXBwRW50cnlGb250U2l6ZX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250V2VpZ2h0IiBWYWx1ZT0iQm9sZCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgPC9TdHlsZT4KICAgIDxTdHlsZSB4OktleT0iQXBwRW50cnlCdXR0b25TdHlsZSIgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSGVpZ2h0IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBJY29uQnV0dG9uU2l6ZX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IkNlbnRlciIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQWxpZ25tZW50IiBWYWx1ZT0iQ2VudGVyIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ29udGVudFRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayAgVGV4dD0ie0JpbmRpbmd9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRGYW1pbHk9IlNlZ29lIE1ETDIgQXNzZXRzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgICAgIDwvRGF0YVRlbXBsYXRlPgogICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICA8L1NldHRlcj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IkJhY2tncm91bmRCb3JkZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJvcmRlclRoaWNrbmVzc30iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29udGVudFByZXNlbnRlciBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNQcmVzc2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZFByZXNzZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkN1cnNvciIgVmFsdWU9IkhhbmQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iRmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRTZWxlY3RlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJEaW1HcmF5Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgoKCiAgICA8L1N0eWxlPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IkJ1dHRvbiIgeDpLZXk9IkhvdmVyQnV0dG9uU3R5bGUiPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRXZWlnaHQiIFZhbHVlPSJOb3JtYWwiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RWxlbWVudC5Gb250RmFtaWx5IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250RmFtaWx5fSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iPgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udGVudFByZXNlbnRlciBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiLz4KICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRXZWlnaHQiIFZhbHVlPSJCb2xkIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgoKICAgIDwhLS1TY3JvbGxCYXJzLS0+CiAgICA8U3R5bGUgeDpLZXk9Int4OlR5cGUgU2Nyb2xsQmFyfSIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBTY3JvbGxCYXJ9Ij4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJTdHlsdXMuSXNGbGlja3NFbmFibGVkIiBWYWx1ZT0iZmFsc2UiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgU2Nyb2xsQmFyQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IjYiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJ7eDpUeXBlIFNjcm9sbEJhcn0iPgogICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9IkdyaWRSb290IiBXaWR0aD0iNyIgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIgPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iMC4wMDAwMSoiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxUcmFjayBOYW1lPSJQQVJUX1RyYWNrIiBHcmlkLlJvdz0iMCIgSXNEaXJlY3Rpb25SZXZlcnNlZD0idHJ1ZSIgRm9jdXNhYmxlPSJmYWxzZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJhY2suVGh1bWI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRodW1iIE5hbWU9IlRodW1iIiBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IiBTdHlsZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxUaHVtYnN9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmFjay5UaHVtYj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmFjay5JbmNyZWFzZVJlcGVhdEJ1dHRvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UmVwZWF0QnV0dG9uIE5hbWU9IlBhZ2VVcCIgQ29tbWFuZD0iU2Nyb2xsQmFyLlBhZ2VEb3duQ29tbWFuZCIgT3BhY2l0eT0iMCIgRm9jdXNhYmxlPSJmYWxzZSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJhY2suSW5jcmVhc2VSZXBlYXRCdXR0b24+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJhY2suRGVjcmVhc2VSZXBlYXRCdXR0b24+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJlcGVhdEJ1dHRvbiBOYW1lPSJQYWdlRG93biIgQ29tbWFuZD0iU2Nyb2xsQmFyLlBhZ2VVcENvbW1hbmQiIE9wYWNpdHk9IjAiIEZvY3VzYWJsZT0iZmFsc2UiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyYWNrLkRlY3JlYXNlUmVwZWF0QnV0dG9uPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyYWNrPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgU291cmNlTmFtZT0iVGh1bWIiIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9InRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxCYXJIb3ZlckNvbG9yfSIgVGFyZ2V0TmFtZT0iVGh1bWIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFNvdXJjZU5hbWU9IlRodW1iIiBQcm9wZXJ0eT0iSXNEcmFnZ2luZyIgVmFsdWU9InRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxCYXJEcmFnZ2luZ0NvbG9yfSIgVGFyZ2V0TmFtZT0iVGh1bWIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iZmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUaHVtYiIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJDb2xsYXBzZWQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9Ik9yaWVudGF0aW9uIiBWYWx1ZT0iSG9yaXpvbnRhbCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkdyaWRSb290IiBQcm9wZXJ0eT0iTGF5b3V0VHJhbnNmb3JtIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um90YXRlVHJhbnNmb3JtIEFuZ2xlPSItOTAiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iUEFSVF9UcmFjayIgUHJvcGVydHk9IkxheW91dFRyYW5zZm9ybSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvdGF0ZVRyYW5zZm9ybSBBbmdsZT0iLTkwIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSI4IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUaHVtYiIgUHJvcGVydHk9IlRhZyIgVmFsdWU9Ikhvcml6b250YWwiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlBhZ2VEb3duIiBQcm9wZXJ0eT0iQ29tbWFuZCIgVmFsdWU9IlNjcm9sbEJhci5QYWdlTGVmdENvbW1hbmQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlBhZ2VVcCIgUHJvcGVydHk9IkNvbW1hbmQiIFZhbHVlPSJTY3JvbGxCYXIuUGFnZVJpZ2h0Q29tbWFuZCIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CiAgICAgICAgPFN0eWxlIHg6S2V5PSJDb21ib0JveFRvZ2dsZUJ1dHRvblN0eWxlIiBUYXJnZXRUeXBlPSJUb2dnbGVCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iVG9nZ2xlQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IiBCb3JkZXJUaGlja25lc3M9IjAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJDb21ib0JveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIENvbWJvQm94Rm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQ29tYm9Cb3hCYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNaW5XaWR0aCIgICBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIC8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJDb21ib0JveCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJPdXRlckJvcmRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uIE5hbWU9IlRvZ2dsZUJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgQ29tYm9Cb3hUb2dnbGVCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIElzQ2hlY2tlZD0ie0JpbmRpbmcgSXNEcm9wRG93bk9wZW4sIE1vZGU9VHdvV2F5LCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgVGVtcGxhdGVkUGFyZW50fX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDbGlja01vZGU9IlByZXNzIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSJ7VGVtcGxhdGVCaW5kaW5nIFNlbGVjdGlvbkJveEl0ZW19IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI2LDMsMiwzIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UGF0aCBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIERhdGE9Ik0gMCwwIEwgOCwwIEwgNCw1IFoiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IjgiIEhlaWdodD0iNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdHJldGNoPSJVbmlmb3JtIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI0LDAsNiwwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFBvcHVwIE5hbWU9IlBvcHVwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIElzT3Blbj0ie1RlbXBsYXRlQmluZGluZyBJc0Ryb3BEb3duT3Blbn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUGxhY2VtZW50PSJCb3R0b20iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9jdXNhYmxlPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBBbGxvd3NUcmFuc3BhcmVuY3k9IlRydWUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUG9wdXBBbmltYXRpb249IlNsaWRlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IkRyb3BEb3duQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0iNCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8SXRlbXNQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgTWFyZ2luPSI0LDIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1BvcHVwPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQ29tYm9Cb3hJdGVtIj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQ29tYm9Cb3hCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIENvbWJvQm94Rm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iNiwzIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnRUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0ie0JpbmRpbmd9IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7QmluZGluZyBGb3JlZ3JvdW5kLCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgQW5jZXN0b3JUeXBlPUNvbWJvQm94SXRlbX19Ii8+CiAgICAgICAgICAgICAgICAgICAgPC9EYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0hpZ2hsaWdodGVkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIvPgogICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzU2VsZWN0ZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJMYWJlbCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExhYmVsYm94Rm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMYWJlbEJhY2tncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8IS0tIFRleHRCbG9jayB0ZW1wbGF0ZSAtLT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iVGV4dEJsb2NrIj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMYWJlbGJveEZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTGFiZWxCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgeDpLZXk9IlRhYlRvZ2dsZUJ1dHRvbiIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBUb2dnbGVCdXR0b259Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25NYXJnaW59Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IlRvZ2dsZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCdXR0b25HbG93IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwyLDEwLDIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJFZmZlY3QiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgT3BhY2l0eT0iMSIgU2hhZG93RGVwdGg9IjUiIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9IiBEaXJlY3Rpb249Ii0xMDAiIEJsdXJSYWRpdXM9IjE1Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhbmVsLlpJbmRleCIgVmFsdWU9IjIwMDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJCcnVzaCIgVmFsdWU9IlBpbmsiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZFNlbGVjdGVkQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEcm9wU2hhZG93RWZmZWN0IE9wYWNpdHk9IjEiIFNoYWRvd0RlcHRoPSIyIiBDb2xvcj0ie0R5bmFtaWNSZXNvdXJjZSBDQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIgRGlyZWN0aW9uPSItMTExIiBCbHVyUmFkaXVzPSIxMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJGYWxzZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlclRoaWNrbmVzcyIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDwhLS0gQnV0dG9uIFRlbXBsYXRlIC0tPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbk1hcmdpbn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkhlaWdodCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29ybmVyUmFkaXVzfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIiBNYXJnaW49IjEwLDIsMTAsMiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc1ByZXNzZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzTW91c2VPdmVyIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzRW5hYmxlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iRGltR3JheSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9IlRvZ2dsZUJ1dHRvblN0eWxlIiBUYXJnZXRUeXBlPSJUb2dnbGVCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbk1hcmdpbn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkhlaWdodCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IlRvZ2dsZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29ybmVyUmFkaXVzfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVG9nZ2xlIERvdCBCYWNrZ3JvdW5kIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RWxsaXBzZSBXaWR0aD0iOCIgSGVpZ2h0PSIxNiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJUb3AiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDMsNSwwIiAvPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBUb2dnbGUgRG90IHdpdGggaG92ZXIgZ3JvdyBlZmZlY3QgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxFbGxpcHNlIE5hbWU9IlRvZ2dsZURvdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iOCIgSGVpZ2h0PSI4IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZpbGw9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwzLDUsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBSZW5kZXJUcmFuc2Zvcm1PcmlnaW49IjAuNSwwLjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UuUmVuZGVyVHJhbnNmb3JtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY2FsZVRyYW5zZm9ybSBTY2FsZVg9IjEiIFNjYWxlWT0iMSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlLlJlbmRlclRyYW5zZm9ybT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBDb250ZW50IFByZXNlbnRlciAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMTAsMiwxMCwyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVHJpZ2dlcnMgZm9yIFRvZ2dsZUJ1dHRvbiBzdGF0ZXMgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEhvdmVyIGVmZmVjdCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEFuaW1hdGlvbiB0byBncm93IHRoZSBkb3Qgd2hlbiBob3ZlcmVkIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJUb2dnbGVEb3QiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0b3J5Ym9hcmQuVGFyZ2V0UHJvcGVydHk9IihVSUVsZW1lbnQuUmVuZGVyVHJhbnNmb3JtKS4oU2NhbGVUcmFuc2Zvcm0uU2NhbGVYKSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVG89IjEuMiIgRHVyYXRpb249IjA6MDowLjEiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWSkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjIiIER1cmF0aW9uPSIwOjA6MC4xIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEFuaW1hdGlvbiB0byBzaHJpbmsgdGhlIGRvdCBiYWNrIHRvIG9yaWdpbmFsIHNpemUgd2hlbiBub3QgaG92ZXJlZCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWCkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERvdWJsZUFuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IlRvZ2dsZURvdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVkpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4wIiBEdXJhdGlvbj0iMDowOjAuMSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBJc0NoZWNrZWQgc3RhdGUgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUb2dnbGVEb3QiIFByb3BlcnR5PSJWZXJ0aWNhbEFsaWdubWVudCIgVmFsdWU9IkJvdHRvbSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IiBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0iMCwwLDUsMyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gSXNFbmFibGVkIHN0YXRlIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzRW5hYmxlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iRGltR3JheSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9IlNlYXJjaEJhckNsZWFyQnV0dG9uU3R5bGUiIFRhcmdldFR5cGU9IkJ1dHRvbiI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRGYW1pbHkiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRGYW1pbHl9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJDbGVhckJ1dHRvbkZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb250ZW50IiBWYWx1ZT0iWCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFNlYXJjaEJhckNsZWFyQnV0dG9uRm9udFNpemV9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IldpZHRoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJDbGVhckJ1dHRvbkZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjAiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIwIi8+CiAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJSZWQiLz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxMCIvPgogICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkN1cnNvciIgVmFsdWU9IkhhbmQiLz4KICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDwhLS0gQ2hlY2tib3ggdGVtcGxhdGUgLS0+CiAgICAgICAgPFN0eWxlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGV4dEVsZW1lbnQuRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnVsbGV0RGVjb3JhdG9yIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnVsbGV0RGVjb3JhdG9yLkJ1bGxldD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZX0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCb3JkZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZSAqMC44NX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBDaGVja0JveEJ1bGxldERlY29yYXRvclNpemUgKjAuODV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFNuYXBzVG9EZXZpY2VQaXhlbHM9IlRydWUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxWaWV3Ym94IE5hbWU9IkNoZWNrTWFya0NvbnRhaW5lciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UGF0aCBOYW1lPSJDaGVja01hcmsiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0cm9rZVRoaWNrbmVzcz0iMS41IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIERhdGE9Ik0gMCA1IEwgNSAxMCBMIDEyIDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3RyZXRjaD0iVW5pZm9ybSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9WaWV3Ym94PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CdWxsZXREZWNvcmF0b3IuQnVsbGV0PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyIE1hcmdpbj0iNCwwLDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVjb2duaXplc0FjY2Vzc0tleT0iVHJ1ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CdWxsZXREZWNvcmF0b3I+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkNoZWNrTWFya0NvbnRhaW5lciIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tU2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRQcmVzc2VkQ29sb3J9Ii8tLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iUmFkaW9CdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250RmFtaWx5IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250RmFtaWx5fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iUmFkaW9CdXR0b24iPgogICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Vmlld2JveCBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBDaGVja0JveEJ1bGxldERlY29yYXRvclNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgV2lkdGg9IjE0IiBIZWlnaHQ9IjE0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iT3V0ZXJDaXJjbGUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9mZkNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlVGhpY2tuZXNzPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSIxNCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjE0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFNuYXBzVG9EZXZpY2VQaXhlbHM9IlRydWUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iSW5uZXJDaXJjbGUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRmlsbD0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PbkNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iOCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjgiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9WaWV3Ym94PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgTWFyZ2luPSI0LDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVjb2duaXplc0FjY2Vzc0tleT0iVHJ1ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJJbm5lckNpcmNsZSIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9Ik91dGVyQ2lyY2xlIiBQcm9wZXJ0eT0iU3Ryb2tlIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PbkNvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSB4OktleT0iVG9nZ2xlU3dpdGNoU3R5bGUiIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIFdpZHRoPSI0NSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0iMjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSIjNTU1NTU1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29ybmVyUmFkaXVzPSIxMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iNSwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iMjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0iQmxhY2siCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IjEyLjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgTmFtZT0iV1BGVG9nZ2xlU3dpdGNoQ29udGVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjEwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IntUZW1wbGF0ZUJpbmRpbmcgQ29udGVudH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iZmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UmVtb3ZlU3Rvcnlib2FyZCBCZWdpblN0b3J5Ym9hcmROYW1lPSJXUEZUb2dnbGVTd2l0Y2hMZWZ0IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkIE5hbWU9IldQRlRvZ2dsZVN3aXRjaFJpZ2h0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUaGlja25lc3NBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iTWFyZ2luIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBEdXJhdGlvbj0iMDowOjA6MCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZyb209IjAsMCwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMjgsMCwwLDAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGhpY2tuZXNzQW5pbWF0aW9uPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQcm9wZXJ0eT0iQmFja2dyb3VuZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZhbHVlPSIjZmZmOWY0ZjQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJ0cnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJlbW92ZVN0b3J5Ym9hcmQgQmVnaW5TdG9yeWJvYXJkTmFtZT0iV1BGVG9nZ2xlU3dpdGNoUmlnaHQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQgTmFtZT0iV1BGVG9nZ2xlU3dpdGNoTGVmdCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGhpY2tuZXNzQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0UHJvcGVydHk9Ik1hcmdpbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iV1BGVG9nZ2xlU3dpdGNoQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRHVyYXRpb249IjA6MDowOjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGcm9tPSIyOCwwLDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIwLDAsMCwwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RoaWNrbmVzc0FuaW1hdGlvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iV1BGVG9nZ2xlU3dpdGNoQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUHJvcGVydHk9IkJhY2tncm91bmQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWYWx1ZT0iI2ZmMDYwNjAwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CgogICAgICAgIDxTdHlsZSB4OktleT0iQ29sb3JmdWxUb2dnbGVTd2l0Y2hTdHlsZSIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBDaGVja0JveH0iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0ie3g6VHlwZSBUb2dnbGVCdXR0b259Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0idG9nZ2xlU3dpdGNoIj4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW49IjEiIE5hbWU9IkJvcmRlciIgQ29ybmVyUmFkaXVzPSI4IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iMzQiIEhlaWdodD0iMTciPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iRWxsaXBzZSIgRmlsbD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgU3RyZXRjaD0iVW5pZm9ybSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIyLDIsMiwxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBXaWR0aD0iMTAuOCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVuZGVyVHJhbnNmb3JtT3JpZ2luPSIwLjUsIDAuNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UuUmVuZGVyVHJhbnNmb3JtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2NhbGVUcmFuc2Zvcm0gU2NhbGVYPSIxIiBTY2FsZVk9IjEiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlLlJlbmRlclRyYW5zZm9ybT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvRWxsaXBzZT4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExpbmtIb3ZlckZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhbmVsLlpJbmRleCIgVmFsdWU9IjEwMDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iRWxsaXBzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVgpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4xIiBEdXJhdGlvbj0iMDowOjAuMSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iRWxsaXBzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVkpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4xIiBEdXJhdGlvbj0iMDowOjAuMSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyLkVudGVyQWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJFbGxpcHNlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWCkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJFbGxpcHNlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWSkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iVG9nZ2xlQnV0dG9uLklzQ2hlY2tlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQm9yZGVyIiBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9mZkNvbG9yfSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkVsbGlwc2UiIFByb3BlcnR5PSJGaWxsIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PZmZDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IlRvZ2dsZUJ1dHRvbi5Jc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQm9yZGVyIiBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iRWxsaXBzZSIgUHJvcGVydHk9IkZpbGwiIFZhbHVlPSJXaGl0ZSIgLz4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIuRW50ZXJBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRoaWNrbmVzc0FuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IkVsbGlwc2UiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSJNYXJnaW4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMTgsMiwyLDIiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRW50ZXJBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRoaWNrbmVzc0FuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IkVsbGlwc2UiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSJNYXJnaW4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMiwyLDIsMSIgRHVyYXRpb249IjA6MDowLjEiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQ29udGVudEFsaWdubWVudCIgVmFsdWU9IkNlbnRlciIgLz4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9ImxhYmVsZm9ydHdlYWtzIiBUYXJnZXRUeXBlPSJ7eDpUeXBlIExhYmVsfSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzTW91c2VPdmVyIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IldoaXRlIiAvPgogICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICA8L1N0eWxlLlRyaWdnZXJzPgogICAgICAgIDwvU3R5bGU+CgogICAgICAgIDxTdHlsZSB4OktleT0iQm9yZGVyU3R5bGUiIFRhcmdldFR5cGU9IkJvcmRlciI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyVGhpY2tuZXNzIiBWYWx1ZT0iMSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb3JuZXJSYWRpdXMiIFZhbHVlPSI1Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhZGRpbmciIFZhbHVlPSI1Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ik1hcmdpbiIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgU2hhZG93RGVwdGg9IjUiIEJsdXJSYWRpdXM9IjUiIE9wYWNpdHk9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyT3BhY2l0eX0iIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iVGV4dEJveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IlN0cmV0Y2giLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbENvbnRlbnRBbGlnbm1lbnQiIFZhbHVlPSJTdHJldGNoIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNhcmV0QnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRleHRNZW51Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRleHRNZW51PgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udGV4dE1lbnUuU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQ29udGV4dE1lbnUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQ29udGV4dE1lbnUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iNSIgUGFkZGluZz0iNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIENvbW1hbmQ9IkN1dCIgSGVhZGVyPSJDdXQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBDb21tYW5kPSJDb3B5IiBIZWFkZXI9IkNvcHkiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBDb21tYW5kPSJQYXN0ZSIgSGVhZGVyPSJQYXN0ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0eWxlPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRleHRNZW51LlN0eWxlPgogICAgICAgICAgICAgICAgICAgIDwvQ29udGV4dE1lbnU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJUZXh0Qm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntUZW1wbGF0ZUJpbmRpbmcgQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNjcm9sbFZpZXdlciBOYW1lPSJQQVJUX0NvbnRlbnRIb3N0IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgU2hhZG93RGVwdGg9IjUiIEJsdXJSYWRpdXM9IjUiIE9wYWNpdHk9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyT3BhY2l0eX0iIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJQYXNzd29yZEJveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IlN0cmV0Y2giLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbENvbnRlbnRBbGlnbm1lbnQiIFZhbHVlPSJTdHJldGNoIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNhcmV0QnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJQYXNzd29yZEJveCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlclRoaWNrbmVzc30iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29ybmVyUmFkaXVzPSI1Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXIgTmFtZT0iUEFSVF9Db250ZW50SG9zdCIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkVmZmVjdCI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxEcm9wU2hhZG93RWZmZWN0IFNoYWRvd0RlcHRoPSI1IiBCbHVyUmFkaXVzPSI1IiBPcGFjaXR5PSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlck9wYWNpdHl9IiBDb2xvcj0ie0R5bmFtaWNSZXNvdXJjZSBDQm9yZGVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgeDpLZXk9IlNjcm9sbFZpc2liaWxpdHlSZWN0YW5nbGUiIFRhcmdldFR5cGU9IlJlY3RhbmdsZSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJDb2xsYXBzZWQiLz4KICAgICAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPE11bHRpRGF0YVRyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPE11bHRpRGF0YVRyaWdnZXIuQ29uZGl0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbmRpdGlvbiBCaW5kaW5nPSJ7QmluZGluZyBQYXRoPUNvbXB1dGVkSG9yaXpvbnRhbFNjcm9sbEJhclZpc2liaWxpdHksIEVsZW1lbnROYW1lPXNjcm9sbFZpZXdlcn0iIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb25kaXRpb24gQmluZGluZz0ie0JpbmRpbmcgUGF0aD1Db21wdXRlZFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eSwgRWxlbWVudE5hbWU9c2Nyb2xsVmlld2VyfSIgVmFsdWU9IlZpc2libGUiLz4KICAgICAgICAgICAgICAgICAgICA8L011bHRpRGF0YVRyaWdnZXIuQ29uZGl0aW9ucz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJWaXNpYmlsaXR5IiBWYWx1ZT0iVmlzaWJsZSIvPgogICAgICAgICAgICAgICAgPC9NdWx0aURhdGFUcmlnZ2VyPgogICAgICAgICAgICA8L1N0eWxlLlRyaWdnZXJzPgogICAgICAgIDwvU3R5bGU+CiAgICAgICAgPFN0eWxlIHg6S2V5PSJSb3VuZGVkUHJvZ3Jlc3NCYXJTdHlsZSIgVGFyZ2V0VHlwZT0iUHJvZ3Jlc3NCYXIiPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iUHJvZ3Jlc3NCYXIiPgogICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIENvcm5lclJhZGl1cz0iNCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBDbGlwVG9Cb3VuZHM9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iUEFSVF9UcmFjayIgQ29ybmVyUmFkaXVzPSI0IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iUEFSVF9JbmRpY2F0b3IiIENvcm5lclJhZGl1cz0iNCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBQcm9ncmVzc0JhckZvcmVncm91bmRDb2xvcn0iIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8IS0tIEZpbHRlciBDaGlwIFN0eWxlIOKAlCB1c2VkIGJ5IHRoZSBJbnN0YWxsIHRhYiBjYXRlZ29yeSBmaWx0ZXIgYnV0dG9ucyAtLT4KICAgICAgICA8U3R5bGUgeDpLZXk9IkZpbHRlckNoaXBTdHlsZSIgVGFyZ2V0VHlwZT0iQnV0dG9uIiBCYXNlZE9uPSJ7U3RhdGljUmVzb3VyY2Uge3g6VHlwZSBCdXR0b259fSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ik1hcmdpbiIgVmFsdWU9IjIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjEyLDAsMTIsMCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ3Vyc29yIiBWYWx1ZT0iSGFuZCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJDaGlwQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntUZW1wbGF0ZUJpbmRpbmcgQm9yZGVyQnJ1c2h9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IntUZW1wbGF0ZUJpbmRpbmcgUGFkZGluZ30iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzUHJlc3NlZCIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQ2hpcEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRQcmVzc2VkQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkNoaXBCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iRmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQ2hpcEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRTZWxlY3RlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJEaW1HcmF5Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CiAgICA8L1dpbmRvdy5SZXNvdXJjZXM+CiAgICA8R3JpZCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBTaG93R3JpZExpbmVzPSJGYWxzZSIgTmFtZT0iV1BGTWFpbkdyaWQiIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgIDwhLS0gT2ZmbGluZSBiYW5uZXIgLS0+CiAgICAgICAgPEJvcmRlciBOYW1lPSJXUEZPZmZsaW5lQmFubmVyIiBHcmlkLlJvdz0iMCIgQmFja2dyb3VuZD0iIzhCMDAwMCIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBQYWRkaW5nPSI2LDQiPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IiYjeDI2QTA7IE9mZmxpbmUgTW9kZSAtIE5vIEludGVybmV0IENvbm5lY3Rpb24iIEZvcmVncm91bmQ9IldoaXRlIiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBGb250U2l6ZT0iMTMiIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ii8+CiAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgPEdyaWQgR3JpZC5Sb3c9IjEiIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iPgogICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+IDwhLS0gTmF2aWdhdGlvbiBidXR0b25zIC0tPgogICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4gPCEtLSBTZWFyY2ggYmFyIGFuZCBidXR0b25zIC0tPgogICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICA8IS0tIE5hdmlnYXRpb24gQnV0dG9ucyBQYW5lbCAtLT4KICAgICAgICAgICAgPFN0YWNrUGFuZWwgTmFtZT0iTmF2RG9ja1BhbmVsIiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgR3JpZC5Db2x1bW49IjAiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iNSw1LDEwLDUiPgogICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgTmFtZT0iTmF2TG9nb1BhbmVsIiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgU25hcHNUb0RldmljZVBpeGVscz0iVHJ1ZSIgTWFyZ2luPSIxMCwwLDIwLDAiPgogICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIFRhYlRvZ2dsZUJ1dHRvbn0iIE1hcmdpbj0iMCwwLDUsMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkhlaWdodH0iIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbldpZHRofSIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkluc3RhbGxCYWNrZ3JvdW5kQ29sb3J9IiBGb3JlZ3JvdW5kPSJ3aGl0ZSIgRm9udFdlaWdodD0iQm9sZCIgTmFtZT0iV1BGVGFiMUJUIj4KICAgICAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uLkNvbnRlbnQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uRm9udFNpemV9IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25JbnN0YWxsRm9yZWdyb3VuZENvbG9yfSIgPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFVuZGVybGluZT5BPC9VbmRlcmxpbmU+5bqU55So5a6J6KOFCiAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uLkNvbnRlbnQ+CiAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbj4KICAgICAgICAgICAgICAgIDxUb2dnbGVCdXR0b24gU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBUYWJUb2dnbGVCdXR0b259IiBNYXJnaW49IjAsMCw1LDAiIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25IZWlnaHR9IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25XaWR0aH0iCiAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Ud2Vha3NCYWNrZ3JvdW5kQ29sb3J9IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvblR3ZWFrc0ZvcmVncm91bmRDb2xvcn0iIEZvbnRXZWlnaHQ9IkJvbGQiIE5hbWU9IldQRlRhYjJCVCI+CiAgICAgICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkZvbnRTaXplfSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uVHdlYWtzRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VW5kZXJsaW5lPlk8L1VuZGVybGluZT7ns7vnu5/kvJjljJYKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uPgogICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIFRhYlRvZ2dsZUJ1dHRvbn0iIE1hcmdpbj0iMCwwLDUsMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkhlaWdodH0iIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbldpZHRofSIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkNvbmZpZ0JhY2tncm91bmRDb2xvcn0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29uZmlnRm9yZWdyb3VuZENvbG9yfSIgRm9udFdlaWdodD0iQm9sZCIgTmFtZT0iV1BGVGFiM0JUIj4KICAgICAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uLkNvbnRlbnQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uRm9udFNpemV9IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db25maWdGb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxVbmRlcmxpbmU+UDwvVW5kZXJsaW5lPuWKn+iDvemFjee9rgogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24+CiAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgVGFiVG9nZ2xlQnV0dG9ufSIgTWFyZ2luPSIwLDAsNSwwIiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uSGVpZ2h0fSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uV2lkdGh9IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uVXBkYXRlc0JhY2tncm91bmRDb2xvcn0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uVXBkYXRlc0ZvcmVncm91bmRDb2xvcn0iIEZvbnRXZWlnaHQ9IkJvbGQiIE5hbWU9IldQRlRhYjRCVCI+CiAgICAgICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkZvbnRTaXplfSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uVXBkYXRlc0ZvcmVncm91bmRDb2xvcn0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFVuZGVybGluZT5HPC9VbmRlcmxpbmU+V2luZG93cyDmm7TmlrAKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uPgogICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIFRhYlRvZ2dsZUJ1dHRvbn0iIE1hcmdpbj0iMCwwLDUsMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkhlaWdodH0iIFdpZHRoPSJBdXRvIiBNaW5XaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25XaWR0aH0iCiAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaW4xMUlTT0JhY2tncm91bmRDb2xvcn0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2luMTFJU09Gb3JlZ3JvdW5kQ29sb3J9IiBGb250V2VpZ2h0PSJCb2xkIiBOYW1lPSJXUEZUYWI1QlQiPgogICAgICAgICAgICAgICAgICAgIDxUb2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25Gb250U2l6ZX0iIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpbjExSVNPRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VW5kZXJsaW5lPlc8L1VuZGVybGluZT5XaW4xMSDliJvlu7rlt6XlhbcKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uPgogICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICA8IS0tIFNlYXJjaCBCYXIgYW5kIEFjdGlvbiBCdXR0b25zIC0tPgogICAgICAgICAgICA8R3JpZCBOYW1lPSJHcmlkQmVzaWRlTmF2RG9ja1BhbmVsIiBHcmlkLkNvbHVtbj0iMSIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgU2hvd0dyaWRMaW5lcz0iRmFsc2UiIEhlaWdodD0iQXV0byI+CiAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iMioiLz4gPCEtLSBTZWFyY2ggYmFyIGFyZWEgLSBwcmlvcml0eSBzcGFjZSAtLT4KICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iQXV0byIvPjwhLS0gQnV0dG9ucyBhcmVhIC0tPgogICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW49IjAiIE1hcmdpbj0iNSwwLDEwLDAiIE1pbldpZHRoPSIxMjAiIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJIZWlnaHR9IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIj4KICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCb3gKICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJIZWlnaHR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgU2VhcmNoQmFyVGV4dEJveEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJTZWFyY2hCYXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgUGFkZGluZz0iMywzLDMwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBUb29sVGlwPSLmjIkgQ3RybC1GIOi+k+WFpeW6lOeUqOWQjeensOi/h+a7pOWIl+ihqO+8jOaMiSBFc2Mg6YeN572u562b6YCJIj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0Qm94PgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJTZWFyY2hCYXJJY29uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZFNlbGVjdGVkQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgSWNvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDgsMCIgV2lkdGg9IkF1dG8iIEhlaWdodD0iQXV0byI+JiN4RTcyMTsKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IgogICAgICAgICAgICAgICAgICAgIE5hbWU9IlNlYXJjaEJhckNsZWFyQnV0dG9uIgogICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgU2VhcmNoQmFyQ2xlYXJCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMjAsMCIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIj4KICAgICAgICAgICAgICAgIDwvQnV0dG9uPgoKICAgICAgICAgICAgICAgIDwhLS0gQnV0dG9ucyBDb250YWluZXIgLS0+CiAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBHcmlkLkNvbHVtbj0iMSIgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIiBNYXJnaW49IjUsNSw1LDUiPgogICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iVGhlbWVCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgSG92ZXJCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgU2V0dGluZ3NJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIKICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwyLDAiCiAgICAgICAgICAgICAgICAgICAgRm9udEZhbWlseT0iU2Vnb2UgTURMMiBBc3NldHMiCiAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5pegIgogICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuWIh+aNoiBXaW5VdGlsIOeVjOmdouS4u+mimCIKICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgPFBvcHVwIE5hbWU9IlRoZW1lUG9wdXAiCiAgICAgICAgICAgICAgICAgICAgSXNPcGVuPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICBQbGFjZW1lbnRUYXJnZXQ9IntCaW5kaW5nIEVsZW1lbnROYW1lPVRoZW1lQnV0dG9ufSIgUGxhY2VtZW50PSJCb3R0b20iCiAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJUb3AiPgogICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSIwIiBNYXJnaW49IjAiPgogICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIiBWZXJ0aWNhbEFsaWdubWVudD0iU3RyZXRjaCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0gRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IiBIZWFkZXI9IkF1dG8iIE5hbWU9IkF1dG9UaGVtZU1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRvb2xUaXAgQ29udGVudD0i6Lef6ZqPIFdpbmRvd3Mg5Li76aKYIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iRGFyayIgTmFtZT0iRGFya1RoZW1lTWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VG9vbFRpcCBDb250ZW50PSLkvb/nlKjmt7HoibLkuLvpopgiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgSGVhZGVyPSJMaWdodCIgTmFtZT0iTGlnaHRUaGVtZU1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRvb2xUaXAgQ29udGVudD0i5L2/55So5rWF6Imy5Li76aKYIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbT4KICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9Qb3B1cD4KCiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJGb250U2NhbGluZ0J1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZXR0aW5nc0ljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDIsMCIKICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICBDb250ZW50PSImI3hFOEQzOyIKICAgICAgICAgICAgICAgICAgICBUb29sVGlwPSLosIPmlbTlrZfkvZPnvKnmlL7ku6XpgILlupTovoXliqnlip/og73pnIDmsYIiCiAgICAgICAgICAgICAgICAvPgogICAgICAgICAgICAgICAgICAgIDxQb3B1cCBOYW1lPSJGb250U2NhbGluZ1BvcHVwIgogICAgICAgICAgICAgICAgICAgIElzT3Blbj0iRmFsc2UiCiAgICAgICAgICAgICAgICAgICAgUGxhY2VtZW50VGFyZ2V0PSJ7QmluZGluZyBFbGVtZW50TmFtZT1Gb250U2NhbGluZ0J1dHRvbn0iIFBsYWNlbWVudD0iQm90dG9tIgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iMCIgTWFyZ2luPSIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giIE1pbldpZHRoPSIyMDAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLlrZfkvZPnvKnmlL4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjEwLDUsMTAsNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNlcGFyYXRvciBNYXJnaW49IjUsMCw1LDUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBNYXJnaW49IjEwLDUsMTAsMTAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0i5bCPIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwxMCwwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNsaWRlciBOYW1lPSJGb250U2NhbGluZ1NsaWRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1pbmltdW09IjAuNzUiIE1heGltdW09IjIuMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZhbHVlPSIxLjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUaWNrRnJlcXVlbmN5PSIwLjI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGlja1BsYWNlbWVudD0iQm90dG9tUmlnaHQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBJc1NuYXBUb1RpY2tFbmFibGVkPSJUcnVlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IjEyMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IuWkpyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwwLDAsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBOYW1lPSJGb250U2NhbGluZ1ZhbHVlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSIxMDAlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwwLDEwLDUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iMTAsMCwxMCwxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJGb250U2NhbGluZ1Jlc2V0QnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i6YeN572uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSI2MCIgSGVpZ2h0PSIyNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iNSwwLDUsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iRm9udFNjYWxpbmdBcHBseUJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuW6lOeUqCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgSG92ZXJCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iNjAiIEhlaWdodD0iMjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjUsMCw1LDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9Qb3B1cD4KCiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJTZXR0aW5nc0J1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZXR0aW5nc0ljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDIsMCIKICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICBDb250ZW50PSImI3hFNzEzOyIvPgogICAgICAgICAgICAgICAgICAgIDxQb3B1cCBOYW1lPSJTZXR0aW5nc1BvcHVwIgogICAgICAgICAgICAgICAgICAgIElzT3Blbj0iRmFsc2UiCiAgICAgICAgICAgICAgICAgICAgUGxhY2VtZW50VGFyZ2V0PSJ7QmluZGluZyBFbGVtZW50TmFtZT1TZXR0aW5nc0J1dHRvbn0iIFBsYWNlbWVudD0iQm90dG9tIgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iMCIgTWFyZ2luPSIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgSGVhZGVyPSJJbXBvcnQiIE5hbWU9IkltcG9ydE1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRvb2xUaXAgQ29udGVudD0i5LuO5a+85Ye655qE5paH5Lu25a+85YWl6YWN572uIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iRXhwb3J0IiBOYW1lPSJFeHBvcnRNZW51SXRlbSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUb29sVGlwIENvbnRlbnQ9IuWvvOWHuuW3sumAiemhueW5tuWwhuWRveS7pOWkjeWItuWIsOWJqui0tOadvyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2VwYXJhdG9yLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iQWJvdXQiIE5hbWU9IkFib3V0TWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iRG9jdW1lbnRhdGlvbiIgTmFtZT0iRG9jdW1lbnRhdGlvbk1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0gRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IiBIZWFkZXI9IlNwb25zb3JzIiBOYW1lPSJTcG9uc29yTWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9Qb3B1cD4KCiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbgogICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSImI3hFOTIxOyIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSIwIgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0iVHJhbnNwYXJlbnQiCiAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udEZhbWlseT0iU2Vnb2UgTURMMiBBc3NldHMiCiAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIENsb3NlSWNvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgVG9vbFRpcD0i5pyA5bCP5YyWIgogICAgICAgICAgICAgICAgICAgICAgICBBdXRvbWF0aW9uUHJvcGVydGllcy5OYW1lPSJNaW5pbWl6ZSIKICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGTWluaW1pemVCdXR0b24iIC8+CiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjAiCiAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQ2xvc2VJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZNYXhpbWl6ZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24uU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQnV0dG9uIiBCYXNlZE9uPSJ7U3RhdGljUmVzb3VyY2UgSG92ZXJCdXR0b25TdHlsZX0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSImI3hFOTIyOyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRvb2xUaXAiIFZhbHVlPSJNYXhpbWl6ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWUiIFZhbHVlPSJNYXhpbWl6ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERhdGFUcmlnZ2VyIEJpbmRpbmc9IntCaW5kaW5nIFdpbmRvd1N0YXRlLCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgQW5jZXN0b3JUeXBlPXt4OlR5cGUgV2luZG93fX19IiBWYWx1ZT0iTWF4aW1pemVkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSImI3hFOTIzOyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVG9vbFRpcCIgVmFsdWU9IlJlc3RvcmUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWUiIFZhbHVlPSJSZXN0b3JlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvRGF0YVRyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQnV0dG9uLlN0eWxlPgogICAgICAgICAgICAgICAgICAgIDwvQnV0dG9uPgoKICAgICAgICAgICAgICAgICAgICA8QnV0dG9uCiAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IiYjeEU4QkI7IgogICAgICAgICAgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEhvdmVyQnV0dG9uU3R5bGV9IgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjAiCiAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwIgogICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQ2xvc2VJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBUb29sVGlwPSLlhbPpl60iCiAgICAgICAgICAgICAgICAgICAgICAgIEF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWU9IkNsb3NlIgogICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZDbG9zZUJ1dHRvbiIgLz4KICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgPC9HcmlkPgogICAgICAgIDwvR3JpZD4KCiAgICAgICAgPFRhYkNvbnRyb2wgTmFtZT0iV1BGVGFiTmF2IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIgV2lkdGg9IkF1dG8iIEhlaWdodD0iQXV0byIgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IiBCb3JkZXJUaGlja25lc3M9IjAiIEdyaWQuUm93PSIyIiBHcmlkLkNvbHVtbj0iMCIgUGFkZGluZz0iLTEiPgogICAgICAgICAgICA8VGFiSXRlbSBIZWFkZXI9IuW6lOeUqOWuieijhSIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWIxIj4KICAgICAgICAgICAgICAgIDxHcmlkIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiA+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgIDwhLS0gUXVpY2sgQ2F0ZWdvcnkgU2VhcmNoIENoaXBzIC0tPgogICAgICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgR3JpZC5Sb3c9IjAiIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBNYXJnaW49IjUsNSw1LDUiIE5hbWU9IldQRlNlYXJjaENoaXBzIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLnrZvpgIkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgSGVhZGVyRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRGYW1pbHk9IntEeW5hbWljUmVzb3VyY2UgSGVhZGVyRm9udEZhbWlseX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBMYWJlbGJveEZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjE1LDAsOCwwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcEFsbCIgICAgICAgICAgICAgQ29udGVudD0i5YWo6YOoIiAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBCcm93c2VycyIgICAgICAgIENvbnRlbnQ9Iua1j+iniOWZqCIgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcENvbW11bmljYXRpb25zIiAgQ29udGVudD0i6YCa6K6vIiAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwRGV2ZWxvcG1lbnQiICAgICBDb250ZW50PSLlvIDlj5Hlt6XlhbciICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBHYW1lcyIgICAgICAgICAgIENvbnRlbnQ9Iua4uOaIjyIgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcE1pY3Jvc29mdFRvb2xzIiAgQ29udGVudD0i5b6u6L2v5bel5YW3IiAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBNdWx0aW1lZGlhVG9vbHMiIENvbnRlbnQ9IuWkmuWqkuS9k+W3peWFtyIgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBQcm9Ub29scyIgICAgICAgIENvbnRlbnQ9IuS4k+S4muW3peWFtyIgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwU2VsZmhvc3RlZFRvb2xzIiBDb250ZW50PSLoh6rmiZjnrqHlt6XlhbciICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwVXRpbGl0aWVzIiAgICAgICBDb250ZW50PSLlrp7nlKjlt6XlhbciICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgPC9XcmFwUGFuZWw+CgogICAgICAgICAgICAgICAgICAgIDxHcmlkIEdyaWQuUm93PSIxIiBNYXJnaW49IntEeW5hbWljUmVzb3VyY2UgVGFiQ29udGVudE1hcmdpbn0iPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9ImFwcHNjYXRlZ29yeSIgR3JpZC5Db2x1bW49IjAiIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFZlcnRpY2FsQWxpZ25tZW50PSJTdHJldGNoIj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgoKICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iYXBwc3BhbmVsIiBHcmlkLkNvbHVtbj0iMSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICA8L1RhYkl0ZW0+CiAgICAgICAgICAgIDxUYWJJdGVtIEhlYWRlcj0i57O757uf5LyY5YyWIiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiIE5hbWU9IldQRlRhYjIiPgogICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgPCEtLSBNYWluIGNvbnRlbnQgYXJlYSB3aXRoIGEgU2Nyb2xsVmlld2VyIC0tPgogICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIgLz4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXIgVmVydGljYWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIiBIb3Jpem9udGFsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iRGlzYWJsZWQiIEdyaWQuUm93PSIwIiBNYXJnaW49IntEeW5hbWljUmVzb3VyY2UgVGFiQ29udGVudE1hcmdpbn0iPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBPcmllbnRhdGlvbj0iVmVydGljYWwiIEdyaWQuUm93PSIwIiBHcmlkLkNvbHVtbj0iMCIgR3JpZC5Db2x1bW5TcGFuPSIyIiBNYXJnaW49IjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxMYWJlbCBDb250ZW50PSLmjqjojZDpgInmi6nvvJoiIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgTWFyZ2luPSIyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFdyYXBQYW5lbCBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgTWFyZ2luPSIwLDIsMCwwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZzdGFuZGFyZCIgQ29udGVudD0iIOagh+WHhiAiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRm1pbmltYWwiIENvbnRlbnQ9IiDnsr7nroAgIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZBZHZhbmNlZCIgQ29udGVudD0iIOmrmOe6pyAiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkNsZWFyVHdlYWtzU2VsZWN0aW9uIiBDb250ZW50PSIg5riF6ZmkICIgTWFyZ2luPSIyIiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGR2V0SW5zdGFsbGVkVHdlYWtzIiBDb250ZW50PSLlt7Llronoo4XkvJjljJbliJfooagiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkFwcHhSZW1vdmFsIiBDb250ZW50PSJBcHBYIOenu+mZpCIgTWFyZ2luPSIyIiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9XcmFwUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0idHdlYWtzcGFuZWwiIEdyaWQuUm93PSIxIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIFlvdXIgdHdlYWtzcGFuZWwgY29udGVudCBnb2VzIGhlcmUgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtblNwYW49IjIiIEdyaWQuUm93PSIyIiBHcmlkLkNvbHVtbj0iMCIgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBCb3JkZXJTdHlsZX0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBQYWRkaW5nPSIxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDms6jmhI/vvJrmgqzlgZzmn6XnnIvor6bnu4bor7TmmI7jgILosKjmhY7mk43kvZzvvIzorrjlpJrkvJjljJblsIblpKfluYXkv67mlLnns7vnu5/jgIIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxMaW5lQnJlYWsvPuaOqOiNkOmAiemhuemAgueUqOS6juaZrumAmueUqOaIt++8jOS4jeehruWumuivt+S4jeimgeWLvumAieWFtuS7lumAiemhue+8gQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgIDwvU2Nyb2xsVmlld2VyPgogICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Sb3c9IjEiIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIgQm9yZGVyVGhpY2tuZXNzPSIxIiBDb3JuZXJSYWRpdXM9IjUiIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFBhZGRpbmc9IjEwIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFdyYXBQYW5lbCBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgR3JpZC5Db2x1bW49IjAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZUd2Vha3NidXR0b24iIENvbnRlbnQ9Iui/kOihjOS8mOWMliIgTWFyZ2luPSI1IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlVuZG9hbGwiIENvbnRlbnQ9IuaSpOmUgOS8mOWMliIgTWFyZ2luPSI1IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvV3JhcFBhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICA8L1RhYkl0ZW0+CiAgICAgICAgICAgIDxUYWJJdGVtIEhlYWRlcj0i5Yqf6IO96YWN572uIiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiIE5hbWU9IldQRlRhYjMiPgogICAgICAgICAgICAgICAgPFNjcm9sbFZpZXdlciBWZXJ0aWNhbFNjcm9sbEJhclZpc2liaWxpdHk9IkF1dG8iIEhvcml6b250YWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIiBNYXJnaW49IntEeW5hbWljUmVzb3VyY2UgVGFiQ29udGVudE1hcmdpbn0iPgogICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9ImZlYXR1cmVzcGFuZWwiIEdyaWQuUm93PSIxIiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCI+CiAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgPC9TY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgIDwvVGFiSXRlbT4KICAgICAgICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJXaW5kb3dzIOabtOaWsCIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWI0Ij4KICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXIgVmVydGljYWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIiBIb3Jpem9udGFsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iRGlzYWJsZWQiIE1hcmdpbj0ie0R5bmFtaWNSZXNvdXJjZSBUYWJDb250ZW50TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIE1heFdpZHRoPSIxMjUwIiBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLlJvd0RlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMTAsMTAsMTAsMTQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJXaW5kb3dzIOabtOaWsOmFjee9ruaWh+S7tiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IjI0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IumAieaLqSBXaW5kb3dzIOaOpeaUtuabtOaWsOeahOaWueW8j+OAguavj+S4qumFjee9ruWwhuabv+aNoiBXaW5VdGlsIOeuoeeQhueahOabtOaWsOiuvue9ruOAgiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDYsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0iMTMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICA8VW5pZm9ybUdyaWQgR3JpZC5Sb3c9IjEiIENvbHVtbnM9IjMiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgUHJvZ3Jlc3NCYXJGb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjE2IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNaW5IZWlnaHQ9IjMwMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIwIiBNYXJnaW49IjAsMCwwLDE0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0i5o6o6I2Q6YWN572uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0iMjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0i5bmz6KGh5a6J5YWo5LiO56iz5a6aIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsNCwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIxIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSDmjqjov5/lip/og73mm7TmlrAgMzY1IOWkqSIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSDmjqjov5/otKjph4/mm7TmlrAgNCDlpKkiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw3IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9Ii0g5LuO6LSo6YeP5pu05paw5Lit5o6S6Zmk6amx5YqoIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIOeZu+W9leaXtumYu+atouiHquWKqOmHjeWQryIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IumAgueUqOS6jiBXaW4g5LiT5Lia54mIL+S8geS4mueJiC/mlZnogrLniYjjgIIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFN0eWxlPSJJdGFsaWMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGVXBkYXRlc3NlY3VyaXR5IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEdyaWQuUm93PSIyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuW6lOeUqOaOqOiNkCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBDb25maWdUYWJCdXR0b25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDE2LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSIxMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBCb3JkZXJTdHlsZX0iIFBhZGRpbmc9IjE2IiBNaW5IZWlnaHQ9IjMwMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIwIiBNYXJnaW49IjAsMCwwLDE0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iV2luZG93cyDpu5jorqQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIyMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLkuqTov5jmjqfliLbmnYPnu5kgV2luZG93cyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDQsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0iMTMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBHcmlkLlJvdz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9Ii0g56e76ZmkIFdpblV0aWwg5bqU55So55qE5pu05paw562W55WlIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIOaBouWkjeabtOaWsOacjeWKoeWQr+WKqOiuvue9riIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSDph43mlrDlkK/nlKjmm7TmlrDorqHliJLku7vliqEiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCwxMiIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLnlKjkuo7mkqTplIDmjqjojZDmiJbnpoHnlKjphY3nva7jgIIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFN0eWxlPSJJdGFsaWMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGVXBkYXRlc2RlZmF1bHQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgR3JpZC5Sb3c9IjIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5oGi5aSN6buY6K6kIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIENvbmZpZ1RhYkJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMTYsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIgUGFkZGluZz0iMTYiIE1pbkhlaWdodD0iMzAwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMCwwLDAsMTQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLnpoHnlKjmm7TmlrAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIyMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iUmVkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IuS7hemZkOmrmOe6p+eUqOaItyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDQsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0iMTMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRXZWlnaHQ9IlNlbWlCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJSZWQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBHcmlkLlJvdz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9Ii0g56aB55So6Ieq5Yqo5pu05paw562W55WlIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIOWBnOatouabtOaWsOacjeWKoeWSjOiuoeWIkuS7u+WKoSIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSDmuIXpmaTlt7LkuIvovb3mm7TmlrDmlofku7YiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCwxMiIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLmraTphY3nva7mv4DmtLvmnJ/pl7TkuI3lronoo4Xlronlhajmm7TmlrDjgIIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFN0eWxlPSJJdGFsaWMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iUmVkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZVcGRhdGVzZGlzYWJsZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBHcmlkLlJvdz0iMiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLnpoHnlKjmm7TmlrAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQ29uZmlnVGFiQnV0dG9uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IlJlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMTYsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvVW5pZm9ybUdyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEdyaWQuUm93PSIyIiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIgTWFyZ2luPSI4LDE0LDgsOCIgUGFkZGluZz0iMTIiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSLmm7TmlLnkvZznlKjkuo7lhajns7vnu5/jgILliIfmjaLphY3nva7lkI7ph43lkK8gV2luZG93c+OAguS9v+eUqOaBouWkjem7mOiupOWPr+aSpOmUgOetlueVpeOAgiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgPC9TY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgIDwvVGFiSXRlbT4KICAgICAgICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJXaW4xMSDliJvlu7rlt6XlhbciIFZpc2liaWxpdHk9IkNvbGxhcHNlZCIgTmFtZT0iV1BGVGFiNSI+CiAgICAgICAgICAgICAgICA8R3JpZCBOYW1lPSJXaW4xMUlTT1BhbmVsIiBNYXJnaW49IntEeW5hbWljUmVzb3VyY2UgVGFiQ29udGVudE1hcmdpbn0iIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ij4KICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+ICA8IS0tIFN0ZXBzIDEtNCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSIqIi8+ICAgICA8IS0tIExvZyAvIFN0YXR1cyAtLT4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgIDwhLS0gU3RlcHMgMS00IC0tPgogICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIwIj4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIOKUgOKUgOKUgCBTVEVQIDEgOiBTZWxlY3QgV2luZG93cyAxMSBJU08g4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iV1BGV2luMTFJU09TZWxlY3RTZWN0aW9uIiBNYXJnaW49IjUiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIE1pbldpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIExlZnQ6IEZpbGUgU2VsZWN0b3IgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Db2x1bW49IjAiIE1hcmdpbj0iNSw1LDE1LDUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBNYXJnaW49IjAsMCwwLDgiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg5q2l6aqkIDEgLSDpgInmi6kgV2luZG93cyAxMSBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw2Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOa1j+iniOacrOWcsOeahCBXaW5kb3dzIDExIElTTyDmlofku7bjgILku4XmlK/mjIEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOS7jiBNaWNyb3NvZnQg5LiL6L2955qE5a6Y5pa5IElTT+OAggogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIiBGb250U3R5bGU9Ikl0YWxpYyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UnVuIEZvbnRXZWlnaHQ9IkJvbGQiPuazqOaEj++8mjwvUnVuPiDku4XpgILnlKjkuo7lhajmlrAgV2luZG93cyDlronoo4XjgIIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCb3ggR3JpZC5Db2x1bW49IjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZXaW4xMUlTT1BhdGgiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBJc1JlYWRPbmx5PSJUcnVlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjYsNCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDYsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHQ9IuacqumAieaLqSBJU08uLi4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09Ccm93c2VCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9Iua1j+iniCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBOYW1lPSJXUEZXaW4xMUlTT0ZpbGVJbmZvIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0V3JhcHBpbmc9IldyYXAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIFJpZ2h0OiBEb3dubG9hZCBndWlkYW5jZSAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI1IiBQYWRkaW5nPSIxNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCIgTWFyZ2luPSIwLDAsMCwxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgISHorablkYrvvIHvvIEg5b+F6aG75L2/55So5a6Y5pa5IE1pY3Jvc29mdCBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDnm7TmjqXku44gTWljcm9zb2Z0LmNvbSDkuIvovb0gV2luZG93cyAxMSBJU0/jgIIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDkuI3mlK/mjIHnrKzkuInmlrnjgIHpooTlhYjkv67mlLnmiJbpnZ7lrpjmlrnmmKDlg48KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDlj6/og73lr7zoh7TmjZ/lnY/nu5PmnpzjgIIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw2Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDlnKggTWljcm9zb2Z0IOS4i+i9vemhtemdoumAieaLqe+8mgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjEyLDAsMCwxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLSDniYjmnKzvvJpXaW5kb3dzIDExCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPExpbmVCcmVhay8+LSDor63oqIDvvJrpppbpgInor63oqIAKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz4tIOaetuaehO+8mjY0LWJpdAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPRG93bmxvYWRMaW5rIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLmiZPlvIDlvq7ova/kuIvovb3pobXpnaIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSDilIDilIDilIAgU1RFUCAyIDogTW91bnQgJiBWZXJpZnkgSVNPIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9IldQRldpbjExSVNPTW91bnRTZWN0aW9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgTWluV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuQ29sdW1uPSIwIiBNYXJnaW49IjAsMCwyMCwwIiBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0ZXAgMiAtIE1vdW50ICZhbXA7IFZlcmlmeSBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIiBNYXhXaWR0aD0iMzIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOaMgui9vSBJU08g5bm256Gu6K6k5YyF5ZCr5pyJ5pWI55qEIFdpbmRvd3MgMTEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGluc3RhbGwud2lt77yM54S25ZCO5YaN5L+u5pS544CCCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPTW91bnRCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5oyC6L295bm26aqM6K+BIElTTyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDaGVja0JveCBOYW1lPSJXUEZXaW4xMUlTT0luamVjdERyaXZlcnMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLms6jlhaXlvZPliY3ns7vnu5/pqbHliqgiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSXNDaGVja2VkPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuS7juacrOacuuWvvOWHuuaJgOaciempseWKqOW5tuazqOWFpSBpbnN0YWxsLndpbSDlkowgYm9vdC53aW3vvIzmjqjojZDnlKjkuo7mnInkuI3mlK/mjIEgTlZNZSDmiJbnvZHnu5zmjqfliLblmajnmoTns7vnu5/jgIIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVmVyaWZpY2F0aW9uIHJlc3VsdHMgcGFuZWwgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPVmVyaWZ5UmVzdWx0UGFuZWwiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSIxIiBDb3JuZXJSYWRpdXM9IjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSIxMiIgTWFyZ2luPSIwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIE5hbWU9IldQRldpbjExSVNPTW91bnREcml2ZUxldHRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgTmFtZT0iV1BGV2luMTFJU09BcmNoTGFiZWwiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMCw0Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDYsMCw0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICDpgInmi6nniYjmnKzvvJoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbWJvQm94IE5hbWU9IldQRldpbjExSVNPRWRpdGlvbkNvbWJvQm94IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0g4pSA4pSA4pSAIFNURVAgMyA6IE1vZGlmeSBpbnN0YWxsLndpbSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBOYW1lPSJXUEZXaW4xMUlTT01vZGlmeVNlY3Rpb24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBNaW5XaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3RlcCAzIC0gTW9kaWZ5IGluc3RhbGwud2ltCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSVNPIOWGheWuueWwhuaPkOWPluWIsOS4tOaXtuW3peS9nOebruW9le+8jAogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBpbnN0YWxsLndpbSDlsIbooqvkv67mlLnvvIjnp7vpmaTnu4Tku7bjgIHlupTnlKjkvJjljJbvvInvvIwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg54S25ZCO6YeN5paw5omT5YyF44CC5q2k6L+H56iL5Y+v6IO96ZyA6KaB5pWw5YiG6ZKf77yMCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOWFt+S9k+WPluWGs+S6juehrOS7tuOAggogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGV2luMTFJU09Nb2RpZnlCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLov5DooYwgV2luZG93cyBJU08g5L+u5pS55ZKM5Yib5bu65bel5YW3IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIOKUgOKUgOKUgCBTVEVQIDQgOiBPdXRwdXQgT3B0aW9ucyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBOYW1lPSJXUEZXaW4xMUlTT091dHB1dFNlY3Rpb24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBNaW5XaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gSGVhZGVyIHJvdzogdGl0bGUgKyBDbGVhbiAmIFJlc2V0IGJ1dHRvbiAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEdyaWQuQ29sdW1uPSIwIiBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOatpemqpCA0IC0g6L6T5Ye677ya5aaC5L2V5aSE55CG5L+u5pS55ZCO55qE5pig5YOP77yfCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPQ2xlYW5SZXNldEJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLmuIXnkIblubbph43nva4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iT3JhbmdlUmVkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuWIoOmZpOS4tOaXtuW3peS9nOebruW9leW5tumHjee9ruWbnuatpemqpCAxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMTIsMCwwLDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0g4pSA4pSAIENob2ljZSBwcm9tcHQgYnV0dG9ucyDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTWFyZ2luPSIwLDAsMCwxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIxNiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPQ2hvb3NlSVNPQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuS/neWtmOS4uiBJU08g5paH5Lu2IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBHcmlkLkNvbHVtbj0iMiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZXaW4xMUlTT0Nob29zZVVTQkJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLnm7TmjqXlhpnlhaUgVVNCIOmpseWKqOWZqO+8iOS8muaTpumZpOaVtOS4quejgeebmO+8iSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJPcmFuZ2VSZWQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iQXV0byIgUGFkZGluZz0iMTIsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSDilIDilIAgVVNCIHdyaXRlIHN1Yi1wYW5lbCAocmV2ZWFsZWQgb24gVVNCIGNob2ljZSkg4pSA4pSAIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iV1BGV2luMTFJU09PcHRpb25VU0IiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZpc2liaWxpdHk9IkNvbGxhcHNlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UnVuIEZvbnRXZWlnaHQ9IkJvbGQiIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCI+ISEg5omA6YCJIFUg55uY5LiK55qE5omA5pyJ5pWw5o2u5bCG6KKr5rC45LmF5pOm6ZmkICEhPC9SdW4+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPExpbmVCcmVhay8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAg6YCJ5oup5LiL5pa555qE5Y+v56e75YqoIFUg55uY77yM54S25ZCO54K55Ye75pOm6Zmk5ZKM5YaZ5YWl44CCCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVVNCIGRyaXZlIHNlbGVjdG9yIHJvdyAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE1hcmdpbj0iMCwwLDAsOCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb21ib0JveCBHcmlkLkNvbHVtbj0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09VU0JEcml2ZUNvbWJvQm94IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCw2LDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09SZWZyZXNoVVNCQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5Yi35pawIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjgsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPV3JpdGVVU0JCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuaTpumZpOW5tuWGmeWFpSBVU0IiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KCiAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgoKICAgICAgICAgICAgICAgICAgICA8IS0tIOeKtuaAgeaXpeW/lyAoZmlsbHMgcmVtYWluaW5nIGhlaWdodCkgLS0+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQgR3JpZC5Sb3c9IjEiIE1hcmdpbj0iNSI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEdyaWQuUm93PSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDAsNCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICDnirbmgIHml6Xlv5cKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0Qm94IEdyaWQuUm93PSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZXaW4xMUlTT1N0YXR1c0xvZyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSXNSZWFkT25seT0iVHJ1ZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbFNjcm9sbEJhclZpc2liaWxpdHk9IlZpc2libGUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJTdHJldGNoIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSI2IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie0R5bmFtaWNSZXNvdXJjZSBCb3JkZXJDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dD0i5bCx57uq44CC6K+36YCJ5oupIFdpbmRvd3MgMTEgSVNPIOW8gOWni+OAgiIvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgIDwvVGFiSXRlbT4KICAgICAgICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJBcHBYIiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiIE5hbWU9IldQRlRhYjYiPgogICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIiAvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgPFNjcm9sbFZpZXdlciBWZXJ0aWNhbFNjcm9sbEJhclZpc2liaWxpdHk9IkF1dG8iIEhvcml6b250YWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJEaXNhYmxlZCIgR3JpZC5Sb3c9IjAiIE1hcmdpbj0ie0R5bmFtaWNSZXNvdXJjZSBUYWJDb250ZW50TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLlJvd0RlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIE9yaWVudGF0aW9uPSJWZXJ0aWNhbCIgR3JpZC5Sb3c9IjAiIEdyaWQuQ29sdW1uPSIwIiBNYXJnaW49IjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxMYWJlbCBDb250ZW50PSLpgInmi6nvvJoiIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgTWFyZ2luPSIyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIE1hcmdpbj0iMCwyLDAsMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGRGVmYXVsdEFwcHhTZWxlY3Rpb24iIENvbnRlbnQ9Ium7mOiupCIgTWFyZ2luPSIyIiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGR2V0SW5zdGFsbGVkQXBweCIgQ29udGVudD0i5bey5a6J6KOF5YiX6KGoIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWxlY3RBbGxBcHB4IiBDb250ZW50PSLlhajpgIkiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkNsZWFyQXBweFNlbGVjdGlvbiIgQ29udGVudD0i5riF6Zmk6YCJ5oupIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iYXBweHBhbmVsIiBHcmlkLlJvdz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLlJvdz0iMiIgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBCb3JkZXJTdHlsZX0iIE1hcmdpbj0iNSwxNSw1LDUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBQYWRkaW5nPSIxMCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIOazqOaEj++8mumAieaLqeimgeWuieijheaIluenu+mZpOeahCBXaW5kb3dzIEFwcFgg5YyF44CCCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz7lronoo4XpgInkuK3lsIblnKjlj6/nlKjml7bms6jlhozmnKzlnLDmuIXljZXvvIzlkKbliJnlm57pgIDliLAgTWljcm9zb2Z0IFN0b3Jl44CCCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz7np7vpmaTpgInkuK3lsIbnp7vpmaTlvZPliY3lkozmiYDmnInmlrDnlKjmiLfnmoTljIXjgIIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICA8L1Njcm9sbFZpZXdlcj4KCiAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLlJvdz0iMSIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iNSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgUGFkZGluZz0iMTAiPgogICAgICAgICAgICAgICAgICAgICAgICA8V3JhcFBhbmVsIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGQmFja1RvVHdlYWtzIiBDb250ZW50PSLov5Tlm57kvJjljJYiIE1hcmdpbj0iNSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZJbnN0YWxsU2VsZWN0ZWRBcHB4IiBDb250ZW50PSLlronoo4XpgInkuK0iIE1hcmdpbj0iNSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZSZW1vdmVTZWxlY3RlZEFwcHgiIENvbnRlbnQ9Iuenu+mZpOmAieS4rSIgTWFyZ2luPSI1IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvV3JhcFBhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICA8L1RhYkl0ZW0+CiAgICAgICAgPC9UYWJDb250cm9sPgoKICAgICAgICA8IS0tIFdpbmRvdy1sZXZlbCBwcm9ncmVzcyBpbmRpY2F0b3IgLSB2aXNpYmxlIHJlZ2FyZGxlc3Mgb2YgYWN0aXZlIHRhYiAtLT4KICAgICAgICA8Qm9yZGVyIE5hbWU9IldQRlR3ZWFrc1Byb2dyZXNzQmFyIiBHcmlkLlJvdz0iMyIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBQYWRkaW5nPSIxMCw2Ij4KICAgICAgICAgICAgPFN0YWNrUGFuZWwgT3JpZW50YXRpb249IlZlcnRpY2FsIj4KICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgTmFtZT0iV1BGVHdlYWtzUHJvZ3Jlc3NMYWJlbCIgVGV4dD0iIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBGb250U2l6ZT0iMTMiIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiBNYXJnaW49IjAsMCwwLDQiLz4KICAgICAgICAgICAgICAgIDxQcm9ncmVzc0JhciBOYW1lPSJXUEZUd2Vha3NQcm9ncmVzc1ZhbHVlIiBIZWlnaHQ9IjYiIE1pbmltdW09IjAiIE1heGltdW09IjEwMCIgVmFsdWU9IjAiIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgUm91bmRlZFByb2dyZXNzQmFyU3R5bGV9Ii8+CiAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICA8L0JvcmRlcj4KICAgIDwvR3JpZD4KPC9XaW5kb3c+Cg=='))


$WinUtilAutounattendXml = @'
<?xml version="1.0" encoding="utf-8"?>
<unattend xmlns="urn:schemas-microsoft-com:unattend" xmlns:wcm="http://schemas.microsoft.com/WMIConfig/2002/State">
    <!--https://schneegans.de/windows/unattend-generator/?LanguageMode=Interactive&ProcessorArchitecture=amd64&BypassRequirementsCheck=true&ComputerNameMode=Random&CompactOsMode=Default&TimeZoneMode=Implicit&PartitionMode=Interactive&DiskAssertionMode=Skip&WindowsEditionMode=Interactive&InstallFromMode=Automatic&PEMode=Default&UserAccountMode=InteractiveLocal&PasswordExpirationMode=Unlimited&LockoutMode=Default&HideFiles=Hidden&ClassicContextMenu=true&LaunchToThisPC=true&ShowEndTask=true&TaskbarSearch=Hide&TaskbarIconsMode=Empty&DisableWidgets=true&LeftTaskbar=true&HideTaskViewButton=true&StartTilesMode=Default&StartPinsMode=Empty&EnableLongPaths=true&HideEdgeFre=true&DisableEdgeStartupBoost=true&DeleteWindowsOld=true&EffectsMode=Default&DeleteEdgeDesktopIcon=true&DesktopIconsMode=Default&StartFoldersMode=Default&WifiMode=Skip&ExpressSettings=DisableAll&LockKeysMode=Configure&CapsLockInitial=Off&CapsLockBehavior=Toggle&NumLockInitial=On&NumLockBehavior=Toggle&ScrollLockInitial=Off&ScrollLockBehavior=Toggle&StickyKeysMode=Disabled&ColorMode=Custom&SystemColorTheme=Dark&AppsColorTheme=Dark&AccentColor=%230078d4&WallpaperMode=Default&LockScreenMode=Default&WdacMode=Skip&AppLockerMode=Skip-->
    <settings pass="offlineServicing"></settings>
    <settings pass="windowsPE">
        <component name="Microsoft-Windows-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <UserData>
                <AcceptEula>true</AcceptEula>
            </UserData>
            <UseConfigurationSet>false</UseConfigurationSet>
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassTPMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassSecureBootCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe add "HKLM\SYSTEM\Setup\LabConfig" /v BypassRAMCheck /t REG_DWORD /d 1 /f</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="generalize"></settings>
    <settings pass="specialize">
        <component name="Microsoft-Windows-Deployment" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <RunSynchronous>
                <RunSynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -NoProfile -Command "$xml = [xml]::new(); $xml.Load('C:\Windows\Panther\unattend.xml'); $sb = [scriptblock]::Create( $xml.unattend.Extensions.ExtractScript ); Invoke-Command -ScriptBlock $sb -ArgumentList $xml;"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>2</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\Specialize.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>3</Order>
                    <Path>reg.exe load "HKU\DefaultUser" "C:\Users\Default\NTUSER.DAT"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>4</Order>
                    <Path>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\DefaultUser.ps1"</Path>
                </RunSynchronousCommand>
                <RunSynchronousCommand wcm:action="add">
                    <Order>5</Order>
                    <Path>reg.exe unload "HKU\DefaultUser"</Path>
                </RunSynchronousCommand>
            </RunSynchronous>
        </component>
    </settings>
    <settings pass="auditSystem"></settings>
    <settings pass="auditUser"></settings>
    <settings pass="oobeSystem">
        <component name="Microsoft-Windows-Shell-Setup" processorArchitecture="amd64" publicKeyToken="31bf3856ad364e35" language="neutral" versionScope="nonSxS">
            <OOBE>
                <ProtectYourPC>3</ProtectYourPC>
                <HideEULAPage>true</HideEULAPage>
                <HideWirelessSetupInOOBE>true</HideWirelessSetupInOOBE>
                <HideOnlineAccountScreens>true</HideOnlineAccountScreens>
            </OOBE>
            <FirstLogonCommands>
                <SynchronousCommand wcm:action="add">
                    <Order>1</Order>
                    <CommandLine>powershell.exe -WindowStyle "Normal" -ExecutionPolicy "Unrestricted" -NoProfile -File "C:\Windows\Setup\Scripts\FirstLogon.ps1"</CommandLine>
                </SynchronousCommand>
            </FirstLogonCommands>
        </component>
    </settings>
    <Extensions xmlns="https://schneegans.de/windows/unattend-generator/">
        <ExtractScript>
param(
    [xml]$Document
);

foreach( $file in $Document.unattend.Extensions.File ) {
    $path = [System.Environment]::ExpandEnvironmentVariables( $file.GetAttribute( 'path' ) );
    mkdir -Path( $path | Split-Path -Parent ) -ErrorAction 'SilentlyContinue';
    $encoding = switch( [System.IO.Path]::GetExtension( $path ) ) {
        { $_ -in '.ps1', '.xml' } { [System.Text.Encoding]::UTF8; }
        { $_ -in '.reg', '.vbs', '.js' } { [System.Text.UnicodeEncoding]::new( $false, $true ); }
        default { [System.Text.Encoding]::Default; }
    };
    $bytes = $encoding.GetPreamble() + $encoding.GetBytes( $file.InnerText.Trim() );
    [System.IO.File]::WriteAllBytes( $path, $bytes );
}
        </ExtractScript>
        <File path="C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml">
&lt;LayoutModificationTemplate xmlns="http://schemas.microsoft.com/Start/2014/LayoutModification" xmlns:defaultlayout="http://schemas.microsoft.com/Start/2014/FullDefaultLayout" xmlns:start="http://schemas.microsoft.com/Start/2014/StartLayout" xmlns:taskbar="http://schemas.microsoft.com/Start/2014/TaskbarLayout" Version="1"&gt;
    &lt;CustomTaskbarLayoutCollection PinListPlacement="Replace"&gt;
        &lt;defaultlayout:TaskbarLayout&gt;
            &lt;taskbar:TaskbarPinList&gt;
                &lt;taskbar:DesktopApp DesktopApplicationLinkPath="#leaveempty" /&gt;
            &lt;/taskbar:TaskbarPinList&gt;
        &lt;/defaultlayout:TaskbarLayout&gt;
    &lt;/CustomTaskbarLayoutCollection&gt;
&lt;/LayoutModificationTemplate&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.vbs">
HKU = &amp;H80000003
Set reg = GetObject("winmgmts://./root/default:StdRegProv")
Set fso = CreateObject("Scripting.FileSystemObject")

If reg.EnumKey(HKU, "", sids) = 0 Then
    If Not IsNull(sids) Then
        For Each sid In sids
            key = sid + "\Software\Policies\Microsoft\Windows\Explorer"
            name = "LockedStartLayout"
            If reg.GetDWORDValue(HKU, key, name, existing) = 0 Then
                reg.SetDWORDValue HKU, key, name, 0
            End If
        Next
    End If
End If
        </File>
        <File path="C:\Windows\Setup\Scripts\UnlockStartLayout.xml">
&lt;Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task"&gt;
    &lt;Triggers&gt;
        &lt;EventTrigger&gt;
            &lt;Enabled&gt;true&lt;/Enabled&gt;
            &lt;Subscription&gt;&amp;lt;QueryList&amp;gt;&amp;lt;Query Id="0" Path="Application"&amp;gt;&amp;lt;Select Path="Application"&amp;gt;*[System[Provider[@Name='UnattendGenerator'] and EventID=1]]&amp;lt;/Select&amp;gt;&amp;lt;/Query&amp;gt;&amp;lt;/QueryList&amp;gt;&lt;/Subscription&gt;
        &lt;/EventTrigger&gt;
    &lt;/Triggers&gt;
    &lt;Principals&gt;
        &lt;Principal id="Author"&gt;
            &lt;UserId&gt;S-1-5-18&lt;/UserId&gt;
            &lt;RunLevel&gt;LeastPrivilege&lt;/RunLevel&gt;
        &lt;/Principal&gt;
    &lt;/Principals&gt;
    &lt;Settings&gt;
        &lt;MultipleInstancesPolicy&gt;IgnoreNew&lt;/MultipleInstancesPolicy&gt;
        &lt;DisallowStartIfOnBatteries&gt;false&lt;/DisallowStartIfOnBatteries&gt;
        &lt;StopIfGoingOnBatteries&gt;false&lt;/StopIfGoingOnBatteries&gt;
        &lt;AllowHardTerminate&gt;true&lt;/AllowHardTerminate&gt;
        &lt;StartWhenAvailable&gt;false&lt;/StartWhenAvailable&gt;
        &lt;RunOnlyIfNetworkAvailable&gt;false&lt;/RunOnlyIfNetworkAvailable&gt;
        &lt;IdleSettings&gt;
            &lt;StopOnIdleEnd&gt;true&lt;/StopOnIdleEnd&gt;
            &lt;RestartOnIdle&gt;false&lt;/RestartOnIdle&gt;
        &lt;/IdleSettings&gt;
        &lt;AllowStartOnDemand&gt;true&lt;/AllowStartOnDemand&gt;
        &lt;Enabled&gt;true&lt;/Enabled&gt;
        &lt;Hidden&gt;false&lt;/Hidden&gt;
        &lt;RunOnlyIfIdle&gt;false&lt;/RunOnlyIfIdle&gt;
        &lt;WakeToRun&gt;false&lt;/WakeToRun&gt;
        &lt;ExecutionTimeLimit&gt;PT72H&lt;/ExecutionTimeLimit&gt;
        &lt;Priority&gt;7&lt;/Priority&gt;
    &lt;/Settings&gt;
    &lt;Actions Context="Author"&gt;
        &lt;Exec&gt;
            &lt;Command&gt;C:\Windows\System32\wscript.exe&lt;/Command&gt;
            &lt;Arguments&gt;C:\Windows\Setup\Scripts\UnlockStartLayout.vbs&lt;/Arguments&gt;
        &lt;/Exec&gt;
    &lt;/Actions&gt;
&lt;/Task&gt;
        </File>
        <File path="C:\Windows\Setup\Scripts\SetStartPins.ps1">
$json = '{"pinnedList":[]}';
if( [System.Environment]::OSVersion.Version.Build -lt 20000 ) {
    return;
}
$key = 'Registry::HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start';
New-Item -Path $key -ItemType 'Directory' -ErrorAction 'SilentlyContinue';
Set-ItemProperty -LiteralPath $key -Name 'ConfigureStartPins' -Value $json -Type 'String';
        </File>
        <File path="C:\Windows\Setup\Scripts\SetColorTheme.ps1">
$lightThemeSystem = 0;
$lightThemeApps = 0;
$accentColorOnStart = 0;
$enableTransparency = 0;
$htmlAccentColor = '#0078D4';
&amp; {
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize';
        Force = $true;
        Type = 'DWord';
    };
    Set-ItemProperty @params -Name 'SystemUsesLightTheme' -Value $lightThemeSystem;
    Set-ItemProperty @params -Name 'AppsUseLightTheme' -Value $lightThemeApps;
    Set-ItemProperty @params -Name 'ColorPrevalence' -Value $accentColorOnStart;
    Set-ItemProperty @params -Name 'EnableTransparency' -Value $enableTransparency;
};
&amp; {
    Add-Type -AssemblyName 'System.Drawing';
    $accentColor = [System.Drawing.ColorTranslator]::FromHtml( $htmlAccentColor );

    function ConvertTo-DWord {
        param(
            [System.Drawing.Color]
            $Color
        );

        [byte[]]$bytes = @(
            $Color.R;
            $Color.G;
            $Color.B;
            $Color.A;
        );
        return [System.BitConverter]::ToUInt32( $bytes, 0);
    }

    $startColor = [System.Drawing.Color]::FromArgb( 0xD2, $accentColor );
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'StartColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent' -Name 'AccentColorMenu' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\DWM' -Name 'AccentColor' -Value( ConvertTo-DWord -Color $accentColor ) -Type 'DWord' -Force;
    $params = @{
        LiteralPath = 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Accent';
        Name = 'AccentPalette';
    };
    $palette = Get-ItemPropertyValue @params;
    $index = 20;
    $palette[ $index++ ] = $accentColor.R;
    $palette[ $index++ ] = $accentColor.G;
    $palette[ $index++ ] = $accentColor.B;
    $palette[ $index++ ] = $accentColor.A;
    Set-ItemProperty @params -Value $palette -Type 'Binary' -Force;
};
        </File>
        <File path="C:\Windows\Setup\Scripts\Specialize.ps1">
$scripts = @(
    {
        reg.exe add "HKLM\SYSTEM\Setup\MoSetup" /v AllowUpgradesWithUnsupportedTPMOrCPU /t REG_DWORD /d 1 /f;
    };
    {
        net.exe accounts /maxpwage:UNLIMITED;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\CloudContent" /v "DisableCloudOptimizedContent" /t REG_DWORD /d 1 /f;
        [System.Diagnostics.EventLog]::CreateEventSource( 'UnattendGenerator', 'Application' );
    };
    {
        Register-ScheduledTask -TaskName 'UnlockStartLayout' -Xml $( Get-Content -LiteralPath 'C:\Windows\Setup\Scripts\UnlockStartLayout.xml' -Raw );
    };
    {
        reg.exe add "HKLM\SYSTEM\CurrentControlSet\Control\FileSystem" /v LongPathsEnabled /t REG_DWORD /d 1 /f
    };
    {
        Remove-Item -LiteralPath 'C:\Users\Public\Desktop\Microsoft Edge.lnk' -ErrorAction 'SilentlyContinue' -Verbose;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Dsh" /v AllowNewsAndInterests /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge" /v HideFirstRunExperience /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v BackgroundModeEnabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Edge\Recommended" /v StartupBoostEnabled /t REG_DWORD /d 0 /f;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetStartPins.ps1';
    };
    {
        reg.exe add "HKU\.DEFAULT\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /t REG_DWORD /d 1 /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to customize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\Specialize.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\UserOnce.ps1">
$scripts = @(
    {
        [System.Diagnostics.EventLog]::WriteEntry( 'UnattendGenerator', "User '$env:USERNAME' has requested to unlock the Start menu layout.", [System.Diagnostics.EventLogEntryType]::Information, 1 );
    };
    {
        Remove-Item -Path "${env:USERPROFILE}\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
        Remove-Item -Path "$env:HOMEDRIVE\Users\Default\Desktop\*.lnk" -Force -ErrorAction 'SilentlyContinue';
    };
    {
        $taskbarPath = "$env:AppData\Microsoft\Internet Explorer\Quick Launch\User Pinned\TaskBar";
        if( Test-Path $taskbarPath ) {
            Get-ChildItem -Path $taskbarPath -File | Remove-Item -Force;
        }
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesRemovedChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'FavoritesChanges' -Force -ErrorAction 'SilentlyContinue';
        Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Taskband' -Name 'Favorites' -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe add "HKCU\Software\Classes\CLSID\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\InprocServer32" /ve /f;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced' -Name 'LaunchTo' -Type 'DWord' -Value 1;
    };
    {
        Set-ItemProperty -LiteralPath 'Registry::HKCU\Software\Microsoft\Windows\CurrentVersion\Search' -Name 'SearchboxTaskbarMode' -Type 'DWord' -Value 0;
    };
    {
        &amp; 'C:\Windows\Setup\Scripts\SetColorTheme.ps1';
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.Suggested" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.StartupApp" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Microsoft.SkyDrive.Desktop" /v Enabled /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Notifications\Settings\Windows.SystemToast.AccountHealth" /v Enabled /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v AllAppsViewMode /t REG_DWORD /d 2 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_IrisRecommendations /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_AccountNotifications /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowAllPinsList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowFrequentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Start" /v ShowRecentList /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v Start_TrackDocs /t REG_DWORD /d 0 /f;
    };
    {
        Restart-Computer -Force;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to configure this user account. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "$env:TEMP\UserOnce.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\DefaultUser.ps1">
$scripts = @(
    {
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "StartLayoutFile" /t REG_SZ /d "C:\Windows\Setup\Scripts\TaskbarLayoutModification.xml" /f;
        reg.exe add "HKU\DefaultUser\Software\Policies\Microsoft\Windows\Explorer" /v "LockedStartLayout" /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v ShowTaskViewButton /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced" /v TaskbarAl /t REG_DWORD /d 0 /f;
    };
    {
        foreach( $root in 'Registry::HKU\.DEFAULT', 'Registry::HKU\DefaultUser' ) {
          Set-ItemProperty -LiteralPath "$root\Control Panel\Keyboard" -Name 'InitialKeyboardIndicators' -Type 'String' -Value 2 -Force;
        }
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced\TaskbarDeveloperSettings" /v TaskbarEndTask /t REG_DWORD /d 1 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Control Panel\Accessibility\StickyKeys" /v Flags /t REG_SZ /d 10 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\DWM" /v ColorPrevalence /t REG_DWORD /d 0 /f;
    };
    {
        reg.exe add "HKU\DefaultUser\Software\Microsoft\Windows\CurrentVersion\RunOnce" /v "UnattendedSetup" /t REG_SZ /d "powershell.exe -WindowStyle \""Normal\"" -ExecutionPolicy \""Unrestricted\"" -NoProfile -File \""C:\Windows\Setup\Scripts\UserOnce.ps1\""" /f;
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to modify the default user&#x2019;&#x2019;s registry hive. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\DefaultUser.log";
        </File>
        <File path="C:\Windows\Setup\Scripts\FirstLogon.ps1">
$scripts = @(
    {
        Remove-Item -LiteralPath @(
          'C:\Windows\Panther\unattend.xml';
          'C:\Windows\Panther\unattend-original.xml';
          'C:\Windows\Setup\Scripts\Wifi.xml';
          'C:\Windows.old';
        ) -Recurse -Force -ErrorAction 'SilentlyContinue';
    };
    {
        reg.exe delete "HKCU\Software\Microsoft\Windows\CurrentVersion\Run" /v OneDriveSetup /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v NoAutoUpdate /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v AUOptions /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU" /v UseWUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v DisableWindowsUpdateAccess /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUServer /f;
        reg.exe delete "HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate" /v WUStatusServer /f;
        reg.exe delete "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DeliveryOptimization\Config" /v DODownloadMode /f;
        reg.exe add "HKLM\Software\Policies\Microsoft\Windows\OneDrive" /v DisableFileSyncNGSC /t REG_DWORD /d 0 /f;
        reg.exe add "HKCU\Software\Microsoft\Windows\CurrentVersion\GameDVR" /v AppCaptureEnabled /t REG_DWORD /d 0 /f;
        $services = @{ BITS = 'Manual'; wuauserv = 'Manual'; UsoSvc = 'Automatic'; WaaSMedicSvc = 'Manual' };
        foreach ($name in $services.Keys) {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction SilentlyContinue;
        }
    };
    {
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Education" /v IsEducationEnvironment /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Policies\Microsoft\Windows\Explorer" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
        reg.exe add "HKLM\SOFTWARE\Microsoft\PolicyManager\current\device\Start" /v HideRecommendedSection /t REG_DWORD /d 1 /f;
    };
    {
        $recallFeature = Get-WindowsOptionalFeature -Online -ErrorAction SilentlyContinue | Where-Object { $_.State -eq 'Enabled' -and $_.FeatureName -like 'Recall' };
        if( $recallFeature ) {
            Disable-WindowsOptionalFeature -Online -FeatureName 'Recall' -Remove -ErrorAction SilentlyContinue;
        }
    };
    {
        $viveDir = Join-Path $env:TEMP 'ViVeTool';
        $viveZip = Join-Path $env:TEMP 'ViVeTool.zip';
        Invoke-WebRequest 'https://github.com/thebookisclosed/ViVe/releases/download/v0.3.4/ViVeTool-v0.3.4-IntelAmd.zip' -OutFile $viveZip;
        Expand-Archive -Path $viveZip -DestinationPath $viveDir -Force;
        Remove-Item -Path $viveZip -Force;
        Start-Process -FilePath (Join-Path $viveDir 'ViVeTool.exe') -ArgumentList '/disable /id:47205210' -Wait -NoNewWindow;
        Remove-Item -Path $viveDir -Recurse -Force;
    };
    {
        Start-Process C:\Windows\System32\OneDriveSetup.exe -ArgumentList /uninstall
    };
    {
        if( (Get-BitLockerVolume -MountPoint $Env:SystemDrive).ProtectionStatus -eq 'On' ) {
            Disable-BitLocker -MountPoint $Env:SystemDrive;
        }
    };
    {
        if( (bcdedit | Select-String 'path').Count -eq 2 ) {
            bcdedit /set `{bootmgr`} timeout 0;
        }
    };
);

&amp; {
  [float]$complete = 0;
  [float]$increment = 100 / $scripts.Count;
  foreach( $script in $scripts ) {
    Write-Progress -Id 0 -Activity 'Running scripts to finalize your Windows installation. Do not close this window.' -PercentComplete $complete;
    '*** Will now execute command &#xAB;{0}&#xBB;.' -f $(
      $str = $script.ToString().Trim() -replace '\s+', ' ';
      $max = 100;
      if( $str.Length -le $max ) {
        $str;
      } else {
        $str.Substring( 0, $max - 1 ) + '&#x2026;';
      }
    );
    $start = [datetime]::Now;
    &amp; $script;
    '*** Finished executing command after {0:0} ms.' -f [datetime]::Now.Subtract( $start ).TotalMilliseconds;
    "`r`n" * 3;
    $complete += $increment;
  }
} *&gt;&amp;1 | Out-String -Width 1KB -Stream &gt;&gt; "C:\Windows\Setup\Scripts\FirstLogon.log";
        </File>
    </Extensions>
</unattend>

'@

Write-Host @"
    CCCCCCCCCCCCCTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTTT
 CCC::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
CC:::::::::::::::CT:::::::::::::::::::::TT:::::::::::::::::::::T
C:::::CCCCCCCC::::CT:::::TT:::::::TT:::::TT:::::TT:::::::TT:::::T
C:::::C       CCCCCCTTTTTT  T:::::T  TTTTTTTTTTTT  T:::::T  TTTTTT
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C                     T:::::T                T:::::T
C:::::C       CCCCCC        T:::::T                T:::::T
C:::::CCCCCCCC::::C      TT:::::::TT            TT:::::::TT
CC:::::::::::::::C       T:::::::::T            T:::::::::T
CCC::::::::::::C         T:::::::::T            T:::::::::T
  CCCCCCCCCCCCC          TTTTTTTTTTT            TTTTTTTTTTT

====Chris Titus Tech=====
=====Windows Toolbox=====
"@

# Load the configuration files

$sync.configs.applicationsHashtable = @{}
$sync.configs.applications.PSObject.Properties | ForEach-Object {
    $sync.configs.applicationsHashtable[$_.Name] = $_.Value
}

$sync.configs.appxHashtable = @{}
$sync.configs.appx.PSObject.Properties | ForEach-Object {
    $sync.configs.appxHashtable[$_.Name] = $_.Value
}
$sync.preferences.theme = "Auto"
$sync.preferences.packagemanager = "Winget"

if ($Preset) {
    Initialize-WinUtilRunspacePool | Out-Null

    # Selects the tweaks from $Preset varible
    Update-WinUtilSelections -flatJson $sync.configs.preset.$Preset

    # Run tweaks that were selected by Update-WinUtilSelections
    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

if ($Config) {
    Initialize-WinUtilRunspacePool | Out-Null

    Invoke-WPFImpex -type "import" -Config $Config

    Invoke-WinUtilAutoRun

    # Cleanup and exit
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    Stop-Transcript
    return
}

[void][System.Reflection.Assembly]::LoadWithPartialName('presentationframework')
[xml]$XAML = $inputXML

# Read the XAML file
$readerOperationSuccessful = $false # There's more cases of failure then success.
$reader = (New-Object System.Xml.XmlNodeReader $xaml)
try {
    $sync["Form"] = [Windows.Markup.XamlReader]::Load( $reader )
    $readerOperationSuccessful = $true
} catch [System.Management.Automation.MethodInvocationException] {
    Write-Host "XAML 代码出现问题。请检查此控件的语法..." -ForegroundColor Red
    Write-Host $error[0].Exception.Message -ForegroundColor Red

    If ($error[0].Exception.Message -like "*button*") {
        write-Host "Ensure your &lt;button in the `$inputXML does NOT have a Click=ButtonClick property.  PS can't handle this`n`n`n`n" -ForegroundColor Red
    }
} catch {
    Write-Host "无法加载 Windows.Markup.XamlReader。请检查语法并确保已安装 .NET。" -ForegroundColor Red
}

if (-NOT ($readerOperationSuccessful)) {
    Write-Host "使用 Windows.Markup.XamlReader 的 Load 方法解析 XAML 内容失败。" -ForegroundColor Red
    Write-Host "正在退出 WinUtil..." -ForegroundColor Red
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
    exit 1
}

# Setup the Window to follow listen for windows Theme Change events and update the winutil theme
# throttle logic needed, because windows seems to send more than one theme change event per change
$lastThemeChangeTime = [datetime]::MinValue
$debounceInterval = [timespan]::FromSeconds(2)
$sync.Form.Add_Loaded({
    $interopHelper = New-Object System.Windows.Interop.WindowInteropHelper $sync.Form
    $hwndSource = [System.Windows.Interop.HwndSource]::FromHwnd($interopHelper.Handle)
    $hwndSource.AddHook({
        param (
            [System.IntPtr]$hwnd,
            [int]$msg,
            [System.IntPtr]$wParam,
            [System.IntPtr]$lParam,
            [ref]$handled
        )
        $null = $hwnd, $wParam, $lParam
        # Check for the Event WM_SETTINGCHANGE (0x1001A) and validate that Button shows the icon for "Auto" => [char]0xF08C
        if (($msg -eq 0x001A) -and $sync.ThemeButton.Content -eq [char]0xF08C) {
            $currentTime = [datetime]::Now
            if ($currentTime - $lastThemeChangeTime -gt $debounceInterval) {
                Invoke-WinutilThemeChange -theme "Auto"
                $script:lastThemeChangeTime = $currentTime
                $handled = $true
            }
        }
        return 0
    })
})

Invoke-WinutilThemeChange -theme $sync.preferences.theme


# Build only the default tab before first paint; other tabs initialize on first activation.
$sync.InitializedTabs = @{}
Initialize-WinUtilTabContent -TabName "Install"

#===========================================================================
# Store Form Objects In PowerShell
#===========================================================================

$xaml.SelectNodes("//*[@Name]") | ForEach-Object {$sync["$("$($psitem.Name)")"] = $sync["Form"].FindName($psitem.Name)}

$sync.ChocoRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Choco"
})
$sync.WingetRadioButton.Add_Checked({
    $sync.preferences.packagemanager = "Winget"
})

switch ($sync.preferences.packagemanager) {
    "Choco" {$sync.ChocoRadioButton.IsChecked = $true; break}
    "Winget" {$sync.WingetRadioButton.IsChecked = $true; break}
}

$sync.keys | ForEach-Object {
    if($sync.$psitem) {
        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "ToggleButton") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

        if($($sync["$psitem"].GetType() | Select-Object -ExpandProperty Name) -eq "Button") {
            if ($sync.Buttons -notcontains $psitem) {
                $sync["$psitem"].Add_Click({
                    [System.Object]$Sender = $args[0]
                    Invoke-WPFButton $Sender.name
                })
                $sync.Buttons.Add($psitem) | Out-Null
            }
        }

    }
}

#===========================================================================
# Setup and Show the Form
#===========================================================================

# Progress bar in taskbaritem > Set-WinUtilProgressbar
$sync["Form"].TaskbarItemInfo = New-Object System.Windows.Shell.TaskbarItemInfo
Set-WinUtilTaskbaritem -state "None"

# Set the titlebar
$sync["Form"].title = $sync["Form"].title + " " + $sync.version
# Set the commands that will run when the form is closed
$sync["Form"].Add_Closing({
    Close-WinUtilRunspacePool
    [System.GC]::Collect()
})

# Attach the event handler to the Click event
$sync.SearchBarClearButton.Add_Click({
    $sync.SearchBar.Text = ""
    $sync.SearchBarClearButton.Visibility = "Collapsed"

    # Focus the search bar after clearing the text
    $sync.SearchBar.Focus()
    $sync.SearchBar.SelectAll()
})

# add some shortcuts for people that don't like clicking
function Invoke-WinUtilFontScaleStep([double]$Step) { $sync.FontScalingSlider.Value = [math]::Max(0.75, [math]::Min(2.0, $sync.FontScalingSlider.Value + $Step)); Invoke-WinUtilFontScaling -ScaleFactor $sync.FontScalingSlider.Value }

$commonKeyEvents = {
    # Prevent shortcuts from executing if a process is already running
    if ($sync.ProcessRunning -eq $true) {
        return
    }

    # Handle key presses of single keys
    switch ($_.Key) {
        "Escape" { $sync.SearchBar.Text = "" }
    }
    # Handle Alt key combinations for navigation
    if ($_.KeyboardDevice.Modifiers -eq "Alt") {
        $keyEventArgs = $_
        switch ($_.SystemKey) {
            "I" { Invoke-WPFButton "WPFTab1BT"; $keyEventArgs.Handled = $true } # Navigate to Install tab and suppress Windows Warning Sound
            "T" { Invoke-WPFButton "WPFTab2BT"; $keyEventArgs.Handled = $true } # Navigate to Tweaks tab
            "C" { Invoke-WPFButton "WPFTab3BT"; $keyEventArgs.Handled = $true } # Navigate to Config tab
            "U" { Invoke-WPFButton "WPFTab4BT"; $keyEventArgs.Handled = $true } # Navigate to Updates tab
            "W" { Invoke-WPFButton "WPFTab5BT"; $keyEventArgs.Handled = $true } # Navigate to Win11ISO tab
        }
    }
    # Handle Ctrl key combinations for specific actions
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl") {
        $keyEventArgs = $_
        switch ($_.Key) {
            "F" { $sync.SearchBar.Focus() } # Focus on the search bar
            "Q" { $this.Close() } # Close the application
        }
    }
    $ctrlShiftModifiers = [Windows.Input.ModifierKeys]::Control -bor [Windows.Input.ModifierKeys]::Shift
    if ($_.KeyboardDevice.Modifiers -eq "Ctrl" -or $_.KeyboardDevice.Modifiers -eq $ctrlShiftModifiers) {
        $keyEventArgs = $_
        switch ($_.Key) {
            { $_ -in "OemPlus", "Add" } { Invoke-WinUtilFontScaleStep 0.05; $keyEventArgs.Handled = $true }
            { $_ -in "OemMinus", "Subtract" } { Invoke-WinUtilFontScaleStep -0.05; $keyEventArgs.Handled = $true }
        }
    }
}
$sync["Form"].Add_PreViewKeyDown($commonKeyEvents)
$sync["Form"].Add_PreviewMouseWheel({
    if ([Windows.Input.Keyboard]::Modifiers -eq "Ctrl") { Invoke-WinUtilFontScaleStep $(if ($_.Delta -gt 0) { 0.05 } else { -0.05 }); $_.Handled = $true }
})

$sync["Form"].Add_MouseLeftButtonDown({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
    $sync["Form"].DragMove()
})

$sync["Form"].Add_MouseDoubleClick({
    if ($_.OriginalSource.Name -eq "NavDockPanel" -or
        $_.OriginalSource.Name -eq "GridBesideNavDockPanel") {
            if ($sync["Form"].WindowState -eq [Windows.WindowState]::Normal) {
                $sync["Form"].WindowState = [Windows.WindowState]::Maximized
            }
            else{
                $sync["Form"].WindowState = [Windows.WindowState]::Normal
            }
    }
})

$sync["Form"].Add_Deactivated({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings", "Theme", "FontScaling")
})

$sync["Form"].Add_ContentRendered({
    # Load the Windows Forms assembly
    Add-Type -AssemblyName System.Windows.Forms
    $primaryScreen = [System.Windows.Forms.Screen]::PrimaryScreen
    # Check if the primary screen is found
    if ($primaryScreen) {
        # Extract screen width and height for the primary monitor
        $screenWidth = $primaryScreen.Bounds.Width
        $screenHeight = $primaryScreen.Bounds.Height
        $sync.Form.MinWidth = [Math]::Min([double]$sync.Form.MinWidth, [double]$screenWidth)

        # Compare with the primary monitor size
        if ($sync.Form.ActualWidth -gt $screenWidth -or $sync.Form.ActualHeight -gt $screenHeight) {
            $sync.Form.Left = 0
            $sync.Form.Top = 0
            $sync.Form.Width = $screenWidth
            $sync.Form.Height = $screenHeight
        }
    }

    if ($PARAM_OFFLINE) {
        # Show offline banner
        $sync.WPFOfflineBanner.Visibility = [System.Windows.Visibility]::Visible

        # Disable the install tab
        $sync.WPFTab1BT.IsEnabled = $false
        $sync.WPFTab1BT.Opacity = 0.5
        $sync.WPFTab1BT.ToolTip = "Internet connection required for installing applications."

        # Disable install-related buttons
        $sync.WPFInstall.IsEnabled = $false
        $sync.WPFUninstall.IsEnabled = $false
        $sync.WPFInstallUpgrade.IsEnabled = $false
        $sync.WPFGetInstalled.IsEnabled = $false

        # Show offline indicator
        Write-Host "检测到离线模式 - 安装选项卡已禁用。" -ForegroundColor Yellow

        # Optionally switch to a different tab if install tab was going to be default
        Invoke-WPFTab "WPFTab2BT"  # Switch to Tweaks tab instead
    }
    else {
        # Online - ensure install tab is enabled
        $sync.WPFTab1BT.IsEnabled = $true
        $sync.WPFTab1BT.Opacity = 1.0
        $sync.WPFTab1BT.ToolTip = $null
        Invoke-WPFTab "WPFTab1BT"  # Default to install tab
    }

    $sync["Form"].Focus()
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilRunspacePool | Out-Null }) | Out-Null
    $sync["Form"].Dispatcher.BeginInvoke([System.Windows.Threading.DispatcherPriority]::Background, [action]{ Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $false -IncludeStatusAssets $true }) | Out-Null
})

# The SearchBarTimer is used to delay the search operation until the user has stopped typing for a short period
# This prevents the ui from stuttering when the user types quickly as it dosnt need to update the ui for every keystroke

$searchBarTimer = New-Object System.Windows.Threading.DispatcherTimer
$searchBarTimer.Interval = [TimeSpan]::FromMilliseconds(300)
$searchBarTimer.IsEnabled = $false

$searchBarTimer.add_Tick({
    $searchBarTimer.Stop()
    # Map current tab to search action (0=应用安装, 1=系统优化, 5=AppX移除)
    switch ($sync.tabManager.currentTab) {
        0 {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
        }
        1 {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        5 {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
    }
})
$sync["SearchBar"].Add_TextChanged({
    if ($sync.SearchBar.Tag -ne $sync.SearchBar.Text) {
        $sync.SearchBar.Tag = $null
    }

    if ($sync.SearchBar.Text -ne "") {
        $sync.SearchBarClearButton.Visibility = "Visible"
        $sync.SearchBarIcon.Visibility = "Collapsed"
    } else {
        $sync.SearchBarClearButton.Visibility = "Collapsed"
        $sync.SearchBarIcon.Visibility = "Visible"
    }

    # Category chip handlers apply their filter immediately.
    if ($sync.SearchBar.Tag -eq $sync.SearchBar.Text) {
        return
    }

    if ($searchBarTimer.IsEnabled) {
        $searchBarTimer.Stop()
    }
    $searchBarTimer.Start()
})

# Quick Category Search Chips
$sync["WPFSearchChipAll"].Add_Click({ Set-WinUtilAppCategoryFilter })
$sync["WPFSearchChipBrowsers"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "浏览器" })
$sync["WPFSearchChipCommunications"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "通讯工具" })
$sync["WPFSearchChipDevelopment"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "开发工具" })
$sync["WPFSearchChipGames"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "游戏" })
$sync["WPFSearchChipMicrosoftTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "微软工具" })
$sync["WPFSearchChipMultimediaTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "多媒体工具" })
$sync["WPFSearchChipProTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "专业工具" })
$sync["WPFSearchChipSelfhostedTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "自托管工具" })
$sync["WPFSearchChipUtilities"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "工具类" })

$sync["Form"].Add_Loaded({
    param($e)
    $null = $e
    $sync.Form.MinWidth = "1150"
    $sync["Form"].MaxWidth = [Double]::PositiveInfinity
    $sync["Form"].MaxHeight = [Double]::PositiveInfinity
})

$NavLogoPanel = $sync["Form"].FindName("NavLogoPanel")
$NavLogoPanel.Children.Add((Invoke-WinUtilAssets -Type "logo" -Size 25)) | Out-Null
Initialize-WinUtilTaskbarOverlayAssets -IncludeLogo $true -IncludeStatusAssets $false

Set-WinUtilTaskbaritem -overlay "logo"

$sync["Form"].Add_Activated({
    Set-WinUtilTaskbaritem -overlay "logo"
})

$sync["ThemeButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Toggle"; "FontScaling" = "Hide" }
})
$sync["AutoThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Auto"
})
$sync["DarkThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Dark"
})
$sync["LightThemeMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Theme")
    Invoke-WinutilThemeChange -theme "Light"
})

$sync["SettingsButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Toggle"; "Theme" = "Hide"; "FontScaling" = "Hide" }
})
$sync["ImportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "import"
})
$sync["ExportMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Invoke-WPFImpex -type "export"
})
$sync["AboutMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
Author   : <a href="https://github.com/ChrisTitusTech">@ChrisTitusTech</a>
UI       : <a href="https://github.com/MyDrift-user">@MyDrift-user</a>, <a href="https://github.com/Marterich">@Marterich</a>
Runspace : <a href="https://github.com/DeveloperDurp">@DeveloperDurp</a>, <a href="https://github.com/Marterich">@Marterich</a>
GitHub   : <a href="https://github.com/ChrisTitusTech/winutil">ChrisTitusTech/winutil</a>
Version  : <a href="https://github.com/ChrisTitusTech/winutil/releases/tag/$($sync.version)">$($sync.version)</a>
"@
    Show-CustomDialog -Title "About" -Message $authorInfo
})
$sync["DocumentationMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")
    Start-Process "https://winutil.christitus.com/"
})
$sync["SponsorMenuItem"].Add_Click({
    Invoke-WPFPopup -Action "Hide" -Popups @("Settings")

    $authorInfo = @"
<a href="https://github.com/sponsors/ChrisTitusTech">Current sponsors for ChrisTitusTech:</a>
"@
    $authorInfo += "`n"
    try {
        $sponsors = Invoke-WinUtilSponsors
        foreach ($sponsor in $sponsors) {
            $authorInfo += "<a href=`"https://github.com/sponsors/ChrisTitusTech`">$sponsor</a>`n"
        }
    } catch {
        $authorInfo += "An error occurred while fetching or processing the sponsors: $_`n"
    }
    Show-CustomDialog -Title "Sponsors" -Message $authorInfo -EnableScroll $true
})

# Font Scaling Event Handlers
$sync["FontScalingButton"].Add_Click({
    Invoke-WPFPopup -PopupActionTable @{ "Settings" = "Hide"; "Theme" = "Hide"; "FontScaling" = "Toggle" }
})

$sync["FontScalingSlider"].Add_ValueChanged({
    param($slider)
    $percentage = [math]::Round($slider.Value * 100)
    $sync.FontScalingValue.Text = "$percentage%"
})

$sync["FontScalingResetButton"].Add_Click({
    $sync.FontScalingSlider.Value = 1.0
    $sync.FontScalingValue.Text = "100%"
})

$sync["FontScalingApplyButton"].Add_Click({
    $scaleFactor = $sync.FontScalingSlider.Value
    Invoke-WinUtilFontScaling -ScaleFactor $scaleFactor
    Invoke-WPFPopup -Action "Hide" -Popups @("FontScaling")
})

# ── Win11ISO Tab button handlers ──────────────────────────────────────────────

$sync["WPFWin11ISOBrowseButton"].Add_Click({
    Invoke-WinUtilISOBrowse
})

$sync["WPFWin11ISODownloadLink"].Add_Click({
    Start-Process "https://www.microsoft.com/software-download/windows11"
})

$sync["WPFWin11ISOMountButton"].Add_Click({
    Invoke-WinUtilISOMountAndVerify
})

$sync["WPFWin11ISOModifyButton"].Add_Click({
    Invoke-WinUtilISOModify
})

$sync["WPFWin11ISOChooseISOButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Collapsed"
    Invoke-WinUtilISOExport
})

$sync["WPFWin11ISOChooseUSBButton"].Add_Click({
    $sync["WPFWin11ISOOptionUSB"].Visibility = "Visible"
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISORefreshUSBButton"].Add_Click({
    Invoke-WinUtilISORefreshUSBDrives
})

$sync["WPFWin11ISOWriteUSBButton"].Add_Click({
    Invoke-WinUtilISOWriteUSB
})

$sync["WPFWin11ISOCleanResetButton"].Add_Click({
    Invoke-WinUtilISOCleanAndReset
})

# ──────────────────────────────────────────────────────────────────────────────

$sync["Form"].ShowDialog() | out-null
Stop-Transcript
