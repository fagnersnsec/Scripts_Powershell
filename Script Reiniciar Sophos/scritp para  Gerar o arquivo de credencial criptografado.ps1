$cred = Get-Credential -UserName "admin" -Message "Qwe@123..@"
$cred | Export-Clixml -Path "D:\logs\sophos_cred.xml"