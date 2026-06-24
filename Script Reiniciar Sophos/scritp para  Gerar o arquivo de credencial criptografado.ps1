
#script para a credencial criptografa do sophos.
$cred = Get-Credential -UserName "admin" -Message "abc@123"
$cred | Export-Clixml -Path "D:\logs\sophos_cred.xml"