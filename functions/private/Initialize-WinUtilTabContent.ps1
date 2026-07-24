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
        $sync.configs.strings.tabInstall = "Install"
        $sync.configs.strings.tabTweaks = "Tweaks"
        $sync.configs.strings.tabConfig = "Config"
        $sync.configs.strings.tabUpdates = "Updates"
        $sync.configs.strings.tabWin11 = "Win11ISO"
        $sync.configs.strings.tabAppX = "AppX"
        "AppX" = "AppX"
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
