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

    switch ($TabName) {
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
    $sync.WPFselectedAppsButton.Content = "Selected Apps: $count"
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

    if ($sync.currentTab -eq "Install" -and $sync.SearchBar -and -not [string]::IsNullOrWhiteSpace($sync.SearchBar.Text)) {
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
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "AppX install finished" -Percent 100
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
        $msg = "[Invoke-WPFFeatureInstall] Install process is currently running."
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
        $msg = "[Invoke-WPFGetInstalled] Install process is currently running."
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
        $msg = "[Invoke-WPFInstall] An Install process is currently running."
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
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App install finished" -Percent 100
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
        $sync.WPFselectedAppsButton.Content = "Selected Apps: $($sync.selectedApps.Count)"
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
    Initialize-WinUtilTabContent -TabName $sync.currentTab

    # Always reset the filter for the current tab
    if ($sync.currentTab -eq "Install") {
        # Reset Install tab filter
        Find-AppsByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "Tweaks") {
        # Reset Tweaks tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    } elseif ($sync.currentTab -eq "AppX") {
        # Reset AppX tab filter
        Find-TweaksByNameOrDescription -SearchString ""
    }

    # Show search bar in Install, Tweaks, and AppX tabs
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
        $msg = "[Invoke-WPFUnInstall] Install process is currently running"
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
                Set-WinUtilTweaksProgressIndicator -Visible $true -Label "App uninstall finished" -Percent 100
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
    $msg = "[Invoke-WPFtweaksbutton] Install process is currently running."
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
        $msg = "[Invoke-WPFundoall] Install process is currently running."
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



$sync.configs = @{}


$sync.configs.applications = @'
{
  "WPFInstall1password": {
    "category": "工具类",
    "choco": "1password",
    "content": "1Password 密码管理器",
    "description": "1Password 是一款密码管理器，可以安全地存储和管理您的密码。",
    "link": "https://1password.com/",
    "winget": "AgileBits.1Password",
    "foss": false
  },
  "WPFInstall7zip": {
    "category": "工具类",
    "choco": "7zip",
    "content": "7-Zip 压缩工具",
    "description": "7-Zip 是一款免费开源的压缩工具，支持多种压缩格式，提供高压缩比，是文件压缩的热门选择。",
    "link": "https://www.7-zip.org/",
    "winget": "7zip.7zip",
    "foss": true
  },
  "WPFInstalladobe": {
    "category": "多媒体工具",
    "choco": "adobereader",
    "content": "Adobe Acrobat Reader PDF阅读器",
    "description": "Adobe Acrobat Reader 是一款免费的 PDF 阅读器，提供查看、打印和注释 PDF 文档的基本功能。",
    "link": "https://www.adobe.com/acrobat/pdf-reader.html",
    "winget": "Adobe.Acrobat.Reader.64-bit",
    "foss": false
  },
  "WPFInstalladvancedip": {
    "category": "专业工具",
    "choco": "advanced-ip-scanner",
    "content": "Advanced IP Scanner 网络扫描",
    "description": "Advanced IP Scanner 是一款快速易用的网络扫描工具，用于分析局域网并提供连接设备的信息。",
    "link": "https://www.advanced-ip-scanner.com/",
    "winget": "Famatech.AdvancedIPScanner",
    "foss": false
  },
  "WPFInstallaimp": {
    "category": "多媒体工具",
    "choco": "aimp",
    "content": "AIMP 音乐播放器",
    "description": "AIMP 是一款功能丰富的音乐播放器，支持多种音频格式、播放列表和可定制的用户界面。",
    "link": "https://www.aimp.ru/",
    "winget": "AIMP.AIMP",
    "foss": false
  },
  "WPFInstallangryipscanner": {
    "category": "专业工具",
    "choco": "angryip",
    "content": "Angry IP Scanner IP扫描器",
    "description": "Angry IP Scanner 是一款开源跨平台的网络扫描器，用于扫描 IP 地址和端口，提供网络连接信息。",
    "link": "https://angryip.org/",
    "winget": "angryziber.AngryIPScanner",
    "foss": true
  },
  "WPFInstallanydesk": {
    "category": "工具类",
    "choco": "anydesk",
    "content": "AnyDesk 远程桌面",
    "description": "AnyDesk 是一款远程桌面软件，使用户能够远程访问和控制计算机，以快速连接和低延迟著称。",
    "link": "https://anydesk.com/",
    "winget": "AnyDesk.AnyDesk",
    "foss": false
  },
  "WPFInstallaudacity": {
    "category": "多媒体工具",
    "choco": "audacity",
    "content": "Audacity 音频编辑",
    "description": "Audacity 是一款免费开源的音频编辑软件，以其强大的录音和编辑功能而闻名。",
    "link": "https://www.audacityteam.org/",
    "winget": "Audacity.Audacity",
    "foss": true
  },
  "WPFInstallautoruns": {
    "category": "微软工具",
    "choco": "autoruns",
    "content": "Autoruns 启动项管理",
    "description": "此工具显示哪些程序配置为在系统启动或登录时运行。",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/autoruns",
    "winget": "Microsoft.Sysinternals.Autoruns",
    "foss": false
  },
  "WPFInstallrdcman": {
    "category": "微软工具",
    "choco": "rdcman",
    "content": "RDCMan 远程桌面管理",
    "description": "RDCMan 管理多个远程桌面连接，适用于需要定期访问每台机器的服务器实验室。",
    "link": "https://learn.microsoft.com/en-us/sysinternals/downloads/rdcman",
    "winget": "Microsoft.Sysinternals.RDCMan",
    "foss": false
  },
  "WPFInstallautohotkey": {
    "category": "工具类",
    "choco": "autohotkey",
    "content": "AutoHotkey 自动脚本",
    "description": "AutoHotkey 是一款 Windows 脚本语言，允许用户创建自定义自动化脚本和宏。",
    "link": "https://www.autohotkey.com/",
    "winget": "AutoHotkey.AutoHotkey",
    "foss": true
  },
  "WPFInstallbitwarden": {
    "category": "工具类",
    "choco": "bitwarden",
    "content": "Bitwarden 密码管理",
    "description": "Bitwarden 是一款开源密码管理解决方案，在多设备间安全存储和管理密码。",
    "link": "https://bitwarden.com/",
    "winget": "Bitwarden.Bitwarden",
    "foss": true
  },
  "WPFInstallblender": {
    "category": "多媒体工具",
    "choco": "blender",
    "content": "Blender 3D 图形",
    "description": "Blender 是一款功能强大的开源 3D 创作套件，提供建模、雕刻、动画和渲染工具。",
    "link": "https://www.blender.org/",
    "winget": "BlenderFoundation.Blender",
    "foss": true
  },
  "WPFInstallbrave": {
    "category": "浏览器",
    "choco": "brave",
    "content": "Brave 浏览器",
    "description": "Brave 是一款注重隐私的网页浏览器，可拦截广告和跟踪器，提供更快更安全的浏览体验。",
    "link": "https://www.brave.com",
    "winget": "Brave.Brave",
    "foss": true
  },
  "WPFInstallbulkcrapuninstaller": {
    "category": "工具类",
    "choco": "bulk-crap-uninstaller",
    "content": "Bulk Crap Uninstaller 批量卸载",
    "description": "Bulk Crap Uninstaller 是一款免费开源 Windows 卸载工具，帮助用户批量卸载程序。",
    "link": "https://www.bcuninstaller.com/",
    "winget": "Klocman.BulkCrapUninstaller",
    "foss": true
  },
  "WPFInstallblurautoclicker": {
    "category": "工具类",
    "choco": "na",
    "content": "BlurAutoClicker 自动点击器",
    "description": "一款具有高级功能且性能优于同类产品的自动点击器。",
    "link": "https://blur009.vercel.app/projects/blur-autoclicker/",
    "winget": "Blur009.BlurAutoClicker",
    "foss": true
  },
  "WPFInstallcalibre": {
    "category": "多媒体工具",
    "choco": "calibre",
    "content": "Calibre 电子书管理",
    "description": "Calibre 是一款功能强大且易于使用的电子书管理器、阅读器和转换器。",
    "link": "https://calibre-ebook.com/",
    "winget": "calibre.calibre",
    "foss": true
  },
  "WPFInstallcemu": {
    "category": "游戏",
    "choco": "cemu",
    "content": "Cemu Wii U 模拟器",
    "description": "Cemu 是一款高度实验性的 Wii U 模拟器软件。",
    "link": "https://cemu.info/",
    "winget": "Cemu.Cemu",
    "foss": true
  },
  "WPFInstallchatgpt": {
    "category": "开发工具",
    "choco": "na",
    "content": "ChatGPT 桌面版",
    "description": "ChatGPT 官方 Windows 桌面应用，通过 Microsoft Store 分发。",
    "link": "https://apps.microsoft.com/detail/9nt1r1c2hh7j",
    "winget": "msstore:9NT1R1C2HH7J",
    "foss": false
  },
  "WPFInstallchatterino": {
    "category": "通讯工具",
    "choco": "chatterino",
    "content": "Chatterino Twitch 聊天",
    "description": "Chatterino 是一款 Twitch 聊天客户端，提供简洁可定制的界面。",
    "link": "https://www.chatterino.com/",
    "winget": "ChatterinoTeam.Chatterino",
    "foss": true
  },
  "WPFInstallchrome": {
    "category": "浏览器",
    "choco": "googlechrome",
    "content": "Chrome 浏览器",
    "description": "Google Chrome 是一款广泛使用的网页浏览器，以速度、简洁和与 Google 服务集成而闻名。",
    "link": "https://www.google.com/chrome/",
    "winget": "Google.Chrome",
    "foss": false
  },
  "WPFInstallchromium": {
    "category": "浏览器",
    "choco": "chromium",
    "content": "Chromium 浏览器",
    "description": "Chromium 是作为包括 Chrome 在内的多种浏览器基础的开源项目。",
    "link": "https://github.com/Hibbiki/chromium-win64",
    "winget": "Hibbiki.Chromium",
    "foss": true
  },
  "WPFInstallcinebenchr23": {
    "category": "专业工具",
    "choco": "na",
    "content": "Cinebench R23 性能测试",
    "description": "Cinebench R23 是一款跨系统比较 CPU 渲染性能的基准测试工具。",
    "link": "https://www.maxon.net/en/cinebench",
    "winget": "Maxon.CinebenchR23",
    "foss": false
  },
  "WPFInstallclaude": {
    "category": "开发工具",
    "choco": "claude",
    "content": "Claude 桌面版",
    "description": "Anthropic 的 Claude 桌面应用程序，用于专注的 AI 辅助工作和聊天。",
    "link": "https://claude.ai/download",
    "winget": "Anthropic.Claude",
    "foss": false
  },
  "WPFInstallclaude-code": {
    "category": "开发工具",
    "choco": "claude-code",
    "content": "Claude Code 编程助手",
    "description": "Anthropic 的代理编程工具，适用于终端和 IDE 开发工作流。",
    "link": "https://code.claude.com/",
    "winget": "Anthropic.ClaudeCode",
    "foss": false
  },
  "WPFInstallcmake": {
    "category": "开发工具",
    "choco": "cmake",
    "content": "CMake 构建工具",
    "description": "CMake 是一款开源跨平台的工具集，用于构建、测试和打包软件。",
    "link": "https://cmake.org/",
    "winget": "Kitware.CMake",
    "foss": true
  },
  "WPFInstallcodex": {
    "category": "开发工具",
    "choco": "codex",
    "content": "Codex CLI 编程代理",
    "description": "Codex CLI 是 OpenAI 的编程代理，在您的终端中本地运行。",
    "link": "https://developers.openai.com/codex/cli",
    "winget": "OpenAI.Codex",
    "foss": true
  },
  "WPFInstallcpuz": {
    "category": "专业工具",
    "choco": "cpu-z",
    "content": "CPU-Z 硬件检测",
    "description": "CPU-Z 是一款 Windows 系统监控和诊断工具，提供硬件组件的详细信息。",
    "link": "https://www.cpuid.com/softwares/cpu-z.html",
    "winget": "CPUID.CPU-Z",
    "foss": false
  },
  "WPFInstallcrystaldiskinfo": {
    "category": "工具类",
    "choco": "crystaldiskinfo",
    "content": "CrystalDiskInfo 磁盘检测",
    "description": "CrystalDiskInfo 是一款磁盘健康监控工具，提供硬盘状态和性能信息。",
    "link": "https://crystalmark.info/en/software/crystaldiskinfo/",
    "winget": "CrystalDewWorld.CrystalDiskInfo",
    "foss": true
  },
  "WPFInstallcrystaldiskmark": {
    "category": "工具类",
    "choco": "crystaldiskmark",
    "content": "CrystalDiskMark 磁盘测试",
    "description": "CrystalDiskMark 是一款磁盘基准测试工具，测量存储设备的读写速度。",
    "link": "https://crystalmark.info/en/software/crystaldiskmark/",
    "winget": "CrystalDewWorld.CrystalDiskMark",
    "foss": true
  },
  "WPFInstallcursor": {
    "category": "开发工具",
    "choco": "cursoride",
    "content": "Cursor AI编辑器",
    "description": "AI 驱动的代码编辑器(基于 VS Code)，具有代理编程功能和集成 AI 辅助。",
    "link": "https://cursor.com/",
    "winget": "Anysphere.Cursor",
    "foss": false
  },
  "WPFInstallddu": {
    "category": "专业工具",
    "choco": "ddu",
    "content": "Display Driver Uninstaller 显卡驱动卸载",
    "description": "Display Driver Uninstaller (DDU) 是一款完全卸载显卡驱动程序的工具。",
    "link": "https://www.wagnardsoft.com/display-driver-uninstaller-DDU-",
    "winget": "Wagnardsoft.DisplayDriverUninstaller",
    "foss": true
  },
  "WPFInstalldiscord": {
    "category": "通讯工具",
    "choco": "discord",
    "content": "Discord 通讯平台",
    "description": "Discord 是一款流行的通讯平台，提供语音、视频和文字聊天。",
    "link": "https://discord.com/",
    "winget": "Discord.Discord",
    "foss": false
  },
  "WPFInstalldismtools": {
    "category": "微软工具",
    "choco": "dismtools",
    "content": "DISMTools 镜像工具",
    "description": "DISMTools 是一款快速可定制的 DISM 工具 GUI，支持 Windows 7 及以上版本的映像处理。",
    "link": "https://github.com/CodingWonders/DISMTools",
    "winget": "CodingWondersSoftware.DISMTools.Stable",
    "foss": true
  },
  "WPFInstallntlite": {
    "category": "微软工具",
    "choco": "ntlite-free",
    "content": "NTLite 系统精简",
    "description": "集成更新、驱动程序，自动化 Windows 和应用程序设置，加速 Windows 部署流程。",
    "link": "https://ntlite.com",
    "winget": "Nlitesoft.NTLite",
    "foss": false
  },
  "WPFInstalldorion": {
    "category": "通讯工具",
    "choco": "dorion",
    "content": "Dorion 轻量Discord",
    "description": "轻量级 Discord 替代客户端，占用更小、启动更快，支持主题和插件！",
    "link": "https://github.com/SpikeHD/Dorion",
    "winget": "SpikeHD.Dorion",
    "foss": true
  },
  "WPFInstalldotnet6": {
    "category": "微软工具",
    "choco": "dotnet-6.0-runtime",
    "content": ".NET 桌面运行时 6",
    "description": ".NET 桌面运行时 6 是运行使用 .NET 6 开发的应用程序所需的运行时环境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/6.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.6",
    "foss": true
  },
  "WPFInstalldotnet8": {
    "category": "微软工具",
    "choco": "dotnet-8.0-runtime",
    "content": ".NET 桌面运行时 8",
    "description": ".NET 桌面运行时 8 是运行使用 .NET 8 开发的应用程序所需的运行时环境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/8.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.8",
    "foss": true
  },
  "WPFInstalldotnet9": {
    "category": "微软工具",
    "choco": "dotnet-9.0-runtime",
    "content": ".NET 桌面运行时 9",
    "description": ".NET 桌面运行时 9 是运行使用 .NET 9 开发的应用程序所需的运行时环境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/9.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.9",
    "foss": true
  },
  "WPFInstalldotnet10": {
    "category": "微软工具",
    "choco": "dotnet-10.0-runtime",
    "content": ".NET 桌面运行时 10",
    "description": ".NET 桌面运行时 10 是运行使用 .NET 10 开发的应用程序所需的运行时环境。",
    "link": "https://dotnet.microsoft.com/download/dotnet/10.0",
    "winget": "Microsoft.DotNet.DesktopRuntime.10",
    "foss": true
  },
  "WPFInstalldropbox": {
    "category": "工具类",
    "choco": "dropbox",
    "content": "Dropbox 云存储",
    "description": "Dropbox 是一款云存储客户端，用于同步文件、共享内容并在多设备间保持文档可用。",
    "link": "https://www.dropbox.com/desktop",
    "winget": "Dropbox.Dropbox",
    "foss": false
  },
  "WPFInstalleaapp": {
    "category": "游戏",
    "choco": "ea-app",
    "content": "EA App 游戏平台",
    "description": "EA App 是访问和游玩 Electronic Arts 游戏的平台。",
    "link": "https://www.ea.com/ea-app",
    "winget": "ElectronicArts.EADesktop",
    "foss": false
  },
  "WPFInstalleartrumpet": {
    "category": "多媒体工具",
    "choco": "eartrumpet",
    "content": "EarTrumpet 音频控制",
    "description": "EarTrumpet 是一款 Windows 音频控制应用，提供简单直观的界面来管理声音设置。",
    "link": "https://eartrumpet.app/",
    "winget": "File-New-Project.EarTrumpet",
    "foss": true
  },
  "WPFInstalledge": {
    "category": "浏览器",
    "choco": "microsoft-edge",
    "content": "Edge 浏览器",
    "description": "Microsoft Edge 是一款基于 Chromium 的现代网页浏览器。",
    "link": "https://www.microsoft.com/edge",
    "winget": "Microsoft.Edge",
    "foss": false
  },
  "WPFInstallenteauth": {
    "category": "工具类",
    "choco": "ente-auth",
    "content": "Ente Auth 验证器",
    "description": "Ente Auth 是一款免费、跨平台、端到端加密的验证器应用。",
    "link": "https://ente.io/auth/",
    "winget": "ente-io.auth-desktop",
    "foss": true
  },
  "WPFInstallepicgames": {
    "category": "游戏",
    "choco": "epicgameslauncher",
    "content": "Epic Games 启动器",
    "description": "Epic Games Launcher 是访问和游玩 Epic Games 商店游戏的客户端。",
    "link": "https://www.epicgames.com/store/en-US/",
    "winget": "EpicGames.EpicGamesLauncher",
    "foss": false
  },
  "WPFInstallfiles": {
    "category": "工具类",
    "choco": "files",
    "content": "Files 文件管理器",
    "description": "替代性文件资源管理器。",
    "link": "https://github.com/files-community/Files",
    "winget": "FilesCommunity.Files",
    "foss": true
  },
  "WPFInstallfirefox": {
    "category": "浏览器",
    "choco": "firefox",
    "content": "Firefox 浏览器",
    "description": "Mozilla Firefox 是一款开源网页浏览器，以其定制选项、隐私功能和扩展而闻名。",
    "link": "https://www.mozilla.org/en-US/firefox/new/",
    "winget": "Mozilla.Firefox",
    "foss": true
  },
  "WPFInstallfirefoxesr": {
    "category": "浏览器",
    "choco": "FirefoxESR",
    "content": "Firefox ESR 长期支持版",
    "description": "Mozilla Firefox 是开源网页浏览器，ESR（扩展支持版）每 42 周收到一次主要更新。",
    "link": "https://www.mozilla.org/en-US/firefox/enterprise/",
    "winget": "Mozilla.Firefox.ESR",
    "foss": true
  },
  "WPFInstallfloorp": {
    "category": "浏览器",
    "choco": "floorp",
    "content": "Floorp 浏览器",
    "description": "Floorp 是一款开源网页浏览器项目，旨在提供简单快速的浏览体验。",
    "link": "https://floorp.app/",
    "winget": "Ablaze.Floorp",
    "foss": true
  },
  "WPFInstallflux": {
    "category": "工具类",
    "choco": "flux",
    "content": "F.lux 护眼调色",
    "description": "F.lux 调整屏幕色温，减少夜间使用时的眼睛疲劳。",
    "link": "https://justgetflux.com/",
    "winget": "flux.flux",
    "foss": false
  },
  "WPFInstallgeforcenow": {
    "category": "游戏",
    "choco": "nvidia-geforce-now",
    "content": "GeForce NOW 云游戏",
    "description": "GeForce NOW 是一款云游戏服务，可让您在设备上玩高品质的 PC 游戏。",
    "link": "https://www.nvidia.com/en-us/geforce-now/",
    "winget": "Nvidia.GeForceNow",
    "foss": false
  },
  "WPFInstallgimp": {
    "category": "多媒体工具",
    "choco": "gimp",
    "content": "GIMP 图像编辑",
    "description": "GIMP 是一款多功能开源光栅图形编辑器，用于照片修饰、图像编辑和图像合成。",
    "link": "https://www.gimp.org/",
    "winget": "GIMP.GIMP.3",
    "foss": true
  },
  "WPFInstallgit": {
    "category": "开发工具",
    "choco": "git",
    "content": "Git 版本控制",
    "description": "Git 是一款分布式版本控制系统，广泛用于软件开发中跟踪源代码的更改。",
    "link": "https://git-scm.com/",
    "winget": "Git.Git",
    "foss": true
  },
  "WPFInstallgithubdesktop": {
    "category": "开发工具",
    "choco": "git;github-desktop",
    "content": "GitHub Desktop 桌面端",
    "description": "GitHub Desktop 是一款可视化 Git 客户端，通过易用的界面简化 GitHub 仓库的协作。",
    "link": "https://desktop.github.com/",
    "winget": "GitHub.GitHubDesktop",
    "foss": true
  },
  "WPFInstallgog": {
    "category": "游戏",
    "choco": "goggalaxy",
    "content": "GOG Galaxy 游戏平台",
    "description": "GOG Galaxy 是一款游戏客户端，提供无 DRM 游戏、附加内容等。",
    "link": "https://www.gog.com/galaxy",
    "winget": "GOG.Galaxy",
    "foss": false
  },
  "WPFInstallgolang": {
    "category": "开发工具",
    "choco": "golang",
    "content": "Go 编程语言",
    "description": "Go（又称 Golang）是一种静态类型、编译型编程语言。",
    "link": "https://go.dev/",
    "winget": "GoLang.Go",
    "foss": true
  },
  "WPFInstallgoogledrive": {
    "category": "工具类",
    "choco": "googledrive",
    "content": "Google Drive 云盘",
    "description": "跨设备文件同步，全部关联到您的 Google 帐户。",
    "link": "https://www.google.com/drive/",
    "winget": "Google.GoogleDrive",
    "foss": false
  },
  "WPFInstallgpuz": {
    "category": "专业工具",
    "choco": "gpu-z",
    "content": "GPU-Z 显卡检测",
    "description": "GPU-Z 提供关于您的显卡和 GPU 的详细信息。",
    "link": "https://www.techpowerup.com/gpuz/",
    "winget": "TechPowerUp.GPU-Z",
    "foss": false
  },
  "WPFInstallgsudo": {
    "category": "专业工具",
    "choco": "gsudo",
    "content": "gsudo 提权工具",
    "description": "gsudo 是 Windows 下的 sudo 替代品，允许在当前控制台窗口中提升权限运行命令。",
    "link": "https://github.com/gerardog/gsudo",
    "winget": "gerardog.gsudo",
    "foss": true
  },
  "WPFInstallhelium": {
    "category": "浏览器",
    "choco": "helium",
    "content": "Helium 浏览器",
    "description": "私密、快速、诚实的网页浏览器。",
    "link": "https://github.com/imputnet/helium/",
    "winget": "ImputNet.Helium",
    "foss": true
  },
  "WPFInstallhugo": {
    "category": "工具类",
    "choco": "hugo-extended",
    "content": "Hugo 网站构建",
    "description": "世界上最快速的网站构建框架。",
    "link": "https://github.com/gohugoio/hugo/",
    "winget": "Hugo.Hugo.Extended",
    "foss": true
  },
  "WPFInstallhandbrake": {
    "category": "多媒体工具",
    "choco": "handbrake",
    "content": "HandBrake 视频转换",
    "description": "HandBrake 是一款开源视频转码器，可将几乎所有格式的视频转换为广泛支持的编解码器。",
    "link": "https://handbrake.fr/",
    "winget": "HandBrake.HandBrake",
    "foss": true
  },
  "WPFInstallheroiclauncher": {
    "category": "游戏",
    "choco": "heroic-games-launcher",
    "content": "Heroic Games Launcher 游戏启动器",
    "description": "Heroic Games Launcher 是 Epic Games Store 的开源替代游戏启动器。",
    "link": "https://heroicgameslauncher.com/",
    "winget": "HeroicGamesLauncher.HeroicGamesLauncher",
    "foss": true
  },
  "WPFInstallhwinfo": {
    "category": "专业工具",
    "choco": "hwinfo",
    "content": "HWiNFO 硬件检测",
    "description": "HWiNFO 提供全面的 Windows 硬件信息和诊断功能。",
    "link": "https://www.hwinfo.com/",
    "winget": "REALiX.HWiNFO",
    "foss": false
  },
  "WPFInstallhwmonitor": {
    "category": "专业工具",
    "choco": "hwmonitor",
    "content": "HWMonitor 硬件监控",
    "description": "HWMonitor 是一款硬件监控程序，读取 PC 系统的主要健康传感器。",
    "link": "https://www.cpuid.com/softwares/hwmonitor.html",
    "winget": "CPUID.HWMonitor",
    "foss": false
  },
  "WPFInstallimageglass": {
    "category": "多媒体工具",
    "choco": "imageglass",
    "content": "ImageGlass 图片查看器",
    "description": "ImageGlass 是一款多功能图片查看器，支持多种图片格式。",
    "link": "https://imageglass.org/",
    "winget": "DuongDieuPhap.ImageGlass",
    "foss": true
  },
  "WPFInstallinternetdownloadmanager": {
    "category": "工具类",
    "choco": "internet-download-manager",
    "content": "IDM 下载管理器",
    "description": "Internet Download Manager 是一款用于加速、续传和计划文件下载的下载管理器。",
    "link": "https://www.internetdownloadmanager.com/",
    "winget": "Tonec.InternetDownloadManager",
    "foss": false
  },
  "WPFInstallirfanview": {
    "category": "多媒体工具",
    "choco": "irfanview",
    "content": "IrfanView 图片查看",
    "description": "IrfanView 是一款轻量、快速、免费的图片查看器和编辑器。",
    "link": "https://irfanview.com/",
    "winget": "IrfanSkiljan.IrfanView",
    "foss": false
  },
  "WPFInstallitch": {
    "category": "游戏",
    "choco": "itch",
    "content": "Itch.io 游戏平台",
    "description": "Itch.io 是独立游戏和创意项目的数字分发平台。",
    "link": "https://itch.io/",
    "winget": "ItchIo.Itch",
    "foss": true
  },
  "WPFInstallitunes": {
    "category": "多媒体工具",
    "choco": "itunes",
    "content": "iTunes 媒体管理",
    "description": "iTunes 是 Apple 公司开发的媒体播放器、媒体库和在线广播应用。",
    "link": "https://www.apple.com/itunes/",
    "winget": "Apple.iTunes",
    "foss": false
  },
  "WPFInstalljava8": {
    "category": "开发工具",
    "choco": "corretto8jdk",
    "content": "Amazon Corretto 8 (LTS) JDK",
    "description": "Amazon Corretto 是一款免费、多平台、生产就绪的 OpenJDK 发行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.8.JDK",
    "foss": true
  },
  "WPFInstalljava21": {
    "category": "开发工具",
    "choco": "corretto21jdk",
    "content": "Amazon Corretto 21 (LTS) JDK",
    "description": "Amazon Corretto 是一款免费、多平台、生产就绪的 OpenJDK 发行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.21.JDK",
    "foss": true
  },
  "WPFInstalljava25": {
    "category": "开发工具",
    "choco": "corretto25jdk",
    "content": "Amazon Corretto 25 (LTS) JDK",
    "description": "Amazon Corretto 是一款免费、多平台、生产就绪的 OpenJDK 发行版。",
    "link": "https://aws.amazon.com/corretto",
    "winget": "Amazon.Corretto.25.JDK",
    "foss": true
  },
  "WPFInstalljellyfinmediaplayer": {
    "category": "自托管工具",
    "choco": "jellyfin-media-player",
    "content": "Jellyfin 媒体播放器",
    "description": "Jellyfin Media Player 是 Jellyfin 媒体服务器的客户端应用。",
    "link": "https://github.com/jellyfin/jellyfin-media-player",
    "winget": "Jellyfin.JellyfinMediaPlayer",
    "foss": true
  },
  "WPFInstalljellyfinserver": {
    "category": "自托管工具",
    "choco": "jellyfin",
    "content": "Jellyfin 服务器",
    "description": "Jellyfin Server 是一款开源媒体服务器软件，让您整理和流式传输您的媒体库。",
    "link": "https://jellyfin.org/",
    "winget": "Jellyfin.Server",
    "foss": true
  },
  "WPFInstalljetbrains": {
    "category": "开发工具",
    "choco": "jetbrainstoolbox",
    "content": "JetBrains Toolbox 工具集",
    "description": "JetBrains Toolbox 是用于轻松安装和管理 JetBrains 开发者工具的平台。",
    "link": "https://www.jetbrains.com/toolbox/",
    "winget": "JetBrains.Toolbox",
    "foss": false
  },
  "WPFInstalljpegview": {
    "category": "工具类",
    "choco": "jpegview",
    "content": "JPEGView 图片查看",
    "description": "JPEGView 是一款精简、快速且高度可配置的图片查看/编辑器，支持多种图片格式。",
    "link": "https://github.com/sylikc/jpegview",
    "winget": "sylikc.JPEGView",
    "foss": true
  },
  "WPFInstallkeepassxc": {
    "category": "工具类",
    "choco": "keepassxc",
    "content": "KeePassXC 密码管理",
    "description": "KeePassXC 是一款现代、安全、开源的密码管理器",
    "link": "https://keepassxc.org/",
    "winget": "KeePassXCTeam.KeePassXC",
    "foss": true
  },
  "WPFInstallklite": {
    "category": "多媒体工具",
    "choco": "k-litecodecpack-standard",
    "content": "K-Lite 解码包标准版",
    "description": "K-Lite Codec Pack 标准版是音频和视频编解码器及相关工具的集合。",
    "link": "https://www.codecguide.com/",
    "winget": "CodecGuide.K-LiteCodecPack.Standard",
    "foss": false
  },
  "WPFInstallkodi": {
    "category": "自托管工具",
    "choco": "kodi",
    "content": "Kodi 媒体中心",
    "description": "Kodi 是一款开源媒体中心应用，可播放和查看大多数视频、音乐、播客和其他数字媒体文件。",
    "link": "https://kodi.tv/",
    "winget": "XBMCFoundation.Kodi",
    "foss": true
  },
  "WPFInstalllazygit": {
    "category": "开发工具",
    "choco": "lazygit",
    "content": "Lazygit Git终端UI",
    "description": "适用于 Git 命令的简洁终端界面。",
    "link": "https://github.com/jesseduffield/lazygit/",
    "winget": "JesseDuffield.lazygit",
    "foss": true
  },
  "WPFInstalllibreoffice": {
    "category": "多媒体工具",
    "choco": "libreoffice-fresh",
    "content": "LibreOffice 办公套件",
    "description": "LibreOffice 是一款功能强大且免费的办公套件，与其他主要办公套件兼容。",
    "link": "https://www.libreoffice.org/",
    "winget": "TheDocumentFoundation.LibreOffice",
    "foss": true
  },
  "WPFInstalllibrewolf": {
    "category": "浏览器",
    "choco": "librewolf",
    "content": "LibreWolf 隐私浏览器",
    "description": "LibreWolf 是一款基于 Firefox 注重隐私的网页浏览器，具有额外的隐私和安全增强功能。",
    "link": "https://librewolf-community.gitlab.io/",
    "winget": "LibreWolf.LibreWolf",
    "foss": true
  },
  "WPFInstalllocalsend": {
    "category": "自托管工具",
    "choco": "localsend.install",
    "content": "LocalSend 文件传输",
    "description": "一款开源的跨平台 AirDrop 替代品。",
    "link": "https://localsend.org/",
    "winget": "LocalSend.LocalSend",
    "foss": true
  },
  "WPFInstallmpc-qt": {
    "category": "多媒体工具",
    "choco": "mediainfo",
    "content": "mpc-qt 媒体播放器",
    "description": "Media Player Classic Qute Theater 媒体播放器",
    "link": "https://github.com/mpc-qt/mpc-qt",
    "winget": "mpc-qt.mpc-qt",
    "foss": true
  },
  "WPFInstallmatrix": {
    "category": "通讯工具",
    "choco": "element-desktop",
    "content": "Element 即时通讯",
    "description": "Element 是 Matrix 的客户端，Matrix 是一个安全、去中心化通讯的开放网络。",
    "link": "https://element.io/",
    "winget": "Element.Element",
    "foss": true
  },
  "WPFInstallminitoolpartitionwizard": {
    "category": "工具类",
    "choco": "minitoolpartitionwizard",
    "content": "MiniTool 分区工具",
    "description": "全面的免费分区管理器，可执行 Windows 本身无法完成的高级操作。",
    "link": "https://www.partitionwizard.com/",
    "winget": "MiniTool.PartitionWizard.Free",
    "foss": false
  },
  "WPFInstallmodrinth": {
    "category": "游戏",
    "choco": "modrinth-app",
    "content": "Modrinth Minecraft 模组管理",
    "description": "Modrinth App 是用于管理 Minecraft 模组和整合包的桌面应用。",
    "link": "https://modrinth.com/app",
    "winget": "Modrinth.ModrinthApp",
    "foss": true
  },
  "WPFInstallmoonlight": {
    "category": "自托管工具",
    "choco": "moonlight-qt",
    "content": "Moonlight 游戏串流",
    "description": "Moonlight/GameStream 客户端允许您通过本地网络将 PC 游戏串流到其他设备。",
    "link": "https://moonlight-stream.org/",
    "winget": "MoonlightGameStreamingProject.Moonlight",
    "foss": true
  },
  "WPFInstallmpchc": {
    "category": "多媒体工具",
    "choco": "mpc-hc-clsid2",
    "content": "MPC-HC 媒体播放器",
    "description": "Media Player Classic - Home Cinema (MPC-HC) 是一款免费开源的视频播放器",
    "link": "https://github.com/clsid2/mpc-hc/",
    "winget": "clsid2.mpc-hc",
    "foss": true
  },
  "WPFInstallmsedgeredirect": {
    "category": "工具类",
    "choco": "msedgeredirect",
    "content": "MSEdgeRedirect 重定向工具",
    "description": "将新闻、搜索、小工具、天气等重定向到默认浏览器的工具。",
    "link": "https://github.com/rcmaehl/MSEdgeRedirect",
    "winget": "rcmaehl.MSEdgeRedirect",
    "foss": true
  },
  "WPFInstallmsiafterburner": {
    "category": "工具类",
    "choco": "msiafterburner",
    "content": "MSI Afterburner 超频工具",
    "description": "MSI Afterburner 是一款显卡超频工具，具有高级功能。",
    "link": "https://www.msi.com/Landing/afterburner",
    "winget": "Guru3D.Afterburner",
    "foss": false
  },
  "WPFInstallmullvadvpn": {
    "category": "专业工具",
    "choco": "mullvad-app",
    "content": "Mullvad VPN",
    "description": "这是 Mullvad VPN 服务的 VPN 客户端软件。",
    "link": "https://github.com/mullvad/mullvadvpn-app",
    "winget": "MullvadVPN.MullvadVPN",
    "foss": true
  },
  "WPFInstallmullvadbrowser": {
    "category": "浏览器",
    "choco": "na",
    "content": "Mullvad 隐私浏览器",
    "description": "Mullvad Browser 是一款注重隐私的网页浏览器，与 Tor 项目合作开发。",
    "link": "https://mullvad.net/browser",
    "winget": "MullvadVPN.MullvadBrowser",
    "foss": true
  },
  "WPFInstallnomacs": {
    "category": "多媒体工具",
    "choco": "nomacs",
    "content": "nomacs 图片查看器",
    "description": "nomacs 是一款免费开源多平台图片查看器，支持所有常见图片格式。",
    "link": "https://nomacs.org/",
    "winget": "nomacs.nomacs",
    "foss": true
  },
  "WPFInstallnanazip": {
    "category": "工具类",
    "choco": "nanazip",
    "content": "NanaZip 压缩工具",
    "description": "NanaZip 是一款快速高效的文件压缩和解压缩工具。",
    "link": "https://github.com/M2Team/NanaZip",
    "winget": "M2Team.NanaZip",
    "foss": true
  },
  "WPFInstallnetbird": {
    "category": "自托管工具",
    "choco": "netbird",
    "content": "NetBird 网络工具",
    "description": "NetBird 是与 TailScale 相当的开源替代品，可连接到自托管服务器。",
    "link": "https://netbird.io/",
    "winget": "Netbird.Netbird",
    "foss": true
  },
  "WPFInstallnaps2": {
    "category": "多媒体工具",
    "choco": "naps2",
    "content": "NAPS2 文档扫描",
    "description": "NAPS2 是一款简化创建电子文档流程的文档扫描应用。",
    "link": "https://www.naps2.com/",
    "winget": "Cyanfish.NAPS2",
    "foss": true
  },
  "WPFInstallneovim": {
    "category": "开发工具",
    "choco": "neovim",
    "content": "Neovim 文本编辑器",
    "description": "Neovim 是一款高度可扩展的文本编辑器，是对原始 Vim 编辑器的改进。",
    "link": "https://neovim.io/",
    "winget": "Neovim.Neovim",
    "foss": true
  },
  "WPFInstallnextclouddesktop": {
    "category": "自托管工具",
    "choco": "nextcloud-client",
    "content": "Nextcloud 桌面客户端",
    "description": "Nextcloud Desktop 是 Nextcloud 文件同步和共享平台的官方桌面客户端。",
    "link": "https://nextcloud.com/install/#install-clients",
    "winget": "Nextcloud.NextcloudDesktop",
    "foss": true
  },
  "WPFInstallnmap": {
    "category": "专业工具",
    "choco": "nmap",
    "content": "Nmap 网络扫描",
    "description": "Nmap (Network Mapper) is an open-source tool for network exploration and security auditing. It discovers devices on a network and provides information about their ports and services.",
    "link": "https://nmap.org/",
    "winget": "Insecure.Nmap",
    "foss": true
  },
  "WPFInstallnodejs": {
    "category": "开发工具",
    "choco": "nodejs",
    "content": "Node.js",
    "description": "Node.js 是基于 Chrome V8 引擎的 JavaScript 运行时。",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS",
    "foss": true
  },
  "WPFInstallnodejslts": {
    "category": "开发工具",
    "choco": "nodejs-lts",
    "content": "Node.js LTS 长期支持版",
    "description": "Node.js LTS 提供长期支持版本，用于稳定可靠的服务器端 JavaScript 开发。",
    "link": "https://nodejs.org/",
    "winget": "OpenJS.NodeJS.LTS",
    "foss": true
  },
  "WPFInstallpnpm": {
    "category": "开发工具",
    "content": "pnpm 包管理器",
    "description": "pnpm 是一款快速且节省磁盘空间的 JavaScript 和 Node.js 包管理器。",
    "link": "https://pnpm.io/",
    "winget": "pnpm.pnpm",
    "foss": true
  },
  "WPFInstallnotepadplus": {
    "category": "多媒体工具",
    "choco": "notepadplusplus",
    "content": "Notepad++ 文本编辑器",
    "description": "Notepad++ 是一款免费开源代码编辑器，是记事本的替代品，支持多种语言。",
    "link": "https://notepad-plus-plus.org/",
    "winget": "Notepad++.Notepad++",
    "foss": true
  },
  "WPFInstallnuget": {
    "category": "微软工具",
    "choco": "nuget.commandline",
    "content": "NuGet 包管理器",
    "description": "NuGet 是 .NET 框架的包管理器，使开发人员能够管理和共享 .NET 应用中的库。",
    "link": "https://www.nuget.org/",
    "winget": "Microsoft.NuGet",
    "foss": true
  },
  "WPFInstallnvclean": {
    "category": "工具类",
    "choco": "na",
    "content": "NVCleanstall 显卡驱动定制",
    "description": "NVCleanstall 是一款定制 NVIDIA 驱动安装的工具。",
    "link": "https://www.techpowerup.com/nvcleanstall/",
    "winget": "TechPowerUp.NVCleanstall",
    "foss": false
  },
  "WPFInstallobs": {
    "category": "多媒体工具",
    "choco": "obs-studio",
    "content": "OBS Studio 直播录屏",
    "description": "OBS Studio 是一款免费开源的视频录制和直播推流软件",
    "link": "https://obsproject.com/",
    "winget": "OBSProject.OBSStudio",
    "foss": true
  },
  "WPFInstallobsidian": {
    "category": "多媒体工具",
    "choco": "obsidian",
    "content": "Obsidian 知识管理",
    "description": "Obsidian 是一款功能强大的笔记和知识管理应用。",
    "link": "https://obsidian.md/",
    "winget": "Obsidian.Obsidian",
    "foss": false
  },
  "WPFInstallonedrive": {
    "category": "微软工具",
    "choco": "onedrive",
    "content": "OneDrive 云存储",
    "description": "OneDrive 是 Microsoft 提供的云存储服务，允许用户安全地跨设备存储和共享文件。",
    "link": "https://onedrive.live.com/",
    "winget": "Microsoft.OneDrive",
    "foss": false
  },
  "WPFInstallonlyoffice": {
    "category": "多媒体工具",
    "choco": "onlyoffice",
    "content": "ONLYOFFICE 桌面办公",
    "description": "ONLYOFFICE Desktop 是一款全面的办公套件，用于文档编辑和协作。",
    "link": "https://www.onlyoffice.com/desktop.aspx",
    "winget": "ONLYOFFICE.DesktopEditors",
    "foss": true
  },
  "WPFInstallOPAutoClicker": {
    "category": "工具类",
    "choco": "autoclicker",
    "content": "OPAutoClicker 自动点击",
    "description": "功能齐全的自动点击器，支持动态光标位置或预设位置两种自动点击模式。",
    "link": "https://www.opautoclicker.com",
    "winget": "OPAutoClicker.OPAutoClicker",
    "foss": false
  },
  "WPFInstallopenrgb": {
    "category": "工具类",
    "choco": "openrgb",
    "content": "OpenRGB RGB灯光控制",
    "description": "OpenRGB 是一款开源 RGB 灯光控制软件。",
    "link": "https://openrgb.org/",
    "winget": "OpenRGB.OpenRGB",
    "foss": true
  },
  "WPFInstallOpenVPN": {
    "category": "专业工具",
    "choco": "openvpn-connect",
    "content": "OpenVPN Connect 客户端",
    "description": "OpenVPN Connect 是一款 VPN 客户端，可让你安全连接到 VPN 服务器",
    "link": "https://openvpn.net/",
    "winget": "OpenVPNTechnologies.OpenVPNConnect",
    "foss": false
  },
  "WPFInstallOVirtualBox": {
    "category": "工具类",
    "choco": "virtualbox",
    "content": "Oracle VirtualBox 虚拟机",
    "description": "Oracle VirtualBox 是一款功能强大且免费开源的虚拟化工具。",
    "link": "https://www.virtualbox.org/",
    "winget": "Oracle.VirtualBox",
    "foss": true
  },
  "WPFInstallpolicyplus": {
    "category": "工具类",
    "choco": "na",
    "content": "Policy Plus 组策略编辑",
    "description": "本地组策略编辑器增强版，适用于所有 Windows 版本。",
    "link": "https://github.com/Fleex255/PolicyPlus",
    "winget": "Fleex255.PolicyPlus",
    "foss": true
  },
  "WPFInstallprocessexplorer": {
    "category": "微软工具",
    "choco": "procexp",
    "content": "Process Explorer 进程管理",
    "description": "Process Explorer 是任务管理器和系统监视器。",
    "link": "https://learn.microsoft.com/sysinternals/downloads/process-explorer",
    "winget": "Microsoft.Sysinternals.ProcessExplorer",
    "foss": false
  },
  "WPFInstallPaintdotnet": {
    "category": "多媒体工具",
    "choco": "paint.net",
    "content": "Paint.NET 图像编辑",
    "description": "Paint.NET 是一款免费的 Windows 图像照片编辑软件",
    "link": "https://www.getpaint.net/",
    "winget": "dotPDN.PaintDotNet",
    "foss": false
  },
  "WPFInstallparsec": {
    "category": "工具类",
    "choco": "parsec",
    "content": "Parsec 远程桌面",
    "description": "Parsec 是一款低延迟、高质量的远程桌面共享应用。",
    "link": "https://parsec.app/",
    "winget": "Parsec.Parsec",
    "foss": false
  },
  "WPFInstallpeazip": {
    "category": "工具类",
    "choco": "peazip",
    "content": "PeaZip 压缩工具",
    "description": "PeaZip 是一款免费开源文件压缩工具，支持多种压缩格式并提供加密功能。",
    "link": "https://peazip.github.io/",
    "winget": "Giorgiotani.Peazip",
    "foss": true
  },
  "WPFInstallplaynite": {
    "category": "游戏",
    "choco": "playnite",
    "content": "Playnite 游戏库管理",
    "description": "Playnite 是一款开源游戏库管理器，目标是为您的所有游戏提供统一界面。",
    "link": "https://playnite.link/",
    "winget": "Playnite.Playnite",
    "foss": true
  },
  "WPFInstallplex": {
    "category": "自托管工具",
    "choco": "plexmediaserver",
    "content": "Plex 媒体服务器",
    "description": "Plex Media Server 是一款媒体服务器软件，可让你管理和流式传输媒体文件",
    "link": "https://www.plex.tv/your-media/",
    "winget": "Plex.PlexMediaServer",
    "foss": false
  },
  "WPFInstallplexdesktop": {
    "category": "自托管工具",
    "choco": "plex",
    "content": "Plex 桌面客户端",
    "description": "Plex Media Server 是一款媒体服务器软件，可让你管理和流式传输媒体文件",
    "link": "https://www.plex.tv",
    "winget": "Plex.Plex",
    "foss": false
  },
  "WPFInstallposh": {
    "category": "开发工具",
    "choco": "oh-my-posh",
    "content": "Oh My Posh 终端美化",
    "description": "Oh My Posh 是一款跨平台的 Shell 提示符主题引擎。",
    "link": "https://ohmyposh.dev/",
    "winget": "JanDeDobbeleer.OhMyPosh",
    "foss": true
  },
  "WPFInstallpowershell": {
    "category": "微软工具",
    "choco": "powershell-core",
    "content": "PowerShell",
    "description": "PowerShell 是微软的自动化任务框架和脚本语言",
    "link": "https://github.com/PowerShell/PowerShell",
    "winget": "Microsoft.PowerShell",
    "foss": true
  },
  "WPFInstallpowertoys": {
    "category": "微软工具",
    "choco": "powertoys",
    "content": "PowerToys 效率工具",
    "description": "PowerToys 是一套面向高级用户的效率工具，包括 FancyZones、PowerRename 等功能。",
    "link": "https://github.com/microsoft/PowerToys",
    "winget": "Microsoft.PowerToys",
    "foss": true
  },
  "WPFInstallprismlauncher": {
    "category": "游戏",
    "choco": "prismlauncher",
    "content": "Prism Launcher Minecraft启动器",
    "description": "Prism Launcher 是一款开源 Minecraft 启动器，支持管理多个实例、帐户和模组。",
    "link": "https://prismlauncher.org/",
    "winget": "PrismLauncher.PrismLauncher",
    "foss": true
  },
  "WPFInstallprocesslasso": {
    "category": "工具类",
    "choco": "plasso",
    "content": "Process Lasso 进程优化",
    "description": "Process Lasso 是一款系统优化和自动化工具，可优化 CPU 使用率",
    "link": "https://bitsum.com/",
    "winget": "BitSum.ProcessLasso",
    "foss": false
  },
  "WPFInstallprotonauth": {
    "category": "工具类",
    "choco": "protonauth",
    "content": "Proton 验证器",
    "description": "Proton 的双因素认证应用，用于安全同步和备份 2FA 验证码。",
    "link": "https://proton.me/authenticator",
    "winget": "Proton.ProtonAuthenticator",
    "foss": true
  },
  "WPFInstallprotonmail": {
    "category": "通讯工具",
    "choco": "protonmail",
    "content": "Proton Mail 加密邮箱",
    "description": "Proton Mail 是 Proton 的端到端加密电子邮件服务。",
    "link": "https://proton.me/mail",
    "winget": "Proton.ProtonMail",
    "foss": true
  },
  "WPFInstallprotondrive": {
    "category": "工具类",
    "choco": "protondrive",
    "content": "Proton Drive 加密云盘",
    "description": "Proton Drive 是端到端加密的瑞士文件保险库。",
    "link": "https://proton.me/drive",
    "winget": "Proton.ProtonDrive",
    "foss": true
  },
  "WPFInstallprotonpass": {
    "category": "工具类",
    "choco": "protonpass",
    "content": "Proton Pass 密码管理",
    "description": "Proton Pass 是一款基于云的密码管理器，具有端到端加密功能。",
    "link": "https://proton.me/pass",
    "winget": "Proton.ProtonPass",
    "foss": true
  },
  "WPFInstallprotonvpn": {
    "category": "专业工具",
    "choco": "protonvpn",
    "content": "Proton VPN",
    "description": "Proton VPN 是无日志 VPN 服务，保护您的在线隐私。",
    "link": "https://protonvpn.com/",
    "winget": "Proton.ProtonVPN",
    "foss": true
  },
  "WPFInstallprocessmonitor": {
    "category": "微软工具",
    "choco": "procexp",
    "content": "Process Monitor 进程监控",
    "description": "SysInternals Process Monitor 是一款高级监控工具，实时显示系统和进程活动。",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/procmon",
    "winget": "Microsoft.Sysinternals.ProcessMonitor",
    "foss": false
  },
  "WPFInstallputty": {
    "category": "专业工具",
    "choco": "putty",
    "content": "PuTTY 远程连接",
    "description": "PuTTY 是一款免费开源的终端仿真器、串行控制台和网络文件传输工具",
    "link": "https://www.chiark.greenend.org.uk/~sgtatham/putty/",
    "winget": "PuTTY.PuTTY",
    "foss": true
  },
  "WPFInstallpython3": {
    "category": "开发工具",
    "choco": "python",
    "content": "Python 3",
    "description": "Python 是一种通用编程语言，用于 Web 开发、数据分析、人工智能等领域。",
    "link": "https://www.python.org/",
    "winget": "Python.Python.3.14",
    "foss": true
  },
  "WPFInstallqbittorrent": {
    "category": "工具类",
    "choco": "qbittorrent",
    "content": "qBittorrent 下载工具",
    "description": "qBittorrent 是一款免费开源的 BitTorrent 客户端",
    "link": "https://www.qbittorrent.org/",
    "winget": "qBittorrent.qBittorrent",
    "foss": true
  },
  "WPFInstallqtox": {
    "category": "通讯工具",
    "choco": "qtox",
    "content": "QTox 安全通讯",
    "description": "QTox 是一款免费开源通讯应用，设计上优先考虑用户隐私和安全。",
    "link": "https://qtox.github.io/",
    "winget": "Tox.qTox",
    "foss": true
  },
  "WPFInstallrevo": {
    "category": "工具类",
    "choco": "revo-uninstaller",
    "content": "Revo Uninstaller 卸载工具",
    "description": "Revo Uninstaller 是一款高级卸载工具，帮助您删除不需要的软件并清理系统。",
    "link": "https://www.revouninstaller.com/",
    "winget": "RevoUninstaller.RevoUninstaller",
    "foss": false
  },
  "WPFInstallWiseProgramUninstaller": {
    "category": "工具类",
    "choco": "na",
    "content": "Wise Program Uninstaller 卸载工具",
    "description": "Wise Program Uninstaller 是卸载 Windows 程序的完美解决方案。",
    "link": "https://www.wisecleaner.com/wise-program-uninstaller.html",
    "winget": "WiseCleaner.WiseProgramUninstaller",
    "foss": false
  },
  "WPFInstallrufus": {
    "category": "工具类",
    "choco": "rufus",
    "content": "Rufus 启动盘制作",
    "description": "Rufus 是一款帮助格式化和创建可启动 USB 驱动器的工具。",
    "link": "https://rufus.ie/",
    "winget": "Rufus.Rufus",
    "foss": true
  },
  "WPFInstallrustlang": {
    "category": "开发工具",
    "choco": "rust",
    "content": "Rust 编程语言",
    "description": "Rust 是一种专为安全和性能设计的编程语言，尤其注重系统编程。",
    "link": "https://www.rust-lang.org/",
    "winget": "Rustlang.Rust.MSVC",
    "foss": true
  },
  "WPFInstallsdio": {
    "category": "工具类",
    "choco": "sdio",
    "content": "Snappy Driver Installer 驱动更新",
    "description": "Snappy Driver Installer Origin 是一款免费开源驱动更新工具。",
    "link": "https://www.glenn.delahoy.com/snappy-driver-installer-origin/",
    "winget": "GlennDelahoy.SnappyDriverInstallerOrigin",
    "foss": true
  },
  "WPFInstallsharex": {
    "category": "多媒体工具",
    "choco": "sharex",
    "content": "ShareX 截图工具",
    "description": "ShareX 是一款免费开源的屏幕截图和文件共享工具",
    "link": "https://getsharex.com/",
    "winget": "ShareX.ShareX",
    "foss": true
  },
  "WPFInstallnilesoftShell": {
    "category": "工具类",
    "choco": "nilesoft-shell",
    "content": "Nilesoft Shell 右键菜单",
    "description": "Shell 是一款 Windows 右键菜单扩展工具，添加额外功能和自定义选项。",
    "link": "https://nilesoft.org/",
    "winget": "Nilesoft.Shell",
    "foss": false
  },
  "WPFInstallsysteminformer": {
    "category": "开发工具",
    "choco": "systeminformer",
    "content": "System Informer 系统监控",
    "description": "一款免费、强大、多用途的工具，帮助您监控系统资源、调试软件和检测恶意软件。",
    "link": "https://systeminformer.com/",
    "winget": "WinsiderSS.SystemInformer",
    "foss": true
  },
  "WPFInstallsignal": {
    "category": "通讯工具",
    "choco": "signal",
    "content": "Signal 加密通讯",
    "description": "Signal 是一款注重隐私的通讯应用，提供端到端加密以确保安全和私密的通信。",
    "link": "https://signal.org/",
    "winget": "OpenWhisperSystems.Signal",
    "foss": true
  },
  "WPFInstallsignalrgb": {
    "category": "工具类",
    "choco": "na",
    "content": "SignalRGB RGB控制",
    "description": "SignalRGB 让您通过一个免费应用程序控制和同步您喜爱的 RGB 设备。",
    "link": "https://www.signalrgb.com/",
    "winget": "WhirlwindFX.SignalRgb",
    "foss": false
  },
  "WPFInstallsimplewall": {
    "category": "专业工具",
    "choco": "simplewall",
    "content": "Simplewall 防火墙",
    "description": "Simplewall 是一款免费开源 Windows 防火墙应用。",
    "link": "https://github.com/henrypp/simplewall",
    "winget": "Henry++.simplewall",
    "foss": true
  },
  "WPFInstallslack": {
    "category": "通讯工具",
    "choco": "slack",
    "content": "Slack 团队协作",
    "description": "Slack 是连接团队并通过频道、消息和文件共享促进沟通的协作中心。",
    "link": "https://slack.com/",
    "winget": "SlackTechnologies.Slack",
    "foss": false
  },
  "WPFInstallstartallback": {
    "category": "工具类",
    "choco": "StartAllBack",
    "content": "StartAllBack 开始菜单恢复",
    "description": "StartAllBack 恢复并改进 Windows 任务栏、开始菜单、文件资源管理器和 Shell UI 行为。",
    "link": "https://www.startallback.com/",
    "winget": "StartIsBack.StartAllBack",
    "foss": false
  },
  "WPFInstallsteam": {
    "category": "游戏",
    "choco": "steam-client",
    "content": "Steam 游戏平台",
    "description": "Steam 是购买和游玩视频游戏的数字分发平台。",
    "link": "https://store.steampowered.com/about/",
    "winget": "Valve.Steam",
    "foss": false
  },
  "WPFInstallsublimetext": {
    "category": "开发工具",
    "choco": "sublimetext4",
    "content": "Sublime Text 文本编辑器",
    "description": "Sublime Text 是一款用于代码、标记和散文的精良文本编辑器。",
    "link": "https://www.sublimetext.com/",
    "winget": "SublimeHQ.SublimeText.4",
    "foss": false
  },
  "WPFInstallsunshine": {
    "category": "自托管工具",
    "choco": "sunshine",
    "content": "Sunshine 游戏串流服务器",
    "description": "Sunshine 是一款游戏串流服务器，允许在 Android 设备上远程玩 PC 游戏。",
    "link": "https://github.com/LizardByte/Sunshine",
    "winget": "LizardByte.Sunshine",
    "foss": true
  },
  "WPFInstalltcpview": {
    "category": "微软工具",
    "choco": "tcpview",
    "content": "TCPView 网络监控",
    "description": "SysInternals TCPView 是一款网络监控工具，显示所有 TCP 和 UDP 端点的详细列表。",
    "link": "https://docs.microsoft.com/en-us/sysinternals/downloads/tcpview",
    "winget": "Microsoft.Sysinternals.TCPView",
    "foss": false
  },
  "WPFInstallteams": {
    "category": "通讯工具",
    "choco": "microsoft-teams",
    "content": "Teams 团队协作",
    "description": "Microsoft Teams 是与 Office 365 集成的协作平台。",
    "link": "https://www.microsoft.com/en-us/microsoft-teams/group-chat-software",
    "winget": "Microsoft.Teams",
    "foss": false
  },
  "WPFInstallteamviewer": {
    "category": "工具类",
    "choco": "teamviewer9",
    "content": "TeamViewer 远程协助",
    "description": "TeamViewer 是一款流行的远程访问和支持软件。",
    "link": "https://www.teamviewer.com/",
    "winget": "TeamViewer.TeamViewer",
    "foss": false
  },
  "WPFInstallteamspeak3": {
    "category": "通讯工具",
    "choco": "teamspeak",
    "content": "TeamSpeak 3 语音通讯",
    "description": "TEAMSPEAK. YOUR TEAM. YOUR RULES. Use crystal clear sound to communicate with your teammates cross-platform with military-grade security, lag-free performance & unparalleled reliability and uptime.",
    "link": "https://www.teamspeak.com/",
    "winget": "TeamSpeakSystems.TeamSpeakClient",
    "foss": false
  },
  "WPFInstalltelegram": {
    "category": "通讯工具",
    "choco": "telegram",
    "content": "Telegram 即时通讯",
    "description": "Telegram 是一款基于云的即时通讯应用，以其安全性、速度和简洁性而闻名。",
    "link": "https://telegram.org/",
    "winget": "Telegram.TelegramDesktop",
    "foss": true
  },
  "WPFInstallterminal": {
    "category": "微软工具",
    "choco": "microsoft-windows-terminal",
    "content": "Windows Terminal 终端",
    "description": "Windows Terminal 是一款现代、快速、高效的终端应用程序",
    "link": "https://aka.ms/terminal",
    "winget": "Microsoft.WindowsTerminal",
    "foss": true
  },
  "WPFInstallthunderbird": {
    "category": "通讯工具",
    "choco": "thunderbird",
    "content": "Thunderbird 邮件客户端",
    "description": "Mozilla Thunderbird 是一款免费开源的电子邮件、新闻和聊天客户端。",
    "link": "https://www.thunderbird.net/",
    "winget": "Mozilla.Thunderbird",
    "foss": true
  },
  "WPFInstallbetterbird": {
    "category": "通讯工具",
    "choco": "betterbird",
    "content": "Betterbird 邮件客户端(优化版)",
    "description": "Betterbird 是 Mozilla Thunderbird 的分支，具有额外功能和错误修复。",
    "link": "https://www.betterbird.eu/",
    "winget": "Betterbird.Betterbird",
    "foss": true
  },
  "WPFInstalltor": {
    "category": "浏览器",
    "choco": "tor-browser",
    "content": "Tor 匿名浏览器",
    "description": "Tor 浏览器专为匿名网页浏览而设计，利用 Tor 网络保护用户隐私和安全。",
    "link": "https://www.torproject.org/",
    "winget": "TorProject.TorBrowser",
    "foss": true
  },
  "WPFInstalltotalcommander": {
    "category": "工具类",
    "choco": "TotalCommander",
    "content": "Total Commander 文件管理",
    "description": "Total Commander 是一款 Windows 文件管理器，提供强大直观的文件管理界面。",
    "link": "https://www.ghisler.com/",
    "winget": "Ghisler.TotalCommander",
    "foss": false
  },
  "WPFInstalltreesize": {
    "category": "工具类",
    "choco": "treesizefree",
    "content": "TreeSize Free 磁盘分析",
    "description": "TreeSize Free 是一款磁盘空间管理器，帮助您分析和可视化驱动器上的空间使用情况。",
    "link": "https://www.jam-software.com/treesize_free/",
    "winget": "JAMSoftware.TreeSize.Free",
    "foss": false
  },
  "WPFInstallttaskbar": {
    "category": "工具类",
    "choco": "translucenttb",
    "content": "TranslucentTB 任务栏透明",
    "description": "TranslucentTB 是一款允许您自定义 Windows 任务栏透明度的工具。",
    "link": "https://github.com/TranslucentTB/TranslucentTB",
    "winget": "CharlesMilette.TranslucentTB",
    "foss": true
  },
  "WPFInstallubisoft": {
    "category": "游戏",
    "choco": "ubisoft-connect",
    "content": "Ubisoft Connect 游戏平台",
    "description": "Ubisoft Connect 是育碧的数字发行和在线多人游戏平台",
    "link": "https://ubisoftconnect.com/",
    "winget": "Ubisoft.Connect",
    "foss": false
  },
  "WPFInstallungoogled": {
    "category": "浏览器",
    "choco": "ungoogled-chromium",
    "content": "Ungoogled Chromium 无谷歌版",
    "description": "Ungoogled Chromium 是不含 Google 集成的 Chromium 版本。",
    "link": "https://github.com/Eloston/ungoogled-chromium",
    "winget": "eloston.ungoogled-chromium",
    "foss": true
  },
  "WPFInstallunity": {
    "category": "开发工具",
    "choco": "unityhub",
    "content": "Unity 游戏引擎",
    "description": "Unity 是一款强大的游戏开发平台，用于创建 2D、3D、增强现实和虚拟现实游戏。",
    "link": "https://unity.com/",
    "winget": "Unity.UnityHub",
    "foss": false
  },
  "WPFInstalleverything": {
    "category": "工具类",
    "choco": "everything",
    "content": "Everything 文件搜索",
    "description": "Everything 是一款极速文件搜索工具，可瞬间定位文件和文件夹",
    "link": "https://www.voidtools.com/",
    "winget": "voidtools.Everything",
    "foss": false
  },
  "WPFInstallvc2015_32": {
    "category": "微软工具",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 32位运行库",
    "description": "Visual C++ 2015-2022 32位可再发行包，安装运行 32 位应用所需的运行时组件。",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x86",
    "foss": false
  },
  "WPFInstallvc2015_64": {
    "category": "微软工具",
    "choco": "vcredist2015",
    "content": "Visual C++ 2015-2022 64位运行库",
    "description": "Visual C++ 2015-2022 64位可再发行包，安装运行 64 位应用所需的运行时组件。",
    "link": "https://support.microsoft.com/en-us/help/2977003/the-latest-supported-visual-c-downloads",
    "winget": "Microsoft.VCRedist.2015+.x64",
    "foss": false
  },
  "WPFInstallventoy": {
    "category": "专业工具",
    "choco": "ventoy",
    "content": "Ventoy 启动盘制作",
    "description": "Ventoy 是一款开源的启动 U 盘制作工具",
    "link": "https://www.ventoy.net/",
    "winget": "Ventoy.Ventoy",
    "foss": true
  },
  "WPFInstallvesktop": {
    "category": "通讯工具",
    "choco": "na",
    "content": "Vesktop Discord客户端",
    "description": "基于 Electron 的跨平台桌面应用，预装 Vencord，提供更流畅的 Discord 体验。",
    "link": "https://github.com/Vencord/Vesktop",
    "winget": "Vencord.Vesktop",
    "foss": true
  },
  "WPFInstallviber": {
    "category": "通讯工具",
    "choco": "viber",
    "content": "Viber 即时通讯",
    "description": "Viber 是一款免费消息和通话应用，具有群聊、视频通话等功能。",
    "link": "https://www.viber.com/",
    "winget": "Rakuten.Viber",
    "foss": false
  },
  "WPFInstallvisualstudio2022": {
    "category": "开发工具",
    "choco": "visualstudio2022community",
    "content": "Visual Studio 2022",
    "description": "Visual Studio 2022 是用于构建、调试和部署应用程序的集成开发环境 (IDE)。",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.2022.Community",
    "foss": false
  },
  "WPFInstallvisualstudio2026": {
    "category": "开发工具",
    "choco": "visualstudio2026community",
    "content": "Visual Studio 2026",
    "description": "Visual Studio 2026 是用于构建、调试和部署应用程序的集成开发环境 (IDE)。",
    "link": "https://visualstudio.microsoft.com/",
    "winget": "Microsoft.VisualStudio.Community",
    "foss": false
  },
  "WPFInstallvivaldi": {
    "category": "浏览器",
    "choco": "vivaldi",
    "content": "Vivaldi 浏览器",
    "description": "Vivaldi 是一款高度可定制的网页浏览器。",
    "link": "https://vivaldi.com/",
    "winget": "Vivaldi.Vivaldi",
    "foss": false
  },
  "WPFInstallvlc": {
    "category": "多媒体工具",
    "choco": "vlc",
    "content": "VLC 视频播放器",
    "description": "VLC 媒体播放器是一款免费开源的多媒体播放器",
    "link": "https://www.videolan.org/vlc/",
    "winget": "VideoLAN.VLC",
    "foss": true
  },
  "WPFInstallvrdesktopstreamer": {
    "category": "游戏",
    "choco": "na",
    "content": "Virtual Desktop Streamer VR串流",
    "description": "Virtual Desktop Streamer 是一款将桌面屏幕串流到 VR 设备的工具。",
    "link": "https://www.vrdesktop.net/",
    "winget": "VirtualDesktop.Streamer",
    "foss": false
  },
  "WPFInstallvscode": {
    "category": "开发工具",
    "choco": "vscode",
    "content": "VS Code 代码编辑器",
    "description": "Visual Studio Code 是一款免费开源的代码编辑器，支持多种编程语言。",
    "link": "https://code.visualstudio.com/",
    "winget": "Microsoft.VisualStudioCode",
    "foss": true
  },
  "WPFInstallvscodium": {
    "category": "开发工具",
    "choco": "vscodium",
    "content": "VS Codium 开源版",
    "description": "VSCodium 是社区驱动的、自由许可的 Microsoft VS Code 二进制发行版。",
    "link": "https://vscodium.com/",
    "winget": "VSCodium.VSCodium",
    "foss": true
  },
  "WPFInstallwaterfox": {
    "category": "浏览器",
    "choco": "waterfox",
    "content": "Waterfox 隐私浏览器",
    "description": "Waterfox 是一款基于 Firefox 的快速隐私浏览器。",
    "link": "https://www.waterfox.net/",
    "winget": "Waterfox.Waterfox",
    "foss": true
  },
  "WPFInstallwhatsapp": {
    "category": "通讯工具",
    "choco": "na",
    "content": "WhatsApp 桌面版",
    "description": "WhatsApp Desktop 是 Meta 的官方 Windows 桌面消息应用。",
    "link": "https://apps.microsoft.com/detail/9nksqgp7f2nh",
    "winget": "msstore:9NKSQGP7F2NH",
    "foss": false
  },
  "WPFInstallwingetui": {
    "category": "工具类",
    "choco": "wingetui",
    "content": "UniGetUI 包管理GUI",
    "description": "UniGetUI 是 WinGet、Chocolatey 和其他 Windows CLI 包管理器的图形界面。",
    "link": "https://devolutions.net/unigetui/",
    "winget": "Devolutions.UniGetUI",
    "foss": true
  },
  "WPFInstallwinrar": {
    "category": "工具类",
    "choco": "winrar",
    "content": "WinRAR 压缩工具",
    "description": "WinRAR 是一款功能强大的压缩文件管理器。",
    "link": "https://www.win-rar.com/",
    "winget": "RARLab.WinRAR",
    "foss": false
  },
  "WPFInstallwinscp": {
    "category": "专业工具",
    "choco": "winscp",
    "content": "WinSCP 文件传输",
    "description": "WinSCP 是一款流行的开源 SFTP/FTP/SCP 客户端",
    "link": "https://winscp.net/",
    "winget": "WinSCP.WinSCP",
    "foss": true
  },
  "WPFInstallwireguard": {
    "category": "专业工具",
    "choco": "wireguard",
    "content": "WireGuard VPN",
    "description": "WireGuard 是一款快速、现代的 VPN（虚拟专用网络）",
    "link": "https://www.wireguard.com/",
    "winget": "WireGuard.WireGuard",
    "foss": true
  },
  "WPFInstallwireshark": {
    "category": "专业工具",
    "choco": "wireshark",
    "content": "Wireshark 网络分析",
    "description": "Wireshark 是一款广泛使用的开源网络协议分析工具",
    "link": "https://www.wireshark.org/",
    "winget": "WiresharkFoundation.Wireshark",
    "foss": true
  },
  "WPFInstallwiztree": {
    "category": "工具类",
    "choco": "wiztree",
    "content": "WizTree 磁盘分析",
    "description": "WizTree 是一款快速的磁盘空间分析工具",
    "link": "https://wiztreefree.com/",
    "winget": "AntibodySoftware.WizTree",
    "foss": false
  },
  "WPFInstallxeheditor": {
    "category": "工具类",
    "choco": "HxD",
    "content": "HxD 十六进制编辑器",
    "description": "HxD 是一款免费的十六进制编辑器。",
    "link": "https://mh-nexus.de/en/hxd/",
    "winget": "MHNexus.HxD",
    "foss": false
  },
  "WPFInstallyarn": {
    "category": "开发工具",
    "choco": "yarn",
    "content": "Yarn 包管理器",
    "description": "Yarn 是一款快速、可靠、安全的 JavaScript 项目依赖管理工具。",
    "link": "https://yarnpkg.com/",
    "winget": "Yarn.Yarn",
    "foss": true
  },
  "WPFInstallzoom": {
    "category": "通讯工具",
    "choco": "zoom",
    "content": "Zoom 视频会议",
    "description": "Zoom 是一款流行的视频会议和网络会议服务。",
    "link": "https://zoom.us/",
    "winget": "Zoom.Zoom",
    "foss": false
  },
  "WPFInstalluv": {
    "category": "开发工具",
    "choco": "uv",
    "content": "uv Python包管理器",
    "description": "uv 是一款用 Rust 编写的快速 Python 包和项目管理器。",
    "link": "https://docs.astral.sh/uv/getting-started/installation/",
    "winget": "astral-sh.uv",
    "foss": true
  },
  "WPFInstalltightvnc": {
    "category": "工具类",
    "choco": "TightVNC",
    "content": "TightVNC 远程桌面",
    "description": "TightVNC 是一款免费开源的远程桌面软件",
    "link": "https://www.tightvnc.com/",
    "winget": "GlavSoft.TightVNC",
    "foss": true
  },
  "WPFInstallglazewm": {
    "category": "工具类",
    "choco": "glazewm",
    "content": "GlazeWM 平铺窗口管理器",
    "description": "GlazeWM 是一款受 i3 和 Polybar 启发的 Windows 平铺窗口管理器。",
    "link": "https://github.com/glzr-io/glazewm",
    "winget": "glzr-io.glazewm",
    "foss": true
  },
  "WPFInstallOverwolf": {
    "category": "游戏",
    "choco": "overwolf",
    "content": "Overwolf 游戏插件平台",
    "description": "流行的游戏覆盖层和辅助应用平台，广泛被游戏玩家使用。",
    "link": "https://www.overwolf.com/app/overwolf-curseforge",
    "winget": "Overwolf.CurseForge",
    "foss": false
  },
  "WPFInstallOFGB": {
    "category": "工具类",
    "choco": "ofgb",
    "content": "OFGB Windows广告移除",
    "description": "从 Windows 11 各处移除广告的 GUI 工具。",
    "link": "https://github.com/xM4ddy/OFGB",
    "winget": "xM4ddy.OFGB",
    "foss": true
  },
  "WPFInstallZenBrowser": {
    "category": "浏览器",
    "choco": "zen-browser",
    "content": "Zen 浏览器",
    "description": "基于 Firefox 构建的现代、注重隐私、性能驱动的浏览器。",
    "link": "https://zen-browser.app/",
    "winget": "Zen-Team.Zen-Browser",
    "foss": true
  },
  "WPFInstallZed": {
    "category": "开发工具",
    "choco": "zed",
    "content": "Zed 代码编辑器",
    "description": "Zed 是一款现代高性能代码编辑器，从头设计以追求速度和协作。",
    "link": "https://zed.dev/",
    "winget": "ZedIndustries.Zed",
    "foss": true
  },
  "WPFInstalldeskflow": {
    "category": "工具类",
    "choco": "deskflow",
    "content": "Deskflow 键鼠共享",
    "description": "Deskflow 是一款免费开源的软件 KVM，让您在多台计算机之间共享键盘和鼠标。",
    "link": "https://github.com/deskflow/deskflow",
    "winget": "Deskflow.Deskflow",
    "foss": true
  },
  "WPFInstallRuby": {
    "category": "开发工具",
    "choco": "ruby",
    "winget": "RubyInstallerTeam.Ruby.4.0",
    "description": "包含 MSYS2 安装的 Ruby 语言执行环境。",
    "content": "Ruby 编程语言",
    "link": "https://rubyinstaller.org/",
    "foss": true
  },
  "WPFInstallLua": {
    "category": "开发工具",
    "choco": "lua",
    "winget": "rjpcomputing.luaforwindows",
    "description": "Lua 脚本语言的电池齐全环境（含依赖库）",
    "content": "Lua 脚本语言",
    "link": "https://github.com/rjpcomputing/luaforwindows",
    "foss": true
  }
}
'@ | ConvertFrom-Json


$sync.configs.appnavigation = @'
{
  "WPFInstall": {
    "Content": "安装/升级应用",
    "Category": "操作",
    "Type": "Button",
    "Order": "1",
    "Description": "安装或升级所选应用"
  },
  "WPFUninstall": {
    "Content": "卸载应用",
    "Category": "操作",
    "Type": "Button",
    "Order": "2",
    "Description": "卸载所选应用"
  },
  "WPFInstallUpgrade": {
    "Content": "升级所有应用",
    "Category": "操作",
    "Type": "Button",
    "Order": "3",
    "Description": "将所有应用升级到最新版本"
  },
  "WingetRadioButton": {
    "Content": "WinGet 包管理器",
    "Category": "包管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": true,
    "Order": "1",
    "Description": "使用 WinGet 进行包管理"
  },
  "ChocoRadioButton": {
    "Content": "Chocolatey 包管理器",
    "Category": "包管理器",
    "Type": "RadioButton",
    "GroupName": "PackageManagerGroup",
    "Checked": false,
    "Order": "2",
    "Description": "使用 Chocolatey 进行包管理"
  },
  "WPFCollapseAllCategories": {
    "Content": "折叠所有分类",
    "Category": "选择",
    "Type": "Button",
    "Order": "1",
    "Description": "折叠所有应用分类"
  },
  "WPFExpandAllCategories": {
    "Content": "展开所有分类",
    "Category": "选择",
    "Type": "Button",
    "Order": "2",
    "Description": "展开所有应用分类"
  },
  "WPFClearInstallSelection": {
    "Content": "清除选择",
    "Category": "选择",
    "Type": "Button",
    "Order": "3",
    "Description": "清除应用选择"
  },
  "WPFGetInstalled": {
    "Content": "显示已安装应用",
    "Category": "选择",
    "Type": "Button",
    "Order": "4",
    "Description": "显示已安装的应用"
  },
  "WPFselectedAppsButton": {
    "Content": "已选应用：0",
    "Category": "选择",
    "Type": "Button",
    "Order": "5",
    "Description": "显示已选的应用"
  },
  "WPFInstallFOSSInfo": {
    "Content": "免费开源软件",
    "Category": "选择",
    "Type": "Note",
    "Order": "0",
    "Description": "关于应用条目上 #FOSS 标签的信息"
  }
}
'@ | ConvertFrom-Json


$sync.configs.appx = @'
{
  "WPFAppxMicrosoft_WindowsFeedbackHub": {
    "Category": "微软应用",
    "Content": "反馈中心",
    "Description": "允许用户直接向 Microsoft 提交错误报告、功能建议和诊断数据。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsFeedbackHub",
    "StoreId": "9NBLGGH4R32N"
  },
  "WPFAppxMicrosoft_GetHelp": {
    "Category": "微软应用",
    "Content": "获取帮助",
    "Description": "提供自动故障排除指南、支持文档和直接 Microsoft 客户协助。",
    "Panel": "0",
    "PackageId": "Microsoft.GetHelp",
    "StoreId": "9PKDZBMV1H3T"
  },
  "WPFAppxMicrosoft_OutlookForWindows": {
    "Category": "微软应用",
    "Content": "Windows 版 Outlook",
    "Description": "提供现代电子邮件管理、日历安排和联系人组织功能。",
    "Panel": "0",
    "PackageId": "Microsoft.OutlookForWindows",
    "StoreId": "9NRX63209R7B"
  },
  "WPFAppxMSTeams": {
    "Category": "微软应用",
    "Content": "Microsoft Teams",
    "Description": "促进即时消息、视频会议、文件共享和工作区协作。",
    "Panel": "0",
    "PackageId": "MSTeams",
    "StoreId": "XP8BT8DW290MPQ"
  },
  "WPFAppxClipchamp_Clipchamp": {
    "Category": "工具与效率",
    "Content": "Clipchamp 视频编辑器",
    "Description": "提供用户友好的视频编辑器，包含内置模板、效果和时间线编辑工具。",
    "Panel": "0",
    "PackageId": "Clipchamp.Clipchamp",
    "StoreId": "9P1J8S7CCWWT"
  },
  "WPFAppxMicrosoft_MicrosoftOfficeHub": {
    "Category": "微软应用",
    "Content": "Microsoft 365",
    "Description": "作为访问云端 Microsoft 365 应用和最近文档的集中启动器和仪表板。",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftOfficeHub",
    "StoreId": "9WZDNCRD29V9"
  },
  "WPFAppxMicrosoft_ZuneMusic": {
    "Category": "工具与效率",
    "Content": "媒体播放器",
    "Description": "播放本地音频和视频文件，具有现代播放列表管理和投射功能。",
    "Panel": "0",
    "PackageId": "Microsoft.ZuneMusic",
    "StoreId": "9WZDNCRFJ3PT"
  },
  "WPFAppxMicrosoft_BingSearch": {
    "Category": "必应与网络服务",
    "Content": "必应搜索",
    "Description": "将 Microsoft Bing 搜索功能和网络服务直接集成到操作系统中。",
    "Panel": "1",
    "PackageId": "Microsoft.BingSearch",
    "StoreId": "9NZBF4GT040C"
  },
  "WPFAppxMicrosoftCorporationII_QuickAssist": {
    "Category": "工具与效率",
    "Content": "快速协助",
    "Description": "通过互联网连接启用安全的远程技术支持和屏幕共享。",
    "Panel": "0",
    "PackageId": "MicrosoftCorporationII.QuickAssist",
    "StoreId": "9P7BP5VNWKX5"
  },
  "WPFAppxMicrosoft_WindowsDevHome": {
    "Category": "开发者工具",
    "Content": "开发人员主页",
    "Description": "为软件开发人员提供环境设置、代码仓库同步和硬件小工具的专用仪表板。",
    "Panel": "1",
    "PackageId": "Microsoft.Windows.DevHome",
    "StoreId": "9N8MHTPHNGVV"
  },
  "WPFAppxMicrosoft_WindowsCrossDevice": {
    "Category": "微软生态系统",
    "Content": "移动设备",
    "Description": "管理与配对移动设备的系统级后台连接",
    "Panel": "0",
    "PackageId": "MicrosoftWindows.CrossDevice",
    "StoreId": "9NTXGKQ8P7N0"
  },
  "WPFAppxMicrosoft_Todos": {
    "Category": "工具与效率",
    "Content": "待办事项",
    "Description": "创建、跟踪和同步个人任务、智能列表和每日提醒。",
    "Panel": "0",
    "PackageId": "Microsoft.Todos",
    "StoreId": "9NBLGGH5R558"
  },
  "WPFAppxMicrosoft_PowerAutomateDesktop": {
    "Category": "开发者工具",
    "Content": "Power Automate",
    "Description": "使用低代码可视化脚本自动执行重复性工作流和桌面任务。",
    "Panel": "1",
    "PackageId": "Microsoft.PowerAutomateDesktop",
    "StoreId": "9NFTCH6J7FHV"
  },
  "WPFAppxMicrosoft_YourPhone": {
    "Category": "微软生态系统",
    "Content": "手机连接",
    "Description": "将短信、手机通知、照片和通话从移动设备同步到桌面。",
    "Panel": "0",
    "PackageId": "Microsoft.YourPhone",
    "StoreId": "9NMPJ99VJBWV"
  },
  "WPFAppxMicrosoft_MicrosoftStickyNotes": {
    "Category": "工具与效率",
    "Content": "便笺",
    "Description": "在桌面上创建快速浮动文本笔记，并自动跨设备同步。",
    "Panel": "0",
    "PackageId": "Microsoft.MicrosoftStickyNotes",
    "StoreId": "9NBLGGH4QGHW"
  },
  "WPFAppxMicrosoft_WindowsSoundRecorder": {
    "Category": "工具与效率",
    "Content": "录音机",
    "Description": "使用简单的麦克风调节控件录制和修剪实时音频输入。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsSoundRecorder",
    "StoreId": "9WZDNCRFHWKN"
  },
  "WPFAppxMicrosoft_WindowsAlarms": {
    "Category": "工具与效率",
    "Content": "时钟",
    "Description": "具有世界时钟、闹钟、倒计时、秒表和专注会话跟踪功能。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsAlarms",
    "StoreId": "9WZDNCRFJ3PR"
  },
  "WPFAppxMicrosoft_Paint": {
    "Category": "工具与效率",
    "Content": "画图",
    "Description": "提供内置的数字素描、基本图像编辑和像素级图形操作工具。",
    "Panel": "0",
    "PackageId": "Microsoft.Paint",
    "StoreId": "9PCFS5B6T72H"
  },
  "WPFAppxMicrosoft_WindowsNotepad": {
    "Category": "工具与效率",
    "Content": "记事本",
    "Description": "提供轻量级文本编辑器，支持多标签页处理纯文本文件和代码片段。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsNotepad",
    "StoreId": "9MSMLRH6LZF3"
  },
  "WPFAppxMicrosoft_ScreenSketch": {
    "Category": "工具与效率",
    "Content": "截图工具",
    "Description": "捕获截图或屏幕录制，具有内置标记、图像裁剪和光学字符识别 (OCR) 功能。",
    "Panel": "0",
    "PackageId": "Microsoft.ScreenSketch",
    "StoreId": "9MZ95KL8MR0L"
  },
  "WPFAppxMicrosoft_Copilot": {
    "Category": "必应与网络服务",
    "Content": "Copilot",
    "Description": "启动 Microsoft AI 伴侣，提供上下文答案、创意写作辅助和智能网页搜索。",
    "Panel": "1",
    "PackageId": "Microsoft.Copilot",
    "StoreId": "9NHT9RB2F4HD"
  },
  "WPFAppxMicrosoft_WindowsCalculator": {
    "Category": "工具与效率",
    "Content": "计算器",
    "Description": "执行标准算术、科学运算、编程计算和单位转换。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCalculator",
    "StoreId": "9WZDNCRFHVN5"
  },
  "WPFAppxMicrosoft_WindowsCamera": {
    "Category": "工具与效率",
    "Content": "相机",
    "Description": "通过连接的摄像头或成像硬件捕获照片和录制视频文件。",
    "Panel": "0",
    "PackageId": "Microsoft.WindowsCamera",
    "StoreId": "9WZDNCRFJBBG"
  },
  "WPFAppxMicrosoft_WindowsPhotos": {
    "Category": "工具与效率",
    "Content": "相册",
    "Description": "整理、查看和裁剪本地图像，具有基本颜色调整和相册创建工具。",
    "Panel": "0",
    "PackageId": "Microsoft.Windows.Photos",
    "StoreId": "9WZDNCRFJBH4"
  },
  "WPFAppxMicrosoft_BingNews": {
    "Category": "必应与网络服务",
    "Content": "新闻",
    "Description": "聚合突发新闻标题、个性化文章推送和世界时事。",
    "Panel": "1",
    "PackageId": "Microsoft.BingNews",
    "StoreId": "9WZDNCRFHVFW"
  },
  "WPFAppxMicrosoft_BingWeather": {
    "Category": "必应与网络服务",
    "Content": "天气",
    "Description": "显示本地实时天气跟踪、雷达地图和历史气象预报。",
    "Panel": "1",
    "PackageId": "Microsoft.BingWeather",
    "StoreId": "9WZDNCRFJ3Q2"
  },
  "WPFAppxMicrosoft_GamingApp": {
    "Category": "Xbox与游戏",
    "Content": "Xbox 应用",
    "Description": "作为主要游戏库管理器、社交社区界面和 PC Game Pass 仪表板。",
    "Panel": "1",
    "PackageId": "Microsoft.GamingApp",
    "StoreId": "9MV0B5HZVK9Z"
  },
  "WPFAppxMicrosoft_XboxGamingOverlay": {
    "Category": "Xbox与游戏",
    "Content": "Xbox Game Bar",
    "Description": "提供可自定义的游戏内状态小工具、音频平衡滑块、系统监控工具和游戏录制。",
    "Panel": "1",
    "PackageId": "Microsoft.XboxGamingOverlay",
    "StoreId": "9NZKPSTSNW4P"
  },
  "WPFAppxMicrosoft_XboxIdentityProvider": {
    "Category": "Xbox与游戏",
    "Content": "Xbox 身份提供程序",
    "Description": "管理 Xbox 网络用户认证和后台账户访问",
    "Panel": "1",
    "PackageId": "Microsoft.XboxIdentityProvider",
    "StoreId": "9WZDNCRD1HKW"
  },
  "WPFAppxMicrosoft_XboxSpeechToTextOverlay": {
    "Category": "Xbox与游戏",
    "Content": "Xbox 语音转文字覆盖",
    "Description": "为游戏聊天网络提供系统级实时辅助字幕和语音转文字翻译。",
    "Panel": "1",
    "PackageId": "Microsoft.XboxSpeechToTextOverlay"
  },
  "WPFAppxMicrosoft_Xbox_TCUI": {
    "Category": "Xbox与游戏",
    "Content": "Xbox TCUI",
    "Description": "为 Xbox 提供核心账户连接 UI 模块",
    "Panel": "1",
    "PackageId": "Microsoft.Xbox.TCUI"
  },
  "WPFAppxMicrosoft_StartExperiencesApp": {
    "Category": "必应与网络服务",
    "Content": "开始体验应用",
    "Description": "驱动 Windows 小组件面板，提供新闻、天气、体育和财经内容的个性化推送。",
    "Panel": "1",
    "PackageId": "Microsoft.StartExperiencesApp",
    "StoreId": "9PC1H9VN18CM"
  },
  "WPFAppxMicrosoft_MicrosoftSolitaireCollection": {
    "Category": "Xbox与游戏",
    "Content": "纸牌游戏合集",
    "Description": "包含内置纸牌游戏模式，包括 Klondike、Spider、FreeCell、Pyramid 和 TriPeaks。",
    "Panel": "1",
    "PackageId": "Microsoft.MicrosoftSolitaireCollection"
  }
}
'@ | ConvertFrom-Json


$sync.configs.dns = @'
{
  "Google": {
    "Primary": "8.8.8.8",
    "Secondary": "8.8.4.4",
    "Primary6": "2001:4860:4860::8888",
    "Secondary6": "2001:4860:4860::8844"
  },
  "Cloudflare": {
    "Primary": "1.1.1.1",
    "Secondary": "1.0.0.1",
    "Primary6": "2606:4700:4700::1111",
    "Secondary6": "2606:4700:4700::1001"
  },
  "Cloudflare_Malware": {
    "Primary": "1.1.1.2",
    "Secondary": "1.0.0.2",
    "Primary6": "2606:4700:4700::1112",
    "Secondary6": "2606:4700:4700::1002"
  },
  "Cloudflare_Malware_Adult": {
    "Primary": "1.1.1.3",
    "Secondary": "1.0.0.3",
    "Primary6": "2606:4700:4700::1113",
    "Secondary6": "2606:4700:4700::1003"
  },
  "Open_DNS": {
    "Primary": "208.67.222.222",
    "Secondary": "208.67.220.220",
    "Primary6": "2620:119:35::35",
    "Secondary6": "2620:119:53::53"
  },
  "Quad9": {
    "Primary": "9.9.9.9",
    "Secondary": "149.112.112.112",
    "Primary6": "2620:fe::fe",
    "Secondary6": "2620:fe::9"
  },
  "AdGuard_Ads_Trackers": {
    "Primary": "94.140.14.14",
    "Secondary": "94.140.15.15",
    "Primary6": "2a10:50c0::ad1:ff",
    "Secondary6": "2a10:50c0::ad2:ff"
  },
  "AdGuard_Ads_Trackers_Malware_Adult": {
    "Primary": "94.140.14.15",
    "Secondary": "94.140.15.16",
    "Primary6": "2a10:50c0::bad1:ff",
    "Secondary6": "2a10:50c0::bad2:ff"
  }
}
'@ | ConvertFrom-Json


$sync.configs.feature = @'
{
  "WPFFeaturesdotnet": {
    "Content": ".NET Framework (2、3、4 版) - 启用",
    "Description": ".NET 和 .NET Framework 是一个开发者平台，由工具、编程语言和库组成。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "NetFx4-AdvSrvs",
      "NetFx3"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/dotnet"
  },
  "WPFFixesNTPPool": {
    "Content": "NTP 服务器 - 启用",
    "Description": "将默认 Windows NTP 服务器替换为 pool.ntp.org，以提高时间同步的准确性和可靠性。",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNTPPool",
    "link": "https://winutil.christitus.com/dev/features/fixes/ntppool"
  },
  "WPFFeatureshyperv": {
    "Content": "Hyper-V - 启用",
    "Description": "Hyper-V 是 Microsoft 开发的硬件虚拟化产品，允许用户创建和管理虚拟机。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "Microsoft-Hyper-V-All"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/hyperv"
  },
  "WPFFeatureslegacymedia": {
    "Content": "旧版媒体组件 (WMP、DirectPlay) - 启用",
    "Description": "启用来自旧版 Windows 的旧版程序。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "WindowsMediaPlayer",
      "MediaPlayback",
      "DirectPlay",
      "LegacyComponents"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/legacymedia"
  },
  "WPFFeaturewsl": {
    "Content": "Windows Linux 子系统 (WSL) - 启用",
    "Description": "Windows Linux 子系统是 Windows 的可选功能，允许 Linux 程序在 Windows 上原生运行。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "VirtualMachinePlatform",
      "Microsoft-Windows-Subsystem-Linux"
    ],
    "InvokeScript": [],
    "link": "https://winutil.christitus.com/dev/features/features/wsl"
  },
  "WPFFeaturenfs": {
    "Content": "网络文件系统 (NFS) - 启用",
    "Description": "网络文件系统 (NFS) 是一种在网络中存储文件的机制。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "ServicesForNFS-ClientOnly",
      "ClientForNFS-Infrastructure",
      "NFS-Administration"
    ],
    "InvokeScript": [
      "nfsadmin client stop",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousUID' -Type DWord -Value 0",
      "Set-ItemProperty -Path 'HKLM:\\SOFTWARE\\Microsoft\\ClientForNFS\\CurrentVersion\\Default' -Name 'AnonymousGID' -Type DWord -Value 0",
      "nfsadmin client start",
      "nfsadmin client localhost config fileaccess=755 SecFlavors=+sys -krb5 -krb5i"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/nfs"
  },
  "WPFFeatureRegBackup": {
    "Content": "注册表备份 (每日凌晨 12:30 任务) - 启用",
    "Description": "启用每日注册表备份，此功能在 Windows 10 1803 中被 Microsoft 禁用。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'EnablePeriodicBackup' -Type DWord -Value 1 -Force      New-ItemProperty -Path 'HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Configuration Manager' -Name 'BackupCount' -Type DWord -Value 2 -Force      $action = New-ScheduledTaskAction -Execute 'schtasks' -Argument '/run /i /tn \"\\Microsoft\\Windows\\Registry\\RegIdleBackup\"'      $trigger = New-ScheduledTaskTrigger -Daily -At 00:30      Register-ScheduledTask -Action $action -Trigger $trigger -TaskName 'AutoRegBackup' -Description 'Create System Registry Backups' -User 'System'      "
    ],
    "link": "https://winutil.christitus.com/dev/features/features/regbackup"
  },
  "WPFFeatureEnableLegacyRecovery": {
    "Content": "旧版 F8 启动恢复 - 启用",
    "Description": "启用高级启动选项屏幕，让您使用高级故障排除模式启动 Windows。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy legacy"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/enablelegacyrecovery"
  },
  "WPFFeatureDisableLegacyRecovery": {
    "Content": "旧版 F8 启动恢复 - 禁用",
    "Description": "禁用允许您使用高级故障排除模式启动 Windows 的高级启动选项屏幕。",
    "category": "功能",
    "panel": "1",
    "feature": [],
    "InvokeScript": [
      "bcdedit /set bootmenupolicy standard"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/disablelegacyrecovery"
  },
  "WPFFeaturesSandbox": {
    "Content": "Windows 沙盒 - 启用",
    "Description": "Windows 沙盒是一个轻量级虚拟机，提供临时的桌面环境以安全隔离地运行应用程序。",
    "category": "功能",
    "panel": "1",
    "feature": [
      "Containers-DisposableClientVM"
    ],
    "link": "https://winutil.christitus.com/dev/features/features/sandbox"
  },
  "WPFFeatureInstall": {
    "Content": "安装功能",
    "category": "功能",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFeatureInstall",
    "link": "https://winutil.christitus.com/dev/features/features/install"
  },
  "WPFPanelAutologin": {
    "Content": "自动登录 - 运行",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFPanelAutologin",
    "link": "https://winutil.christitus.com/dev/features/fixes/autologin"
  },
  "WPFFixesUpdate": {
    "Content": "Windows 更新 - 重置",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesUpdate",
    "link": "https://winutil.christitus.com/dev/features/fixes/update"
  },
  "WPFFixesNetwork": {
    "Content": "网络 - 重置",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesNetwork",
    "link": "https://winutil.christitus.com/dev/features/fixes/network"
  },
  "WPFPanelDISM": {
    "Content": "系统损坏扫描 - 运行",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSystemRepair",
    "link": "https://winutil.christitus.com/dev/features/fixes/dism"
  },
  "WPFFixesWinget": {
    "Content": "WinGet - 重新安装",
    "category": "修复",
    "panel": "1",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFFixesWinget",
    "link": "https://winutil.christitus.com/dev/features/fixes/winget"
  },
  "WPFPanelComputer": {
    "Content": "计算机管理",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "compmgmt.msc"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/computer"
  },
  "WPFPanelControl": {
    "Content": "控制面板",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "control"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/control"
  },
  "WPFPanelMouse": {
    "Content": "鼠标属性",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "main.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/mouse"
  },
  "WPFPanelNetwork": {
    "Content": "网络连接",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "ncpa.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/network"
  },
  "WPFPanelPower": {
    "Content": "电源设置",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "powercfg.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/power"
  },
  "WPFPanelPrinter": {
    "Content": "打印机设置",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "Start-Process 'shell:::{A8A91A66-3A7D-4424-8D24-04E180695C7A}'"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/printer"
  },
  "WPFPanelPrograms": {
    "Content": "程序和功能",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "appwiz.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/programs"
  },
  "WPFPanelRegion": {
    "Content": "区域",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "intl.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/region"
  },
  "WPFPanelSecurity": {
    "Content": "安全和维护",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "wscui.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/security"
  },
  "WPFPanelSound": {
    "Content": "声音设置",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "mmsys.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/sound"
  },
  "WPFPanelSystem": {
    "Content": "系统属性",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "sysdm.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/system"
  },
  "WPFPanelTimedate": {
    "Content": "时间和日期",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "timedate.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/timedate"
  },
  "WPFPanelFirewall": {
    "Content": "Windows Defender 防火墙",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "firewall.cpl"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/firewall"
  },
  "WPFPanelRestore": {
    "Content": "Windows 还原",
    "category": "传统 Windows 面板",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "InvokeScript": [
      "rstrui.exe"
    ],
    "link": "https://winutil.christitus.com/dev/features/legacy-windows-panels/restore"
  },
  "WPFWinUtilInstallPSProfile": {
    "Content": "PowerShell 是微软的自动化任务框架和脚本语言",
    "category": "PowerShell 配置文件 (仅 PowerShell 7+)",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilInstallPSProfile",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/installpsprofile"
  },
  "WPFWinUtilUninstallPSProfile": {
    "Content": "PowerShell 是微软的自动化任务框架和脚本语言",
    "category": "PowerShell 配置文件 (仅 PowerShell 7+)",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WinUtilUninstallPSProfile",
    "link": "https://winutil.christitus.com/dev/features/powershell-profile-powershell-7--only/uninstallpsprofile"
  },
  "WPFWinUtilSSHServer": {
    "Content": "OpenSSH 服务器 - 启用",
    "category": "远程访问",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "function": "Invoke-WPFSSHServer",
    "link": "https://winutil.christitus.com/dev/features/remote-access/sshserver"
  }
}
'@ | ConvertFrom-Json


$sync.configs.preset = @'
{
  "Standard": [
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDiskCleanup",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksRestorePoint"
  ],
  "Minimal": [
    "WPFTweaksConsumerFeatures",
    "WPFTweaksWPBT",
    "WPFTweaksServices",
    "WPFTweaksTelemetry"
  ],
  "Advanced": [
    "WPFTweaksRestorePoint",
    "WPFTweaksActivity",
    "WPFTweaksConsumerFeatures",
    "WPFTweaksDisableExplorerAutoDiscovery",
    "WPFTweaksWPBT",
    "WPFTweaksLocation",
    "WPFTweaksServices",
    "WPFTweaksTelemetry",
    "WPFTweaksDeliveryOptimization",
    "WPFTweaksDeleteTempFiles",
    "WPFTweaksEndTaskOnTaskbar",
    "WPFTweaksDisableStoreSearch",
    "WPFTweaksRevertStartMenu",
    "WPFTweaksWidget",
    "WPFTweaksRemoveOneDrive",
    "WPFTweaksWindowsAI",
    "WPFTweaksRightClickMenu"
  ],
  "AppxDefault": [
    "WPFAppxMicrosoft_WindowsFeedbackHub",
    "WPFAppxMicrosoft_GetHelp",
    "WPFAppxMicrosoft_MicrosoftOfficeHub",
    "WPFAppxMicrosoft_WindowsCalculator",
    "WPFAppxClipchamp_Clipchamp",
    "WPFAppxMicrosoft_WindowsAlarms",
    "WPFAppxMicrosoftCorporationII_QuickAssist",
    "WPFAppxMicrosoft_WindowsSoundRecorder",
    "WPFAppxMicrosoft_MicrosoftStickyNotes",
    "WPFAppxMicrosoft_Todos",
    "WPFAppxMicrosoft_MicrosoftSolitaireCollection",
    "WPFAppxMicrosoft_PowerAutomateDesktop",
    "WPFAppxMicrosoft_WindowsDevHome",
    "WPFAppxMicrosoft_BingWeather",
    "WPFAppxMicrosoft_StartExperiencesApp",
    "WPFAppxMicrosoft_BingNews",
    "WPFAppxMicrosoft_Copilot",
    "WPFAppxMicrosoft_BingSearch"
  ]
}
'@ | ConvertFrom-Json


$sync.configs.themes = @'
{
  "shared": {
    "AppEntryWidth": "220",
    "AppEntryFontSize": "13.2",
    "AppEntryIconSize": "28",
    "AppEntryMargin": "3",
    "AppEntryBorderThickness": "1",
    "CustomDialogFontSize": "12",
    "CustomDialogFontSizeHeader": "14",
    "CustomDialogLogoSize": "25",
    "CustomDialogWidth": "400",
    "CustomDialogHeight": "200",
    "FontSize": "12",
    "FontFamily": "Arial",
    "HeaderFontSize": "16",
    "HeaderFontFamily": "Consolas, Monaco",
    "CheckBoxBulletDecoratorSize": "14",
    "CheckBoxMargin": "15,0,0,2",
    "TabContentMargin": "5",
    "TabButtonFontSize": "14",
    "TabButtonWidth": "110",
    "TabButtonHeight": "26",
    "TabRowHeightInPixels": "50",
    "ToolTipWidth": "300",
    "IconFontSize": "14",
    "IconButtonSize": "35",
    "SettingsIconFontSize": "18",
    "CloseIconFontSize": "12",
    "GroupBorderBackgroundColor": "#232629",
    "ButtonFontSize": "12",
    "ButtonFontFamily": "Arial",
    "ButtonWidth": "200",
    "ButtonHeight": "25",
    "ConfigTabButtonFontSize": "14",
    "ConfigUpdateButtonFontSize": "14",
    "SearchBarWidth": "200",
    "SearchBarHeight": "26",
    "SearchBarTextBoxFontSize": "12",
    "SearchBarClearButtonFontSize": "14",
    "CheckboxMouseOverColor": "#999999",
    "ButtonBorderThickness": "1",
    "ButtonMargin": "1",
    "ButtonCornerRadius": "2"
  },
  "Light": {
    "AppInstallUnselectedColor": "#F7F7F7",
    "AppInstallHighlightedColor": "#CFCFCF",
    "AppInstallSelectedColor": "#C2C2C2",
    "ComboBoxForegroundColor": "#232629",
    "ComboBoxBackgroundColor": "#F7F7F7",
    "LabelboxForegroundColor": "#232629",
    "MainForegroundColor": "#232629",
    "MainBackgroundColor": "#F7F7F7",
    "LabelBackgroundColor": "#F7F7F7",
    "LinkForegroundColor": "#484848",
    "LinkHoverForegroundColor": "#232629",
    "ScrollBarBackgroundColor": "#4A4D52",
    "ScrollBarHoverColor": "#5A5D62",
    "ScrollBarDraggingColor": "#6A6D72",
    "ProgressBarForegroundColor": "#2E77FF",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#F7F7F7",
    "ButtonTweaksBackgroundColor": "#F7F7F7",
    "ButtonConfigBackgroundColor": "#F7F7F7",
    "ButtonUpdatesBackgroundColor": "#F7F7F7",
    "ButtonWin11ISOBackgroundColor": "#F7F7F7",
    "ButtonAppxBackgroundColor": "#F7F7F7",
    "ButtonInstallForegroundColor": "#232629",
    "ButtonTweaksForegroundColor": "#232629",
    "ButtonConfigForegroundColor": "#232629",
    "ButtonUpdatesForegroundColor": "#232629",
    "ButtonWin11ISOForegroundColor": "#232629",
    "ButtonAppxForegroundColor": "#232629",
    "ButtonBackgroundColor": "#F5F5F5",
    "ButtonBackgroundPressedColor": "#1A1A1A",
    "ButtonBackgroundMouseoverColor": "#C2C2C2",
    "ButtonBackgroundSelectedColor": "#F0F0F0",
    "ButtonForegroundColor": "#232629",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#F7F7F7",
    "BorderColor": "#232629",
    "BorderOpacity": "0.2"
  },
  "Dark": {
    "AppInstallUnselectedColor": "#232629",
    "AppInstallHighlightedColor": "#3C3C3C",
    "AppInstallSelectedColor": "#4C4C4C",
    "ComboBoxForegroundColor": "#F7F7F7",
    "ComboBoxBackgroundColor": "#1E3747",
    "LabelboxForegroundColor": "#5BDCFF",
    "MainForegroundColor": "#F7F7F7",
    "MainBackgroundColor": "#232629",
    "LabelBackgroundColor": "#232629",
    "LinkForegroundColor": "#ADD8E6",
    "LinkHoverForegroundColor": "#F7F7F7",
    "ScrollBarBackgroundColor": "#2E3135",
    "ScrollBarHoverColor": "#3B4252",
    "ScrollBarDraggingColor": "#5E81AC",
    "ProgressBarForegroundColor": "#6EFF72",
    "ProgressBarBackgroundColor": "Transparent",
    "ButtonInstallBackgroundColor": "#222222",
    "ButtonTweaksBackgroundColor": "#333333",
    "ButtonConfigBackgroundColor": "#444444",
    "ButtonUpdatesBackgroundColor": "#555555",
    "ButtonWin11ISOBackgroundColor": "#666666",
    "ButtonAppxBackgroundColor": "#777777",
    "ButtonInstallForegroundColor": "#F7F7F7",
    "ButtonTweaksForegroundColor": "#F7F7F7",
    "ButtonConfigForegroundColor": "#F7F7F7",
    "ButtonUpdatesForegroundColor": "#F7F7F7",
    "ButtonWin11ISOForegroundColor": "#F7F7F7",
    "ButtonAppxForegroundColor": "#F7F7F7",
    "ButtonBackgroundColor": "#1E3747",
    "ButtonBackgroundPressedColor": "#F7F7F7",
    "ButtonBackgroundMouseoverColor": "#3B4252",
    "ButtonBackgroundSelectedColor": "#5E81AC",
    "ButtonForegroundColor": "#F7F7F7",
    "ToggleButtonOnColor": "#2E77FF",
    "ToggleButtonOffColor": "#707070",
    "ToolTipBackgroundColor": "#2F373D",
    "BorderColor": "#2F373D",
    "BorderOpacity": "0.2"
  }
}
'@ | ConvertFrom-Json


$sync.configs.tweaks = @'
{
  "WPFTweaksActivity": {
    "Content": "活动历史记录 - 禁用",
    "Description": "清除最近的文档、剪贴板和运行历史记录。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "EnableActivityFeed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "UploadUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/activity"
  },
  "WPFTweaksHiber": {
    "Content": "休眠功能 - 禁用",
    "Description": "休眠功能适用于笔记本电脑，在关机前保存内存内容。通常不推荐使用。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\System\\CurrentControlSet\\Control\\Session Manager\\Power",
        "Name": "HibernateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Explorer\\FlyoutMenuSettings",
        "Name": "ShowHibernateOption",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "powercfg.exe /hibernate off"
    ],
    "UndoScript": [
      "powercfg.exe /hibernate on"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/hiber"
  },
  "WPFTweaksWidget": {
    "Content": "小组件 - 移除",
    "Description": "移除任务栏左下角的烦人小组件。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "      # Sometimes if you dont stop the Widgets process the removal may fail      Get-Process *Widget* | Stop-Process      Get-AppxPackage Microsoft.WidgetsPlatformRuntime -AllUsers | Remove-AppxPackage -AllUsers      Get-AppxPackage MicrosoftWindows.Client.WebExperience -AllUsers | Remove-AppxPackage -AllUsers      Invoke-WinUtilExplorerUpdate -action \"restart\"      Write-Host \"Removed widgets\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/widget"
  },
  "WPFTweaksRevertStartMenu": {
    "Content": "开始菜单旧版布局 - 启用",
    "Description": "恢复 25H2 新版本之前的旧开始菜单布局。在更新的 Windows 版本上此调整将不起作用。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\ControlSet001\\Control\\FeatureManagement\\Overrides\\8\\3036241548",
        "Name": "EnabledState",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/revertstartmenu"
  },
  "WPFTweaksDisableStoreSearch": {
    "Content": "Microsoft Store 推荐搜索结果 - 禁用",
    "Description": "在开始菜单搜索应用时将不显示推荐的 Microsoft Store 应用。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /deny Everyone:F"
    ],
    "UndoScript": [
      "icacls \"$Env:LocalAppData\\Packages\\Microsoft.WindowsStore_8wekyb3d8bbwe\\LocalState\\store.db\" /grant Everyone:F"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablestoresearch"
  },
  "WPFTweaksLocation": {
    "Content": "位置跟踪 - 禁用",
    "Description": "禁用位置跟踪。",
    "category": "基本优化",
    "panel": "1",
    "service": [
      {
        "Name": "lfsvc",
        "StartupType": "Disable",
        "OriginalType": "Manual"
      }
    ],
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\location",
        "Name": "Value",
        "Value": "Deny",
        "Type": "String",
        "OriginalValue": "Allow"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\Sensor\\Overrides\\{BFA794E4-F964-4FDB-90F6-51056BFE4B44}",
        "Name": "SensorPermissionState",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SYSTEM\\Maps",
        "Name": "AutoUpdateEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/location"
  },
  "WPFTweaksServices": {
    "Content": "服务 - 设为手动",
    "Description": "将某些服务设为手动启动并调整注册表值以匹配系统内存，可显著减少 svchost.exe 进程数量。",
    "category": "基本优化",
    "panel": "1",
    "service": [
      {
        "Name": "CscService",
        "StartupType": "Disabled",
        "OriginalType": "Manual"
      },
      {
        "Name": "DiagTrack",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      },
      {
        "Name": "MapsBroker",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "StorSvc",
        "StartupType": "Manual",
        "OriginalType": "Automatic"
      },
      {
        "Name": "SharedAccess",
        "StartupType": "Disabled",
        "OriginalType": "Automatic"
      }
    ],
    "InvokeScript": [
      "      $Memory = (Get-CimInstance Win32_PhysicalMemory | Measure-Object Capacity -Sum).Sum / 1KB      Set-ItemProperty -Path \"HKLM:\\SYSTEM\\CurrentControlSet\\Control\" -Name SvcHostSplitThresholdInKB -Value $Memory      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/services"
  },
  "WPFTweaksBraveDebloat": {
    "Content": "Brave 浏览器 - 精简",
    "Description": "禁用各种烦人功能，如 Brave Rewards、Leo AI、加密钱包和 VPN。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveRewardsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveWalletDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveVPNDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveAIChatEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveStatsPingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveNewsDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveTalkDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "TorDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "BraveP3AEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "UrlKeyedAnonymizedDataCollectionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "SafeBrowsingExtendedReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\BraveSoftware\\Brave",
        "Name": "MetricsReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/bravedebloat"
  },
  "WPFTweaksDisableWarningForUnsignedRdp": {
    "Content": "RDP 未签名文件警告 - 禁用",
    "Description": "禁用启动未签名 RDP 文件时显示的警告。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows NT\\Terminal Services\\Client",
        "Name": "RedirectionWarningDialogVersion",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Terminal Server Client",
        "Name": "RdpLaunchConsentAccepted",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablewarningforunsignedrdp"
  },
  "WPFTweaksEdgeDebloat": {
    "Content": "Microsoft Edge - 精简",
    "Description": "禁用 Edge 中的各种遥测选项、弹窗和其他烦人功能。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\EdgeUpdate",
        "Name": "CreateDesktopShortcutDefault",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "PersonalizationReportingEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge\\ExtensionInstallBlocklist",
        "Name": "1",
        "Value": "ofefcgjbeghpigppfmkologfjadafddi",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowRecommendationsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "HideFirstRunExperience",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "UserFeedbackAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ConfigureDoNotTrack",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "AlternateErrorPagesEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeCollectionsEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeShoppingAssistantEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "MicrosoftEdgeInsiderPromotionEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "ShowMicrosoftRewards",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WebWidgetAllowed",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DiagnosticData",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "EdgeAssetDeliveryServiceEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "WalletDonationEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Edge",
        "Name": "DefaultBrowserSettingsCampaignEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/edgedebloat"
  },
  "WPFTweaksConsumerFeatures": {
    "Content": "消费者功能 - 禁用",
    "Description": "停止推广应用安装并减少 Microsoft Store 内容的应用建议。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\CloudContent",
        "Name": "DisableWindowsConsumerFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/consumerfeatures"
  },
  "WPFTweaksTelemetry": {
    "Content": "遥测 - 禁用",
    "Description": "禁用 Microsoft 遥测。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\AdvertisingInfo",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Privacy",
        "Name": "TailoredExperiencesWithDiagnosticDataEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Speech_OneCore\\Settings\\OnlineSpeechPrivacy",
        "Name": "HasAccepted",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Input\\TIPC",
        "Name": "Enabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitInkCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization",
        "Name": "RestrictImplicitTextCollection",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\InputPersonalization\\TrainedDataStore",
        "Name": "HarvestContacts",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Personalization\\Settings",
        "Name": "AcceptedPrivacyPolicy",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\DataCollection",
        "Name": "AllowTelemetry",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Start_TrackProgs",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "PublishUserActivities",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Siuf\\Rules",
        "Name": "NumberOfSIUFInPeriod",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "      # Disable Defender Auto Sample Submission      Set-MpPreference -SubmitSamplesConsent 2      # Disable (Connected User Experiences and Telemetry) Service      Set-Service -Name diagtrack -StartupType Disabled      # Disable (Windows Error Reporting Manager) Service      Set-Service -Name wermgr -StartupType Disabled      # Disable PowerShell 7 telemetry      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '1', 'Machine')      Remove-ItemProperty -Path \"HKCU:\\Software\\Microsoft\\Siuf\\Rules\" -Name PeriodInNanoSeconds      "
    ],
    "UndoScript": [
      "      # Enable Defender Auto Sample Submission      Set-MpPreference -SubmitSamplesConsent 1      # Enable (Connected User Experiences and Telemetry) Service      Set-Service -Name diagtrack -StartupType Automatic      # Enable (Windows Error Reporting Manager) Service      Set-Service -Name wermgr -StartupType Automatic      # Enable PowerShell 7 telemetry      [Environment]::SetEnvironmentVariable('POWERSHELL_TELEMETRY_OPTOUT', '', 'Machine')      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/telemetry"
  },
  "WPFTweaksDeliveryOptimization": {
    "Content": "传递优化 - 禁用",
    "Description": "阻止 Windows 使用您的带宽向其他电脑上传更新。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\DeliveryOptimization",
        "Name": "DODownloadMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/deliveryoptimization"
  },
  "WPFTweaksRemoveEdge": {
    "Content": "Microsoft Edge - 移除",
    "Description": "通过创建虚拟 MicrosoftEdge.exe 文件解锁官方卸载程序，实现系统级移除 Microsoft Edge",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "InvokeScript": [
      "      $Path = Resolve-Path -Path \"$Env:ProgramFiles (x86)\\Microsoft\\Edge\\Application\\*\\Installer\\setup.exe\" | Select-Object -Last 1      if (Test-Path $Path) {          New-Item -Path \"$Env:SystemRoot\\SystemApps\\Microsoft.MicrosoftEdge_8wekyb3d8bbwe\\MicrosoftEdge.exe\" -Force          Start-Process -FilePath $Path -ArgumentList \"--uninstall --system-level --force-uninstall --delete-profile\" -Wait          Write-Host \"Microsoft Edge was removed\"      } else {          Write-Host \"Microsoft Edge is not installed\"      }      "
    ],
    "UndoScript": [
      "      Write-Host \"Installing Microsoft Edge...\"      winget install Microsoft.Edge --source winget      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeedge"
  },
  "WPFTweaksDisableBitLocker": {
    "Content": "BitLocker - 禁用",
    "Description": "禁用 BitLocker。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "Disable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "UndoScript": [
      "Enable-BitLocker -MountPoint $Env:SystemDrive"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disablebitlocker"
  },
  "WPFTweaksUTC": {
    "Content": "日期和时间 - 设置为 UTC",
    "Description": "对双系统启动的计算机至关重要，修复与 Linux 系统的时间同步问题。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\TimeZoneInformation",
        "Name": "RealTimeIsUniversal",
        "Value": "1",
        "Type": "QWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/utc"
  },
  "WPFTweaksRemoveOneDrive": {
    "Content": "Microsoft OneDrive - 移除",
    "Description": "拒绝删除 OneDrive 用户文件的权限，卸载后恢复原始权限。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "InvokeScript": [
      "      # Deny permission to remove OneDrive folder      icacls $Env:OneDrive /deny \"Administrators:(D,DC)\"      Write-Host \"Uninstalling OneDrive...\"      Start-Process -FilePath (Join-Path $Env:SystemRoot \"System32\\OneDriveSetup.exe\") -ArgumentList '/uninstall' -Wait      # Some of OneDrive files use explorer, and OneDrive uses FileCoAuth      Write-Host \"Removing leftover OneDrive Files...\"      Stop-Process -Name FileCoAuth,Explorer      Remove-Item \"$Env:LocalAppData\\Microsoft\\OneDrive\" -Recurse -Force      Remove-Item \"$Env:ProgramData\\Microsoft OneDrive\" -Recurse -Force      # Grant back permission to access OneDrive folder      icacls $Env:OneDrive /grant \"Administrators:(D,DC)\"      if (-not (Get-ChildItem -Path $Env:OneDrive)) {          Remove-Item -Path $Env:OneDrive -Recurse          [Environment]::SetEnvironmentVariable('OneDrive', $null, 'User')      }      # Disable OneSyncSvc      Set-Service -Name OneSyncSvc -StartupType Disabled      "
    ],
    "UndoScript": [
      "      Write-Host \"Installing OneDrive\"      winget install Microsoft.Onedrive --source winget      # Enabled OneSyncSvc      Set-Service -Name OneSyncSvc -StartupType Automatic      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removeonedrive"
  },
  "WPFTweaksRemoveHomeAndGallery": {
    "Content": "文件资源管理器主页和图库 - 禁用",
    "Description": "从资源管理器中移除主页和图库，并将此电脑设为默认。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{f874310e-b6b7-47dc-bc84-b9e6b38f5903}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Classes\\CLSID\\{e88865ea-0e1c-4e20-9aa6-edcd0212c87c}",
        "Name": "System.IsPinnedToNameSpaceTree",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "LaunchTo",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/removehomeandgallery"
  },
  "WPFTweaksDisplay": {
    "Content": "视觉效果 - 设置为最佳性能",
    "Description": "将系统偏好设置为性能模式。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "DragFullWindows",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "MenuShowDelay",
        "Value": "200",
        "Type": "String",
        "OriginalValue": "400"
      },
      {
        "Path": "HKCU:\\Control Panel\\Desktop\\WindowMetrics",
        "Name": "MinAnimate",
        "Value": "0",
        "Type": "String",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "KeyboardDelay",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewAlphaSelect",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ListviewShadow",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAnimations",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\VisualEffects",
        "Name": "VisualFXSetting",
        "Value": "3",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\DWM",
        "Name": "EnableAeroPeek",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarMn",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "InvokeScript": [
      "Set-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\" -Type Binary -Value ([byte[]](144,18,3,128,16,0,0,0))"
    ],
    "UndoScript": [
      "Remove-ItemProperty -Path \"HKCU:\\Control Panel\\Desktop\" -Name \"UserPreferencesMask\""
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/display"
  },
  "WPFTweaksReservedStorage": {
    "Content": "禁用预留存储",
    "Description": "禁用 Windows 预留存储（约 7-10 GB 用于更新和临时文件）。仅建议小容量硬盘使用",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "InvokeScript": [
      "DISM /Online /Set-ReservedStorageState /State:Disabled"
    ],
    "UndoScript": [
      "DISM /Online /Set-ReservedStorageState /State:Enabled"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/reservedstorage"
  },
  "WPFTweaksRestorePoint": {
    "Content": "还原点 - 创建",
    "Description": "在运行时创建还原点，以便在需要时恢复 WinUtil 的修改。",
    "category": "基本优化",
    "panel": "1",
    "Checked": "False",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion\\SystemRestore",
        "Name": "SystemRestorePointCreationFrequency",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1440"
      }
    ],
    "InvokeScript": [
      "      if (-not (Get-ComputerRestorePoint)) {          Enable-ComputerRestore -Drive $Env:SystemDrive      }      Checkpoint-Computer -Description \"System Restore Point created by WinUtil\" -RestorePointType MODIFY_SETTINGS      Write-Host \"System Restore Point Created Successfully\" -ForegroundColor Green      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/restorepoint"
  },
  "WPFTweaksEndTaskOnTaskbar": {
    "Content": "右键结束任务 - 启用",
    "Description": "启用右键单击任务栏程序时结束任务的选项。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced\\TaskbarDeveloperSettings",
        "Name": "TaskbarEndTask",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/endtaskontaskbar"
  },
  "WPFTweaksStorage": {
    "Content": "存储感知 - 禁用",
    "Description": "存储感知会自动删除临时文件。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\StorageSense\\Parameters\\StoragePolicy",
        "Name": "01",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/storage"
  },
  "WPFTweaksWindowsAI": {
    "Content": "Windows AI - 禁用并移除",
    "Description": "移除并禁用所有 AI 功能/包。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "hide:aicomponents",
        "Type": "String",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\WindowsNotepad",
        "Name": "DisableAIFeatures",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "InvokeScript": [
      "      $Appx = (Get-AppxPackage MicrosoftWindows.Client.CoreAI).PackageFullName      $Sid = (Get-LocalUser $Env:UserName).Sid.Value      New-Item \"HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Appx\\AppxAllUserStore\\EndOfLife\\$Sid\\$Appx\" -Force      Get-AppxPackage -AllUsers \"*Copilot*\" | Remove-AppxPackage -AllUsers      winget uninstall -e --name \"Copilot\" --silent --force --accept-source-agreements 2>$null      Get-AppxPackage -AllUsers Microsoft.MicrosoftOfficeHub | Remove-AppxPackage -AllUsers      if ($Appx) {          Remove-AppxPackage $Appx      }      Set-Service -Name WSAIFabricSvc -StartupType Disabled      Disable-WindowsOptionalFeature -FeatureName Recall -Online -NoRestart      Write-Host \"Windows AI Disabled\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/windowsai"
  },
  "WPFTweaksWPBT": {
    "Content": "Windows 平台二进制表 (WPBT) - 禁用",
    "Description": "如果启用，WPBT 允许计算机供应商在启动时执行程序，存在潜在安全风险。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Session Manager",
        "Name": "DisableWpbtExecution",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/wpbt"
  },
  "WPFTweaksPreventDeviceMetadataFromNetwork": {
    "Content": "阻止设备配套应用",
    "Description": "防止插入设备时安装额外的软件。存在潜在安全风险。",
    "category": "基本优化",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Device Metadata",
        "Name": "PreventDeviceMetadataFromNetwork",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/preventdevicemetadatafromnetwork"
  },
  "WPFTweaksRazerBlock": {
    "Content": "雷蛇软件自动安装 - 禁用",
    "Description": "阻止所有雷蛇软件的安装。硬件无需任何软件即可正常工作。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\DriverSearching",
        "Name": "SearchOrderConfig",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Device Installer",
        "Name": "DisableCoInstallers",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "      $RazerPath = \"$Env:SystemRoot\\Installer\\Razer\"      if (Test-Path $RazerPath) {        Remove-Item $RazerPath\\* -Recurse -Force      } else {        New-Item -Path $RazerPath -ItemType Directory      }      icacls $RazerPath /deny \"Everyone:(W)\"      "
    ],
    "UndoScript": [
      "      icacls \"$Env:SystemRoot\\Installer\\Razer\" /remove:d Everyone      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/razerblock"
  },
  "WPFTweaksDisableNotifications": {
    "Content": "系统托盘通知和日历 - 禁用",
    "Description": "禁用所有通知，包括日历。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "DisableNotificationCenter",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\PushNotifications",
        "Name": "ToastEnabled",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablenotifications"
  },
  "WPFTweaksBlockAdobeNet": {
    "Content": "Adobe URL 阻止列表 - 启用",
    "Description": "通过选择性阻止 Adobe 连接来减少不必要的用户干扰",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "InvokeScript": [
      "      $hostsUrl = Invoke-RestMethod -Uri https://github.com/Ruddernation-Designs/Adobe-URL-Block-List/raw/refs/heads/master/hosts      Add-Content -Path \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" -Value $hostsUrl      ipconfig /flushdns      Write-Host 'Added Adobe url block list from host file'      "
    ],
    "UndoScript": [
      "      Set-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\" (          (Get-Content \"$Env:SystemRoot\\System32\\drivers\\etc\\hosts\") -join \"`n\" -replace '(?s)#New Ver.*', ''      )      ipconfig /flushdns      Write-Host 'Removed Adobe url block list from host file'      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/blockadobenet"
  },
  "WPFTweaksRightClickMenu": {
    "Content": "右键菜单旧版布局 - 启用",
    "Description": "恢复文件资源管理器中右键单击时的经典右键菜单。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "InvokeScript": [
      "      New-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Name InprocServer32 -Value \"\" -Force      Stop-Process -Name explorer      "
    ],
    "UndoScript": [
      "Remove-Item -Path \"HKCU:\\Software\\Classes\\CLSID\\{86ca1aa0-34aa-4e8b-a509-50c905bae2a2}\" -Recurse"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/rightclickmenu"
  },
  "WPFTweaksDiskCleanup": {
    "Content": "磁盘清理 - 运行",
    "Description": "在 C 盘运行磁盘清理并移除旧的 Windows 更新。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "      cleanmgr.exe /d C: /VERYLOWDISK      Dism.exe /online /Cleanup-Image /StartComponentCleanup /ResetBase      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/diskcleanup"
  },
  "WPFTweaksDeleteTempFiles": {
    "Content": "临时文件 - 移除",
    "Description": "清除临时文件夹。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "      Remove-Item -Path \"$Env:Temp\\*\" -Recurse -Force      Remove-Item -Path \"$Env:SystemRoot\\Temp\\*\" -Recurse -Force      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/deletetempfiles"
  },
  "WPFTweaksIPv46": {
    "Content": "IPv6 - 设置 IPv4 为首选",
    "Description": "在未配置 IPv6 的私有网络上设置 IPv4 首选项可带来延迟和安全方面的好处。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "32",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/ipv46"
  },
  "WPFTweaksTeredo": {
    "Content": "Teredo - 禁用",
    "Description": "Teredo 网络隧道是一种 IPv6 功能，可能导致额外延迟。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "netsh interface teredo set state disabled"
    ],
    "UndoScript": [
      "netsh interface teredo set state default"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/teredo"
  },
  "WPFTweaksDisableIPv6": {
    "Content": "IPv6 - 禁用",
    "Description": "禁用 IPv6。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Services\\Tcpip6\\Parameters",
        "Name": "DisabledComponents",
        "Value": "255",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "InvokeScript": [
      "Disable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "UndoScript": [
      "Enable-NetAdapterBinding -Name * -ComponentID ms_tcpip6"
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disableipv6"
  },
  "WPFTweaksDisableBGapps": {
    "Content": "后台应用 - 禁用",
    "Description": "禁用所有 Microsoft Store 应用在后台运行。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\BackgroundAccessApplications",
        "Name": "GlobalUserDisabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablebgapps"
  },
  "WPFTweaksDisableFSO": {
    "Content": "全屏优化 - 禁用",
    "Description": "禁用所有应用的全屏优化。注意：这将禁用独占全屏的色彩管理。",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "registry": [
      {
        "Path": "HKCU:\\System\\GameConfigStore",
        "Name": "GameDVR_DXGIHonorFSEWindowsCompatible",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/disablefso"
  },
  "WPFTweaksDisableExplorerAutoDiscovery": {
    "Content": "文件资源管理器自动文件夹发现 - 禁用",
    "Description": "Windows 资源管理器自动根据内容猜测文件夹类型。警告！将禁用文件资源管理器分组。",
    "category": "基本优化",
    "panel": "1",
    "InvokeScript": [
      "      # Previously detected folders      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"      # Folder types lookup table      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"      # Flush Explorer view database      Remove-Item -Path $bags -Recurse -Force      Write-Host \"Removed $bags\"      Remove-Item -Path $bagMRU -Recurse -Force      Write-Host \"Removed $bagMRU\"      # Every folder      $allFolders = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\\AllFolders\\Shell\"      if (!(Test-Path $allFolders)) {        New-Item -Path $allFolders -Force        Write-Host \"Created $allFolders\"      }      # Generic view      New-ItemProperty -Path $allFolders -Name \"FolderType\" -Value \"NotSpecified\" -PropertyType String -Force      Write-Host \"Set FolderType to NotSpecified\"      Write-Host Please sign out and back in, or restart your computer to apply the changes!      "
    ],
    "UndoScript": [
      "      # Previously detected folders      $bags = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\Bags\"      # Folder types lookup table      $bagMRU = \"HKCU:\\Software\\Classes\\Local Settings\\Software\\Microsoft\\Windows\\Shell\\BagMRU\"      # Flush Explorer view database      Remove-Item -Path $bags -Recurse -Force      Write-Host \"Removed $bags\"      Remove-Item -Path $bagMRU -Recurse -Force      Write-Host \"Removed $bagMRU\"      Write-Host Please sign out and back in, or restart your computer to apply the changes!      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/essential-tweaks/disableexplorerautodiscovery"
  },
  "WPFToggleDetailedBSoD": {
    "Content": "蓝屏详细模式",
    "Description": "蓝屏时提供更多信息。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisplayParameters",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\CrashControl",
        "Name": "DisableEmoticon",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/detailedbsod"
  },
  "WPFToggleBatteryPercentage": {
    "Content": "系统托盘电池百分比",
    "Description": "在系统托盘中电池图标旁显示数字电池百分比。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "IsBatteryPercentageEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/batterypercentage"
  },
  "WPFToggleDarkMode": {
    "Content": "Windows 深色主题",
    "Description": "系统和应用的深色模式。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "AppsUseLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
        "Name": "SystemUsesLightTheme",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "      Invoke-WinUtilExplorerUpdate      if ($sync.ThemeButton.Content -eq [char]0xF08C) {        Invoke-WinutilThemeChange -theme \"Auto\"      }      "
    ],
    "UndoScript": [
      "      Invoke-WinUtilExplorerUpdate      if ($sync.ThemeButton.Content -eq [char]0xF08C) {        Invoke-WinutilThemeChange -theme \"Auto\"      }      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/darkmode"
  },
  "WPFToggleShowExt": {
    "Content": "文件资源管理器文件扩展名",
    "Description": "在资源管理器中显示文件扩展名（.exe、.png 等）。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "HideFileExt",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "UndoScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/showext"
  },
  "WPFToggleHiddenFiles": {
    "Content": "文件资源管理器隐藏文件",
    "Description": "在资源管理器中显示隐藏文件。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "Hidden",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "InvokeScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "UndoScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hiddenfiles"
  },
  "WPFToggleVerboseLogon": {
    "Content": "登录详细模式",
    "Description": "在启动/关机时显示详细信息。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Policies\\System",
        "Name": "VerboseStatus",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/verboselogon"
  },
  "WPFToggleNewOutlook": {
    "Content": "Microsoft Outlook 新版",
    "Description": "这将确保使用经典 Outlook 应用程序。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "UseNewOutlook",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "HideNewOutlookToggle",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Options\\General",
        "Name": "DoNewOutlookAutoMigration",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Software\\Policies\\Microsoft\\Office\\16.0\\Outlook\\Preferences",
        "Name": "NewOutlookMigrationUserSetting",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/newoutlook"
  },
  "WPFToggleScrollbars": {
    "Content": "滚动条始终可见",
    "Description": "如果启用，滚动条将始终可见。如果禁用，Windows 将自动隐藏不使用的滚动条。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility",
        "Name": "DynamicScrollbars",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "false",
        "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/scrollbars"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/scrollbars"
  },
  "WPFToggleMultiplaneOverlay": {
    "Content": "多平面覆盖",
    "Description": "多平面覆盖合成多个图像层，有时可能导致显卡问题。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\Windows\\Dwm",
        "Name": "OverlayTestMode",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "5",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\GraphicsDrivers",
        "Name": "DisableOverlays",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/multiplaneoverlay"
  },
  "WPFToggleMouseAcceleration": {
    "Content": "鼠标加速",
    "Description": "使光标移动受物理鼠标移动速度的影响。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseSpeed",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold1",
        "Value": "6",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Control Panel\\Mouse",
        "Name": "MouseThreshold2",
        "Value": "10",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/mouseacceleration"
  },
  "WPFToggleNumLock": {
    "Content": "开机 Num Lock 键状态",
    "Description": "在计算机启动时切换 Num Lock 键状态。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKU:\\.Default\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      },
      {
        "Path": "HKCU:\\Control Panel\\Keyboard",
        "Name": "InitialKeyboardIndicators",
        "Value": "2",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/numlock"
  },
  "WPFToggleWindowSnapping": {
    "Content": "窗口贴靠",
    "Description": "切换拖动窗口时的窗口贴靠功能。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Desktop",
        "Name": "WindowArrangementActive",
        "Value": "1",
        "Type": "String",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/windowsnapping"
  },
  "WPFToggleStandbyFix": {
    "Content": "S0 睡眠网络连接",
    "Description": "切换现代笔记本电脑低功耗空闲 (S0 睡眠) 期间的网络连接。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\SOFTWARE\\Policies\\Microsoft\\Power\\PowerSettings\\f15576e8-98b7-4186-b944-eafa664402d9",
        "Name": "ACSettingIndex",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/standbyfix"
  },
  "WPFToggleS3Sleep": {
    "Content": "S3 休眠",
    "Description": "在现代待机和 S3 休眠之间切换。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\Power",
        "Name": "PlatformAoAcOverride",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/s3sleep"
  },
  "WPFToggleHideSettingsHome": {
    "Content": "设置主页",
    "Description": "切换 Windows 设置应用中的主页。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\Explorer",
        "Name": "SettingsPageVisibility",
        "Value": "show:home",
        "Type": "String",
        "OriginalValue": "hide:home",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/hidesettingshome"
  },
  "WPFToggleBingSearch": {
    "Content": "开始菜单必应搜索",
    "Description": "切换 Windows 搜索中的必应网页搜索结果。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "BingSearchEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/bingsearch"
  },
  "WPFToggleLoginBlur": {
    "Content": "登录屏幕亚克力模糊",
    "Description": "切换登录屏幕背景上的亚克力模糊效果。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\System",
        "Name": "DisableAcrylicBackgroundOnLogon",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/loginblur"
  },
  "WPFTweaksDisableLockscreen": {
    "Content": "锁定屏幕 - 禁用",
    "Description": "完全跳过锁定屏幕，在启动和唤醒时直接进入登录屏幕。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Personalization",
        "Name": "NoLockScreen",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "<RemoveEntry>"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/disablelockscreen"
  },
  "WPFToggleStartMenuRecommendations": {
    "Content": "开始菜单推荐",
    "Description": "切换开始菜单中的推荐部分。警告：这也会同时禁用锁屏上的 Windows 聚焦。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Start",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Microsoft\\PolicyManager\\current\\device\\Education",
        "Name": "IsEducationEnvironment",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      },
      {
        "Path": "HKLM:\\SOFTWARE\\Policies\\Microsoft\\Windows\\Explorer",
        "Name": "HideRecommendedSection",
        "Value": "0",
        "Type": "DWord",
        "OriginalValue": "1",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "UndoScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/startmenurecommendations"
  },
  "WPFToggleStickyKeys": {
    "Content": "粘滞键",
    "Description": "切换粘滞键功能，该功能在快速点击 Shift 键时激活。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Control Panel\\Accessibility\\StickyKeys",
        "Name": "Flags",
        "Value": "506",
        "Type": "DWord",
        "OriginalValue": "58",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/stickykeys"
  },
  "WPFToggleTaskbarAlignment": {
    "Content": "任务栏居中图标",
    "Description": "切换任务栏图标左对齐或居中。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "TaskbarAl",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "InvokeScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "UndoScript": [
      "      Invoke-WinUtilExplorerUpdate -action \"restart\"      "
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbaralignment"
  },
  "WPFToggleTaskbarSearch": {
    "Content": "任务栏搜索图标",
    "Description": "切换任务栏上的搜索按钮。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Search",
        "Name": "SearchboxTaskbarMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskbarsearch"
  },
  "WPFToggleTaskView": {
    "Content": "任务栏任务视图图标",
    "Description": "切换任务栏中的任务视图按钮。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\Windows\\CurrentVersion\\Explorer\\Advanced",
        "Name": "ShowTaskViewButton",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/taskview"
  },
  "WPFToggleGameMode": {
    "Content": "游戏模式",
    "Description": "切换 Windows 通过分配系统资源给游戏来优先考虑游戏性能。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AllowAutoGameMode",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      },
      {
        "Path": "HKCU:\\Software\\Microsoft\\GameBar",
        "Name": "AutoGameModeEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "true"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/gamemode"
  },
  "WPFToggleLongPaths": {
    "Content": "启用长路径",
    "Description": "切换资源管理器中超过 260 个字符的文件路径支持。",
    "category": "自定义偏好",
    "panel": "2",
    "Type": "Toggle",
    "registry": [
      {
        "Path": "HKLM:\\SYSTEM\\CurrentControlSet\\Control\\FileSystem",
        "Name": "LongPathsEnabled",
        "Value": "1",
        "Type": "DWord",
        "OriginalValue": "0",
        "DefaultState": "false"
      }
    ],
    "link": "https://winutil.christitus.com/dev/tweaks/customize-preferences/longpaths"
  },
  "WPFOOSUbutton": {
    "Content": "O&O ShutUp10++ - 运行",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "Type": "Button",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/oosubutton"
  },
  "WPFchangedns": {
    "Content": "DNS - 设置为：",
    "category": "高级优化 - 谨慎操作",
    "panel": "1",
    "Type": "Combobox",
    "ComboItems": "Default DHCP Google Cloudflare Cloudflare_Malware Cloudflare_Malware_Adult Open_DNS Quad9 AdGuard_Ads_Trackers AdGuard_Ads_Trackers_Malware_Adult",
    "link": "https://winutil.christitus.com/dev/tweaks/z--advanced-tweaks---caution/changedns"
  },
  "WPFAddUltPerf": {
    "Content": "卓越性能方案 - 启用",
    "category": "性能计划 - 不适用于笔记本电脑",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans---not-for-laptops/addultperf"
  },
  "WPFRemoveUltPerf": {
    "Content": "卓越性能方案 - 禁用",
    "category": "性能计划 - 不适用于笔记本电脑",
    "panel": "2",
    "Type": "Button",
    "ButtonWidth": "300",
    "link": "https://winutil.christitus.com/dev/tweaks/performance-plans---not-for-laptops/removeultperf"
  }
}
'@ | ConvertFrom-Json


$inputXML = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String('PFdpbmRvdwogICAgICAgIHhtbG5zPSJodHRwOi8vc2NoZW1hcy5taWNyb3NvZnQuY29tL3dpbmZ4LzIwMDYveGFtbC9wcmVzZW50YXRpb24iCiAgICAgICAgeG1sbnM6eD0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS93aW5meC8yMDA2L3hhbWwiCiAgICAgICAgeG1sbnM6ZD0iaHR0cDovL3NjaGVtYXMubWljcm9zb2Z0LmNvbS9leHByZXNzaW9uL2JsZW5kLzIwMDgiCiAgICAgICAgeG1sbnM6bWM9Imh0dHA6Ly9zY2hlbWFzLm9wZW54bWxmb3JtYXRzLm9yZy9tYXJrdXAtY29tcGF0aWJpbGl0eS8yMDA2IgogICAgICAgIHhtbG5zOmxvY2FsPSJjbHItbmFtZXNwYWNlOldpblV0aWxpdHkiCiAgICAgICAgV2luZG93U3RhcnR1cExvY2F0aW9uPSJDZW50ZXJTY3JlZW4iCiAgICAgICAgVXNlTGF5b3V0Um91bmRpbmc9IlRydWUiCiAgICAgICAgV2luZG93U3R5bGU9IlNpbmdsZUJvcmRlcldpbmRvdyIKICAgICAgICBXaWR0aD0iQXV0byIKICAgICAgICBIZWlnaHQ9IkF1dG8iCiAgICAgICAgTWluV2lkdGg9IjgwMCIKICAgICAgICBNaW5IZWlnaHQ9IjYwMCIKICAgICAgICBUaXRsZT0iV2luVXRpbCI+CiAgICA8V2luZG93Q2hyb21lLldpbmRvd0Nocm9tZT4KICAgICAgICA8V2luZG93Q2hyb21lIENhcHRpb25IZWlnaHQ9IjAiIENvcm5lclJhZGl1cz0iMTAiLz4KICAgIDwvV2luZG93Q2hyb21lLldpbmRvd0Nocm9tZT4KICAgIDxXaW5kb3cuUmVzb3VyY2VzPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IlRvb2xUaXAiPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvb2xUaXBCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJCcnVzaCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWF4V2lkdGgiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvb2xUaXBXaWR0aH0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8IS0tIFRoaXMgQ29udGVudFRlbXBsYXRlIGVuc3VyZXMgdGhhdCB0aGUgY29udGVudCBvZiB0aGUgVG9vbFRpcCB3cmFwcyB0ZXh0IHByb3Blcmx5IGZvciBiZXR0ZXIgcmVhZGFiaWxpdHkgLS0+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ29udGVudFRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgQ29udGVudD0ie1RlbXBsYXRlQmluZGluZyBDb250ZW50fSI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyLlJlc291cmNlcz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJUZXh0QmxvY2siPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRleHRXcmFwcGluZyIgVmFsdWU9IldyYXAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udGVudFByZXNlbnRlci5SZXNvdXJjZXM+CiAgICAgICAgICAgICAgICAgICAgPC9Db250ZW50UHJlc2VudGVyPgogICAgICAgICAgICAgICAgPC9EYXRhVGVtcGxhdGU+CiAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgIDwvU2V0dGVyPgogICAgPC9TdHlsZT4KCiAgICA8U3R5bGUgVGFyZ2V0VHlwZT0ie3g6VHlwZSBNZW51SXRlbX0iPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iNSwyLDUsMiIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlclRoaWNrbmVzcyIgVmFsdWU9IjAiLz4KICAgIDwvU3R5bGU+CgogICAgPCEtLVNjcm9sbGJhciBUaHVtYnMtLT4KICAgIDxTdHlsZSB4OktleT0iU2Nyb2xsVGh1bWJzIiBUYXJnZXRUeXBlPSJ7eDpUeXBlIFRodW1ifSI+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJ7eDpUeXBlIFRodW1ifSI+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iR3JpZCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSZWN0YW5nbGUgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iIEZpbGw9IlRyYW5zcGFyZW50IiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IlJlY3RhbmdsZTEiIENvcm5lclJhZGl1cz0iNSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IiAvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iVGFnIiBWYWx1ZT0iSG9yaXpvbnRhbCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlJlY3RhbmdsZTEiIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlJlY3RhbmdsZTEiIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSI3IiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgoKICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJUZXh0QmxvY2siIHg6S2V5PSJIb3ZlclRleHRCbG9ja1N0eWxlIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMaW5rRm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RGVjb3JhdGlvbnMiIFZhbHVlPSJVbmRlcmxpbmUiIC8+CiAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExpbmtIb3ZlckZvcmVncm91bmRDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RGVjb3JhdGlvbnMiIFZhbHVlPSJVbmRlcmxpbmUiIC8+CiAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgIDwvU3R5bGU+CiAgICA8U3R5bGUgeDpLZXk9IkFwcEVudHJ5Qm9yZGVyU3R5bGUiIFRhcmdldFR5cGU9IkJvcmRlciI+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJHcmF5Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyVGhpY2tuZXNzIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeUJvcmRlclRoaWNrbmVzc30iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb3JuZXJSYWRpdXMiIFZhbHVlPSI1Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjYsNCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IldpZHRoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeVdpZHRofSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQWxpZ25tZW50IiBWYWx1ZT0iVG9wIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBBcHBFbnRyeU1hcmdpbn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQXBwSW5zdGFsbFVuc2VsZWN0ZWRDb2xvcn0iLz4KICAgIDwvU3R5bGU+CiAgICA8U3R5bGUgeDpLZXk9IkFwcEVudHJ5Q2hlY2tib3hTdHlsZSIgVGFyZ2V0VHlwZT0iQ2hlY2tCb3giPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ikhvcml6b250YWxBbGlnbm1lbnQiIFZhbHVlPSJMZWZ0Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQ2hlY2tCb3giPgogICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyIENvbnRlbnQ9IntUZW1wbGF0ZUJpbmRpbmcgQ29udGVudH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0Ii8+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgogICAgPFN0eWxlIHg6S2V5PSJBcHBFbnRyeU5hbWVTdHlsZSIgVGFyZ2V0VHlwZT0iVGV4dEJsb2NrIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQXBwRW50cnlGb250U2l6ZX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250V2VpZ2h0IiBWYWx1ZT0iQm9sZCIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgPC9TdHlsZT4KICAgIDxTdHlsZSB4OktleT0iQXBwRW50cnlCdXR0b25TdHlsZSIgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSGVpZ2h0IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBJY29uQnV0dG9uU2l6ZX0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEFwcEVudHJ5TWFyZ2lufSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IkNlbnRlciIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQWxpZ25tZW50IiBWYWx1ZT0iQ2VudGVyIi8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ29udGVudFRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayAgVGV4dD0ie0JpbmRpbmd9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRGYW1pbHk9IlNlZ29lIE1ETDIgQXNzZXRzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgICAgIDwvRGF0YVRlbXBsYXRlPgogICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICA8L1NldHRlcj4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IkJhY2tncm91bmRCb3JkZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJvcmRlclRoaWNrbmVzc30iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29udGVudFByZXNlbnRlciBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNQcmVzc2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZFByZXNzZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkN1cnNvciIgVmFsdWU9IkhhbmQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iRmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRTZWxlY3RlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJEaW1HcmF5Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgoKCiAgICA8L1N0eWxlPgogICAgPFN0eWxlIFRhcmdldFR5cGU9IkJ1dHRvbiIgeDpLZXk9IkhvdmVyQnV0dG9uU3R5bGUiPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRXZWlnaHQiIFZhbHVlPSJOb3JtYWwiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZXh0RWxlbWVudC5Gb250RmFtaWx5IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250RmFtaWx5fSIvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iPgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udGVudFByZXNlbnRlciBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiLz4KICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRXZWlnaHQiIFZhbHVlPSJCb2xkIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgPC9TZXR0ZXI+CiAgICA8L1N0eWxlPgoKICAgIDwhLS1TY3JvbGxCYXJzLS0+CiAgICA8U3R5bGUgeDpLZXk9Int4OlR5cGUgU2Nyb2xsQmFyfSIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBTY3JvbGxCYXJ9Ij4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJTdHlsdXMuSXNGbGlja3NFbmFibGVkIiBWYWx1ZT0iZmFsc2UiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgU2Nyb2xsQmFyQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IjYiIC8+CiAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJ7eDpUeXBlIFNjcm9sbEJhcn0iPgogICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9IkdyaWRSb290IiBXaWR0aD0iNyIgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIgPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iMC4wMDAwMSoiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxUcmFjayBOYW1lPSJQQVJUX1RyYWNrIiBHcmlkLlJvdz0iMCIgSXNEaXJlY3Rpb25SZXZlcnNlZD0idHJ1ZSIgRm9jdXNhYmxlPSJmYWxzZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJhY2suVGh1bWI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRodW1iIE5hbWU9IlRodW1iIiBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IiBTdHlsZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxUaHVtYnN9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmFjay5UaHVtYj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmFjay5JbmNyZWFzZVJlcGVhdEJ1dHRvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UmVwZWF0QnV0dG9uIE5hbWU9IlBhZ2VVcCIgQ29tbWFuZD0iU2Nyb2xsQmFyLlBhZ2VEb3duQ29tbWFuZCIgT3BhY2l0eT0iMCIgRm9jdXNhYmxlPSJmYWxzZSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJhY2suSW5jcmVhc2VSZXBlYXRCdXR0b24+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJhY2suRGVjcmVhc2VSZXBlYXRCdXR0b24+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJlcGVhdEJ1dHRvbiBOYW1lPSJQYWdlRG93biIgQ29tbWFuZD0iU2Nyb2xsQmFyLlBhZ2VVcENvbW1hbmQiIE9wYWNpdHk9IjAiIEZvY3VzYWJsZT0iZmFsc2UiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyYWNrLkRlY3JlYXNlUmVwZWF0QnV0dG9uPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyYWNrPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgU291cmNlTmFtZT0iVGh1bWIiIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9InRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxCYXJIb3ZlckNvbG9yfSIgVGFyZ2V0TmFtZT0iVGh1bWIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFNvdXJjZU5hbWU9IlRodW1iIiBQcm9wZXJ0eT0iSXNEcmFnZ2luZyIgVmFsdWU9InRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTY3JvbGxCYXJEcmFnZ2luZ0NvbG9yfSIgVGFyZ2V0TmFtZT0iVGh1bWIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iZmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUaHVtYiIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJDb2xsYXBzZWQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9Ik9yaWVudGF0aW9uIiBWYWx1ZT0iSG9yaXpvbnRhbCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkdyaWRSb290IiBQcm9wZXJ0eT0iTGF5b3V0VHJhbnNmb3JtIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um90YXRlVHJhbnNmb3JtIEFuZ2xlPSItOTAiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iUEFSVF9UcmFjayIgUHJvcGVydHk9IkxheW91dFRyYW5zZm9ybSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvdGF0ZVRyYW5zZm9ybSBBbmdsZT0iLTkwIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSI4IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUaHVtYiIgUHJvcGVydHk9IlRhZyIgVmFsdWU9Ikhvcml6b250YWwiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlBhZ2VEb3duIiBQcm9wZXJ0eT0iQ29tbWFuZCIgVmFsdWU9IlNjcm9sbEJhci5QYWdlTGVmdENvbW1hbmQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IlBhZ2VVcCIgUHJvcGVydHk9IkNvbW1hbmQiIFZhbHVlPSJTY3JvbGxCYXIuUGFnZVJpZ2h0Q29tbWFuZCIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CiAgICAgICAgPFN0eWxlIHg6S2V5PSJDb21ib0JveFRvZ2dsZUJ1dHRvblN0eWxlIiBUYXJnZXRUeXBlPSJUb2dnbGVCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iVG9nZ2xlQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IiBCb3JkZXJUaGlja25lc3M9IjAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJDb21ib0JveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIENvbWJvQm94Rm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQ29tYm9Cb3hCYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNaW5XaWR0aCIgICBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIC8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJDb21ib0JveCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJPdXRlckJvcmRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uIE5hbWU9IlRvZ2dsZUJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgQ29tYm9Cb3hUb2dnbGVCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIElzQ2hlY2tlZD0ie0JpbmRpbmcgSXNEcm9wRG93bk9wZW4sIE1vZGU9VHdvV2F5LCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgVGVtcGxhdGVkUGFyZW50fX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDbGlja01vZGU9IlByZXNzIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSJ7VGVtcGxhdGVCaW5kaW5nIFNlbGVjdGlvbkJveEl0ZW19IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI2LDMsMiwzIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UGF0aCBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIERhdGE9Ik0gMCwwIEwgOCwwIEwgNCw1IFoiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7VGVtcGxhdGVCaW5kaW5nIEZvcmVncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IjgiIEhlaWdodD0iNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdHJldGNoPSJVbmlmb3JtIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI0LDAsNiwwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFBvcHVwIE5hbWU9IlBvcHVwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIElzT3Blbj0ie1RlbXBsYXRlQmluZGluZyBJc0Ryb3BEb3duT3Blbn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUGxhY2VtZW50PSJCb3R0b20iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9jdXNhYmxlPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBBbGxvd3NUcmFuc3BhcmVuY3k9IlRydWUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUG9wdXBBbmltYXRpb249IlNsaWRlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIE5hbWU9IkRyb3BEb3duQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0iNCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8SXRlbXNQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgTWFyZ2luPSI0LDIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TY3JvbGxWaWV3ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1BvcHVwPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQ29tYm9Cb3hJdGVtIj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQ29tYm9Cb3hCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIENvbWJvQm94Rm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJQYWRkaW5nIiBWYWx1ZT0iNiwzIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnRUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxEYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0ie0JpbmRpbmd9IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7QmluZGluZyBGb3JlZ3JvdW5kLCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgQW5jZXN0b3JUeXBlPUNvbWJvQm94SXRlbX19Ii8+CiAgICAgICAgICAgICAgICAgICAgPC9EYXRhVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0hpZ2hsaWdodGVkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIvPgogICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzU2VsZWN0ZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJMYWJlbCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExhYmVsYm94Rm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMYWJlbEJhY2tncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8IS0tIFRleHRCbG9jayB0ZW1wbGF0ZSAtLT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iVGV4dEJsb2NrIj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBMYWJlbGJveEZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTGFiZWxCYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgeDpLZXk9IlRhYlRvZ2dsZUJ1dHRvbiIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBUb2dnbGVCdXR0b259Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25NYXJnaW59Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IlRvZ2dsZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCdXR0b25HbG93IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwyLDEwLDIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJFZmZlY3QiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgT3BhY2l0eT0iMSIgU2hhZG93RGVwdGg9IjUiIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9IiBEaXJlY3Rpb249Ii0xMDAiIEJsdXJSYWRpdXM9IjE1Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhbmVsLlpJbmRleCIgVmFsdWU9IjIwMDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJCcnVzaCIgVmFsdWU9IlBpbmsiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZFNlbGVjdGVkQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEcm9wU2hhZG93RWZmZWN0IE9wYWNpdHk9IjEiIFNoYWRvd0RlcHRoPSIyIiBDb2xvcj0ie0R5bmFtaWNSZXNvdXJjZSBDQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIgRGlyZWN0aW9uPSItMTExIiBCbHVyUmFkaXVzPSIxMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJGYWxzZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlclRoaWNrbmVzcyIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQm9yZGVyVGhpY2tuZXNzfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDwhLS0gQnV0dG9uIFRlbXBsYXRlIC0tPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbk1hcmdpbn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkhlaWdodCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29ybmVyUmFkaXVzfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIiBNYXJnaW49IjEwLDIsMTAsMiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc1ByZXNzZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzTW91c2VPdmVyIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIiBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQmFja2dyb3VuZE1vdXNlb3ZlckNvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzRW5hYmxlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iRGltR3JheSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9IlRvZ2dsZUJ1dHRvblN0eWxlIiBUYXJnZXRUeXBlPSJUb2dnbGVCdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJNYXJnaW4iIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbk1hcmdpbn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkhlaWdodCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IlRvZ2dsZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCYWNrZ3JvdW5kQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29ybmVyUmFkaXVzfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVG9nZ2xlIERvdCBCYWNrZ3JvdW5kIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RWxsaXBzZSBXaWR0aD0iOCIgSGVpZ2h0PSIxNiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJUb3AiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDMsNSwwIiAvPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBUb2dnbGUgRG90IHdpdGggaG92ZXIgZ3JvdyBlZmZlY3QgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxFbGxpcHNlIE5hbWU9IlRvZ2dsZURvdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iOCIgSGVpZ2h0PSI4IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZpbGw9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwzLDUsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBSZW5kZXJUcmFuc2Zvcm1PcmlnaW49IjAuNSwwLjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UuUmVuZGVyVHJhbnNmb3JtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY2FsZVRyYW5zZm9ybSBTY2FsZVg9IjEiIFNjYWxlWT0iMSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlLlJlbmRlclRyYW5zZm9ybT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBDb250ZW50IFByZXNlbnRlciAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMTAsMiwxMCwyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVHJpZ2dlcnMgZm9yIFRvZ2dsZUJ1dHRvbiBzdGF0ZXMgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEhvdmVyIGVmZmVjdCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQmFja2dyb3VuZEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRNb3VzZW92ZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEFuaW1hdGlvbiB0byBncm93IHRoZSBkb3Qgd2hlbiBob3ZlcmVkIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJUb2dnbGVEb3QiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0b3J5Ym9hcmQuVGFyZ2V0UHJvcGVydHk9IihVSUVsZW1lbnQuUmVuZGVyVHJhbnNmb3JtKS4oU2NhbGVUcmFuc2Zvcm0uU2NhbGVYKSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVG89IjEuMiIgRHVyYXRpb249IjA6MDowLjEiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWSkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjIiIER1cmF0aW9uPSIwOjA6MC4xIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEFuaW1hdGlvbiB0byBzaHJpbmsgdGhlIGRvdCBiYWNrIHRvIG9yaWdpbmFsIHNpemUgd2hlbiBub3QgaG92ZXJlZCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWCkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERvdWJsZUFuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IlRvZ2dsZURvdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVkpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4wIiBEdXJhdGlvbj0iMDowOjAuMSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBJc0NoZWNrZWQgc3RhdGUgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJUb2dnbGVEb3QiIFByb3BlcnR5PSJWZXJ0aWNhbEFsaWdubWVudCIgVmFsdWU9IkJvdHRvbSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iVG9nZ2xlRG90IiBQcm9wZXJ0eT0iTWFyZ2luIiBWYWx1ZT0iMCwwLDUsMyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gSXNFbmFibGVkIHN0YXRlIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzRW5hYmxlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJhY2tncm91bmRCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0iRGltR3JheSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9IlNlYXJjaEJhckNsZWFyQnV0dG9uU3R5bGUiIFRhcmdldFR5cGU9IkJ1dHRvbiI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRGYW1pbHkiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRGYW1pbHl9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJDbGVhckJ1dHRvbkZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb250ZW50IiBWYWx1ZT0iWCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJIZWlnaHQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFNlYXJjaEJhckNsZWFyQnV0dG9uRm9udFNpemV9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IldpZHRoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJDbGVhckJ1dHRvbkZvbnRTaXplfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjAiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIwIi8+CiAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc01vdXNlT3ZlciIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJSZWQiLz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0iVHJhbnNwYXJlbnQiLz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxMCIvPgogICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkN1cnNvciIgVmFsdWU9IkhhbmQiLz4KICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDwhLS0gQ2hlY2tib3ggdGVtcGxhdGUgLS0+CiAgICAgICAgPFN0eWxlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQmFja2dyb3VuZCIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udFNpemUiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGV4dEVsZW1lbnQuRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnVsbGV0RGVjb3JhdG9yIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnVsbGV0RGVjb3JhdG9yLkJ1bGxldD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZX0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJCb3JkZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZSAqMC44NX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBDaGVja0JveEJ1bGxldERlY29yYXRvclNpemUgKjAuODV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFNuYXBzVG9EZXZpY2VQaXhlbHM9IlRydWUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxWaWV3Ym94IE5hbWU9IkNoZWNrTWFya0NvbnRhaW5lciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94QnVsbGV0RGVjb3JhdG9yU2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UGF0aCBOYW1lPSJDaGVja01hcmsiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0cm9rZVRoaWNrbmVzcz0iMS41IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIERhdGE9Ik0gMCA1IEwgNSAxMCBMIDEyIDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3RyZXRjaD0iVW5pZm9ybSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9WaWV3Ym94PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CdWxsZXREZWNvcmF0b3IuQnVsbGV0PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250ZW50UHJlc2VudGVyIE1hcmdpbj0iNCwwLDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVjb2duaXplc0FjY2Vzc0tleT0iVHJ1ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CdWxsZXREZWNvcmF0b3I+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkNoZWNrTWFya0NvbnRhaW5lciIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tU2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRQcmVzc2VkQ29sb3J9Ii8tLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kUHJlc3NlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iUmFkaW9CdXR0b24iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb3JlZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250U2l6ZSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJGb250RmFtaWx5IiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250RmFtaWx5fSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iUmFkaW9CdXR0b24iPgogICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIENoZWNrQm94TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Vmlld2JveCBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBDaGVja0JveEJ1bGxldERlY29yYXRvclNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQ2hlY2tCb3hCdWxsZXREZWNvcmF0b3JTaXplfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgV2lkdGg9IjE0IiBIZWlnaHQ9IjE0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iT3V0ZXJDaXJjbGUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9mZkNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGaWxsPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Ryb2tlVGhpY2tuZXNzPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSIxNCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjE0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFNuYXBzVG9EZXZpY2VQaXhlbHM9IlRydWUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iSW5uZXJDaXJjbGUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRmlsbD0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PbkNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iOCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjgiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9WaWV3Ym94PgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgTWFyZ2luPSI0LDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVjb2duaXplc0FjY2Vzc0tleT0iVHJ1ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJJbm5lckNpcmNsZSIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9Ik91dGVyQ2lyY2xlIiBQcm9wZXJ0eT0iU3Ryb2tlIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PbkNvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSB4OktleT0iVG9nZ2xlU3dpdGNoU3R5bGUiIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVGVtcGxhdGUiPgogICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlIFRhcmdldFR5cGU9IkNoZWNrQm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIFdpZHRoPSI0NSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0iMjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSIjNTU1NTU1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29ybmVyUmFkaXVzPSIxMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iNSwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iMjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IjI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0iQmxhY2siCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IjEyLjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgTmFtZT0iV1BGVG9nZ2xlU3dpdGNoQ29udGVudCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjEwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IntUZW1wbGF0ZUJpbmRpbmcgQ29udGVudH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNDaGVja2VkIiBWYWx1ZT0iZmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UmVtb3ZlU3Rvcnlib2FyZCBCZWdpblN0b3J5Ym9hcmROYW1lPSJXUEZUb2dnbGVTd2l0Y2hMZWZ0IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkIE5hbWU9IldQRlRvZ2dsZVN3aXRjaFJpZ2h0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUaGlja25lc3NBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iTWFyZ2luIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBEdXJhdGlvbj0iMDowOjA6MCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZyb209IjAsMCwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMjgsMCwwLDAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGhpY2tuZXNzQW5pbWF0aW9uPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBUYXJnZXROYW1lPSJXUEZUb2dnbGVTd2l0Y2hCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQcm9wZXJ0eT0iQmFja2dyb3VuZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZhbHVlPSIjZmZmOWY0ZjQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyIFByb3BlcnR5PSJJc0NoZWNrZWQiIFZhbHVlPSJ0cnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJlbW92ZVN0b3J5Ym9hcmQgQmVnaW5TdG9yeWJvYXJkTmFtZT0iV1BGVG9nZ2xlU3dpdGNoUmlnaHQiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQgTmFtZT0iV1BGVG9nZ2xlU3dpdGNoTGVmdCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGhpY2tuZXNzQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0UHJvcGVydHk9Ik1hcmdpbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iV1BGVG9nZ2xlU3dpdGNoQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRHVyYXRpb249IjA6MDowOjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGcm9tPSIyOCwwLDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIwLDAsMCwwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RoaWNrbmVzc0FuaW1hdGlvbj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iV1BGVG9nZ2xlU3dpdGNoQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUHJvcGVydHk9IkJhY2tncm91bmQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWYWx1ZT0iI2ZmMDYwNjAwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CgogICAgICAgIDxTdHlsZSB4OktleT0iQ29sb3JmdWxUb2dnbGVTd2l0Y2hTdHlsZSIgVGFyZ2V0VHlwZT0ie3g6VHlwZSBDaGVja0JveH0iPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0ie3g6VHlwZSBUb2dnbGVCdXR0b259Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0idG9nZ2xlU3dpdGNoIj4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW49IjEiIE5hbWU9IkJvcmRlciIgQ29ybmVyUmFkaXVzPSI4IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iMzQiIEhlaWdodD0iMTciPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UgTmFtZT0iRWxsaXBzZSIgRmlsbD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgU3RyZXRjaD0iVW5pZm9ybSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIyLDIsMiwxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBXaWR0aD0iMTAuOCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUmVuZGVyVHJhbnNmb3JtT3JpZ2luPSIwLjUsIDAuNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEVsbGlwc2UuUmVuZGVyVHJhbnNmb3JtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2NhbGVUcmFuc2Zvcm0gU2NhbGVYPSIxIiBTY2FsZVk9IjEiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9FbGxpcHNlLlJlbmRlclRyYW5zZm9ybT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvRWxsaXBzZT4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIExpbmtIb3ZlckZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDdXJzb3IiIFZhbHVlPSJIYW5kIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhbmVsLlpJbmRleCIgVmFsdWU9IjEwMDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FbnRlckFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iRWxsaXBzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVgpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4xIiBEdXJhdGlvbj0iMDowOjAuMSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8RG91YmxlQW5pbWF0aW9uIFN0b3J5Ym9hcmQuVGFyZ2V0TmFtZT0iRWxsaXBzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3Rvcnlib2FyZC5UYXJnZXRQcm9wZXJ0eT0iKFVJRWxlbWVudC5SZW5kZXJUcmFuc2Zvcm0pLihTY2FsZVRyYW5zZm9ybS5TY2FsZVkpIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMS4xIiBEdXJhdGlvbj0iMDowOjAuMSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9CZWdpblN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UcmlnZ2VyLkVudGVyQWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJFbGxpcHNlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWCkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxEb3VibGVBbmltYXRpb24gU3Rvcnlib2FyZC5UYXJnZXROYW1lPSJFbGxpcHNlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSIoVUlFbGVtZW50LlJlbmRlclRyYW5zZm9ybSkuKFNjYWxlVHJhbnNmb3JtLlNjYWxlWSkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvPSIxLjAiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRXhpdEFjdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iVG9nZ2xlQnV0dG9uLklzQ2hlY2tlZCIgVmFsdWU9IkZhbHNlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQm9yZGVyIiBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9mZkNvbG9yfSIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkVsbGlwc2UiIFByb3BlcnR5PSJGaWxsIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBUb2dnbGVCdXR0b25PZmZDb2xvcn0iIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IlRvZ2dsZUJ1dHRvbi5Jc0NoZWNrZWQiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQm9yZGVyIiBQcm9wZXJ0eT0iQm9yZGVyQnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIFRvZ2dsZUJ1dHRvbk9uQ29sb3J9IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iRWxsaXBzZSIgUHJvcGVydHk9IkZpbGwiIFZhbHVlPSJXaGl0ZSIgLz4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIuRW50ZXJBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRoaWNrbmVzc0FuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IkVsbGlwc2UiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSJNYXJnaW4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMTgsMiwyLDIiIER1cmF0aW9uPSIwOjA6MC4xIiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JlZ2luU3Rvcnlib2FyZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXIuRW50ZXJBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUcmlnZ2VyLkV4aXRBY3Rpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRoaWNrbmVzc0FuaW1hdGlvbiBTdG9yeWJvYXJkLlRhcmdldE5hbWU9IkVsbGlwc2UiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdG9yeWJvYXJkLlRhcmdldFByb3BlcnR5PSJNYXJnaW4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUbz0iMiwyLDIsMSIgRHVyYXRpb249IjA6MDowLjEiIC8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0b3J5Ym9hcmQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQmVnaW5TdG9yeWJvYXJkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlci5FeGl0QWN0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVHJpZ2dlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGUuVHJpZ2dlcnM+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZlcnRpY2FsQ29udGVudEFsaWdubWVudCIgVmFsdWU9IkNlbnRlciIgLz4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgeDpLZXk9ImxhYmVsZm9ydHdlYWtzIiBUYXJnZXRUeXBlPSJ7eDpUeXBlIExhYmVsfSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiAvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzTW91c2VPdmVyIiBWYWx1ZT0iVHJ1ZSI+CiAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9yZWdyb3VuZCIgVmFsdWU9IldoaXRlIiAvPgogICAgICAgICAgICAgICAgPC9UcmlnZ2VyPgogICAgICAgICAgICA8L1N0eWxlLlRyaWdnZXJzPgogICAgICAgIDwvU3R5bGU+CgogICAgICAgIDxTdHlsZSB4OktleT0iQm9yZGVyU3R5bGUiIFRhcmdldFR5cGU9IkJvcmRlciI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQm9yZGVyVGhpY2tuZXNzIiBWYWx1ZT0iMSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJDb3JuZXJSYWRpdXMiIFZhbHVlPSI1Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlBhZGRpbmciIFZhbHVlPSI1Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ik1hcmdpbiIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgU2hhZG93RGVwdGg9IjUiIEJsdXJSYWRpdXM9IjUiIE9wYWNpdHk9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyT3BhY2l0eX0iIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgoKICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iVGV4dEJveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IlN0cmV0Y2giLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbENvbnRlbnRBbGlnbm1lbnQiIFZhbHVlPSJTdHJldGNoIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNhcmV0QnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRleHRNZW51Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRleHRNZW51PgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udGV4dE1lbnUuU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQ29udGV4dE1lbnUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlci5WYWx1ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQ29udGV4dE1lbnUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iNSIgUGFkZGluZz0iNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIENvbW1hbmQ9IkN1dCIgSGVhZGVyPSJDdXQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBDb21tYW5kPSJDb3B5IiBIZWFkZXI9IkNvcHkiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBDb21tYW5kPSJQYXN0ZSIgSGVhZGVyPSJQYXN0ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0eWxlPgogICAgICAgICAgICAgICAgICAgICAgICA8L0NvbnRleHRNZW51LlN0eWxlPgogICAgICAgICAgICAgICAgICAgIDwvQ29udGV4dE1lbnU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJUZXh0Qm94Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSJ7VGVtcGxhdGVCaW5kaW5nIEJhY2tncm91bmR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlckJydXNofSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IntUZW1wbGF0ZUJpbmRpbmcgQm9yZGVyVGhpY2tuZXNzfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb3JuZXJSYWRpdXM9IjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNjcm9sbFZpZXdlciBOYW1lPSJQQVJUX0NvbnRlbnRIb3N0IiAvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8L0NvbnRyb2xUZW1wbGF0ZT4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRWZmZWN0Ij4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPERyb3BTaGFkb3dFZmZlY3QgU2hhZG93RGVwdGg9IjUiIEJsdXJSYWRpdXM9IjUiIE9wYWNpdHk9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyT3BhY2l0eX0iIENvbG9yPSJ7RHluYW1pY1Jlc291cmNlIENCb3JkZXJDb2xvcn0iLz4KICAgICAgICAgICAgICAgIDwvU2V0dGVyLlZhbHVlPgogICAgICAgICAgICA8L1NldHRlcj4KICAgICAgICA8L1N0eWxlPgogICAgICAgIDxTdHlsZSBUYXJnZXRUeXBlPSJQYXNzd29yZEJveCI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkJvcmRlckJydXNoIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJCb3JkZXJUaGlja25lc3MiIFZhbHVlPSIxIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvbnRTaXplIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iRm9udEZhbWlseSIgVmFsdWU9IntEeW5hbWljUmVzb3VyY2UgRm9udEZhbWlseX0iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjUiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbEFsaWdubWVudCIgVmFsdWU9IlN0cmV0Y2giLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVmVydGljYWxBbGlnbm1lbnQiIFZhbHVlPSJDZW50ZXIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iSG9yaXpvbnRhbENvbnRlbnRBbGlnbm1lbnQiIFZhbHVlPSJTdHJldGNoIi8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNhcmV0QnJ1c2giIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRlbXBsYXRlIj4KICAgICAgICAgICAgICAgIDxTZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgICAgICAgICAgPENvbnRyb2xUZW1wbGF0ZSBUYXJnZXRUeXBlPSJQYXNzd29yZEJveCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie1RlbXBsYXRlQmluZGluZyBCYWNrZ3JvdW5kfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie1RlbXBsYXRlQmluZGluZyBCb3JkZXJCcnVzaH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSJ7VGVtcGxhdGVCaW5kaW5nIEJvcmRlclRoaWNrbmVzc30iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29ybmVyUmFkaXVzPSI1Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXIgTmFtZT0iUEFSVF9Db250ZW50SG9zdCIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkVmZmVjdCI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxEcm9wU2hhZG93RWZmZWN0IFNoYWRvd0RlcHRoPSI1IiBCbHVyUmFkaXVzPSI1IiBPcGFjaXR5PSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlck9wYWNpdHl9IiBDb2xvcj0ie0R5bmFtaWNSZXNvdXJjZSBDQm9yZGVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8U3R5bGUgeDpLZXk9IlNjcm9sbFZpc2liaWxpdHlSZWN0YW5nbGUiIFRhcmdldFR5cGU9IlJlY3RhbmdsZSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlZpc2liaWxpdHkiIFZhbHVlPSJDb2xsYXBzZWQiLz4KICAgICAgICAgICAgPFN0eWxlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgPE11bHRpRGF0YVRyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgPE11bHRpRGF0YVRyaWdnZXIuQ29uZGl0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgPENvbmRpdGlvbiBCaW5kaW5nPSJ7QmluZGluZyBQYXRoPUNvbXB1dGVkSG9yaXpvbnRhbFNjcm9sbEJhclZpc2liaWxpdHksIEVsZW1lbnROYW1lPXNjcm9sbFZpZXdlcn0iIFZhbHVlPSJWaXNpYmxlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxDb25kaXRpb24gQmluZGluZz0ie0JpbmRpbmcgUGF0aD1Db21wdXRlZFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eSwgRWxlbWVudE5hbWU9c2Nyb2xsVmlld2VyfSIgVmFsdWU9IlZpc2libGUiLz4KICAgICAgICAgICAgICAgICAgICA8L011bHRpRGF0YVRyaWdnZXIuQ29uZGl0aW9ucz4KICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJWaXNpYmlsaXR5IiBWYWx1ZT0iVmlzaWJsZSIvPgogICAgICAgICAgICAgICAgPC9NdWx0aURhdGFUcmlnZ2VyPgogICAgICAgICAgICA8L1N0eWxlLlRyaWdnZXJzPgogICAgICAgIDwvU3R5bGU+CiAgICAgICAgPFN0eWxlIHg6S2V5PSJSb3VuZGVkUHJvZ3Jlc3NCYXJTdHlsZSIgVGFyZ2V0VHlwZT0iUHJvZ3Jlc3NCYXIiPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iUHJvZ3Jlc3NCYXIiPgogICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIENvcm5lclJhZGl1cz0iNCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBDbGlwVG9Cb3VuZHM9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iUEFSVF9UcmFjayIgQ29ybmVyUmFkaXVzPSI0IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iUEFSVF9JbmRpY2F0b3IiIENvcm5lclJhZGl1cz0iNCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBQcm9ncmVzc0JhckZvcmVncm91bmRDb2xvcn0iIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgPC9Db250cm9sVGVtcGxhdGU+CiAgICAgICAgICAgICAgICA8L1NldHRlci5WYWx1ZT4KICAgICAgICAgICAgPC9TZXR0ZXI+CiAgICAgICAgPC9TdHlsZT4KICAgICAgICA8IS0tIEZpbHRlciBDaGlwIFN0eWxlIOKAlCB1c2VkIGJ5IHRoZSBJbnN0YWxsIHRhYiBjYXRlZ29yeSBmaWx0ZXIgYnV0dG9ucyAtLT4KICAgICAgICA8U3R5bGUgeDpLZXk9IkZpbHRlckNoaXBTdHlsZSIgVGFyZ2V0VHlwZT0iQnV0dG9uIiBCYXNlZE9uPSJ7U3RhdGljUmVzb3VyY2Uge3g6VHlwZSBCdXR0b259fSI+CiAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9Ik1hcmdpbiIgVmFsdWU9IjIiLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iUGFkZGluZyIgVmFsdWU9IjEyLDAsMTIsMCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJXaWR0aCIgVmFsdWU9IkF1dG8iLz4KICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iQ3Vyc29yIiBWYWx1ZT0iSGFuZCIvPgogICAgICAgICAgICA8U2V0dGVyIFByb3BlcnR5PSJUZW1wbGF0ZSI+CiAgICAgICAgICAgICAgICA8U2V0dGVyLlZhbHVlPgogICAgICAgICAgICAgICAgICAgIDxDb250cm9sVGVtcGxhdGUgVGFyZ2V0VHlwZT0iQnV0dG9uIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBOYW1lPSJDaGlwQm9yZGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntUZW1wbGF0ZUJpbmRpbmcgQmFja2dyb3VuZH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntUZW1wbGF0ZUJpbmRpbmcgQm9yZGVyQnJ1c2h9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Cb3JkZXJUaGlja25lc3N9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvcm5lclJhZGl1cz0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db3JuZXJSYWRpdXN9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IntUZW1wbGF0ZUJpbmRpbmcgUGFkZGluZ30iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbnRlbnRQcmVzZW50ZXIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICA8Q29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRyaWdnZXIgUHJvcGVydHk9IklzUHJlc3NlZCIgVmFsdWU9IlRydWUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQ2hpcEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRQcmVzc2VkQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNNb3VzZU92ZXIiIFZhbHVlPSJUcnVlIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2V0dGVyIFRhcmdldE5hbWU9IkNoaXBCb3JkZXIiIFByb3BlcnR5PSJCYWNrZ3JvdW5kIiBWYWx1ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kTW91c2VvdmVyQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VHJpZ2dlciBQcm9wZXJ0eT0iSXNFbmFibGVkIiBWYWx1ZT0iRmFsc2UiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgVGFyZ2V0TmFtZT0iQ2hpcEJvcmRlciIgUHJvcGVydHk9IkJhY2tncm91bmQiIFZhbHVlPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkJhY2tncm91bmRTZWxlY3RlZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkZvcmVncm91bmQiIFZhbHVlPSJEaW1HcmF5Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlLlRyaWdnZXJzPgogICAgICAgICAgICAgICAgICAgIDwvQ29udHJvbFRlbXBsYXRlPgogICAgICAgICAgICAgICAgPC9TZXR0ZXIuVmFsdWU+CiAgICAgICAgICAgIDwvU2V0dGVyPgogICAgICAgIDwvU3R5bGU+CiAgICA8L1dpbmRvdy5SZXNvdXJjZXM+CiAgICA8R3JpZCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBTaG93R3JpZExpbmVzPSJGYWxzZSIgTmFtZT0iV1BGTWFpbkdyaWQiIFdpZHRoPSJBdXRvIiBIZWlnaHQ9IkF1dG8iIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgIDwhLS0gT2ZmbGluZSBiYW5uZXIgLS0+CiAgICAgICAgPEJvcmRlciBOYW1lPSJXUEZPZmZsaW5lQmFubmVyIiBHcmlkLlJvdz0iMCIgQmFja2dyb3VuZD0iIzhCMDAwMCIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBQYWRkaW5nPSI2LDQiPgogICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IiYjeDI2QTA7IE9mZmxpbmUgTW9kZSAtIE5vIEludGVybmV0IENvbm5lY3Rpb24iIEZvcmVncm91bmQ9IldoaXRlIiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIiBGb250U2l6ZT0iMTMiIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ii8+CiAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgPEdyaWQgR3JpZC5Sb3c9IjEiIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iPgogICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+IDwhLS0gTmF2aWdhdGlvbiBidXR0b25zIC0tPgogICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4gPCEtLSBTZWFyY2ggYmFyIGFuZCBidXR0b25zIC0tPgogICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICA8IS0tIE5hdmlnYXRpb24gQnV0dG9ucyBQYW5lbCAtLT4KICAgICAgICAgICAgPFN0YWNrUGFuZWwgTmFtZT0iTmF2RG9ja1BhbmVsIiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgR3JpZC5Db2x1bW49IjAiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iNSw1LDEwLDUiPgogICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgTmFtZT0iTmF2TG9nb1BhbmVsIiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgU25hcHNUb0RldmljZVBpeGVscz0iVHJ1ZSIgTWFyZ2luPSIxMCwwLDIwLDAiPgogICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIFRhYlRvZ2dsZUJ1dHRvbn0iIE1hcmdpbj0iMCwwLDUsMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkhlaWdodH0iIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbldpZHRofSIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkluc3RhbGxCYWNrZ3JvdW5kQ29sb3J9IiBGb3JlZ3JvdW5kPSJ3aGl0ZSIgRm9udFdlaWdodD0iQm9sZCIgTmFtZT0iV1BGVGFiMUJUIj4KICAgICAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uLkNvbnRlbnQ+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uRm9udFNpemV9IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25JbnN0YWxsRm9yZWdyb3VuZENvbG9yfSIgPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFVuZGVybGluZT5JPC9VbmRlcmxpbmU+bnN0YWxsCiAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uLkNvbnRlbnQ+CiAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbj4KICAgICAgICAgICAgICAgIDxUb2dnbGVCdXR0b24gU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBUYWJUb2dnbGVCdXR0b259IiBNYXJnaW49IjAsMCw1LDAiIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25IZWlnaHR9IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25XaWR0aH0iCiAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Ud2Vha3NCYWNrZ3JvdW5kQ29sb3J9IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvblR3ZWFrc0ZvcmVncm91bmRDb2xvcn0iIEZvbnRXZWlnaHQ9IkJvbGQiIE5hbWU9IldQRlRhYjJCVCI+CiAgICAgICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkZvbnRTaXplfSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uVHdlYWtzRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VW5kZXJsaW5lPlQ8L1VuZGVybGluZT53ZWFrcwogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24+CiAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgVGFiVG9nZ2xlQnV0dG9ufSIgTWFyZ2luPSIwLDAsNSwwIiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uSGVpZ2h0fSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uV2lkdGh9IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uQ29uZmlnQmFja2dyb3VuZENvbG9yfSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Db25maWdGb3JlZ3JvdW5kQ29sb3J9IiBGb250V2VpZ2h0PSJCb2xkIiBOYW1lPSJXUEZUYWIzQlQiPgogICAgICAgICAgICAgICAgICAgIDxUb2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25Gb250U2l6ZX0iIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkNvbmZpZ0ZvcmVncm91bmRDb2xvcn0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFVuZGVybGluZT5DPC9VbmRlcmxpbmU+b25maWcKICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgIDwvVG9nZ2xlQnV0dG9uPgogICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbiBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIFRhYlRvZ2dsZUJ1dHRvbn0iIE1hcmdpbj0iMCwwLDUsMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkhlaWdodH0iIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbldpZHRofSIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvblVwZGF0ZXNCYWNrZ3JvdW5kQ29sb3J9IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvblVwZGF0ZXNGb3JlZ3JvdW5kQ29sb3J9IiBGb250V2VpZ2h0PSJCb2xkIiBOYW1lPSJXUEZUYWI0QlQiPgogICAgICAgICAgICAgICAgICAgIDxUb2dnbGVCdXR0b24uQ29udGVudD4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBUYWJCdXR0b25Gb250U2l6ZX0iIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvblVwZGF0ZXNGb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxVbmRlcmxpbmU+VTwvVW5kZXJsaW5lPnBkYXRlcwogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24+CiAgICAgICAgICAgICAgICA8VG9nZ2xlQnV0dG9uIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgVGFiVG9nZ2xlQnV0dG9ufSIgTWFyZ2luPSIwLDAsNSwwIiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgVGFiQnV0dG9uSGVpZ2h0fSIgV2lkdGg9IkF1dG8iIE1pbldpZHRoPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbldpZHRofSIKICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpbjExSVNPQmFja2dyb3VuZENvbG9yfSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaW4xMUlTT0ZvcmVncm91bmRDb2xvcn0iIEZvbnRXZWlnaHQ9IkJvbGQiIE5hbWU9IldQRlRhYjVCVCI+CiAgICAgICAgICAgICAgICAgICAgPFRvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIFRhYkJ1dHRvbkZvbnRTaXplfSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2luMTFJU09Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxVbmRlcmxpbmU+VzwvVW5kZXJsaW5lPmluMTEgQ3JlYXRvcgogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICA8L1RvZ2dsZUJ1dHRvbi5Db250ZW50PgogICAgICAgICAgICAgICAgPC9Ub2dnbGVCdXR0b24+CiAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KCiAgICAgICAgICAgIDwhLS0gU2VhcmNoIEJhciBhbmQgQWN0aW9uIEJ1dHRvbnMgLS0+CiAgICAgICAgICAgIDxHcmlkIE5hbWU9IkdyaWRCZXNpZGVOYXZEb2NrUGFuZWwiIEdyaWQuQ29sdW1uPSIxIiBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBTaG93R3JpZExpbmVzPSJGYWxzZSIgSGVpZ2h0PSJBdXRvIj4KICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIyKiIvPiA8IS0tIFNlYXJjaCBiYXIgYXJlYSAtIHByaW9yaXR5IHNwYWNlIC0tPgogICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+PCEtLSBCdXR0b25zIGFyZWEgLS0+CiAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtbj0iMCIgTWFyZ2luPSI1LDAsMTAsMCIgTWluV2lkdGg9IjEyMCIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFNlYXJjaEJhckhlaWdodH0iIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJveAogICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIFNlYXJjaEJhckhlaWdodH0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZWFyY2hCYXJUZXh0Qm94Rm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IlNlYXJjaEJhciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSIzLDMsMzAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuaMiSBDdHJsLUYg6L6T5YWl5bqU55So5ZCN56ew6L+H5ruk5YiX6KGo77yM5oyJIEVzYyDph43nva7nrZvpgIkiPgogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCb3g+CiAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sKICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IlNlYXJjaEJhckljb24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIiBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRGYW1pbHk9IlNlZ29lIE1ETDIgQXNzZXRzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25CYWNrZ3JvdW5kU2VsZWN0ZWRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsOCwwIiBXaWR0aD0iQXV0byIgSGVpZ2h0PSJBdXRvIj4mI3hFNzIxOwogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgIDxCdXR0b24gR3JpZC5Db2x1bW49IjAiCiAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiCiAgICAgICAgICAgICAgICAgICAgTmFtZT0iU2VhcmNoQmFyQ2xlYXJCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBTZWFyY2hCYXJDbGVhckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwyMCwwIiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiPgogICAgICAgICAgICAgICAgPC9CdXR0b24+CgogICAgICAgICAgICAgICAgPCEtLSBCdXR0b25zIENvbnRhaW5lciAtLT4KICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuQ29sdW1uPSIxIiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iNSw1LDUsNSI+CiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJUaGVtZUJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZXR0aW5nc0ljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDIsMCIKICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLml6AiCiAgICAgICAgICAgICAgICAgICAgVG9vbFRpcD0i5YiH5o2iIFdpblV0aWwg55WM6Z2i5Li76aKYIgogICAgICAgICAgICAgICAgLz4KICAgICAgICAgICAgICAgICAgICA8UG9wdXAgTmFtZT0iVGhlbWVQb3B1cCIKICAgICAgICAgICAgICAgICAgICBJc09wZW49IkZhbHNlIgogICAgICAgICAgICAgICAgICAgIFBsYWNlbWVudFRhcmdldD0ie0JpbmRpbmcgRWxlbWVudE5hbWU9VGhlbWVCdXR0b259IiBQbGFjZW1lbnQ9IkJvdHRvbSIKICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IlRvcCI+CiAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBCb3JkZXJCcnVzaD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgQm9yZGVyVGhpY2tuZXNzPSIxIiBDb3JuZXJSYWRpdXM9IjAiIE1hcmdpbj0iMCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFZlcnRpY2FsQWxpZ25tZW50PSJTdHJldGNoIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iQXV0byIgTmFtZT0iQXV0b1RoZW1lTWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VG9vbFRpcCBDb250ZW50PSLot5/pmo8gV2luZG93cyDkuLvpopgiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgSGVhZGVyPSJEYXJrIiBOYW1lPSJEYXJrVGhlbWVNZW51SXRlbSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUb29sVGlwIENvbnRlbnQ9IuS9v+eUqOa3seiJsuS4u+mimCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0gRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IiBIZWFkZXI9IkxpZ2h0IiBOYW1lPSJMaWdodFRoZW1lTWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VG9vbFRpcCBDb250ZW50PSLkvb/nlKjmtYXoibLkuLvpopgiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L01lbnVJdGVtPgogICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICA8L1BvcHVwPgoKICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IkZvbnRTY2FsaW5nQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEhvdmVyQnV0dG9uU3R5bGV9IgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0iVHJhbnNwYXJlbnQiCiAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIFNldHRpbmdzSWNvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBJY29uQnV0dG9uU2l6ZX0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBJY29uQnV0dG9uU2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMiwwIgogICAgICAgICAgICAgICAgICAgIEZvbnRGYW1pbHk9IlNlZ29lIE1ETDIgQXNzZXRzIgogICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IiYjeEU4RDM7IgogICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9Iuiwg+aVtOWtl+S9k+e8qeaUvuS7pemAguW6lOi+heWKqeWKn+iDvemcgOaxgiIKICAgICAgICAgICAgICAgIC8+CiAgICAgICAgICAgICAgICAgICAgPFBvcHVwIE5hbWU9IkZvbnRTY2FsaW5nUG9wdXAiCiAgICAgICAgICAgICAgICAgICAgSXNPcGVuPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICBQbGFjZW1lbnRUYXJnZXQ9IntCaW5kaW5nIEVsZW1lbnROYW1lPUZvbnRTY2FsaW5nQnV0dG9ufSIgUGxhY2VtZW50PSJCb3R0b20iCiAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJUb3AiPgogICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSIwIiBNYXJnaW49IjAiPgogICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIiBWZXJ0aWNhbEFsaWdubWVudD0iU3RyZXRjaCIgTWluV2lkdGg9IjIwMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IkZvbnQgU2NhbGluZyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMTAsNSwxMCw1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250V2VpZ2h0PSJCb2xkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2VwYXJhdG9yIE1hcmdpbj0iNSwwLDUsNSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIE1hcmdpbj0iMTAsNSwxMCwxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJTbWFsbCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMTAsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTbGlkZXIgTmFtZT0iRm9udFNjYWxpbmdTbGlkZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNaW5pbXVtPSIwLjc1IiBNYXhpbXVtPSIyLjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWYWx1ZT0iMS4wIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGlja0ZyZXF1ZW5jeT0iMC4yNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRpY2tQbGFjZW1lbnQ9IkJvdHRvbVJpZ2h0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSXNTbmFwVG9UaWNrRW5hYmxlZD0iVHJ1ZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSIxMjAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJMYXJnZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwwLDAsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBOYW1lPSJGb250U2NhbGluZ1ZhbHVlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSIxMDAlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxMCwwLDEwLDUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iMTAsMCwxMCwxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJGb250U2NhbGluZ1Jlc2V0QnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i6YeN572uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSI2MCIgSGVpZ2h0PSIyNSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iNSwwLDUsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iRm9udFNjYWxpbmdBcHBseUJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuW6lOeUqCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgSG92ZXJCdXR0b25TdHlsZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iNjAiIEhlaWdodD0iMjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjUsMCw1LDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9Qb3B1cD4KCiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJTZXR0aW5nc0J1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IgogICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBTZXR0aW5nc0ljb25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwwLDIsMCIKICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICBDb250ZW50PSImI3hFNzEzOyIvPgogICAgICAgICAgICAgICAgICAgIDxQb3B1cCBOYW1lPSJTZXR0aW5nc1BvcHVwIgogICAgICAgICAgICAgICAgICAgIElzT3Blbj0iRmFsc2UiCiAgICAgICAgICAgICAgICAgICAgUGxhY2VtZW50VGFyZ2V0PSJ7QmluZGluZyBFbGVtZW50TmFtZT1TZXR0aW5nc0J1dHRvbn0iIFBsYWNlbWVudD0iQm90dG9tIgogICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlJpZ2h0IiBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IiBCb3JkZXJUaGlja25lc3M9IjEiIENvcm5lclJhZGl1cz0iMCIgTWFyZ2luPSIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkZvbnRTaXplfSIgSGVhZGVyPSJJbXBvcnQiIE5hbWU9IkltcG9ydE1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRvb2xUaXAgQ29udGVudD0i5LuO5a+85Ye655qE5paH5Lu25a+85YWl6YWN572uIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbS5Ub29sVGlwPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9NZW51SXRlbT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iRXhwb3J0IiBOYW1lPSJFeHBvcnRNZW51SXRlbSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPE1lbnVJdGVtLlRvb2xUaXA+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUb29sVGlwIENvbnRlbnQ9IuWvvOWHuuW3sumAiemhueW5tuWwhuWRveS7pOWkjeWItuWIsOWJqui0tOadvyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0uVG9vbFRpcD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvTWVudUl0ZW0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U2VwYXJhdG9yLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iQWJvdXQiIE5hbWU9IkFib3V0TWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxNZW51SXRlbSBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25Gb250U2l6ZX0iIEhlYWRlcj0iRG9jdW1lbnRhdGlvbiIgTmFtZT0iRG9jdW1lbnRhdGlvbk1lbnVJdGVtIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TWVudUl0ZW0gRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uRm9udFNpemV9IiBIZWFkZXI9IlNwb25zb3JzIiBOYW1lPSJTcG9uc29yTWVudUl0ZW0iIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgPC9Qb3B1cD4KCiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbgogICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSImI3hFOTIxOyIKICAgICAgICAgICAgICAgICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBIb3ZlckJ1dHRvblN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSIwIgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0iVHJhbnNwYXJlbnQiCiAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEljb25CdXR0b25TaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iUmlnaHQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udEZhbWlseT0iU2Vnb2UgTURMMiBBc3NldHMiCiAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIENsb3NlSWNvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgVG9vbFRpcD0i5pyA5bCP5YyWIgogICAgICAgICAgICAgICAgICAgICAgICBBdXRvbWF0aW9uUHJvcGVydGllcy5OYW1lPSJNaW5pbWl6ZSIKICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGTWluaW1pemVCdXR0b24iIC8+CiAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjAiCiAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQ2xvc2VJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZNYXhpbWl6ZUJ1dHRvbiI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24uU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3R5bGUgVGFyZ2V0VHlwZT0iQnV0dG9uIiBCYXNlZE9uPSJ7U3RhdGljUmVzb3VyY2UgSG92ZXJCdXR0b25TdHlsZX0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSImI3hFOTIyOyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IlRvb2xUaXAiIFZhbHVlPSJNYXhpbWl6ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWUiIFZhbHVlPSJNYXhpbWl6ZSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPERhdGFUcmlnZ2VyIEJpbmRpbmc9IntCaW5kaW5nIFdpbmRvd1N0YXRlLCBSZWxhdGl2ZVNvdXJjZT17UmVsYXRpdmVTb3VyY2UgQW5jZXN0b3JUeXBlPXt4OlR5cGUgV2luZG93fX19IiBWYWx1ZT0iTWF4aW1pemVkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkNvbnRlbnQiIFZhbHVlPSImI3hFOTIzOyIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFNldHRlciBQcm9wZXJ0eT0iVG9vbFRpcCIgVmFsdWU9IlJlc3RvcmUiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTZXR0ZXIgUHJvcGVydHk9IkF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWUiIFZhbHVlPSJSZXN0b3JlIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvRGF0YVRyaWdnZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdHlsZS5UcmlnZ2Vycz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3R5bGU+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvQnV0dG9uLlN0eWxlPgogICAgICAgICAgICAgICAgICAgIDwvQnV0dG9uPgoKICAgICAgICAgICAgICAgICAgICA8QnV0dG9uCiAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IiYjeEU4QkI7IgogICAgICAgICAgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEhvdmVyQnV0dG9uU3R5bGV9IgogICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJUaGlja25lc3M9IjAiCiAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJUcmFuc3BhcmVudCIKICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgSWNvbkJ1dHRvblNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJSaWdodCIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwIgogICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJTZWdvZSBNREwyIEFzc2V0cyIKICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgQ2xvc2VJY29uRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICBUb29sVGlwPSLlhbPpl60iCiAgICAgICAgICAgICAgICAgICAgICAgIEF1dG9tYXRpb25Qcm9wZXJ0aWVzLk5hbWU9IkNsb3NlIgogICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZDbG9zZUJ1dHRvbiIgLz4KICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgPC9HcmlkPgogICAgICAgIDwvR3JpZD4KCiAgICAgICAgPFRhYkNvbnRyb2wgTmFtZT0iV1BGVGFiTmF2IiBCYWNrZ3JvdW5kPSJUcmFuc3BhcmVudCIgV2lkdGg9IkF1dG8iIEhlaWdodD0iQXV0byIgQm9yZGVyQnJ1c2g9IlRyYW5zcGFyZW50IiBCb3JkZXJUaGlja25lc3M9IjAiIEdyaWQuUm93PSIyIiBHcmlkLkNvbHVtbj0iMCIgUGFkZGluZz0iLTEiPgogICAgICAgICAgICA8VGFiSXRlbSBIZWFkZXI9IuW6lOeUqOWuieijhSIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWIxIj4KICAgICAgICAgICAgICAgIDxHcmlkIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiA+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgIDwhLS0gUXVpY2sgQ2F0ZWdvcnkgU2VhcmNoIENoaXBzIC0tPgogICAgICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgR3JpZC5Sb3c9IjAiIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBNYXJnaW49IjUsNSw1LDUiIE5hbWU9IldQRlNlYXJjaENoaXBzIj4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJGaWx0ZXJzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEhlYWRlckZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250RmFtaWx5PSJ7RHluYW1pY1Jlc291cmNlIEhlYWRlckZvbnRGYW1pbHl9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTGFiZWxib3hGb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIxNSwwLDgsMCIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBBbGwiICAgICAgICAgICAgIENvbnRlbnQ9IuWFqOmDqCIgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwQnJvd3NlcnMiICAgICAgICBDb250ZW50PSLmtY/op4jlmagiICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBDb21tdW5pY2F0aW9ucyIgIENvbnRlbnQ9IumAmuiuryIgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcERldmVsb3BtZW50IiAgICAgQ29udGVudD0i5byA5Y+R5bel5YW3IiAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwR2FtZXMiICAgICAgICAgICBDb250ZW50PSLmuLjmiI8iICAgICAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlNlYXJjaENoaXBNaWNyb3NvZnRUb29scyIgIENvbnRlbnQ9IuW+rui9r+W3peWFtyIgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwTXVsdGltZWRpYVRvb2xzIiBDb250ZW50PSLlpJrlqpLkvZPlt6XlhbciICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEZpbHRlckNoaXBTdHlsZX0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWFyY2hDaGlwUHJvVG9vbHMiICAgICAgICBDb250ZW50PSLkuJPkuJrlt6XlhbciICAgICAgICAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcFNlbGZob3N0ZWRUb29scyIgQ29udGVudD0i6Ieq5omY566h5bel5YW3IiAgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBGaWx0ZXJDaGlwU3R5bGV9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGU2VhcmNoQ2hpcFV0aWxpdGllcyIgICAgICAgQ29udGVudD0i5a6e55So5bel5YW3IiAgICAgICAgIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgRmlsdGVyQ2hpcFN0eWxlfSIvPgogICAgICAgICAgICAgICAgICAgIDwvV3JhcFBhbmVsPgoKICAgICAgICAgICAgICAgICAgICA8R3JpZCBHcmlkLlJvdz0iMSIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIFRhYkNvbnRlbnRNYXJnaW59Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Q29sdW1uRGVmaW5pdGlvbiBXaWR0aD0iQXV0byIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBOYW1lPSJhcHBzY2F0ZWdvcnkiIEdyaWQuQ29sdW1uPSIwIiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIiBWZXJ0aWNhbEFsaWdubWVudD0iU3RyZXRjaCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9ImFwcHNwYW5lbCIgR3JpZC5Db2x1bW49IjEiIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giIFZlcnRpY2FsQWxpZ25tZW50PSJTdHJldGNoIj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgPC9UYWJJdGVtPgogICAgICAgICAgICA8VGFiSXRlbSBIZWFkZXI9Iuezu+e7n+S8mOWMliIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWIyIj4KICAgICAgICAgICAgICAgIDxHcmlkPgogICAgICAgICAgICAgICAgICAgIDwhLS0gTWFpbiBjb250ZW50IGFyZWEgd2l0aCBhIFNjcm9sbFZpZXdlciAtLT4KICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSIqIiAvPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iIC8+CiAgICAgICAgICAgICAgICAgICAgPC9HcmlkLlJvd0RlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgICAgICA8U2Nyb2xsVmlld2VyIFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iQXV0byIgSG9yaXpvbnRhbFNjcm9sbEJhclZpc2liaWxpdHk9IkRpc2FibGVkIiBHcmlkLlJvdz0iMCIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIFRhYkNvbnRlbnRNYXJnaW59Ij4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuUm93RGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIgT3JpZW50YXRpb249IlZlcnRpY2FsIiBHcmlkLlJvdz0iMCIgR3JpZC5Db2x1bW49IjAiIEdyaWQuQ29sdW1uU3Bhbj0iMiIgTWFyZ2luPSI1Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGFiZWwgQ29udGVudD0i5o6o6I2Q6YCJ5oup77yaIiBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIE1hcmdpbj0iMiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIE1hcmdpbj0iMCwyLDAsMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGc3RhbmRhcmQiIENvbnRlbnQ9IiDmoIflh4YgIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZtaW5pbWFsIiBDb250ZW50PSIg57K+566AICIgTWFyZ2luPSIyIiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGQWR2YW5jZWQiIENvbnRlbnQ9IiDpq5jnuqcgIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZDbGVhclR3ZWFrc1NlbGVjdGlvbiIgQ29udGVudD0iIOa4hemZpCAiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkdldEluc3RhbGxlZFR3ZWFrcyIgQ29udGVudD0i5bey5a6J6KOF5LyY5YyW5YiX6KGoIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZBcHB4UmVtb3ZhbCIgQ29udGVudD0iQXBwWCDnp7vpmaQiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvV3JhcFBhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9InR3ZWFrc3BhbmVsIiBHcmlkLlJvdz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSBZb3VyIHR3ZWFrc3BhbmVsIGNvbnRlbnQgZ29lcyBoZXJlIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Db2x1bW5TcGFuPSIyIiBHcmlkLlJvdz0iMiIgR3JpZC5Db2x1bW49IjAiIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgQm9yZGVyU3R5bGV9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBPcmllbnRhdGlvbj0iSG9yaXpvbnRhbCIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgUGFkZGluZz0iMTAiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTm90ZTogSG92ZXIgb3ZlciBpdGVtcyB0byBnZXQgYSBiZXR0ZXIgZGVzY3JpcHRpb24uIFBsZWFzZSBiZSBjYXJlZnVsIGFzIG1hbnkgb2YgdGhlc2UgdHdlYWtzIHdpbGwgaGVhdmlseSBtb2RpZnkgeW91ciBzeXN0ZW0uCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz5SZWNvbW1lbmRlZCBzZWxlY3Rpb25zIGFyZSBmb3Igbm9ybWFsIHVzZXJzIGFuZCBpZiB5b3UgYXJlIHVuc3VyZSBkbyBOT1QgY2hlY2sgYW55dGhpbmcgZWxzZSEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICA8L1Njcm9sbFZpZXdlcj4KICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEdyaWQuUm93PSIxIiBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBCb3JkZXJCcnVzaD0ie0R5bmFtaWNSZXNvdXJjZSBCb3JkZXJDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI1IiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIiBQYWRkaW5nPSIxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiIEdyaWQuQ29sdW1uPSIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGVHdlYWtzYnV0dG9uIiBDb250ZW50PSLov5DooYzkvJjljJYiIE1hcmdpbj0iNSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZVbmRvYWxsIiBDb250ZW50PSLmkqTplIDkvJjljJYiIE1hcmdpbj0iNSIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L1dyYXBQYW5lbD4KICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgPC9UYWJJdGVtPgogICAgICAgICAgICA8VGFiSXRlbSBIZWFkZXI9IuWKn+iDvemFjee9riIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWIzIj4KICAgICAgICAgICAgICAgIDxTY3JvbGxWaWV3ZXIgVmVydGljYWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJBdXRvIiBIb3Jpem9udGFsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iQXV0byIgTWFyZ2luPSJ7RHluYW1pY1Jlc291cmNlIFRhYkNvbnRlbnRNYXJnaW59Ij4KICAgICAgICAgICAgICAgICAgICA8R3JpZCBOYW1lPSJmZWF0dXJlc3BhbmVsIiBHcmlkLlJvdz0iMSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgIDwvU2Nyb2xsVmlld2VyPgogICAgICAgICAgICA8L1RhYkl0ZW0+CiAgICAgICAgICAgIDxUYWJJdGVtIEhlYWRlcj0iV2luZG93cyDmm7TmlrAiIFZpc2liaWxpdHk9IkNvbGxhcHNlZCIgTmFtZT0iV1BGVGFiNCI+CiAgICAgICAgICAgICAgICA8U2Nyb2xsVmlld2VyIFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iQXV0byIgSG9yaXpvbnRhbFNjcm9sbEJhclZpc2liaWxpdHk9IkRpc2FibGVkIiBNYXJnaW49IntEeW5hbWljUmVzb3VyY2UgVGFiQ29udGVudE1hcmdpbn0iPgogICAgICAgICAgICAgICAgICAgIDxHcmlkIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50IiBNYXhXaWR0aD0iMTI1MCIgSG9yaXpvbnRhbEFsaWdubWVudD0iQ2VudGVyIj4KICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIwIiBNYXJnaW49IjEwLDEwLDEwLDE0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iV2luZG93cyBVcGRhdGUgUHJvZmlsZXMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIyNCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJDaG9vc2UgaG93IFdpbmRvd3MgcmVjZWl2ZXMgdXBkYXRlcy4gRWFjaCBwcm9maWxlIHJlcGxhY2VzIHRoZSBXaW5kb3dzIFVwZGF0ZSBzZXR0aW5ncyBtYW5hZ2VkIGJ5IFdpblV0aWwuIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsNiwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxVbmlmb3JtR3JpZCBHcmlkLlJvdz0iMSIgQ29sdW1ucz0iMyI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgQm9yZGVyU3R5bGV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCb3JkZXJCcnVzaD0ie0R5bmFtaWNSZXNvdXJjZSBQcm9ncmVzc0JhckZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUGFkZGluZz0iMTYiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1pbkhlaWdodD0iMzAwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMCwwLDAsMTQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJSZWNvbW1lbmRlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IjIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IkJhbGFuY2VkIHNlY3VyaXR5IGFuZCBzdGFiaWxpdHkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw0LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IjEzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjEiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIERlZmVycyBmZWF0dXJlIHVwZGF0ZXMgZm9yIDM2NSBkYXlzIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIERlZmVycyBxdWFsaXR5IHVwZGF0ZXMgZm9yIDQgZGF5cyIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBFeGNsdWRlcyBkcml2ZXJzIGZyb20gcXVhbGl0eSB1cGRhdGVzIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIFByZXZlbnRzIGF1dG9tYXRpYyByZXN0YXJ0cyB3aGlsZSBhIHVzZXIgaXMgc2lnbmVkIGluIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsMTIiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iQXZhaWxhYmxlIG9uIFdpbmRvd3MgUHJvLCBFbnRlcnByaXNlLCBhbmQgRWR1Y2F0aW9uIGVkaXRpb25zLiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IjExIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U3R5bGU9Ikl0YWxpYyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZVcGRhdGVzc2VjdXJpdHkiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgR3JpZC5Sb3c9IjIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5bqU55So5o6o6I2QIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIENvbmZpZ1RhYkJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMTYsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIgUGFkZGluZz0iMTYiIE1pbkhlaWdodD0iMzAwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMCwwLDAsMTQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJXaW5kb3dzIERlZmF1bHQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIyMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJSZXR1cm4gY29udHJvbCB0byBXaW5kb3dzIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsNCwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIxIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBSZW1vdmVzIFdpbmRvd3MgVXBkYXRlIHBvbGljaWVzIGFwcGxpZWQgYnkgV2luVXRpbCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBSZXN0b3JlcyB1cGRhdGUgc2VydmljZSBzdGFydHVwIHNldHRpbmdzIiBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsNyIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSItIFJlLWVuYWJsZXMgdXBkYXRlIHNjaGVkdWxlZCB0YXNrcyIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IlVzZSB0aGlzIHRvIHVuZG8gdGhlIFJlY29tbWVuZGVkIG9yIERpc2FibGUgcHJvZmlsZS4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFN0eWxlPSJJdGFsaWMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGVXBkYXRlc2RlZmF1bHQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgR3JpZC5Sb3c9IjIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5oGi5aSN6buY6K6kIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIENvbmZpZ1RhYkJ1dHRvbkZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMTYsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIgUGFkZGluZz0iMTYiIE1pbkhlaWdodD0iMzAwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiIE1hcmdpbj0iMCwwLDAsMTQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJEaXNhYmxlIFVwZGF0ZXMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIyMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iUmVkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IkFkdmFuY2VkIHVzZSBvbmx5IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsNCwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSIxMyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFdlaWdodD0iU2VtaUJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IlJlZCIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuUm93PSIxIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBEaXNhYmxlcyBhdXRvbWF0aWMgdXBkYXRlIHBvbGljeSIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBTdG9wcyB1cGRhdGUgc2VydmljZXMgYW5kIHNjaGVkdWxlZCB0YXNrcyIgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDciIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgVGV4dD0iLSBDbGVhcnMgZG93bmxvYWRlZCB1cGRhdGUgZmlsZXMiIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCwxMiIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBUZXh0PSJTZWN1cml0eSB1cGRhdGVzIHdpbGwgbm90IGJlIGluc3RhbGxlZCB3aGlsZSB0aGlzIHByb2ZpbGUgaXMgYWN0aXZlLiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IjExIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U3R5bGU9Ikl0YWxpYyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJSZWQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlVwZGF0ZXNkaXNhYmxlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEdyaWQuUm93PSIyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuemgeeUqOabtOaWsCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBDb25maWdUYWJCdXR0b25Gb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iUmVkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCwxNiwwLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgUGFkZGluZz0iMTAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9Vbmlmb3JtR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgR3JpZC5Sb3c9IjIiIFN0eWxlPSJ7U3RhdGljUmVzb3VyY2UgQm9yZGVyU3R5bGV9IiBNYXJnaW49IjgsMTQsOCw4IiBQYWRkaW5nPSIxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIFRleHQ9IkNoYW5nZXMgYXBwbHkgc3lzdGVtLXdpZGUuIFJlc3RhcnQgV2luZG93cyBhZnRlciBzd2l0Y2hpbmcgcHJvZmlsZXMuIFVzZSBSZXN0b3JlIERlZmF1bHRzIHRvIHVuZG8gV2luVXRpbCB1cGRhdGUgcG9saWNpZXMuIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0V3JhcHBpbmc9IldyYXAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkNlbnRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICA8L1Njcm9sbFZpZXdlcj4KICAgICAgICAgICAgPC9UYWJJdGVtPgogICAgICAgICAgICA8VGFiSXRlbSBIZWFkZXI9IldpbjExIElTTyIgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIiBOYW1lPSJXUEZUYWI1Ij4KICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9IldpbjExSVNPUGFuZWwiIE1hcmdpbj0ie0R5bmFtaWNSZXNvdXJjZSBUYWJDb250ZW50TWFyZ2lufSIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiPgogICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IkF1dG8iLz4gIDwhLS0gU3RlcHMgMS00IC0tPgogICAgICAgICAgICAgICAgICAgICAgICA8Um93RGVmaW5pdGlvbiBIZWlnaHQ9IioiLz4gICAgIDwhLS0gTG9nIC8gU3RhdHVzIC0tPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgPCEtLSBTdGVwcyAxLTQgLS0+CiAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgR3JpZC5Sb3c9IjAiPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0g4pSA4pSA4pSAIFNURVAgMSA6IFNlbGVjdCBXaW5kb3dzIDExIElTTyDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZCBOYW1lPSJXUEZXaW4xMUlTT1NlbGVjdFNlY3Rpb24iIE1hcmdpbj0iNSIgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgTWluV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gTGVmdDogRmlsZSBTZWxlY3RvciAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBHcmlkLkNvbHVtbj0iMCIgTWFyZ2luPSI1LDUsMTUsNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIE1hcmdpbj0iMCwwLDAsOCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdGVwIDEgLSBTZWxlY3QgV2luZG93cyAxMSBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw2Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJyb3dzZSB0byB5b3VyIGxvY2FsbHkgc2F2ZWQgV2luZG93cyAxMSBJU08gZmlsZS4gT25seSBvZmZpY2lhbCBJU09zCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBkb3dubG9hZGVkIGZyb20gTWljcm9zb2Z0IGFyZSBzdXBwb3J0ZWQuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0V3JhcHBpbmc9IldyYXAiIE1hcmdpbj0iMCwwLDAsMTIiIEZvbnRTdHlsZT0iSXRhbGljIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSdW4gRm9udFdlaWdodD0iQm9sZCI+Tk9URTo8L1J1bj4gVGhpcyBpcyBvbmx5IG1lYW50IGZvciBGcmVzaCBhbmQgTmV3IFdpbmRvd3MgaW5zdGFsbHMuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0Qm94IEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09QYXRoIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSXNSZWFkT25seT0iVHJ1ZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSI2LDQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCw2LDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSJObyBJU08gc2VsZWN0ZWQuLi4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09Ccm93c2VCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9Iua1j+iniCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBOYW1lPSJXUEZXaW4xMUlTT0ZpbGVJbmZvIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0V3JhcHBpbmc9IldyYXAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIFJpZ2h0OiBEb3dubG9hZCBndWlkYW5jZSAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQmFja2dyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluQmFja2dyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI1IiBQYWRkaW5nPSIxNSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCIgTWFyZ2luPSIwLDAsMCwxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgISFXQVJOSU5HISEgWW91IG11c3QgdXNlIGFuIG9mZmljaWFsIE1pY3Jvc29mdCBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBEb3dubG9hZCB0aGUgV2luZG93cyAxMSBJU08gZGlyZWN0bHkgZnJvbSBNaWNyb3NvZnQuY29tLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRoaXJkLXBhcnR5LCBwcmUtbW9kaWZpZWQsIG9yIHVub2ZmaWNpYWwgaW1hZ2VzIGFyZSBub3Qgc3VwcG9ydGVkCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgYW5kIG1heSBwcm9kdWNlIGJyb2tlbiByZXN1bHRzLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDYiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE9uIHRoZSBNaWNyb3NvZnQgZG93bmxvYWQgcGFnZSwgY2hvb3NlOgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjEyLDAsMCwxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgLSBFZGl0aW9uICA6IFdpbmRvd3MgMTEKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz4tIExhbmd1YWdlIDogeW91ciBwcmVmZXJyZWQgbGFuZ3VhZ2UKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz4tIEFyY2hpdGVjdHVyZSA6IDY0LWJpdCAoeDY0KQogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPRG93bmxvYWRMaW5rIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLmiZPlvIDlvq7ova/kuIvovb3pobXpnaIiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSDilIDilIDilIAgU1RFUCAyIDogTW91bnQgJiBWZXJpZnkgSVNPIOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgOKUgCAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE5hbWU9IldQRldpbjExSVNPTW91bnRTZWN0aW9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgTWluV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IkF1dG8iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEdyaWQuQ29sdW1uPSIwIiBNYXJnaW49IjAsMCwyMCwwIiBWZXJ0aWNhbEFsaWdubWVudD0iVG9wIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFN0ZXAgMiAtIE1vdW50ICZhbXA7IFZlcmlmeSBJU08KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIiBNYXhXaWR0aD0iMzIwIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1vdW50IHRoZSBJU08gYW5kIGNvbmZpcm0gaXQgY29udGFpbnMgYSB2YWxpZCBXaW5kb3dzIDExCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBpbnN0YWxsLndpbSBiZWZvcmUgYW55IG1vZGlmaWNhdGlvbnMgYXJlIG1hZGUuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPTW91bnRCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5oyC6L295bm26aqM6K+BIElTTyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDaGVja0JveCBOYW1lPSJXUEZXaW4xMUlTT0luamVjdERyaXZlcnMiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLms6jlhaXlvZPliY3ns7vnu5/pqbHliqgiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSXNDaGVja2VkPSJGYWxzZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuS7juacrOacuuWvvOWHuuaJgOaciempseWKqOW5tuazqOWFpSBpbnN0YWxsLndpbSDlkowgYm9vdC53aW3vvIzmjqjojZDnlKjkuo7mnInkuI3mlK/mjIEgTlZNZSDmiJbnvZHnu5zmjqfliLblmajnmoTns7vnu5/jgIIiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVmVyaWZpY2F0aW9uIHJlc3VsdHMgcGFuZWwgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLkNvbHVtbj0iMSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPVmVyaWZ5UmVzdWx0UGFuZWwiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyQnJ1c2g9IntEeW5hbWljUmVzb3VyY2UgQm9yZGVyQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSIxIiBDb3JuZXJSYWRpdXM9IjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBQYWRkaW5nPSIxMiIgTWFyZ2luPSIwLDAsMCwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIE5hbWU9IldQRldpbjExSVNPTW91bnREcml2ZUxldHRlciIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDQiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgTmFtZT0iV1BGV2luMTFJU09BcmNoTGFiZWwiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDAsMCw0Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8VGV4dEJsb2NrIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgRm9udFdlaWdodD0iQm9sZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSIwLDYsMCw0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTZWxlY3QgRWRpdGlvbjoKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbWJvQm94IE5hbWU9IldQRldpbjExSVNPRWRpdGlvbkNvbWJvQm94IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvQm9yZGVyPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0g4pSA4pSA4pSAIFNURVAgMyA6IE1vZGlmeSBpbnN0YWxsLndpbSDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8U3RhY2tQYW5lbCBOYW1lPSJXUEZXaW4xMUlTT01vZGlmeVNlY3Rpb24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjUiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0IiBNaW5XaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxUZXh0QmxvY2sgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgU3RlcCAzIC0gTW9kaWZ5IGluc3RhbGwud2ltCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9UZXh0QmxvY2s+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGV4dFdyYXBwaW5nPSJXcmFwIiBNYXJnaW49IjAsMCwwLDEyIj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVGhlIElTTyBjb250ZW50cyB3aWxsIGJlIGV4dHJhY3RlZCB0byBhIHRlbXBvcmFyeSB3b3JraW5nIGRpcmVjdG9yeSwKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgaW5zdGFsbC53aW0gd2lsbCBiZSBtb2RpZmllZCAoY29tcG9uZW50cyByZW1vdmVkLCB0d2Vha3MgYXBwbGllZCksCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIGFuZCB0aGUgcmVzdWx0IHdpbGwgYmUgcmVwYWNrYWdlZC4gVGhpcyBwcm9jZXNzIG1heSB0YWtlIHNldmVyYWwgbWludXRlcwogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBkZXBlbmRpbmcgb24geW91ciBoYXJkd2FyZS4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPTW9kaWZ5QnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i6L+Q6KGMIFdpbmRvd3MgSVNPIOS/ruaUueWSjOWIm+W7uuW3peWFtyIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iQXV0byIgUGFkZGluZz0iMTIsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSDilIDilIDilIAgU1RFUCA0IDogT3V0cHV0IE9wdGlvbnMg4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSA4pSAIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgTmFtZT0iV1BGV2luMTFJU09PdXRwdXRTZWN0aW9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTWFyZ2luPSI1IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmlzaWJpbGl0eT0iQ29sbGFwc2VkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iTGVmdCIgTWluV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8IS0tIEhlYWRlciByb3c6IHRpdGxlICsgQ2xlYW4gJiBSZXNldCBidXR0b24gLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTWFyZ2luPSIwLDAsMCwxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Db2x1bW5EZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBHcmlkLkNvbHVtbj0iMCIgRm9udFNpemU9IntEeW5hbWljUmVzb3VyY2UgRm9udFNpemV9IiBGb250V2VpZ2h0PSJCb2xkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdGVwIDQgLSBPdXRwdXQ6IFdoYXQgd291bGQgeW91IGxpa2UgdG8gZG8gd2l0aCB0aGUgbW9kaWZpZWQgaW1hZ2U/CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvVGV4dEJsb2NrPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPQ2xlYW5SZXNldEJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLmuIXnkIblubbph43nva4iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0iT3JhbmdlUmVkIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFdpZHRoPSJBdXRvIiBQYWRkaW5nPSIxMiwwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRvb2xUaXA9IuWIoOmZpOS4tOaXtuW3peS9nOebruW9leW5tumHjee9ruWbnuatpemqpCAxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMTIsMCwwLDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0g4pSA4pSAIENob2ljZSBwcm9tcHQgYnV0dG9ucyDilIDilIAgLS0+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTWFyZ2luPSIwLDAsMCwxMiI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIxNiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPENvbHVtbkRlZmluaXRpb24gV2lkdGg9IioiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIwIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPQ2hvb3NlSVNPQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuS/neWtmOS4uiBJU08g5paH5Lu2IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhvcml6b250YWxBbGlnbm1lbnQ9IlN0cmV0Y2giCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBHcmlkLkNvbHVtbj0iMiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBOYW1lPSJXUEZXaW4xMUlTT0Nob29zZVVTQkJ1dHRvbiIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBDb250ZW50PSLnm7TmjqXlhpnlhaUgVVNCIOmpseWKqOWZqO+8iOS8muaTpumZpOaVtOS4quejgeebmO+8iSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJPcmFuZ2VSZWQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBXaWR0aD0iQXV0byIgUGFkZGluZz0iMTIsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPCEtLSDilIDilIAgVVNCIHdyaXRlIHN1Yi1wYW5lbCAocmV2ZWFsZWQgb24gVVNCIGNob2ljZSkg4pSA4pSAIC0tPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCb3JkZXIgTmFtZT0iV1BGV2luMTFJU09PcHRpb25VU0IiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBTdHlsZT0ie1N0YXRpY1Jlc291cmNlIEJvcmRlclN0eWxlfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZpc2liaWxpdHk9IkNvbGxhcHNlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE1hcmdpbj0iMCw4LDAsMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFRleHRXcmFwcGluZz0iV3JhcCIgTWFyZ2luPSIwLDAsMCw4Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8UnVuIEZvbnRXZWlnaHQ9IkJvbGQiIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCI+ISEgQWxsIGRhdGEgb24gdGhlIHNlbGVjdGVkIFVTQiBkcml2ZSB3aWxsIGJlIHBlcm1hbmVudGx5IGVyYXNlZCAhITwvUnVuPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxMaW5lQnJlYWsvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFNlbGVjdCBhIHJlbW92YWJsZSBVU0IgZHJpdmUgYmVsb3csIHRoZW4gY2xpY2sgRXJhc2UgJmFtcDsgV3JpdGUuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwhLS0gVVNCIGRyaXZlIHNlbGVjdG9yIHJvdyAtLT4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIE1hcmdpbj0iMCwwLDAsOCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQuQ29sdW1uRGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb2x1bW5EZWZpbml0aW9uIFdpZHRoPSJBdXRvIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLkNvbHVtbkRlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxDb21ib0JveCBHcmlkLkNvbHVtbj0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09VU0JEcml2ZUNvbWJvQm94IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBWZXJ0aWNhbEFsaWdubWVudD0iQ2VudGVyIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCw2LDAiLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIEdyaWQuQ29sdW1uPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgTmFtZT0iV1BGV2luMTFJU09SZWZyZXNoVVNCQnV0dG9uIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQ29udGVudD0i5Yi35pawIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjgsMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRldpbjExSVNPV3JpdGVVU0JCdXR0b24iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIENvbnRlbnQ9IuaTpumZpOW5tuWGmeWFpSBVU0IiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9Ik9yYW5nZVJlZCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgSG9yaXpvbnRhbEFsaWdubWVudD0iU3RyZXRjaCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgV2lkdGg9IkF1dG8iIFBhZGRpbmc9IjEyLDAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9IgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDEwIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDwvU3RhY2tQYW5lbD4KCiAgICAgICAgICAgICAgICAgICAgPC9TdGFja1BhbmVsPgoKICAgICAgICAgICAgICAgICAgICA8IS0tIFN0YXR1cyBMb2cgKGZpbGxzIHJlbWFpbmluZyBoZWlnaHQpIC0tPgogICAgICAgICAgICAgICAgICAgIDxHcmlkIEdyaWQuUm93PSIxIiBNYXJnaW49IjUiPgogICAgICAgICAgICAgICAgICAgICAgICA8R3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSIqIi8+CiAgICAgICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBHcmlkLlJvdz0iMCIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBGb250U2l6ZT0ie0R5bmFtaWNSZXNvdXJjZSBGb250U2l6ZX0iIEZvbnRXZWlnaHQ9IkJvbGQiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgRm9yZWdyb3VuZD0ie0R5bmFtaWNSZXNvdXJjZSBNYWluRm9yZWdyb3VuZENvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBNYXJnaW49IjAsMCwwLDQiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgU3RhdHVzIExvZwogICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCb3ggR3JpZC5Sb3c9IjEiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5hbWU9IldQRldpbjExSVNPU3RhdHVzTG9nIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBJc1JlYWRPbmx5PSJUcnVlIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0V3JhcHBpbmc9IldyYXAiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFZlcnRpY2FsU2Nyb2xsQmFyVmlzaWJpbGl0eT0iVmlzaWJsZSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgVmVydGljYWxBbGlnbm1lbnQ9IlN0cmV0Y2giCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIFBhZGRpbmc9IjYiCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIEJvcmRlckJydXNoPSJ7RHluYW1pY1Jlc291cmNlIEJvcmRlckNvbG9yfSIKICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgQm9yZGVyVGhpY2tuZXNzPSIxIgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICBUZXh0PSJSZWFkeS4gUGxlYXNlIHNlbGVjdCBhIFdpbmRvd3MgMTEgSVNPIHRvIGJlZ2luLiIvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZD4KCiAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgIDwvVGFiSXRlbT4KICAgICAgICAgICAgPFRhYkl0ZW0gSGVhZGVyPSJBcHBYIiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiIE5hbWU9IldQRlRhYjYiPgogICAgICAgICAgICAgICAgPEdyaWQ+CiAgICAgICAgICAgICAgICAgICAgPEdyaWQuUm93RGVmaW5pdGlvbnM+CiAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIgLz4KICAgICAgICAgICAgICAgICAgICAgICAgPFJvd0RlZmluaXRpb24gSGVpZ2h0PSJBdXRvIiAvPgogICAgICAgICAgICAgICAgICAgIDwvR3JpZC5Sb3dEZWZpbml0aW9ucz4KCiAgICAgICAgICAgICAgICAgICAgPFNjcm9sbFZpZXdlciBWZXJ0aWNhbFNjcm9sbEJhclZpc2liaWxpdHk9IkF1dG8iIEhvcml6b250YWxTY3JvbGxCYXJWaXNpYmlsaXR5PSJEaXNhYmxlZCIgR3JpZC5Sb3c9IjAiIE1hcmdpbj0ie0R5bmFtaWNSZXNvdXJjZSBUYWJDb250ZW50TWFyZ2lufSI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkIEJhY2tncm91bmQ9IlRyYW5zcGFyZW50Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxHcmlkLlJvd0RlZmluaXRpb25zPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iKiIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxSb3dEZWZpbml0aW9uIEhlaWdodD0iQXV0byIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkLlJvd0RlZmluaXRpb25zPgoKICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIE9yaWVudGF0aW9uPSJWZXJ0aWNhbCIgR3JpZC5Sb3c9IjAiIEdyaWQuQ29sdW1uPSIwIiBNYXJnaW49IjUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxMYWJlbCBDb250ZW50PSLpgInmi6nvvJoiIEZvbnRTaXplPSJ7RHluYW1pY1Jlc291cmNlIEZvbnRTaXplfSIgVmVydGljYWxBbGlnbm1lbnQ9IkNlbnRlciIgTWFyZ2luPSIyIi8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFN0YWNrUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIE1hcmdpbj0iMCwyLDAsMCI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGRGVmYXVsdEFwcHhTZWxlY3Rpb24iIENvbnRlbnQ9Ium7mOiupCIgTWFyZ2luPSIyIiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxCdXR0b24gTmFtZT0iV1BGR2V0SW5zdGFsbGVkQXBweCIgQ29udGVudD0i5bey5a6J6KOF5YiX6KGoIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZTZWxlY3RBbGxBcHB4IiBDb250ZW50PSLlhajpgIkiIE1hcmdpbj0iMiIgV2lkdGg9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uV2lkdGh9IiBIZWlnaHQ9IntEeW5hbWljUmVzb3VyY2UgQnV0dG9uSGVpZ2h0fSIvPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkNsZWFyQXBweFNlbGVjdGlvbiIgQ29udGVudD0i5riF6Zmk6YCJ5oupIiBNYXJnaW49IjIiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEdyaWQgTmFtZT0iYXBweHBhbmVsIiBHcmlkLlJvdz0iMSI+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0dyaWQ+CgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJvcmRlciBHcmlkLlJvdz0iMiIgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBCb3JkZXJTdHlsZX0iIE1hcmdpbj0iNSwxNSw1LDUiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIDxTdGFja1BhbmVsIEJhY2tncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkJhY2tncm91bmRDb2xvcn0iIE9yaWVudGF0aW9uPSJIb3Jpem9udGFsIiBIb3Jpem9udGFsQWxpZ25tZW50PSJMZWZ0Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPFRleHRCbG9jayBQYWRkaW5nPSIxMCIgVGV4dFdyYXBwaW5nPSJXcmFwIiBGb3JlZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5Gb3JlZ3JvdW5kQ29sb3J9Ij4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgIE5vdGU6IFNlbGVjdCB0aGUgV2luZG93cyBBcHBYIHBhY2thZ2VzIHlvdSB3aXNoIHRvIGluc3RhbGwgb3IgcmVtb3ZlLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgPExpbmVCcmVhay8+SW5zdGFsbCBTZWxlY3RlZCByZWdpc3RlcnMgYSBsb2NhbCBtYW5pZmVzdCB3aGVuIGF2YWlsYWJsZSwgdGhlbiBmYWxscyBiYWNrIHRvIHRoZSBNaWNyb3NvZnQgU3RvcmUuCiAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8TGluZUJyZWFrLz5SZW1vdmUgU2VsZWN0ZWQgcmVtb3ZlcyBwYWNrYWdlcyBmb3IgdGhlIGN1cnJlbnQgdXNlciBhbmQgYWxsIG5ldyB1c2VyIHByb2ZpbGVzLgogICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1RleHRCbG9jaz4KICAgICAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L1N0YWNrUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8L0JvcmRlcj4KICAgICAgICAgICAgICAgICAgICAgICAgPC9HcmlkPgogICAgICAgICAgICAgICAgICAgIDwvU2Nyb2xsVmlld2VyPgoKICAgICAgICAgICAgICAgICAgICA8Qm9yZGVyIEdyaWQuUm93PSIxIiBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBCb3JkZXJCcnVzaD0ie0R5bmFtaWNSZXNvdXJjZSBCb3JkZXJDb2xvcn0iIEJvcmRlclRoaWNrbmVzcz0iMSIgQ29ybmVyUmFkaXVzPSI1IiBIb3Jpem9udGFsQWxpZ25tZW50PSJTdHJldGNoIiBQYWRkaW5nPSIxMCI+CiAgICAgICAgICAgICAgICAgICAgICAgIDxXcmFwUGFuZWwgT3JpZW50YXRpb249Ikhvcml6b250YWwiIEhvcml6b250YWxBbGlnbm1lbnQ9IkxlZnQiIFZlcnRpY2FsQWxpZ25tZW50PSJDZW50ZXIiPgogICAgICAgICAgICAgICAgICAgICAgICAgICAgPEJ1dHRvbiBOYW1lPSJXUEZCYWNrVG9Ud2Vha3MiIENvbnRlbnQ9Iui/lOWbnuS8mOWMliIgTWFyZ2luPSI1IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRkluc3RhbGxTZWxlY3RlZEFwcHgiIENvbnRlbnQ9IuWuieijhemAieS4rSIgTWFyZ2luPSI1IiBXaWR0aD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25XaWR0aH0iIEhlaWdodD0ie0R5bmFtaWNSZXNvdXJjZSBCdXR0b25IZWlnaHR9Ii8+CiAgICAgICAgICAgICAgICAgICAgICAgICAgICA8QnV0dG9uIE5hbWU9IldQRlJlbW92ZVNlbGVjdGVkQXBweCIgQ29udGVudD0i56e76Zmk6YCJ5LitIiBNYXJnaW49IjUiIFdpZHRoPSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbldpZHRofSIgSGVpZ2h0PSJ7RHluYW1pY1Jlc291cmNlIEJ1dHRvbkhlaWdodH0iLz4KICAgICAgICAgICAgICAgICAgICAgICAgPC9XcmFwUGFuZWw+CiAgICAgICAgICAgICAgICAgICAgPC9Cb3JkZXI+CiAgICAgICAgICAgICAgICA8L0dyaWQ+CiAgICAgICAgICAgIDwvVGFiSXRlbT4KICAgICAgICA8L1RhYkNvbnRyb2w+CgogICAgICAgIDwhLS0gV2luZG93LWxldmVsIHByb2dyZXNzIGluZGljYXRvciAtIHZpc2libGUgcmVnYXJkbGVzcyBvZiBhY3RpdmUgdGFiIC0tPgogICAgICAgIDxCb3JkZXIgTmFtZT0iV1BGVHdlYWtzUHJvZ3Jlc3NCYXIiIEdyaWQuUm93PSIzIiBCYWNrZ3JvdW5kPSJ7RHluYW1pY1Jlc291cmNlIE1haW5CYWNrZ3JvdW5kQ29sb3J9IiBWaXNpYmlsaXR5PSJDb2xsYXBzZWQiIFBhZGRpbmc9IjEwLDYiPgogICAgICAgICAgICA8U3RhY2tQYW5lbCBPcmllbnRhdGlvbj0iVmVydGljYWwiPgogICAgICAgICAgICAgICAgPFRleHRCbG9jayBOYW1lPSJXUEZUd2Vha3NQcm9ncmVzc0xhYmVsIiBUZXh0PSIiIEZvcmVncm91bmQ9IntEeW5hbWljUmVzb3VyY2UgTWFpbkZvcmVncm91bmRDb2xvcn0iIEZvbnRTaXplPSIxMyIgQmFja2dyb3VuZD0iVHJhbnNwYXJlbnQiIE1hcmdpbj0iMCwwLDAsNCIvPgogICAgICAgICAgICAgICAgPFByb2dyZXNzQmFyIE5hbWU9IldQRlR3ZWFrc1Byb2dyZXNzVmFsdWUiIEhlaWdodD0iNiIgTWluaW11bT0iMCIgTWF4aW11bT0iMTAwIiBWYWx1ZT0iMCIgU3R5bGU9IntTdGF0aWNSZXNvdXJjZSBSb3VuZGVkUHJvZ3Jlc3NCYXJTdHlsZX0iLz4KICAgICAgICAgICAgPC9TdGFja1BhbmVsPgogICAgICAgIDwvQm9yZGVyPgogICAgPC9HcmlkPgo8L1dpbmRvdz4K'))



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
    switch ($sync.currentTab) {
        "Install" {
            Find-AppsByNameOrDescription -SearchString $sync.SearchBar.Text -Category $sync.SearchBar.Tag
        }
        "Tweaks" {
            Find-TweaksByNameOrDescription -SearchString $sync.SearchBar.Text
        }
        "AppX" {
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
$sync["WPFSearchChipBrowsers"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Browsers" })
$sync["WPFSearchChipCommunications"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Communications" })
$sync["WPFSearchChipDevelopment"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Development" })
$sync["WPFSearchChipGames"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Games" })
$sync["WPFSearchChipMicrosoftTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Microsoft Tools" })
$sync["WPFSearchChipMultimediaTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Multimedia Tools" })
$sync["WPFSearchChipProTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Pro Tools" })
$sync["WPFSearchChipSelfhostedTools"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Selfhosted Tools" })
$sync["WPFSearchChipUtilities"].Add_Click({ Set-WinUtilAppCategoryFilter -Category "Utilities" })

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
