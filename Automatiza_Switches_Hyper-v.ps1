# ============================================================
#  Automatiza a Criação e Gestão de Switches Virtuais no Hyper-V
#  Ambiente : Windows Server 2019 ou superior / Windows 10+ com Hyper-V
#  Autor    : Fagner Nascimento — Especialista Microsoft Datacenter
#  Versão   : 1.0 — Criação de switches Externo/Interno/Privado,
#             criação de switch NAT (internet para VMs), listagem
#             e remoção com limpeza de NAT associado.
# ============================================================
#
#  Referências oficiais (Microsoft Learn):
#   - New-VMSwitch : https://learn.microsoft.com/pt-br/powershell/module/hyper-v/new-vmswitch
#   - New-NetNat   : https://learn.microsoft.com/pt-br/powershell/module/netnat/new-netnat
#   - Setup NAT    : https://learn.microsoft.com/pt-br/windows-server/virtualization/hyper-v/setup-nat-network
#
#  OBSERVAÇÕES IMPORTANTES:
#   * Switch EXTERNO usa -NetAdapterName (o tipo é definido implicitamente).
#     Somente Internal e Private são aceitos em -SwitchType.
#   * O Windows (WinNAT) suporta APENAS UM NAT por host.
#   * A configuração de IP/Gateway/DNS de cada VM é feita DENTRO da VM
#     (o host não acessa o SO convidado). O script exibe as instruções.
# ============================================================

# ============================================================
#  FUNÇÕES AUXILIARES
# ============================================================

function Show-Header {
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "       CRIAÇÃO E GESTÃO DE SWITCHES VIRTUAIS — HYPER-V"          -ForegroundColor Cyan
    Write-Host "       Autor: Fagner Nascimento | Microsoft Datacenter"          -ForegroundColor DarkCyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ------------------------------------------------------------
# Verifica se a sessão está elevada (Administrador)
# ------------------------------------------------------------
function Test-Administrador {
    $identidade = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal  = New-Object System.Security.Principal.WindowsPrincipal($identidade)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
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
# Lê um texto não vazio do usuário
# ------------------------------------------------------------
function Read-NonEmpty {
    param([string]$Mensagem)
    do {
        $entrada = (Read-Host "  >> $Mensagem").Trim()
        if ([string]::IsNullOrWhiteSpace($entrada)) {
            Write-Host "  [AVISO] O valor não pode ser vazio." -ForegroundColor Yellow
        }
    } while ([string]::IsNullOrWhiteSpace($entrada))
    return $entrada
}

# ------------------------------------------------------------
# Confirmação padronizada (S/N)
# ------------------------------------------------------------
function Confirm-Operacao {
    param([string]$Mensagem = "Confirmar operação?")
    $conf = (Read-Host "  >> $Mensagem (S/N)").Trim().ToUpper()
    return ($conf -eq "S")
}

# ------------------------------------------------------------
# Valida um endereço IPv4
# ------------------------------------------------------------
function Validate-IPv4 {
    param([string]$IP)
    $padrao = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
    return $IP.Trim() -match $padrao
}

# ------------------------------------------------------------
# Valida um prefixo CIDR (ex.: 192.168.100.0/24)
# ------------------------------------------------------------
function Validate-Cidr {
    param([string]$Cidr)
    $partes = $Cidr.Trim() -split '/'
    if ($partes.Count -ne 2)              { return $false }
    if (-not (Validate-IPv4 $partes[0]))  { return $false }
    $prefixo = 0
    if (-not [int]::TryParse($partes[1], [ref]$prefixo)) { return $false }
    return ($prefixo -ge 8 -and $prefixo -le 30)
}

# ------------------------------------------------------------
# Lê e valida um endereço IPv4 (com valor padrão opcional)
# ------------------------------------------------------------
function Read-IPv4 {
    param(
        [string]$Mensagem,
        [string]$Padrao = ""
    )
    do {
        $rotulo  = if ($Padrao) { "$Mensagem [$Padrao]" } else { $Mensagem }
        $entrada = (Read-Host "  >> $rotulo").Trim()
        if ([string]::IsNullOrWhiteSpace($entrada) -and $Padrao) { $entrada = $Padrao }

        if (-not (Validate-IPv4 $entrada)) {
            Write-Host "  [AVISO] Endereço IPv4 inválido. Ex.: 192.168.100.1" -ForegroundColor Yellow
        }
    } while (-not (Validate-IPv4 $entrada))
    return $entrada
}

# ------------------------------------------------------------
# Verifica se já existe um switch com o nome informado
# ------------------------------------------------------------
function Test-SwitchExiste {
    param([string]$Nome)
    return [bool](Get-VMSwitch -Name $Nome -ErrorAction SilentlyContinue)
}

# ------------------------------------------------------------
# Lê um nome de switch inédito (não pode já existir)
# ------------------------------------------------------------
function Read-NovoNomeSwitch {
    param([string]$Padrao = "")
    do {
        $reprompt = $false
        $rotulo   = if ($Padrao) { "Informe o nome do novo switch [$Padrao]" } else { "Informe o nome do novo switch" }
        $nome     = (Read-Host "  >> $rotulo").Trim()
        if ([string]::IsNullOrWhiteSpace($nome) -and $Padrao) { $nome = $Padrao }

        if ([string]::IsNullOrWhiteSpace($nome)) {
            Write-Host "  [AVISO] O nome não pode ser vazio." -ForegroundColor Yellow
            $reprompt = $true
        } elseif (Test-SwitchExiste $nome) {
            Write-Host "  [AVISO] Já existe um switch chamado '$nome'. Escolha outro nome." -ForegroundColor Yellow
            $reprompt = $true
        }
    } while ($reprompt)
    return $nome
}

# ============================================================
#  OPÇÃO 1 — Criar Switch Virtual (Externo / Interno / Privado)
# ============================================================
function New-SwitchVirtual {
    Show-Header
    Write-Host "  [ OPÇÃO 1 ] Criar Switch Virtual" -ForegroundColor Cyan
    Write-Host ""

    # Tipo do switch
    $tipos = @(
        "Externo  — conecta as VMs à rede física (internet/LAN) via uma placa de rede do host",
        "Interno  — comunicação entre as VMs e o host (sem rede física)",
        "Privado  — comunicação apenas entre as VMs (isolado do host e da rede física)"
    )
    $tipoEscolhido = Select-FromList -Titulo "Selecione o TIPO de Switch Virtual:" -Itens $tipos
    $tipo = switch -Wildcard ($tipoEscolhido) {
        "Externo*" { "External" }
        "Interno*" { "Internal" }
        "Privado*" { "Private"  }
    }

    # Nome do switch
    Write-Host ""
    $nome = Read-NovoNomeSwitch

    # Parâmetros específicos do tipo Externo
    $adaptadorFisico = $null
    $allowMgmt       = $true

    if ($tipo -eq "External") {
        # Listar adaptadores físicos disponíveis
        $fisicos = @(Get-NetAdapter -Physical -ErrorAction SilentlyContinue |
                     Sort-Object Name)

        if (-not $fisicos -or $fisicos.Count -eq 0) {
            Write-Host ""
            Write-Host "  [ERRO] Nenhum adaptador de rede físico encontrado no host." -ForegroundColor Red
            return
        }

        $itensFisicos = $fisicos | ForEach-Object {
            "{0}  ({1} — {2})" -f $_.Name, $_.InterfaceDescription, $_.Status
        }
        $adaptadorEscolhido = Select-FromList -Titulo "Selecione a Placa de Rede Física (uplink):" -Itens $itensFisicos
        $adaptadorFisico    = ($adaptadorEscolhido -split '  \(')[0].Trim()

        Write-Host ""
        Write-Host "  Permitir que o Sistema Operacional do host compartilhe esta placa?" -ForegroundColor Yellow
        Write-Host "  (Recomendado: S — mantém a conectividade do host pela mesma placa)"  -ForegroundColor DarkGray
        $allowMgmt = Confirm-Operacao "Compartilhar com o host?"

        Write-Host ""
        Write-Host "  [AVISO] A criação de um switch EXTERNO pode causar uma breve queda" -ForegroundColor Yellow
        Write-Host "          na conectividade de rede do host durante a operação."        -ForegroundColor Yellow
    }

    # Resumo
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  Nome do Switch   : $nome"                    -ForegroundColor White
    Write-Host "  Tipo             : $tipo"                     -ForegroundColor White
    if ($tipo -eq "External") {
        Write-Host "  Placa Física     : $adaptadorFisico"      -ForegroundColor White
        Write-Host "  Compartilhar host: $(if ($allowMgmt) { 'Sim' } else { 'Não' })" -ForegroundColor White
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Confirm-Operacao)) {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    try {
        if ($tipo -eq "External") {
            New-VMSwitch -Name $nome `
                         -NetAdapterName $adaptadorFisico `
                         -AllowManagementOS $allowMgmt | Out-Null
        } else {
            New-VMSwitch -Name $nome -SwitchType $tipo | Out-Null
        }
        Write-Host "  [OK] Switch '$nome' ($tipo) criado com sucesso." -ForegroundColor Green
    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
    }
}

# ============================================================
#  OPÇÃO 2 — Criar Switch NAT (fornecer internet às VMs)
# ============================================================
function New-SwitchNat {
    Show-Header
    Write-Host "  [ OPÇÃO 2 ] Criar Switch NAT (Internet para VMs)" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  Cria um switch INTERNO + rede NAT (WinNAT), permitindo que as VMs" -ForegroundColor DarkGray
    Write-Host "  acessem a internet compartilhando o IP do host."                    -ForegroundColor DarkGray

    # Restrição do WinNAT: apenas um NAT por host
    $natExistente = @(Get-NetNat -ErrorAction SilentlyContinue)
    if ($natExistente.Count -gt 0) {
        Write-Host ""
        Write-Host "  [AVISO] Já existe uma rede NAT neste host (o Windows suporta apenas UMA):" -ForegroundColor Yellow
        foreach ($n in $natExistente) {
            Write-Host ("           - {0}  ({1})" -f $n.Name, $n.InternalIPInterfaceAddressPrefix) -ForegroundColor Yellow
        }
        Write-Host "          Criar outra rede NAT deixará o WinNAT em estado inconsistente." -ForegroundColor Yellow
        Write-Host ""
        if (-not (Confirm-Operacao "Deseja continuar mesmo assim?")) {
            Write-Host "  Operação cancelada." -ForegroundColor Yellow
            return
        }
    }

    # Nome do switch
    Write-Host ""
    $nome = Read-NovoNomeSwitch -Padrao "VmNAT"

    # Nome do objeto NAT
    Write-Host ""
    do {
        $natNome = (Read-Host "  >> Informe o nome da rede NAT [LocalNAT]").Trim()
        if ([string]::IsNullOrWhiteSpace($natNome)) { $natNome = "LocalNAT" }
        $natDup = Get-NetNat -Name $natNome -ErrorAction SilentlyContinue
        if ($natDup) {
            Write-Host "  [AVISO] Já existe uma rede NAT chamada '$natNome'." -ForegroundColor Yellow
        }
    } while ($natDup)

    # Sub-rede NAT (CIDR)
    Write-Host ""
    do {
        $cidr = (Read-Host "  >> Sub-rede NAT em formato CIDR [192.168.100.0/24]").Trim()
        if ([string]::IsNullOrWhiteSpace($cidr)) { $cidr = "192.168.100.0/24" }
        if (-not (Validate-Cidr $cidr)) {
            Write-Host "  [AVISO] Formato CIDR inválido. Ex.: 192.168.100.0/24 (prefixo entre /8 e /30)." -ForegroundColor Yellow
        }
    } while (-not (Validate-Cidr $cidr))

    $prefixLen = [int](($cidr -split '/')[1])
    $rede      = ($cidr -split '/')[0]

    # IP do gateway (adaptador vEthernet do host) — sugere .1 da rede
    $octetos      = $rede -split '\.'
    $gatewayPadrao = "$($octetos[0]).$($octetos[1]).$($octetos[2]).1"

    Write-Host ""
    Write-Host "  O IP do Gateway é atribuído ao adaptador virtual do host (vEthernet)." -ForegroundColor DarkGray
    Write-Host "  Será o Default Gateway das VMs conectadas a este switch."               -ForegroundColor DarkGray
    Write-Host ""
    $gateway = Read-IPv4 "IP do Gateway (host)" $gatewayPadrao

    # DNS sugerido para as VMs (apenas informativo)
    Write-Host ""
    $dns = Read-IPv4 "DNS a informar dentro das VMs" "8.8.8.8"

    $alias = "vEthernet ($nome)"

    # Resumo
    Write-Host ""
    Write-Host "  ── Resumo da operação ──────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  Switch (Interno) : $nome"        -ForegroundColor White
    Write-Host "  Rede NAT         : $natNome"     -ForegroundColor White
    Write-Host "  Sub-rede (CIDR)  : $cidr"        -ForegroundColor White
    Write-Host "  Gateway (host)   : $gateway/$prefixLen  (adaptador '$alias')" -ForegroundColor White
    Write-Host "  DNS p/ as VMs    : $dns"         -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Confirm-Operacao)) {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    Write-Host ""

    # -------- Passo 1: criar switch interno --------
    try {
        New-VMSwitch -Name $nome -SwitchType Internal | Out-Null
        Write-Host "  [OK] Switch interno '$nome' criado." -ForegroundColor Green
    } catch {
        Write-Host "  [ERRO] Falha ao criar o switch: $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    # Aguarda o adaptador virtual do host aparecer
    $nic = $null
    for ($i = 0; $i -lt 10 -and -not $nic; $i++) {
        Start-Sleep -Milliseconds 500
        $nic = Get-NetAdapter -Name $alias -ErrorAction SilentlyContinue
    }
    if (-not $nic) {
        Write-Host "  [ERRO] Adaptador '$alias' não localizado. Revertendo criação do switch." -ForegroundColor Red
        Remove-VMSwitch -Name $nome -Force -ErrorAction SilentlyContinue
        return
    }

    # -------- Passo 2: atribuir IP do gateway ao vEthernet --------
    try {
        # Remove qualquer IP residual no adaptador antes de atribuir
        Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -eq $gateway } |
            Remove-NetIPAddress -Confirm:$false -ErrorAction SilentlyContinue

        New-NetIPAddress -InterfaceAlias $alias `
                         -IPAddress $gateway `
                         -PrefixLength $prefixLen `
                         -AddressFamily IPv4 | Out-Null
        Write-Host "  [OK] IP $gateway/$prefixLen atribuído ao adaptador '$alias'." -ForegroundColor Green
    } catch {
        Write-Host "  [ERRO] Falha ao atribuir IP ao gateway: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "         Revertendo criação do switch." -ForegroundColor Yellow
        Remove-VMSwitch -Name $nome -Force -ErrorAction SilentlyContinue
        return
    }

    # -------- Passo 3: criar a rede NAT --------
    try {
        New-NetNat -Name $natNome -InternalIPInterfaceAddressPrefix $cidr | Out-Null
        Write-Host "  [OK] Rede NAT '$natNome' criada para a sub-rede $cidr." -ForegroundColor Green
    } catch {
        Write-Host "  [ERRO] Falha ao criar a rede NAT: $($_.Exception.Message)" -ForegroundColor Red
        Write-Host "         O switch e o IP foram mantidos. Verifique 'Get-NetNat'." -ForegroundColor Yellow
        return
    }

    # -------- Instruções para configurar DENTRO de cada VM --------
    $ipExemplo = "$($octetos[0]).$($octetos[1]).$($octetos[2]).50"
    Write-Host ""
    Write-Host "  ════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "   NAT PRONTO NO HOST! Agora configure a rede DENTRO da VM:" -ForegroundColor Cyan
    Write-Host "  ════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "   1) Conecte o adaptador da VM ao switch '$nome'."          -ForegroundColor White
    Write-Host "      (Hyper-V Manager > Settings da VM, ou via PowerShell:" -ForegroundColor DarkGray
    Write-Host "       Connect-VMNetworkAdapter -VMName <VM> -SwitchName '$nome')" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "   2) DENTRO do Sistema Operacional da VM, configure IP estático:" -ForegroundColor White
    Write-Host "      - Endereço IP     : $ipExemplo   (qualquer livre em $cidr)"  -ForegroundColor White
    Write-Host "      - Máscara/Prefixo : /$prefixLen"                              -ForegroundColor White
    Write-Host "      - Gateway padrão  : $gateway"                                 -ForegroundColor White
    Write-Host "      - Servidor DNS    : $dns"                                     -ForegroundColor White
    Write-Host ""
    Write-Host "   Exemplo (PowerShell, executado DENTRO da VM Windows):"          -ForegroundColor DarkGray
    Write-Host "      New-NetIPAddress -InterfaceAlias 'Ethernet' -IPAddress $ipExemplo ``" -ForegroundColor DarkGray
    Write-Host "          -DefaultGateway $gateway -AddressFamily IPv4 -PrefixLength $prefixLen" -ForegroundColor DarkGray
    Write-Host "      Set-DnsClientServerAddress -InterfaceAlias 'Ethernet' -ServerAddresses $dns" -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "  [NOTA] O WinNAT não distribui IPs automaticamente (não há DHCP)." -ForegroundColor Yellow
    Write-Host "         Cada VM precisa de IP estático dentro da sub-rede $cidr."   -ForegroundColor Yellow
}

# ============================================================
#  OPÇÃO 3 — Listar Switches Virtuais
# ============================================================
function Show-SwitchList {
    Show-Header
    Write-Host "  [ OPÇÃO 3 ] Listar Switches Virtuais" -ForegroundColor Cyan
    Write-Host ""

    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($switches.Count -eq 0) {
        Write-Host "  Nenhum switch virtual encontrado neste host." -ForegroundColor Yellow
        return
    }

    $tabela = foreach ($sw in $switches) {
        $netAdapter = if ($sw.SwitchType -eq "External") { $sw.NetAdapterInterfaceDescription } else { "—" }
        [PSCustomObject]@{
            "Nome"          = $sw.Name
            "Tipo"          = $sw.SwitchType
            "Placa Física"  = $netAdapter
            "Compart. Host" = $sw.AllowManagementOS
        }
    }
    $tabela | Format-Table -AutoSize | Out-Host

    # Também exibe redes NAT existentes (contexto de switches NAT)
    $nats = @(Get-NetNat -ErrorAction SilentlyContinue)
    if ($nats.Count -gt 0) {
        Write-Host "  Redes NAT (WinNAT) configuradas:" -ForegroundColor Yellow
        Write-Host "  $("-" * 32)" -ForegroundColor DarkGray
        $nats | Select-Object Name, InternalIPInterfaceAddressPrefix, Active |
            Format-Table -AutoSize | Out-Host
    }
}

# ============================================================
#  OPÇÃO 4 — Remover Switch Virtual (com limpeza de NAT)
# ============================================================
function Remove-SwitchVirtual {
    Show-Header
    Write-Host "  [ OPÇÃO 4 ] Remover Switch Virtual" -ForegroundColor Cyan
    Write-Host ""

    $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Sort-Object Name)
    if ($switches.Count -eq 0) {
        Write-Host "  Nenhum switch virtual encontrado neste host." -ForegroundColor Yellow
        return
    }

    $itens = $switches | ForEach-Object { "{0}  ({1})" -f $_.Name, $_.SwitchType }
    $escolhido = Select-FromList -Titulo "Selecione o Switch a ser REMOVIDO:" -Itens $itens
    $nome = ($escolhido -split '  \(')[0].Trim()
    $sw   = $switches | Where-Object { $_.Name -eq $nome } | Select-Object -First 1

    # Verifica VMs conectadas a este switch
    $vmsConectadas = @(Get-VMNetworkAdapter -All -ErrorAction SilentlyContinue |
                       Where-Object { $_.SwitchName -eq $nome })

    # Detecta rede NAT associada (switch interno cujo prefixo cobre o IP do vEthernet)
    $alias      = "vEthernet ($nome)"
    $ipsSwitch  = @(Get-NetIPAddress -InterfaceAlias $alias -AddressFamily IPv4 -ErrorAction SilentlyContinue)
    $natAssoc   = $null
    if ($sw.SwitchType -eq "Internal" -and $ipsSwitch.Count -gt 0) {
        foreach ($nat in @(Get-NetNat -ErrorAction SilentlyContinue)) {
            $natRede   = ($nat.InternalIPInterfaceAddressPrefix -split '/')[0]
            $natPrefix = ($natRede -split '\.')[0..2] -join '.'
            foreach ($ip in $ipsSwitch) {
                $ipPrefix = ($ip.IPAddress -split '\.')[0..2] -join '.'
                if ($ipPrefix -eq $natPrefix) { $natAssoc = $nat; break }
            }
            if ($natAssoc) { break }
        }
    }

    # Resumo
    Write-Host ""
    Write-Host "  ── Resumo da remoção ───────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host "  Switch           : $nome"              -ForegroundColor White
    Write-Host "  Tipo             : $($sw.SwitchType)"  -ForegroundColor White
    Write-Host "  VMs conectadas   : $($vmsConectadas.Count)" -ForegroundColor White
    if ($natAssoc) {
        Write-Host "  Rede NAT assoc.  : $($natAssoc.Name)  ($($natAssoc.InternalIPInterfaceAddressPrefix))" -ForegroundColor White
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan

    if ($vmsConectadas.Count -gt 0) {
        Write-Host ""
        Write-Host "  [AVISO] Há $($vmsConectadas.Count) adaptador(es) de VM conectados a este switch." -ForegroundColor Yellow
        Write-Host "          Essas VMs ficarão SEM conexão de rede após a remoção:"                     -ForegroundColor Yellow
        $vmsConectadas | Select-Object VMName, Name |
            Sort-Object VMName | Format-Table -AutoSize | Out-Host
    }

    Write-Host ""
    if (-not (Confirm-Operacao "Confirmar remoção do switch '$nome'?")) {
        Write-Host "  Operação cancelada." -ForegroundColor Yellow
        return
    }

    # Pergunta sobre remover a rede NAT associada
    $removerNat = $false
    if ($natAssoc) {
        Write-Host ""
        $removerNat = Confirm-Operacao "Remover também a rede NAT '$($natAssoc.Name)'?"
    }

    Write-Host ""

    try {
        Remove-VMSwitch -Name $nome -Force
        Write-Host "  [OK] Switch '$nome' removido." -ForegroundColor Green
    } catch {
        Write-Host "  [ERRO] $($_.Exception.Message)" -ForegroundColor Red
        return
    }

    if ($removerNat -and $natAssoc) {
        try {
            Remove-NetNat -Name $natAssoc.Name -Confirm:$false
            Write-Host "  [OK] Rede NAT '$($natAssoc.Name)' removida." -ForegroundColor Green
        } catch {
            Write-Host "  [AVISO] Falha ao remover a rede NAT: $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================

# Verificação de pré-requisitos
if (-not (Test-Administrador)) {
    Write-Host ""
    Write-Host "  [ERRO] Este script precisa ser executado como Administrador." -ForegroundColor Red
    Write-Host "         Abra o PowerShell com 'Executar como administrador' e tente novamente." -ForegroundColor Yellow
    Write-Host ""
    return
}

if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
    Write-Host ""
    Write-Host "  [ERRO] O módulo Hyper-V não está disponível neste host." -ForegroundColor Red
    Write-Host "         Instale a função Hyper-V antes de usar este script." -ForegroundColor Yellow
    Write-Host ""
    return
}

do {
    Show-Header

    Write-Host "  Selecione a operação desejada:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1]  Criar Switch Virtual (Externo / Interno / Privado)"   -ForegroundColor White
    Write-Host "  [2]  Criar Switch NAT (fornecer internet às VMs)"          -ForegroundColor White
    Write-Host "  [3]  Listar Switches Virtuais"                             -ForegroundColor White
    Write-Host "  [4]  Remover Switch Virtual"                               -ForegroundColor White
    Write-Host "  [0]  Sair"                                                 -ForegroundColor DarkGray
    Write-Host ""

    $opcao = (Read-Host "  >> Digite a opção").Trim()

    switch ($opcao) {
        "1" { New-SwitchVirtual    }
        "2" { New-SwitchNat        }
        "3" { Show-SwitchList      }
        "4" { Remove-SwitchVirtual }
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
