$ErrorActionPreference='Stop'
$ProgressPreference='SilentlyContinue'
foreach ($item in @{ 'llama.zip'='fc6df285aaeabb0d70ed87cad763d0bae0c1d1242bcc9f8dec1f4caf09f84de0'; 'cudart.zip'='8c79a9b226de4b3cacfd1f83d24f962d0773be79f1e7b75c6af4ded7e32ae1d6'; 'decider-0.8b.Q8_0.gguf'='2665d08c1052b4e01dabcb08771d25579f6776f7066355e4a0ccc5f74e32d4a2' }.GetEnumerator()) {
    if ((Get-FileHash (Join-Path 'D:\Decider' $item.Key) -Algorithm SHA256).Hash -ne $item.Value) { throw "Checksum mismatch: $($item.Key)" }
}
Expand-Archive D:\Decider\llama.zip D:\Decider\runtime -Force
Expand-Archive D:\Decider\cudart.zip D:\Decider\runtime -Force
$cmd = '@echo off' + "`r`n" + 'cd /d D:\Decider\runtime' + "`r`n" + 'llama-server.exe -m D:\Decider\decider-0.8b.Q8_0.gguf --host 192.168.31.213 --port 47839 -ngl 99 -c 32768 -b 8192 -ub 512 -t 4 -np 1 --no-webui >>D:\Decider\runtime.log 2>&1' + "`r`n"
Set-Content D:\Decider\start.cmd $cmd -Encoding Ascii
$action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument '/c D:\Decider\start.cmd' -WorkingDirectory 'D:\Decider'
$trigger = New-ScheduledTaskTrigger -AtStartup
$settings = New-ScheduledTaskSettingsSet -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit ([TimeSpan]::Zero) -StartWhenAvailable
Register-ScheduledTask -TaskName 'Yedu-Decider-4090' -Action $action -Trigger $trigger -Settings $settings -User 'SYSTEM' -RunLevel Highest -Force | Out-Null
Get-NetFirewallRule -DisplayName 'Yedu-Decider-MINI-47839' -ErrorAction SilentlyContinue | Remove-NetFirewallRule
New-NetFirewallRule -DisplayName 'Yedu-Decider-MINI-47839' -Direction Inbound -Action Allow -Protocol TCP -LocalPort 47839 -RemoteAddress 192.168.31.38 -Profile Any | Out-Null
Start-ScheduledTask -TaskName 'Yedu-Decider-4090'
Write-Output 'DECIDER_TASK_STARTED'
