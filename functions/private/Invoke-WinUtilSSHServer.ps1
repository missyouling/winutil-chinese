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
