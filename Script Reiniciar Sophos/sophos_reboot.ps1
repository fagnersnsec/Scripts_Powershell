Import-Module Posh-SSH

# Carrega credencial criptografada do disco
$cred = Import-Clixml -Path "D:\logs\sophos_cred.xml"

$session = New-SSHSession -ComputerName "172.16.0.200" -Credential $cred -AcceptKey
$stream  = New-SSHShellStream -SessionId $session.SessionId

Start-Sleep -Seconds 2
$stream.Write("7`n")   # Shutdown/Restart
Start-Sleep -Seconds 1
$stream.Write("r`n")   # Reboot
Start-Sleep -Seconds 2

Remove-SSHSession -SessionId $session.SessionId