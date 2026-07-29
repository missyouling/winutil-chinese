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
        $count = $sync.selectedApps.Count

        # Update button visual feedback based on selection count
        $installBtn = $sync.WPFInstall
        $upgradeBtn = $sync.WPFInstallUpgrade
        $clearBtn = $sync.WPFClearInstallSelection

        $highlightBg = [System.Windows.Media.Brushes]::Black
        $highlightFg = [System.Windows.Media.Brushes]::White
        $defaultBg = $null  # null → fall back to DynamicResource style
        $defaultFg = [System.Windows.Media.Brushes]::White

        if ($count -eq 0) {
            # No selection → all buttons default
            if ($installBtn) { $installBtn.Background = $defaultBg; $installBtn.Foreground = $defaultFg }
            if ($upgradeBtn) { $upgradeBtn.Background = $defaultBg; $upgradeBtn.Foreground = $defaultFg }
            if ($clearBtn)  { $clearBtn.Background = $defaultBg; $clearBtn.Foreground = $defaultFg }
        } elseif ($count -eq 1) {
            # Single selection → highlight only Install button
            if ($installBtn) { $installBtn.Background = $highlightBg; $installBtn.Foreground = $highlightFg }
            if ($upgradeBtn) { $upgradeBtn.Background = $defaultBg; $upgradeBtn.Foreground = $defaultFg }
            if ($clearBtn)  { $clearBtn.Background = $defaultBg; $clearBtn.Foreground = $defaultFg }
        } else {
            # Multiple selections → highlight Install, Upgrade, Clear buttons
            if ($installBtn) { $installBtn.Background = $highlightBg; $installBtn.Foreground = $highlightFg }
            if ($upgradeBtn) { $upgradeBtn.Background = $highlightBg; $upgradeBtn.Foreground = $highlightFg }
            if ($clearBtn)  { $clearBtn.Background = $highlightBg; $clearBtn.Foreground = $highlightFg }
        }

        $sync.WPFselectedAppsButton.Content = "已选应用： $count"
        $sync.selectedAppsstackPanel.Children.Clear()
        $sync.selectedApps | Sort-Object | ForEach-Object {
            Add-SelectedAppsMenuItem -name $sync.configs.applicationsHashtable.$_.Content -key $_
        }
    }
}
