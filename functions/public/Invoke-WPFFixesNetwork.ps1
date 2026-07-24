function Invoke-WPFFixesNetwork {
    netsh winsock reset
    netsh int ip reset
    Write-Host "网络配置已重置。请重新启动计算机。"
}
