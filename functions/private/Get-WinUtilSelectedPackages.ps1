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
    $packagesScoop = [System.Collections.ArrayList]::new()
    $packages = @{
        Winget = $packagesWinget
        Choco = $packagesChoco
        Scoop = $packagesScoop
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
            "Winget" {
                if ([string]::IsNullOrWhiteSpace([string]$package.winget) -or $package.winget -eq "na") {
                    if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                        Add-PackageId -Target $packagesScoop -PackageId $package.scoop
                    } else {
                        Add-PackageId -Target $packagesChoco -PackageId $package.choco
                    }
                } else {
                    Add-PackageId -Target $packagesWinget -PackageId $package.winget
                }
            }
            "Choco" {
                if ([string]::IsNullOrWhiteSpace([string]$package.choco) -or $package.choco -eq "na") {
                    if ([string]::IsNullOrWhiteSpace([string]$package.winget) -or $package.winget -eq "na") {
                        Add-PackageId -Target $packagesScoop -PackageId $package.scoop
                    } else {
                        Add-PackageId -Target $packagesWinget -PackageId $package.winget
                    }
                } else {
                    Add-PackageId -Target $packagesChoco -PackageId $package.choco
                }
            }
            "Scoop" {
                if ([string]::IsNullOrWhiteSpace([string]$package.scoop) -or $package.scoop -eq "na") {
                    if ([string]::IsNullOrWhiteSpace([string]$package.winget) -or $package.winget -eq "na") {
                        Add-PackageId -Target $packagesChoco -PackageId $package.choco
                    } else {
                        Add-PackageId -Target $packagesWinget -PackageId $package.winget
                    }
                } else {
                    Add-PackageId -Target $packagesScoop -PackageId $package.scoop
                }
            }
        }
    }

    return $packages
}
