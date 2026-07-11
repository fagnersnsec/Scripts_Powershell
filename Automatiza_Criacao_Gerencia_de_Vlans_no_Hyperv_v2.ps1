# ============================================================
#  Administração de VLANs em Ambientes Hyper-V
#  Ambiente : Windows Server 2019 ou superior
#  Autor    : Fagner Nascimento — Especialista Microsoft Datacenter
#  Versão   : 1.4 — Opção 2 agora permite ACRESCENTAR VLANs à lista
#             atual (sem sobrescrever) ou substituir tudo; entrada de
#             VLANs passa a aceitar faixas (ex: 4-10,70-71).
#             v1.3 — Opção 6: Consultar VLANs de um Adaptador específico
#             + exibição automática das VLANs atuais nas Opções 2 e 4.
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
# Valida se a string contém IDs de VLAN (individuais ou faixas)
# separados por vírgula. Ex.: 10,20,30  ou  4-10,12-15,70-71,133
# ------------------------------------------------------------
function Validate-VlanList {
    param([string]$Entrada)
    $padrao = '^\s*\d{1,4}(-\d{1,4})?(\s*,\s*\d{1,4}(-\d{1,4})?)*\s*$'
    return $Entrada.Trim() -match $padrao
}

# ------------------------------------------------------------
# Expande uma lista de VLANs (com faixas) em um array de inteiros
# ordenado e sem duplicatas. Ex.: "4-6,10" -> 4,5,6,10
# ------------------------------------------------------------
function Expand-VlanList {
    param([string]$Entrada)
    $ids = New-Object System.Collections.Generic.List[int]
    foreach ($parte in ($Entrada -split ',')) {
        $parte = $parte.Trim()
        if ($parte -match '^(\d{1,4})-(\d{1,4})$') {
            $ini = [int]$Matches[1]
            $fim = [int]$Matches[2]
            if ($ini -gt $fim) { $tmp = $ini; $ini = $fim; $fim = $tmp }
            for ($n = $ini; $n -le $fim; $n++) { $ids.Add($n) }
        } elseif ($parte -match '^\d{1,4}$') {
            $ids.Add([int]$parte)
        }
    }
    return @($ids | Sort-Object -Unique)
}

# ------------------------------------------------------------
# Compacta um array de inteiros em uma string de VLANs com faixas.
# Ex.: 4,5,6,10 -> "4-6,10"
# ------------------------------------------------------------
function Compress-VlanList {
    param([int[]]$Ids)
    $ordenados = @($Ids | Sort-Object -Unique)
    if ($ordenados.Count -eq 0) { return "" }

    $resultado = @()
    $ini = $ordenados[0]
    $ant = $ordenados[0]

    for ($i = 1; $i -lt $ordenados.Count; $i++) {
        $n = $ordenados[$i]
        if ($n -eq $ant + 1) {
            $ant = $n
            continue
        }
        $resultado += if ($ini -eq $ant) { "$ini" } else { "$ini-$ant" }
        $ini = $n
        $ant = $n
    }
    $resultado += if ($ini -eq $ant) { "$ini" } else { "$ini-$ant" }

    return ($resultado -join ',')
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
        Write-Host "  Exemplo: 10,20,30,40,60  |  faixas: 4-10,12-15,70-71" -ForegroundColor DarkGray
        $entrada = (Read-Host "  >> VLANs").Trim()

        if (-not (Validate-VlanList $entrada)) {
            Write-Host "  [AVISO] Formato inválido. Use apenas números separados por vírgula." -ForegroundColor Yellow
        }
    } while (-not (Validate-VlanList $entrada))
    return $entrada
}

# ------------------------------------------------------------
# Exibe as VLANs configuradas atualmente em um único adaptador
# ------------------------------------------------------------
function Show-AdapterVlanInfo {
    param(
        [string]$VMName,
        [string]$AdapterName
    )

    try {
        $vlan = Get-VMNetworkAdapterVlan -VMName $VMName -VMNetworkAdapterName $AdapterName

        Write-Host ""
        Write-Host "  ── VLANs atuais — VM: $VMName | Adaptador: $AdapterName ──" -ForegroundColor DarkCyan
        Write-Host "  Modo             : $($vlan.OperationMode)" -ForegroundColor White

        switch ($vlan.OperationMode) {
            "Access" {
                Write-Host "  VLAN de Acesso   : $($vlan.AccessVlanId)" -ForegroundColor White
            }
            "Trunk" {
                Write-Host "  VLAN Nativa      : $($vlan.NativeVlanId)"            -ForegroundColor White
                Write-Host "  VLANs Permitidas : $($vlan.AllowedVlanIdListString)" -ForegroundColor White
            }
            default {
                Write-Host "  (Sem VLAN configurada / modo Untagged)" -ForegroundColor DarkGray
            }
        }

        Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    } catch {
        Write-Host ""
        Write-Host "  [AVISO] Não foi possível obter as VLANs atuais: $($_.Exception.Message)" -ForegroundColor Yellow
    }
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

    # Exibir VLANs atualmente configuradas neste adaptador
    Show-AdapterVlanInfo -VMName $vmEscolhida -AdapterName $adapterEscolhido

    # Obter configuração atual para permitir ACRESCENTAR sem sobrescrever
    try {
        $vlanAtual = Get-VMNetworkAdapterVlan -VMName $vmEscolhida `
                                              -VMNetworkAdapterName $adapterEscolhido
    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    $ehTrunk        = $vlanAtual.OperationMode -eq "Trunk"
    $vlansAtuaisArr = if ($ehTrunk) { @($vlanAtual.AllowedVlanIdList) } else { @() }

    # Escolher o modo de aplicação
    Write-Host ""
    Write-Host "  Como deseja aplicar as VLANs?" -ForegroundColor Yellow
    Write-Host "  $("-" * 30)" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [A]  Acrescentar VLAN(s) — mantém as existentes e soma as novas" -ForegroundColor White
    Write-Host "  [S]  Substituir toda a lista — redefine as VLANs do zero"        -ForegroundColor White
    Write-Host ""

    do {
        $modo = (Read-Host "  >> Digite A ou S").Trim().ToUpper()
        if ($modo -ne "A" -and $modo -ne "S") {
            Write-Host "  [AVISO] Opção inválida. Digite 'A' para acrescentar ou 'S' para substituir." -ForegroundColor Yellow
        }
    } while ($modo -ne "A" -and $modo -ne "S")

    if ($modo -eq "A") {
        # ── Modo ACRESCENTAR ─────────────────────────────────────
        $novasEntrada = Read-VlanList "Digite a(s) VLAN(s) que deseja ACRESCENTAR à lista atual:"
        $novasArr     = Expand-VlanList $novasEntrada

        $listaFinalArr = @($vlansAtuaisArr + $novasArr | Sort-Object -Unique)
        $vlanList      = Compress-VlanList $listaFinalArr

        # Mantém a VLAN nativa atual se já for Trunk; caso contrário, solicita
        if ($ehTrunk) {
            $vlanNativa = $vlanAtual.NativeVlanId
        } else {
            $vlanNativa = Read-SingleVlan "Informe o ID da VLAN Nativa (NativeVlanId):"
        }

        # Destaca somente as VLANs que serão realmente adicionadas
        $realmenteNovas = @($novasArr | Where-Object { $_ -notin $vlansAtuaisArr }) | Sort-Object -Unique
        $vlanNovasTexto = if ($realmenteNovas.Count -gt 0) { Compress-VlanList $realmenteNovas } else { "(nenhuma — já existiam)" }
    } else {
        # ── Modo SUBSTITUIR ──────────────────────────────────────
        $vlanList   = Read-VlanList  "Digite os IDs de VLAN que deseja taguear neste adaptador (Trunk):"
        $vlanNativa = Read-SingleVlan "Informe o ID da VLAN Nativa (NativeVlanId):"
    }

    # Confirmação
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  VM               : $vmEscolhida"          -ForegroundColor White
    Write-Host "  Adaptador        : $adapterEscolhido"      -ForegroundColor White
    Write-Host "  Ação             : $(if ($modo -eq 'A') { 'Acrescentar VLANs' } else { 'Substituir lista' })" -ForegroundColor White
    if ($modo -eq "A") {
        Write-Host "  VLANs atuais     : $($vlanAtual.AllowedVlanIdListString)" -ForegroundColor White
        Write-Host "  VLANs a adicionar: $vlanNovasTexto"     -ForegroundColor White
    }
    Write-Host "  VLANs (resultado): $vlanList"              -ForegroundColor White
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

    # Exibir VLANs atualmente configuradas neste adaptador
    Show-AdapterVlanInfo -VMName $vmEscolhida -AdapterName $adapterEscolhido

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
#  OPÇÃO 5 — Renomear Adaptador de rede da VM
# ============================================================
function Rename-VMAdapter {
    Show-Header
    Write-Host "  [ OPÇÃO 5 ] Renomear Adaptador de rede da VM" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    # Listar adaptadores com VMName, Name, MacAddress e SwitchName
    try {
        $adapters = Get-VMNetworkAdapter -VMName $vmEscolhida |
                    Select-Object VMName, Name, MacAddress, SwitchName
    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if (-not $adapters) {
        Write-Host ""
        Write-Host "  [ERRO] Nenhum adaptador de rede encontrado na VM '$vmEscolhida'." -ForegroundColor Red
        return
    }

    # Normaliza em array para suportar VM com um único adaptador
    $adapters = @($adapters)

    Write-Host ""
    Write-Host "  Adaptadores de rede da VM '$vmEscolhida':" -ForegroundColor Yellow
    Write-Host "  $("-" * 45)" -ForegroundColor DarkGray
    Write-Host ""

    # Monta tabela indexada preservando todos os campos da consulta
    $tabela = for ($i = 0; $i -lt $adapters.Count; $i++) {
        [PSCustomObject]@{
            "#"          = $i + 1
            "VMName"     = $adapters[$i].VMName
            "Name"       = $adapters[$i].Name
            "MacAddress" = $adapters[$i].MacAddress
            "SwitchName" = $adapters[$i].SwitchName
        }
    }

    $tabela | Format-Table -AutoSize | Out-Host

    # Seleção numérica do adaptador
    do {
        $entrada = Read-Host "  >> Digite o número do adaptador que deseja renomear"
        $numero  = 0
        $valido  = [int]::TryParse($entrada.Trim(), [ref]$numero) -and
                   $numero -ge 1 -and $numero -le $adapters.Count

        if (-not $valido) {
            Write-Host "  [AVISO] Opção inválida. Digite um número entre 1 e $($adapters.Count)." -ForegroundColor Yellow
        }
    } while (-not $valido)

    $adapterSelecionado = $adapters[$numero - 1]
    $nomeAtual          = $adapterSelecionado.Name

    # Novo nome do adaptador
    Write-Host ""
    do {
        $novoNome = (Read-Host "  >> Informe o NOVO nome para o adaptador '$nomeAtual'").Trim()
        if ([string]::IsNullOrWhiteSpace($novoNome)) {
            Write-Host "  [AVISO] O novo nome não pode ser vazio." -ForegroundColor Yellow
        } elseif ($novoNome -eq $nomeAtual) {
            Write-Host "  [AVISO] O novo nome é igual ao atual. Informe um nome diferente." -ForegroundColor Yellow
            $novoNome = ""
        }
    } while ([string]::IsNullOrWhiteSpace($novoNome))

    # Confirmação
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  VM               : $vmEscolhida"                  -ForegroundColor White
    Write-Host "  Adaptador atual  : $nomeAtual"                    -ForegroundColor White
    Write-Host "  MacAddress       : $($adapterSelecionado.MacAddress)" -ForegroundColor White
    Write-Host "  SwitchName       : $($adapterSelecionado.SwitchName)" -ForegroundColor White
    Write-Host "  Novo nome        : $novoNome"                     -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    $conf = (Read-Host "  >> Confirmar operação? (S/N)").Trim().ToUpper()
    if ($conf -ne "S") {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    try {
        Rename-VMNetworkAdapter -VMName $vmEscolhida `
                                -Name $nomeAtual `
                                -NewName $novoNome
        Write-Host "  [OK] Adaptador renomeado de '$nomeAtual' para '$novoNome' na VM '$vmEscolhida'." -ForegroundColor Green

    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  OPÇÃO 6 — Consultar VLANs de um Adaptador específico
# ============================================================
function Show-SingleAdapterVlan {
    Show-Header
    Write-Host "  [ OPÇÃO 6 ] Consultar VLANs de um Adaptador específico" -ForegroundColor Cyan
    Write-Host ""

    # Selecionar VM
    $vmNames = Get-VMNames
    if (-not $vmNames) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a Máquina Virtual:" -Itens $vmNames

    # Selecionar adaptador
    $adapterNames = Get-AdapterNames -VMName $vmEscolhida
    if (-not $adapterNames) { return }
    $adapterEscolhido = Select-FromList -Titulo "Selecione o Adaptador de Rede:" -Itens $adapterNames

    Show-AdapterVlanInfo -VMName $vmEscolhida -AdapterName $adapterEscolhido
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
    Write-Host "  [5]  Renomear Adaptador de rede da VM"                        -ForegroundColor White
    Write-Host "  [6]  Consultar VLANs de um Adaptador específico"               -ForegroundColor White
    Write-Host "  [0]  Sair"                                                    -ForegroundColor DarkGray
    Write-Host ""

    $opcao = (Read-Host "  >> Digite a opção").Trim()

    switch ($opcao) {
        "1" { Add-NicWithVlan           }
        "2" { Set-VlanOnExistingAdapter }
        "3" { Show-VlanInfo             }
        "4" { Set-AccessVlan            }
        "5" { Rename-VMAdapter          }
        "6" { Show-SingleAdapterVlan    }
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