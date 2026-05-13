# ============================================================
#  Criação de Máquina Virtual no Hyper-V
#  Ambiente: A partir do Windows Server 2019 ou superior
#  v3.1 — Correção do template de Secure Boot
# ============================================================

# ============================================================
# 0. Solicitar o Nome da VM ao operador
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   CRIAÇÃO DE MÁQUINA VIRTUAL - HYPER-V"    -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

do {
    $VMName = (Read-Host "  >> Informe o Nome da Máquina Virtual").Trim()

    if ([string]::IsNullOrWhiteSpace($VMName)) {
        Write-Host "  [AVISO] O nome não pode ser vazio. Tente novamente." -ForegroundColor Yellow
    }
} while ([string]::IsNullOrWhiteSpace($VMName))

Write-Host ""
Write-Host "  Nome definido: '$VMName'" -ForegroundColor Green
Write-Host ""

# --- Confirmação antes de prosseguir ---
$confirmacao = Read-Host "  >> Confirma a criação da VM '$VMName'? (S/N)"
if ($confirmacao.Trim().ToUpper() -ne "S") {
    Write-Host ""
    Write-Host "  Operação cancelada pelo operador." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "  Iniciando criação da VM '$VMName'..." -ForegroundColor Cyan
Write-Host ""

# ============================================================
# Variáveis fixas de configuração (Substitua por sua preferencia)
# ============================================================
$VMPath     = "E:\VMS"
$MemoryRAM  = 4GB
$vCPU       = 4
$DiskSize   = 200GB
$NICName    = "vNIC1"
$SwitchName = "vSWITCH-01"
$Generation = 2
$ISOPath    = "E:\ISOS\pt-br_windows_server_2019_updated_aug_2021_x64_dvd.iso"

# Caminhos derivados do nome informado
$VMFolder   = Join-Path $VMPath $VMName
$VHDXPath   = Join-Path $VMFolder "$VMName.vhdx"

# ============================================================
# 1. Validar se a ISO existe antes de prosseguir
# ============================================================
if (-not (Test-Path $ISOPath)) {
    Write-Host "[ERRO] ISO não encontrada em: $ISOPath" -ForegroundColor Red
    Write-Host "       Verifique o caminho e execute o script novamente." -ForegroundColor Red
    exit 1
}
Write-Host "[OK] ISO localizada: $ISOPath" -ForegroundColor Green

# ============================================================
# 2. Garantir que o diretório de destino existe
# ============================================================
if (-not (Test-Path $VMFolder)) {
    New-Item -ItemType Directory -Path $VMFolder -Force | Out-Null
    Write-Host "[OK] Diretório criado: $VMFolder" -ForegroundColor Green
} else {
    Write-Host "[OK] Diretório já existe: $VMFolder" -ForegroundColor Yellow
}

# ============================================================
# 3. Criar o disco virtual dinâmico (VHDX) de 200 GB
# ============================================================
New-VHD -Path $VHDXPath `
        -SizeBytes $DiskSize `
        -Dynamic | Out-Null

Write-Host "[OK] Disco VHDX criado: $VHDXPath" -ForegroundColor Green

# ============================================================
# 4. Criar a Máquina Virtual e remover o adaptador de rede padrão
# ============================================================
New-VM -Name $VMName `
       -Generation $Generation `
       -MemoryStartupBytes $MemoryRAM `
       -Path $VMPath `
       -NoVHD | Out-Null

Write-Host "[OK] VM '$VMName' criada (Geração $Generation)" -ForegroundColor Green

# O New-VM sempre cria um adaptador "Network Adapter" padrão; removê-lo
# para que a VM fique apenas com o adaptador personalizado (vNIC1)
Get-VMNetworkAdapter -VMName $VMName | Remove-VMNetworkAdapter

Write-Host "[OK] Adaptador de rede padrão removido" -ForegroundColor Green

# ============================================================
# 5. Configurar vCPUs
# ============================================================
Set-VMProcessor -VMName $VMName `
                -Count $vCPU

Write-Host "[OK] vCPUs configuradas: $vCPU" -ForegroundColor Green

# ============================================================
# 6. Desabilitar memória dinâmica e fixar em 4 GB
# ============================================================
Set-VMMemory -VMName $VMName `
             -DynamicMemoryEnabled $false `
             -StartupBytes $MemoryRAM

Write-Host "[OK] Memória RAM fixada em 4 GB" -ForegroundColor Green

# ============================================================
# 7. Anexar o disco VHDX ao controlador SCSI (slot 0)
# ============================================================
Add-VMHardDiskDrive -VMName $VMName `
                    -Path $VHDXPath `
                    -ControllerType SCSI `
                    -ControllerNumber 0 `
                    -ControllerLocation 0

Write-Host "[OK] Disco VHDX anexado (SCSI 0:0)" -ForegroundColor Green

# ============================================================
# 8. Adicionar Drive de DVD Virtual e montar a ISO
# ============================================================
Add-VMDvdDrive -VMName $VMName `
               -ControllerNumber 0 `
               -ControllerLocation 1

$DVDDrive = Get-VMDvdDrive -VMName $VMName

Set-VMDvdDrive -VMName $VMName `
               -ControllerNumber $DVDDrive.ControllerNumber `
               -ControllerLocation $DVDDrive.ControllerLocation `
               -Path $ISOPath

Write-Host "[OK] Drive de DVD criado e ISO montada (SCSI 0:1)" -ForegroundColor Green

# ============================================================
# 9. Adicionar adaptador de rede e vincular ao Switch Virtual
# ============================================================
Add-VMNetworkAdapter -VMName $VMName `
                     -Name $NICName `
                     -SwitchName $SwitchName

Write-Host "[OK] Adaptador '$NICName' vinculado ao switch '$SwitchName'" -ForegroundColor Green

# ============================================================
# 10. Habilitar Secure Boot com template correto para Windows
#     ✔ "MicrosoftWindows"  → Windows Server / Windows 10+
#     ✗ "MicrosoftUEFI"     → apenas para Linux (Ubuntu, etc.)
# ============================================================
Set-VMFirmware -VMName $VMName `
               -EnableSecureBoot On `
               -SecureBootTemplate MicrosoftWindows

Write-Host "[OK] Secure Boot habilitado (template: MicrosoftWindows)" -ForegroundColor Green

# ============================================================
# 11. Definir ordem de boot: DVD (ISO) → Disco SCSI
# ============================================================
$BootDVD  = Get-VMDvdDrive      -VMName $VMName
$BootDisk = Get-VMHardDiskDrive -VMName $VMName

Set-VMFirmware -VMName $VMName `
               -BootOrder $BootDVD, $BootDisk

Write-Host "[OK] Ordem de boot: DVD (ISO) → Disco SCSI" -ForegroundColor Green

# ============================================================
# 12. Iniciar a VM — boot imediato pela ISO
# ============================================================
Start-VM -Name $VMName

Write-Host ""
Write-Host "[OK] VM '$VMName' iniciada! Aguardando heartbeat..." -ForegroundColor Green

$timeout  = 60
$elapsed  = 0
$interval = 5

while ($elapsed -lt $timeout) {
    Start-Sleep -Seconds $interval
    $elapsed += $interval
    $state = (Get-VM -Name $VMName).State
    Write-Host "    Estado atual: $state ($elapsed s)" -ForegroundColor DarkGray
    if ($state -eq "Running") { break }
}

# ============================================================
# 13. Resumo final
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  RESUMO DA VM CRIADA E INICIADA"            -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan

Get-VM -Name $VMName | Select-Object Name, Generation, State,
    @{N="RAM (GB)";  E={ [math]::Round($_.MemoryAssigned/1GB,0) }},
    @{N="vCPUs";     E={ $_.ProcessorCount }},
    @{N="Diretório"; E={ $_.Path }} |
    Format-List

Get-VMHardDiskDrive -VMName $VMName |
    Select-Object VMName, Path,
    @{N="Tamanho (GB)"; E={ [math]::Round((Get-VHD $_.Path).Size/1GB,0) }} |
    Format-List

Get-VMDvdDrive -VMName $VMName |
    Select-Object VMName,
    @{N="ISO Montada"; E={ $_.Path }} |
    Format-List

Get-VMNetworkAdapter -VMName $VMName |
    Select-Object VMName, Name, SwitchName |
    Format-List

Write-Host "A VM está rodando e bootando pela ISO."                                             -ForegroundColor Cyan
Write-Host "Abra o Hyper-V Manager e conecte-se à '$VMName' para prosseguir com a instalação." -ForegroundColor Cyan