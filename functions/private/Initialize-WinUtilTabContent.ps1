function Initialize-WinUtilTabContent {
    param(
        [Parameter(Mandatory = $true)]
        [string]$TabName
    )

    # 先做名称归一化，再检查缓存，避免 main.ps1 用英文名初始化后
    # 用户点击中文标签再次初始化（产生重复无功能的按钮）
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

    if ($null -eq $sync.InitializedTabs) {
        $sync.InitializedTabs = @{}
    }

    if ($sync.InitializedTabs[$normalizedTab]) {
        return
    }

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

    $sync.InitializedTabs[$normalizedTab] = $true
}
