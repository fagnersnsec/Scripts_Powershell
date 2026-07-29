# ============================================================
#  Criação de Máquina Virtual no Hyper-V
#  Ambiente: A partir do Windows Server 2019 ou superior
#  v4.0 — Seleção interativa de Switch Virtual e ISO
#  v4.1 — Opção de habilitar Virtualização Aninhada (Nested)
# ============================================================

# ============================================================
# Funções auxiliares
# ============================================================
function Read-Confirmacao {
    <#
        Pergunta (S/N) com reprompt e valor padrão aplicado ao ENTER vazio.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Pergunta,
        [ValidateSet('S', 'N')][string]$Padrao = 'N'
    )

    $sufixo = if ($Padrao -eq 'S') { '(S/n)' } else { '(s/N)' }

    while ($true) {
        $resposta = (Read-Host "  >> $Pergunta $sufixo").Trim().ToUpper()

        if ([string]::IsNullOrWhiteSpace($resposta)) { return ($Padrao -eq 'S') }
        if ($resposta -eq 'S') { return $true }
        if ($resposta -eq 'N') { return $false }

        Write-Host "  [AVISO] Resposta inválida. Informe 'S' ou 'N'." -ForegroundColor Yellow
    }
}

function Test-NestedVirtualizationSupport {
    <#
        Avalia os pré-requisitos do HOST para Virtualização Aninhada.
        Fonte oficial:
        https://learn.microsoft.com/windows-server/virtualization/hyper-v/enable-nested-virtualization
          - Intel (VT-x + EPT) : host Windows Server 2016+ / Windows 10+, versão de configuração da VM >= 8.0
          - AMD (EPYC/Ryzen+)  : host Windows Server 2022+ / Windows 11+, versão de configuração da VM >= 9.3
    #>
    $resultado = [pscustomobject]@{
        Suportado      = $false
        Fabricante     = 'Desconhecido'
        BuildHost      = 0
        VersaoMinimaVM = '8.0'
        Motivo         = ''
    }

    try {
        $cpu   = Get-CimInstance -ClassName Win32_Processor       -ErrorAction Stop | Select-Object -First 1
        $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber

        $resultado.Fabricante = $cpu.Manufacturer
        $resultado.BuildHost  = $build

        switch -Wildcard ($cpu.Manufacturer) {
            '*Intel*' {
                $resultado.VersaoMinimaVM = '8.0'
                if ($build -ge 14393) {
                    $resultado.Suportado = $true
                    $resultado.Motivo    = "CPU Intel e host build $build (Windows Server 2016+ / Windows 10+)."
                } else {
                    $resultado.Motivo    = "CPU Intel, porém o host build $build é anterior ao Windows Server 2016."
                }
            }
            '*AMD*' {
                # AMD exige host bem mais novo que Intel — build 20348 = Windows Server 2022
                $resultado.VersaoMinimaVM = '9.3'
                if ($build -ge 20348) {
                    $resultado.Suportado = $true
                    $resultado.Motivo    = "CPU AMD e host build $build (Windows Server 2022+ / Windows 11+)."
                } else {
                    $resultado.Motivo    = "CPU AMD exige host Windows Server 2022+ / Windows 11+ (build 20348 ou superior); host atual: build $build."
                }
            }
            default {
                $resultado.Motivo = "Fabricante de CPU não reconhecido: '$($cpu.Manufacturer)'."
            }
        }
    }
    catch {
        $resultado.Motivo = "Não foi possível consultar o hardware do host: $($_.Exception.Message)"
    }

    return $resultado
}

# ============================================================
# 0. Solicitar o Nome da VM ao operador
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   CRIAÇÃO DE MÁQUINA VIRTUAL - HYPER-V"    -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

do {
    $VMName = (Read-Host "  >> Informe o Nome da Maquina Virtual").Trim()

    if ([string]::IsNullOrWhiteSpace($VMName)) {
        Write-Host "  [AVISO] O nome não pode ser vazio. Tente novamente." -ForegroundColor Yellow
    }
} while ([string]::IsNullOrWhiteSpace($VMName))

Write-Host ""
Write-Host "  Nome definido: '$VMName'" -ForegroundColor Green
Write-Host ""

# ============================================================
# Variáveis fixas de configuração (Substitua por sua preferencia)
# ============================================================
$VMPath     = "E:\VMS"
$MemoryRAM  = 4GB
$vCPU       = 4
$DiskSize   = 200GB
$NICName    = "vNIC1"
$Generation = 2
$ISODir     = "E:\ISOS"

# ============================================================
# 0.1 Seleção interativa do Switch Virtual
# ============================================================
Write-Host "  --- Switches Virtuais disponiveis no servidor Hyper-V ---" -ForegroundColor Cyan

$Switches = @(Get-VMSwitch | Sort-Object Name)

if ($Switches.Count -eq 0) {
    Write-Host "  [ERRO] Nenhum Switch Virtual encontrado neste servidor Hyper-V." -ForegroundColor Red
    Write-Host "         Crie um Switch Virtual antes de prosseguir." -ForegroundColor Red
    exit 1
}

for ($i = 0; $i -lt $Switches.Count; $i++) {
    $sw = $Switches[$i]
    Write-Host ("    [{0}] {1}  (Tipo: {2})" -f ($i + 1), $sw.Name, $sw.SwitchType) -ForegroundColor White
}

do {
    $opcao  = (Read-Host "  >> Selecione o numero do Switch Virtual desejado").Trim()
    $valido = $false

    if ($opcao -match '^\d+$') {
        $idx = [int]$opcao - 1
        if ($idx -ge 0 -and $idx -lt $Switches.Count) {
            $valido     = $true
            $SwitchName = $Switches[$idx].Name
        }
    }

    if (-not $valido) {
        Write-Host "  [AVISO] Opção inválida. Informe um número entre 1 e $($Switches.Count)." -ForegroundColor Yellow
    }
} while (-not $valido)

Write-Host "  Switch selecionado: '$SwitchName'" -ForegroundColor Green
Write-Host ""

# ============================================================
# 0.2 Seleção interativa da ISO (Sistema Operacional)
# ============================================================
Write-Host "  --- ISOs disponíveis em '$ISODir' ---" -ForegroundColor Cyan

if (-not (Test-Path $ISODir)) {
    Write-Host "  [ERRO] Diretório de ISOs nao encontrado: $ISODir" -ForegroundColor Red
    Write-Host "         Ajuste a variável \$ISODir no script e tente novamente." -ForegroundColor Red
    exit 1
}

$ISOs = @(Get-ChildItem -Path $ISODir -Filter *.iso -File | Sort-Object Name)

if ($ISOs.Count -eq 0) {
    Write-Host "  [ERRO] Nenhum arquivo .iso encontrado em '$ISODir'." -ForegroundColor Red
    Write-Host "         Copie ao menos um instalador (.iso) para o diretório e tente novamente." -ForegroundColor Red
    exit 1
}

for ($i = 0; $i -lt $ISOs.Count; $i++) {
    $iso   = $ISOs[$i]
    $tamGB = [math]::Round($iso.Length / 1GB, 2)
    Write-Host ("    [{0}] {1}  ({2} GB)" -f ($i + 1), $iso.Name, $tamGB) -ForegroundColor White
}

do {
    $opcao  = (Read-Host "  >> Qual sistema operacional você deseja instalar?").Trim()
    $valido = $false

    if ($opcao -match '^\d+$') {
        $idx = [int]$opcao - 1
        if ($idx -ge 0 -and $idx -lt $ISOs.Count) {
            $valido  = $true
            $ISOPath = $ISOs[$idx].FullName
        }
    }

    if (-not $valido) {
        Write-Host "  [AVISO] Opção inválida. Informe um número entre 1 e $($ISOs.Count)." -ForegroundColor Yellow
    }
} while (-not $valido)

Write-Host "  ISO selecionada: '$ISOPath'" -ForegroundColor Green
Write-Host ""

# ============================================================
# 0.25 Virtualização Aninhada (Nested Virtualization)
# ============================================================
Write-Host "  --- Virtualização Aninhada (Nested) ---" -ForegroundColor Cyan
Write-Host "  Permite executar Hyper-V, WSL2, Sandbox ou containers Hyper-V DENTRO desta VM." -ForegroundColor DarkGray
Write-Host "  Pré-requisitos da VM (Geração 2, memória dinâmica off, 2+ vCPUs) já são atendidos." -ForegroundColor DarkGray
Write-Host ""

$suporteNested = Test-NestedVirtualizationSupport

if ($suporteNested.Suportado) {
    Write-Host "  [OK] Host compatível. $($suporteNested.Motivo)" -ForegroundColor Green
} else {
    Write-Host "  [AVISO] $($suporteNested.Motivo)" -ForegroundColor Yellow
    Write-Host "          Habilitar mesmo assim pode falhar ao aplicar ou ao iniciar a VM." -ForegroundColor Yellow
}

Write-Host ""
$EnableNested      = Read-Confirmacao -Pergunta "Deseja habilitar a Virtualização Aninhada nesta VM?" -Padrao 'N'
$EnableMacSpoofing = $false

if ($EnableNested) {
    Write-Host ""
    Write-Host "  [AVISO] Sem MAC Address Spoofing, as VMs criadas DENTRO desta VM não" -ForegroundColor Yellow
    Write-Host "          conseguem trafegar pela rede através do switch do host." -ForegroundColor Yellow
    $EnableMacSpoofing = Read-Confirmacao -Pergunta "Habilitar MAC Address Spoofing no adaptador '$NICName'?" -Padrao 'S'
}

Write-Host ""

# ============================================================
# 0.3 Resumo e confirmação antes de criar a VM
# ============================================================
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "   RESUMO DA CONFIGURAÇÃO"                    -ForegroundColor Cyan
Write-Host "  ============================================" -ForegroundColor Cyan
Write-Host "    Nome da VM......: $VMName"
Write-Host "    Switch Virtual..: $SwitchName"
Write-Host "    ISO (Boot)......: $ISOPath"
Write-Host "    Memória RAM.....: $([int]($MemoryRAM/1GB)) GB"
Write-Host "    vCPUs...........: $vCPU"
Write-Host "    Disco VHDX......: $([int]($DiskSize/1GB)) GB"
Write-Host "    Diretório VMs...: $VMPath"
Write-Host "    Virt. Aninhada..: $(if ($EnableNested) { 'SIM' } else { 'NAO' })"
Write-Host "    MAC Spoofing....: $(if ($EnableMacSpoofing) { 'ON' } else { 'OFF' })"
Write-Host ""

$confirmacao = Read-Host "  >> Confirma a criação da VM '$VMName'? (S/N)"
if ($confirmacao.Trim().ToUpper() -ne "S") {
    Write-Host ""
    Write-Host "  Operação cancelada pelo operador." -ForegroundColor Yellow
    exit 0
}

Write-Host ""
Write-Host "  Iniciando criação da VM '$VMName'..." -ForegroundColor Cyan
Write-Host ""

# Caminhos derivados do nome informado
$VMFolder = Join-Path $VMPath $VMName
$VHDXPath = Join-Path $VMFolder "$VMName.vhdx"

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
# 5.1 Habilitar Virtualização Aninhada (Nested Virtualization)
#     A VM PRECISA estar desligada — este é o momento correto, antes do Start-VM.
#     Fonte: https://learn.microsoft.com/windows-server/virtualization/hyper-v/enable-nested-virtualization
# ============================================================
if ($EnableNested) {
    try {
        Set-VMProcessor -VMName $VMName `
                        -ExposeVirtualizationExtensions $true `
                        -ErrorAction Stop

        # Releitura para confirmar que a propriedade realmente ficou ativa
        $nestedAtivo = (Get-VMProcessor -VMName $VMName).ExposeVirtualizationExtensions
        $versaoVM    = (Get-VM -Name $VMName).Version

        if ($nestedAtivo) {
            Write-Host "[OK] Virtualização Aninhada habilitada (versão de configuração da VM: $versaoVM)" -ForegroundColor Green
        } else {
            Write-Host "[AVISO] O comando foi aceito, mas a propriedade não ficou ativa." -ForegroundColor Yellow
            $EnableNested = $false
        }

        if ([version]$versaoVM -lt [version]$suporteNested.VersaoMinimaVM) {
            Write-Host "[AVISO] Versão de configuração $versaoVM é inferior à mínima $($suporteNested.VersaoMinimaVM) exigida para esta CPU." -ForegroundColor Yellow
            Write-Host "        Atualize com: Update-VMVersion -Name '$VMName'" -ForegroundColor Yellow
        }
    }
    catch {
        Write-Host "[ERRO] Falha ao habilitar a Virtualização Aninhada: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "       A VM continuará sendo criada SEM o recurso." -ForegroundColor Yellow
        $EnableNested      = $false
        $EnableMacSpoofing = $false
    }
} else {
    Write-Host "[OK] Virtualização Aninhada não solicitada (mantida desabilitada)" -ForegroundColor DarkGray
}

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
# 9.1 MAC Address Spoofing — obrigatório para que as VMs aninhadas
#     consigam trafegar na rede através do switch virtual do host
# ============================================================
if ($EnableMacSpoofing) {
    try {
        Set-VMNetworkAdapter -VMName $VMName `
                             -Name $NICName `
                             -MacAddressSpoofing On `
                             -ErrorAction Stop

        Write-Host "[OK] MAC Address Spoofing habilitado no adaptador '$NICName'" -ForegroundColor Green
    }
    catch {
        Write-Host "[AVISO] Não foi possível habilitar o MAC Address Spoofing: $($_.Exception.Message)" -ForegroundColor Yellow
        Write-Host "        As VMs aninhadas podem ficar sem acesso à rede." -ForegroundColor Yellow
    }
}

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
    @{N="Virt. Aninhada"; E={
        if ((Get-VMProcessor -VMName $_.Name).ExposeVirtualizationExtensions) { "Habilitada" } else { "Desabilitada" }
    }},
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
    Select-Object VMName, Name, SwitchName, MacAddressSpoofing |
    Format-List

Write-Host "A VM está rodando e bootando pela ISO."                                             -ForegroundColor Cyan
Write-Host "Abra o Hyper-V Manager e conecte-se à '$VMName' para prosseguir com a instalação." -ForegroundColor Cyan

if ($EnableNested) {
    Write-Host ""
    Write-Host "Virtualização Aninhada ATIVA. Depois de instalar o sistema, habilite o Hyper-V dentro da VM:" -ForegroundColor Cyan
    Write-Host "  Windows Server : Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart"      -ForegroundColor DarkGray
    Write-Host "  Windows 10/11  : Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor DarkGray
}
