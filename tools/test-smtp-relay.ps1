$relays = @('mail.wtg.zone', 'smtp.wtg.zone', 'relay.wtg.zone', 'mailrelay.wtg.zone')
foreach ($r in $relays) {
    try {
        $tcp = New-Object System.Net.Sockets.TcpClient
        $task = $tcp.ConnectAsync($r, 25)
        if ($task.Wait(3000) -and $tcp.Connected) {
            Write-Host "$r`:25 REACHABLE"
        } else {
            Write-Host "$r`:25 TIMEOUT"
        }
        $tcp.Dispose()
    } catch {
        Write-Host "$r`:25 UNREACHABLE"
    }
}

# Also try Office365 on port 587
try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $task = $tcp.ConnectAsync('smtp.office365.com', 587)
    if ($task.Wait(3000) -and $tcp.Connected) {
        Write-Host "smtp.office365.com:587 REACHABLE"
    }
    $tcp.Dispose()
} catch {}
