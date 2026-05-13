# ============================================================
#  Administração de VLANs em Ambientes Hyper-V
#  Ambiente : Windows Server 2019 ou superior
#  Autor    : Fagner Nascimento — Especialista Microsoft Datacenter
#  Versão   : 1.1 — Correção na exibição de VLANs (Opção 3)
# ============================================================

# ============================================================
#  FUNÇÕES AUXILIARES
# ============================================================

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "       ADMINISTRAÇÃO DE VLANs EM AMBIENTES HYPER-V"            -ForegroundColor Cyan
    Write-Host "       Autor: Fagner Nascimento | Microsoft Datacenter"         -ForegroundColor DarkCyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ------------------------------------------------------------
# Exibe lista numerada e retorna o item escolhido pelo usuário
# ------------------------------------------------------------
function Select-FromList {
    param(
        [string]   $Titulo,
        [string[]] $Itens
    )

    Write-Host ""
    Write-Host "  $Titulo" -ForegroundColor Yellow
    Write-Host "  $("-" * ($Titulo.Length))" -ForegroundColor DarkGray
    Write-Host ""

    for ($i = 0; $i -lt $Itens.Count; $i++) {
        Write-Host ("  [{0,2}]  {1}" -f ($i + 1), $Itens[$i]) -ForegroundColor White
    }

    Write-Host ""

    do {
        $entrada = Read-Host "  >> Digite o número correspondente"
        $numero  = 0
        $valido  = [int]::TryParse($entrada.Trim(), [ref]$numero) -and
                   $numero -ge 1 -and $numero -le $Itens.Count

        if (-not $valido) {
            Write-Host "  [AVISO] Opção inválida. Digite um número entre 1 e $($Itens.Count)." -ForegroundColor Yellow
        }
    } while (-not $valido)

    return $Itens[$numero - 1]
}

# ------------------------------------------------------------
# Valida se a string contém apenas IDs de VLAN separados por vírgula
# ------------------------------------------------------------
function Validate-VlanList {
    param([string]$Entrada)
    $padrao = '^(\d{1,4})(,\d{1,4})*$'
    return $Entrada.Trim() -match $padrao
}

# ------------------------------------------------------------
# Retorna lista de nomes de VMs do host
# ------------------------------------------------------------
function Get-VMNames {
    $vms = Get-VM | Sort-Object Name | Select-Object -ExpandProperty Name
    if ($vms.Count -eq 0) {
        Write-Host ""
        Write-Host "  [ERRO] Nenhuma máquina virtual encontrada neste host." -ForegroundColor Red
        return $null
    }
    return $vms
}

# ------------------------------------------------------------
# Retorna lista de adaptadores de rede de uma VM
# ------------------------------------------------------------
function Get-AdapterNames {
    param([string]$VMName)
    $adapters = Get-VMNetworkAdapter -VMName $VMName |
                Sort-Object Name |
                Select-Object -ExpandProperty Name
    if ($adapters.Count -eq 0) {
        Write-Host ""
        Write-Host "  [ERRO] Nenhum adaptador de rede encontrado na VM '$VMName'." -ForegroundColor Red
        return $null
    }
    return $adapters
}

# ------------------------------------------------------------
# Retorna lista de Switches Virtuais do host
# ------------------------------------------------------------
function Get-SwitchNames {
    $switches = Get-VMSwitch | Sort-Object Name | Select-Object -ExpandProperty Name
    if ($switches.Count -eq 0) {
        Write-Host ""
        Write-Host "  [ERRO] Nenhum Switch Virtual encontrado neste host." -ForegroundColor Red
        return $null
    }
    return $switches
}

# ------------------------------------------------------------
# Coleta e valida lista de VLANs do usuário
# ------------------------------------------------------------
function Read-VlanList {
    param([string]$Mensagem)
    do {
        Write-Host ""
        Write-Host "  $Mensagem" -ForegroundColor Yellow
        Write-Host "  Exemplo: 10,20,30,40,60" -ForegroundColor DarkGray
        $entrada = (Read-Host "  >> VLANs").Trim()

        if (-not (Validate-VlanList $entrada)) {
            Write-Host "  [AVISO] Formato inválido. Use apenas números separados por vírgula." -ForegroundColor Yellow
        }
    } while (-not (Validate-VlanList $entrada))
    return $entrada
}

# ------------------------------------------------------------
# Coleta e valida ID de VLAN único
# ------------------------------------------------------------
function Read-SingleVlan {
    param([string]$Mensagem)
    do {
        Write-Host ""
        $entrada = (Read-Host "  >> $Mensagem").Trim()
        $numero  = 0
        $valido  = [int]::TryParse($entrada, [ref]$numero) -and $numero -ge 1 -and $numero -le 4094

        if (-not $valido) {
            Write-Host "  [AVISO] ID de VLAN inválido. Informe um número entre 1 e 4094." -ForegroundColor Yellow
        }
    } while (-not $valido)
    return $numero
}

# ============================================================
#  OPÇÃO 1 — Adicionar novo adaptador de rede com VLANs (Trunk)
# ============================================================
function Add-NicWithVlan {
    Show-Header
    Write-Host "  [ OPÇÃO 1 ] Adicionar novo adaptador de rede com VLANs" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    # Nome do novo adaptador
    Write-Host ""
    do {
        $nomeAdapter = (Read-Host "  >> Informe o nome do novo adaptador de rede").Trim()
        if ([string]::IsNullOrWhiteSpace($nomeAdapter)) {
            Write-Host "  [AVISO] O nome não pode ser vazio." -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($nomeAdapter))

    # Selecionar Switch Virtual
    $switchNames = Get-SwitchNames
    if (-not $switchNames) { return }
    $switchEscolhido = Select-FromList -Titulo "Selecione o Switch Virtual:" -Itens $switchNames

    # Coletar VLANs permitidas e VLAN nativa
    $vlanList   = Read-VlanList  "Digite os IDs de VLAN que deseja taguear neste adaptador (Trunk):"
    $vlanNativa = Read-SingleVlan "Informe o ID da VLAN Nativa (NativeVlanId):"

    # Confirmação
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  VM               : $vmEscolhida"        -ForegroundColor White
    Write-Host "  Adaptador        : $nomeAdapter"         -ForegroundColor White
    Write-Host "  Switch Virtual   : $switchEscolhido"     -ForegroundColor White
    Write-Host "  VLANs (Trunk)    : $vlanList"            -ForegroundColor White
    Write-Host "  VLAN Nativa      : $vlanNativa"          -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    $conf = (Read-Host "  >> Confirmar operação? (S/N)").Trim().ToUpper()
    if ($conf -ne "S") {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    try {
        Add-VMNetworkAdapter -VMName $vmEscolhida `
                             -Name $nomeAdapter `
                             -SwitchName $switchEscolhido
        Write-Host "  [OK] Adaptador '$nomeAdapter' adicionado à VM '$vmEscolhida'." -ForegroundColor Green

        Set-VMNetworkAdapterVlan -VMName $vmEscolhida `
                                 -VMNetworkAdapterName $nomeAdapter `
                                 -Trunk `
                                 -AllowedVlanIdList $vlanList `
                                 -NativeVlanId $vlanNativa
        Write-Host "  [OK] VLANs configuradas em modo Trunk com sucesso." -ForegroundColor Green

    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  OPÇÃO 2 — Configurar VLANs em adaptador existente (Trunk)
# ============================================================
function Set-VlanOnExistingAdapter {
    Show-Header
    Write-Host "  [ OPÇÃO 2 ] Configurar VLANs em adaptador existente" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    # Selecionar adaptador
    $adapterNames = Get-AdapterNames -VMName $vmEscolhida
    if (-not $adapterNames) { return }
    $adapterEscolhido = Select-FromList -Titulo "Selecione o Adaptador de Rede:" -Itens $adapterNames

    # Coletar VLANs e VLAN nativa
    $vlanList   = Read-VlanList  "Digite os IDs de VLAN que deseja taguear neste adaptador (Trunk):"
    $vlanNativa = Read-SingleVlan "Informe o ID da VLAN Nativa (NativeVlanId):"

    # Confirmação
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  VM               : $vmEscolhida"          -ForegroundColor White
    Write-Host "  Adaptador        : $adapterEscolhido"      -ForegroundColor White
    Write-Host "  VLANs (Trunk)    : $vlanList"              -ForegroundColor White
    Write-Host "  VLAN Nativa      : $vlanNativa"            -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    $conf = (Read-Host "  >> Confirmar operação? (S/N)").Trim().ToUpper()
    if ($conf -ne "S") {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    try {
        Set-VMNetworkAdapterVlan -VMName $vmEscolhida `
                                 -VMNetworkAdapterName $adapterEscolhido `
                                 -Trunk `
                                 -AllowedVlanIdList $vlanList `
                                 -NativeVlanId $vlanNativa
        Write-Host "  [OK] VLANs configuradas em modo Trunk com sucesso." -ForegroundColor Green

    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  OPÇÃO 3 — Visualizar VLANs de uma Máquina Virtual  [v1.1]
# ============================================================
function Show-VlanInfo {
    Show-Header
    Write-Host "  [ OPÇÃO 3 ] Visualizar VLANs das Máquinas Virtuais" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    Write-Host ""
    Write-Host "  ── Configuração de VLANs — VM: $vmEscolhida ───────────" -ForegroundColor DarkCyan
    Write-Host ""

    try {
        # Busca os adaptadores reais da VM garantindo o nome correto
        $adapters = Get-VMNetworkAdapter -VMName $vmEscolhida

        if (-not $adapters) {
            Write-Host "  Nenhum adaptador encontrado para '$vmEscolhida'." -ForegroundColor Yellow
            return
        }

        # Para cada adaptador busca as VLANs individualmente e monta a tabela
        $tabela = foreach ($adapter in $adapters) {

            $vlan = Get-VMNetworkAdapterVlan -VMNetworkAdapter $adapter

            [PSCustomObject]@{
                "Adaptador"        = $adapter.Name
                "Modo"             = $vlan.OperationMode
                "VLAN de Acesso"   = if ($vlan.OperationMode -eq "Access") { $vlan.AccessVlanId }            else { "—" }
                "VLAN Nativa"      = if ($vlan.OperationMode -eq "Trunk")  { $vlan.NativeVlanId }            else { "—" }
                "VLANs Permitidas" = if ($vlan.OperationMode -eq "Trunk")  { $vlan.AllowedVlanIdListString } else { "—" }
            }
        }

        $tabela | Format-Table -AutoSize

    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  OPÇÃO 4 — Configurar VLAN de Acesso em adaptador
# ============================================================
function Set-AccessVlan {
    Show-Header
    Write-Host "  [ OPÇÃO 4 ] Configurar VLAN de Acesso em adaptador" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    # Selecionar adaptador
    $adapterNames = Get-AdapterNames -VMName $vmEscolhida
    if (-not $adapterNames) { return }
    $adapterEscolhido = Select-FromList -Titulo "Selecione o Adaptador de Rede:" -Itens $adapterNames

    # ID da VLAN de acesso
    $vlanAcesso = Read-SingleVlan "Informe o ID da VLAN de Acesso (Access):"

    # Confirmação
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  VM               : $vmEscolhida"       -ForegroundColor White
    Write-Host "  Adaptador        : $adapterEscolhido"   -ForegroundColor White
    Write-Host "  Modo             : Access"               -ForegroundColor White
    Write-Host "  VLAN de Acesso   : $vlanAcesso"         -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    $conf = (Read-Host "  >> Confirmar operação? (S/N)").Trim().ToUpper()
    if ($conf -ne "S") {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    try {
        Set-VMNetworkAdapterVlan -VMName $vmEscolhida `
                                 -VMNetworkAdapterName $adapterEscolhido `
                                 -Access `
                                 -VlanId $vlanAcesso
        Write-Host "  [OK] VLAN $vlanAcesso configurada como modo Access no adaptador '$adapterEscolhido'." -ForegroundColor Green

    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================
do {
    Show-Header

    Write-Host "  Selecione a operação desejada:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1]  Adicionar novo adaptador de rede com VLANs (Trunk)"    -ForegroundColor White
    Write-Host "  [2]  Configurar VLANs em adaptador existente (Trunk)"        -ForegroundColor White
    Write-Host "  [3]  Visualizar VLANs das Máquinas Virtuais"                 -ForegroundColor White
    Write-Host "  [4]  Configurar VLAN de Acesso em adaptador (Access)"        -ForegroundColor White
    Write-Host "  [0]  Sair"                                                    -ForegroundColor DarkGray
    Write-Host ""

    $opcao = (Read-Host "  >> Digite a opção").Trim()

    switch ($opcao) {
        "1" { Add-NicWithVlan           }
        "2" { Set-VlanOnExistingAdapter }
        "3" { Show-VlanInfo             }
        "4" { Set-AccessVlan            }
        "0" {
            Write-Host ""
            Write-Host "  Encerrando o script. Até logo!" -ForegroundColor Cyan
            Write-Host ""
            break
        }
        default {
            Write-Host ""
            Write-Host "  [AVISO] Opção inválida. Tente novamente." -ForegroundColor Yellow
        }
    }

    if ($opcao -ne "0") {
        Write-Host ""
        Read-Host "  >> Pressione ENTER para voltar ao menu principal"
    }

} while ($opcao -ne "0")