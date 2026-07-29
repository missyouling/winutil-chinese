function Update-WinUtilInstallButtonFeedback {
    <#
    .SYNOPSIS
        Updates the visual feedback of installation-related buttons based on
        how many apps are currently selected.

    .DESCRIPTION
        - 0 selected: all buttons reset to theme default
        - 1 selected: only Install button highlighted (Black bg, White fg)
        - 2+ selected: Install, Upgrade, and Clear buttons all highlighted
    #>
    param (
        [int]$Count = 0
    )

    $installBtn = $sync.WPFInstall
    $upgradeBtn = $sync.WPFInstallUpgrade
    $clearBtn = $sync.WPFClearInstallSelection
    $highlightBg = [System.Windows.Media.Brushes]::Black
    $highlightFg = [System.Windows.Media.Brushes]::White

    # $null = let theme's DynamicResource style take over (default look)
    $defaultBg = $null
    $defaultFg = $null

    if ($Count -eq 0) {
        if ($installBtn) { $installBtn.Background = $defaultBg; $installBtn.Foreground = $defaultFg }
        if ($upgradeBtn)  { $upgradeBtn.Background  = $defaultBg; $upgradeBtn.Foreground  = $defaultFg }
        if ($clearBtn)   { $clearBtn.Background   = $defaultBg; $clearBtn.Foreground   = $defaultFg }
    } elseif ($Count -eq 1) {
        if ($installBtn) { $installBtn.Background = $highlightBg; $installBtn.Foreground = $highlightFg }
        if ($upgradeBtn)  { $upgradeBtn.Background  = $defaultBg; $upgradeBtn.Foreground  = $defaultFg }
        if ($clearBtn)   { $clearBtn.Background   = $defaultBg; $clearBtn.Foreground   = $defaultFg }
    } else {
        if ($installBtn) { $installBtn.Background = $highlightBg; $installBtn.Foreground = $highlightFg }
        if ($upgradeBtn)  { $upgradeBtn.Background  = $highlightBg; $upgradeBtn.Foreground  = $highlightFg }
        if ($clearBtn)   { $clearBtn.Background   = $highlightBg; $clearBtn.Foreground   = $highlightFg }
    }
}
