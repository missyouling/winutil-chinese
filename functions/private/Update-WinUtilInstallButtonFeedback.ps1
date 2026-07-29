function Update-WinUtilInstallButtonFeedback {
    <#
    .SYNOPSIS
        Updates the visual feedback of installation-related buttons based on
        how many apps are currently selected.

    .DESCRIPTION
        - 0 selected: all buttons reset to theme default
        - 1 selected: only Install button highlighted (Black bg, White fg)
        - 2+ selected: Install, Upgrade, and Clear buttons all highlighted

        Uses ClearValue to revert to theme's DynamicResource style instead of
        setting $null, which avoids local-value override issues in WPF.
    #>
    param (
        [int]$Count = 0
    )

    $installBtn = $sync.WPFInstall
    $upgradeBtn = $sync.WPFInstallUpgrade
    $clearBtn = $sync.WPFClearInstallSelection
    $highlightBg = [System.Windows.Media.Brushes]::Black
    $highlightFg = [System.Windows.Media.Brushes]::White
    $ctrlType = [Windows.Controls.Control]

    # Helper to reset a button to theme default by clearing local values
    $resetBtn = {
        param($btn)
        if (-not $btn) { return }
        $btn.ClearValue($ctrlType::BackgroundProperty)
        $btn.ClearValue($ctrlType::ForegroundProperty)
    }

    # Helper to highlight a button (black bg, white fg)
    $highlightBtn = {
        param($btn)
        if (-not $btn) { return }
        $btn.Background = $highlightBg
        $btn.Foreground = $highlightFg
    }

    if ($Count -eq 0) {
        & $resetBtn $installBtn
        & $resetBtn $upgradeBtn
        & $resetBtn $clearBtn
    } elseif ($Count -eq 1) {
        & $highlightBtn $installBtn
        & $resetBtn $upgradeBtn
        & $resetBtn $clearBtn
    } else {
        & $highlightBtn $installBtn
        & $highlightBtn $upgradeBtn
        & $highlightBtn $clearBtn
    }
}
