# ============================================================
#  Automatiza a Implantação e Gestão do HYPER-V REPLICA
#  Ambiente : Windows Server 2019 ou superior (Hyper-V Replica
#             NÃO existe em Windows client)
#  Autor    : Fagner Nascimento — Especialista Microsoft Datacenter
#  Versão   : 1.0 — Preparação completa do servidor (Domínio ou
#             Workgroup, Kerberos ou Certificado HTTPS autoassinado,
#             instalação da função Hyper-V com resume pós-reboot),
#             administração do ciclo de vida da replicação (habilitar,
#             failover de teste/planejado/não planejado, estendida) e
#             monitoramento com dashboard HTML.
#             1.0.1 — CORREÇÃO: a CA raiz era removida da store Root
#             logo após ser instalada (Remove-CertificadoAntigo varria
#             My E Root), o que quebrava a cadeia e fazia o
#             Set-VMReplicationServer falhar com 0x800B0109
#             ("raiz que não é confiável"). Agora a remoção é dirigida
#             por store, Test-CertificadoReplica valida a CADEIA de
#             fato (X509Chain) e a etapa de certificado reinstala a CA
#             raiz do .cer quando ela estiver ausente.
#             1.1.0 — Menu 2 -> 13: RENOVAR o certificado da replicação
#             antes do vencimento, em duas fases (gerar / aplicar) e com
#             dois modos: reemitir SÓ o certificado do host mantendo a
#             mesma CA raiz (sem janela de risco, pois o par já confia
#             nela) ou gerar cadeia nova completa. A implantação passa a
#             exportar HyperV_Replica_RootCA.pfx para preservar a chave
#             da CA — sem ela, a raiz não pode mais assinar nada. A
#             aplicação atualiza o servidor Replica E o thumbprint de
#             CADA VM replicada, com Test-VMReplicationConnection como
#             trava antes da troca.
# ============================================================
#
#  COMO USAR EM CAMPO:
#   1. Execute este script PRIMEIRO no servidor PRIMÁRIO (ele coleta
#      a topologia e, no modo HTTPS, gera o certificado).
#   2. Copie a PASTA INTEIRA do script (com o .pfx gerado) para o
#      servidor SECUNDÁRIO (e o ESTENDIDO, se houver) e execute lá.
#   3. O progresso fica em Estado_Replica_<HOSTNAME>.json — se um
#      reboot for necessário, execute o script novamente e ele
#      continua de onde parou.
#
#  Referências oficiais (Microsoft Learn):
#   - Visão geral        : https://learn.microsoft.com/windows-server/virtualization/hyper-v/replication-overview
#   - Habilitar replica  : https://learn.microsoft.com/windows-server/virtualization/hyper-v/configure-replication-single-host
#   - Replicar VM        : https://learn.microsoft.com/windows-server/virtualization/hyper-v/replication-virtual-machines
#   - Failover           : https://learn.microsoft.com/windows-server/virtualization/hyper-v/replication-failover
#   - Set-VMReplicationServer : https://learn.microsoft.com/powershell/module/hyper-v/set-vmreplicationserver
#   - Enable-VMReplication    : https://learn.microsoft.com/powershell/module/hyper-v/enable-vmreplication
#   - Registro DisableCertRevocationCheck (KB 2767928):
#     https://learn.microsoft.com/troubleshoot/windows-server/virtualization/feature-performance-optimization-hyper-v-replica
#
#  OBSERVAÇÕES IMPORTANTES:
#   * Kerberos (HTTP/80)  : exige hosts no MESMO domínio (ou domínios
#     confiáveis); o tráfego NÃO é criptografado.
#   * Certificado (HTTPS/443): obrigatório em WORKGROUP; criptografa o
#     tráfego. O certificado precisa de EKU Client+Server Authentication
#     e CN/SAN igual ao FQDN de cada host — por isso o script gera UM
#     certificado com o FQDN de TODOS os hosts da topologia no SAN.
#   * As regras de firewall do ouvinte da replicação são criadas pela
#     instalação do Hyper-V, porém vêm DESABILITADAS — o script habilita
#     a regra correta conforme a autenticação. Elas são localizadas pelo
#     IDENTIFICADOR INTERNO (VIRT-HVRHTTPL* / VIRT-HVRHTTPSL*), e não pelo
#     DisplayName, que é traduzido conforme o idioma do Windows.
# ============================================================

# ============================================================
#  VARIÁVEIS DE SCRIPT
# ============================================================
$script:PastaScript    = $PSScriptRoot
$script:ArquivoEstado  = Join-Path $PSScriptRoot ("Estado_Replica_{0}.json" -f $env:COMPUTERNAME)
$script:ArquivoPfx     = Join-Path $PSScriptRoot "HyperV_Replica_Cert.pfx"
$script:ArquivoRootCer = Join-Path $PSScriptRoot "HyperV_Replica_RootCA.cer"
# PFX da CA raiz: guarda a CHAVE PRIVADA da CA para que a RENOVAÇÃO possa
# reemitir apenas o certificado do host (Menu 2 -> 13) sem trocar a raiz —
# o par já confia nela, então a renovação não tem janela de risco.
$script:ArquivoRootPfx = Join-Path $PSScriptRoot "HyperV_Replica_RootCA.pfx"
$script:PastaLogs      = Join-Path $PSScriptRoot "Logs"
$script:AnosCertHost   = 5
$script:AnosCertRaiz   = 10
$script:PortaKerberos  = 80
$script:PortaCert      = 443
$script:RegReplicacao  = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Replication"

# ============================================================
#  FUNÇÕES AUXILIARES GENÉRICAS
# ============================================================

# ------------------------------------------------------------
# Cabeçalho padrão exibido em todas as telas
# ------------------------------------------------------------
function Show-Header {
    param([string]$Titulo = "IMPLANTAÇÃO E GESTÃO DO HYPER-V REPLICA")
    Clear-Host
    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "       $Titulo" -ForegroundColor Cyan
    Write-Host "       Autor: Fagner Nascimento | Microsoft Datacenter"         -ForegroundColor DarkCyan
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host ""
}

# ------------------------------------------------------------
# Feedback padronizado do projeto: [OK]/[AVISO]/[ERRO]/[INFO]
# ------------------------------------------------------------
function Write-Status {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('OK', 'AVISO', 'ERRO', 'INFO')][string]$Tipo,
        [Parameter(Mandatory = $true)][string]$Mensagem
    )
    $cores = @{ OK = 'Green'; AVISO = 'Yellow'; ERRO = 'Red'; INFO = 'Cyan' }
    Write-Host ("  [{0}] {1}" -f $Tipo, $Mensagem) -ForegroundColor $cores[$Tipo]
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
# Lista numerada com validação e reprompt; retorna o item escolhido
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
            Write-Status -Tipo AVISO -Mensagem "Opção inválida. Digite um número entre 1 e $($Itens.Count)."
        }
    } while (-not $valido)
    return $Itens[$numero - 1]
}

# ------------------------------------------------------------
# Lê texto não vazio, com reprompt
# ------------------------------------------------------------
function Read-NonEmpty {
    param([string]$Mensagem)
    do {
        $valor = (Read-Host "  >> $Mensagem").Trim()
        if ([string]::IsNullOrWhiteSpace($valor)) {
            Write-Status -Tipo AVISO -Mensagem "O valor não pode ser vazio."
        }
    } while ([string]::IsNullOrWhiteSpace($valor))
    return $valor
}

# ------------------------------------------------------------
# Lê um inteiro dentro de uma faixa, com reprompt e padrão no ENTER vazio
# ------------------------------------------------------------
function Read-Inteiro {
    param(
        [Parameter(Mandatory = $true)][string]$Mensagem,
        [int]$Padrao,
        [int]$Minimo = 1,
        [int]$Maximo = 100
    )
    while ($true) {
        $bruto = (Read-Host ("  >> {0} [{1}]" -f $Mensagem, $Padrao)).Trim()
        if ([string]::IsNullOrWhiteSpace($bruto)) { return $Padrao }
        $numero = 0
        if (-not [int]::TryParse($bruto, [ref]$numero)) {
            Write-Status -Tipo AVISO -Mensagem "Informe um número inteiro."
            continue
        }
        if ($numero -lt $Minimo -or $numero -gt $Maximo) {
            Write-Status -Tipo AVISO -Mensagem "Informe um valor entre $Minimo e $Maximo."
            continue
        }
        return $numero
    }
}

# ------------------------------------------------------------
# Pergunta (S/N) com reprompt e valor padrão aplicado ao ENTER vazio
# ------------------------------------------------------------
function Read-Confirmacao {
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
        Write-Status -Tipo AVISO -Mensagem "Resposta inválida. Informe 'S' ou 'N'."
    }
}

# ------------------------------------------------------------
# Confirmação simples antes de aplicar uma alteração
# ------------------------------------------------------------
function Confirm-Operacao {
    param([string]$Mensagem = "Confirmar operação?")
    $conf = (Read-Host "  >> $Mensagem (S/N)").Trim().ToUpper()
    return ($conf -eq "S")
}

# ------------------------------------------------------------
# Validação de endereço IPv4
# ------------------------------------------------------------
function Validate-IPv4 {
    param([string]$IP)
    $regex = '^((25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)$'
    return ($IP -match $regex)
}

# ------------------------------------------------------------
# Lê um IPv4 com valor padrão aplicado ao ENTER vazio
# ------------------------------------------------------------
function Read-IPv4 {
    param(
        [string]$Mensagem,
        [string]$Padrao = ""
    )
    do {
        $sufixo = ""
        if ($Padrao) { $sufixo = " [$Padrao]" }
        $valor = (Read-Host "  >> $Mensagem$sufixo").Trim()
        if ([string]::IsNullOrWhiteSpace($valor) -and $Padrao) { $valor = $Padrao }
        $valido = Validate-IPv4 -IP $valor
        if (-not $valido) {
            Write-Status -Tipo AVISO -Mensagem "Endereço IPv4 inválido. Exemplo: 192.168.10.21"
        }
    } while (-not $valido)
    return $valor
}

# ------------------------------------------------------------
# Lê um FQDN (nome com pelo menos um ponto), com valor padrão
# ------------------------------------------------------------
function Read-Fqdn {
    param(
        [string]$Mensagem,
        [string]$Padrao = ""
    )
    $regex = '^(?=.{4,255}$)([A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?\.)+[A-Za-z0-9]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$'
    do {
        $sufixo = ""
        if ($Padrao) { $sufixo = " [$Padrao]" }
        $valor = (Read-Host "  >> $Mensagem$sufixo").Trim()
        if ([string]::IsNullOrWhiteSpace($valor) -and $Padrao) { $valor = $Padrao }
        $valido = ($valor -match $regex)
        if (-not $valido) {
            Write-Status -Tipo AVISO -Mensagem "Informe um FQDN válido (com ponto). Exemplo: hv01.replica.local"
        }
    } while (-not $valido)
    return $valor.ToLower()
}

# ------------------------------------------------------------
# Lê uma senha (SecureString) duas vezes e compara em memória.
# A comparação usa System.Net.NetworkCredential apenas em memória;
# a senha NUNCA é gravada em disco.
# ------------------------------------------------------------
function Read-SenhaConfirmada {
    param([string]$Mensagem = "Defina a senha do arquivo PFX")
    while ($true) {
        $senha1 = Read-Host "  >> $Mensagem" -AsSecureString
        $senha2 = Read-Host "  >> Confirme a senha" -AsSecureString
        $texto1 = (New-Object System.Net.NetworkCredential("", $senha1)).Password
        $texto2 = (New-Object System.Net.NetworkCredential("", $senha2)).Password
        if ([string]::IsNullOrWhiteSpace($texto1)) {
            Write-Status -Tipo AVISO -Mensagem "A senha não pode ser vazia."
            continue
        }
        if ($texto1 -ceq $texto2) {
            $texto1 = $null; $texto2 = $null
            return $senha1
        }
        Write-Status -Tipo AVISO -Mensagem "As senhas não conferem. Tente novamente."
    }
}

# ------------------------------------------------------------
# Pausa padrão entre telas
# ------------------------------------------------------------
function Wait-EnterContinuar {
    Write-Host ""
    Read-Host "  >> Pressione ENTER para continuar" | Out-Null
}

# ------------------------------------------------------------
# Transcript das operações que alteram o ambiente (evidência de campo)
# ------------------------------------------------------------
function Start-LogOperacao {
    param([string]$Operacao)
    try {
        if (-not (Test-Path $script:PastaLogs)) {
            New-Item -ItemType Directory -Path $script:PastaLogs -Force | Out-Null
        }
        $arquivo = Join-Path $script:PastaLogs ("Replica_{0}_{1}.log" -f $Operacao, (Get-Date -Format 'yyyyMMdd_HHmmss'))
        Start-Transcript -Path $arquivo -ErrorAction Stop | Out-Null
        return $true
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível iniciar o log da operação: $($_.Exception.Message)"
        return $false
    }
}

function Stop-LogOperacao {
    param([bool]$LogAtivo)
    if ($LogAtivo) {
        try { Stop-Transcript | Out-Null } catch { }
    }
}

# ============================================================
#  ESTADO DA IMPLANTAÇÃO (JSON por hostname)
# ============================================================

# ------------------------------------------------------------
# Objeto de estado novo, com todos os campos zerados
# ------------------------------------------------------------
function New-EstadoImplantacao {
    return [pscustomobject]@{
        VersaoEstado          = 1
        Computador            = $env:COMPUTERNAME
        AtualizadoEm          = ""
        Papel                 = ""          # Primario | Secundario | Estendido
        Ambiente              = ""          # Dominio | Workgroup
        NomeWorkgroup         = ""
        SufixoDns             = ""
        Autenticacao          = ""          # Kerberos | Certificate
        Topologia             = @()         # [{Funcao, Fqdn, Ip}]
        CertificadoThumbprint = ""          # certificado do HOST (store My)
        RootCAThumbprint      = ""          # CA raiz que assinou (store Root)
        PastaReplicas         = ""
        Etapas                = [pscustomobject]@{}
        RebootPendente        = $null       # {Motivo, DataHora}
        # Renovação de certificado gerada e ainda NÃO aplicada neste host
        # (Menu 2 -> 13). Guarda o thumbprint novo entre as duas fases.
        RenovacaoPendente     = $null       # {Thumbprint, RootCAThumbprint, Modo, GeradoEm, NotAfter}
    }
}

# ------------------------------------------------------------
# Lê o estado do disco; se não existir/for inválido, retorna novo
# ------------------------------------------------------------
function Get-EstadoImplantacao {
    if (Test-Path $script:ArquivoEstado) {
        try {
            $json = Get-Content -Path $script:ArquivoEstado -Raw -Encoding UTF8
            $obj  = $json | ConvertFrom-Json
            if ($null -ne $obj -and $obj.Computador -eq $env:COMPUTERNAME) { return $obj }
            Write-Status -Tipo AVISO -Mensagem "Arquivo de estado pertence a outro computador ('$($obj.Computador)') — iniciando estado novo."
        } catch {
            Write-Status -Tipo AVISO -Mensagem "Arquivo de estado ilegível — iniciando estado novo. ($($_.Exception.Message))"
        }
    }
    return New-EstadoImplantacao
}

# ------------------------------------------------------------
# Grava o estado no disco (sempre ANTES de qualquer reboot)
# ------------------------------------------------------------
function Save-EstadoImplantacao {
    param([Parameter(Mandatory = $true)]$Estado)
    try {
        $Estado.AtualizadoEm = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
        $Estado | ConvertTo-Json -Depth 6 | Out-File -FilePath $script:ArquivoEstado -Encoding UTF8 -Force
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao gravar o arquivo de estado: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Marca uma etapa como concluída (com timestamp) e salva
# ------------------------------------------------------------
function Set-EtapaConcluida {
    param(
        [Parameter(Mandatory = $true)]$Estado,
        [Parameter(Mandatory = $true)][string]$Etapa
    )
    $carimbo = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    $Estado.Etapas | Add-Member -MemberType NoteProperty -Name $Etapa -Value $carimbo -Force
    Save-EstadoImplantacao -Estado $Estado
}

# ------------------------------------------------------------
# Verifica se uma etapa consta como concluída no estado
# ------------------------------------------------------------
function Test-EtapaConcluida {
    param(
        [Parameter(Mandatory = $true)]$Estado,
        [Parameter(Mandatory = $true)][string]$Etapa
    )
    $prop = $Estado.Etapas.PSObject.Properties[$Etapa]
    return ($null -ne $prop -and -not [string]::IsNullOrWhiteSpace([string]$prop.Value))
}


# ============================================================
#  DIAGNÓSTICO E PRÉ-REQUISITOS
# ============================================================

# ------------------------------------------------------------
# Hyper-V Replica só existe em Windows SERVER (ProductType 1 = client).
# Deve rodar ANTES de Get-WindowsFeature, que não existe em client.
# ------------------------------------------------------------
function Test-SOSuportado {
    $resultado = [pscustomobject]@{ Suportado = $false; Caption = ""; Motivo = "" }
    try {
        $so = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        $resultado.Caption = $so.Caption
        if ([int]$so.ProductType -eq 1) {
            $resultado.Motivo = "Hyper-V Replica não está disponível em Windows client ($($so.Caption)). Use Windows Server 2019 ou superior."
        } else {
            $resultado.Suportado = $true
            $resultado.Motivo    = "Sistema operacional compatível: $($so.Caption)."
        }
    } catch {
        $resultado.Motivo = "Não foi possível consultar o sistema operacional: $($_.Exception.Message)"
    }
    return $resultado
}

# ------------------------------------------------------------
# Estado da função Hyper-V no servidor
# ------------------------------------------------------------
function Test-HyperVInstalado {
    $resultado = [pscustomobject]@{ Instalado = $false; PendenteReboot = $false; Motivo = "" }
    try {
        $feature = Get-WindowsFeature -Name Hyper-V -ErrorAction Stop
        switch ([string]$feature.InstallState) {
            'Installed'      { $resultado.Instalado = $true;  $resultado.Motivo = "Função Hyper-V instalada." }
            'InstallPending' { $resultado.PendenteReboot = $true; $resultado.Motivo = "Instalação do Hyper-V aguardando REINICIALIZAÇÃO." }
            default          { $resultado.Motivo = "Função Hyper-V não instalada (estado: $($feature.InstallState))." }
        }
    } catch {
        $resultado.Motivo = "Não foi possível consultar a função Hyper-V: $($_.Exception.Message)"
    }
    return $resultado
}

# ------------------------------------------------------------
# Oferece e executa a reinicialização do servidor.
#
# Isolado em try/catch PRÓPRIO de propósito: uma falha ao reiniciar não
# pode ser reportada como falha da operação anterior — que já foi
# concluída com sucesso e gravada no arquivo de estado.
#
# ATENÇÃO: 'Restart-Computer -Delay' só é válido em conjunto com '-Wait'
# (ambos pertencem ao DefaultSet, mas Delay/Timeout/For dependem de Wait).
# Por isso a contagem regressiva usa Start-Sleep.
# ------------------------------------------------------------
function Invoke-ReinicioServidor {
    param([Parameter(Mandatory = $true)][string]$Motivo)

    Write-Host ""
    if (-not (Read-Confirmacao -Pergunta "Reiniciar o servidor AGORA?" -Padrao 'N')) {
        Write-Status -Tipo AVISO -Mensagem "Reinicie o servidor manualmente e execute o script novamente."
        Write-Status -Tipo INFO  -Mensagem "O progresso já foi salvo — a preparação continua de onde parou."
        return
    }
    try {
        Write-Status -Tipo INFO  -Mensagem "Reiniciando em 10 segundos... Execute o script novamente após o boot."
        Write-Status -Tipo AVISO -Mensagem "Pressione CTRL+C agora se quiser cancelar."
        Start-Sleep -Seconds 10
        Restart-Computer -Force -ErrorAction Stop
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível reiniciar automaticamente: $($_.Exception.Message)"
        Write-Status -Tipo INFO  -Mensagem "REINICIE O SERVIDOR MANUALMENTE para concluir $Motivo."
        Write-Status -Tipo INFO  -Mensagem "O progresso já foi salvo — execute o script novamente após o boot."
    }
}

# ------------------------------------------------------------
# Instala a função Hyper-V + consoles de gerenciamento (exige reboot)
# ------------------------------------------------------------
function Install-HyperVRole {
    param([Parameter(Mandatory = $true)]$Estado)
    Write-Host ""
    Write-Status -Tipo INFO -Mensagem "A função Hyper-V será instalada com os consoles de gerenciamento."
    Write-Status -Tipo AVISO -Mensagem "Será necessário REINICIAR o servidor ao final. Após reiniciar,"
    Write-Host "          execute este script novamente — ele continua de onde parou." -ForegroundColor Yellow
    Write-Host ""
    if (-not (Confirm-Operacao -Mensagem "Instalar a função Hyper-V agora?")) {
        Write-Status -Tipo AVISO -Mensagem "Instalação cancelada pelo operador."
        return $false
    }
    # O try/catch cobre SOMENTE a instalação — o reboot é tratado à parte
    try {
        $resultado = Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -ErrorAction Stop
        if (-not $resultado.Success) {
            Write-Status -Tipo ERRO -Mensagem "A instalação retornou falha (ExitCode: $($resultado.ExitCode))."
            return $false
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao instalar a função Hyper-V: $($_.Exception.Message)"
        return $false
    }

    Write-Status -Tipo OK -Mensagem "Função Hyper-V instalada. Reinicialização necessária."

    # Grava o estado ANTES de oferecer o reboot
    $Estado.RebootPendente = [pscustomobject]@{
        Motivo   = "Instalacao Hyper-V"
        DataHora = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Save-EstadoImplantacao -Estado $Estado

    Invoke-ReinicioServidor -Motivo "a instalação do Hyper-V"
    return $true
}

# ------------------------------------------------------------
# FQDN local: DNS primeiro, fallback COMPUTERNAME + sufixo do registro
# ------------------------------------------------------------
function Get-HostFqdn {
    try {
        $fqdn = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
        if ($fqdn -and $fqdn.Contains('.')) { return $fqdn.ToLower() }
    } catch { }
    try {
        $sufixo = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -ErrorAction Stop).'NV Domain'
        if (-not [string]::IsNullOrWhiteSpace($sufixo)) {
            return ("{0}.{1}" -f $env:COMPUTERNAME, $sufixo).ToLower()
        }
    } catch { }
    return $env:COMPUTERNAME.ToLower()
}

# ------------------------------------------------------------
# Resolve um nome via DNS/hosts (sem Test-NetConnection)
# ------------------------------------------------------------
function Test-ResolucaoNome {
    param([Parameter(Mandatory = $true)][string]$Nome)
    try {
        $enderecos = [System.Net.Dns]::GetHostAddresses($Nome)
        return ($enderecos.Count -gt 0)
    } catch {
        return $false
    }
}

# ------------------------------------------------------------
# Teste de porta TCP com timeout curto (Test-NetConnection é lento
# demais em porta fechada — ~20s; TcpClient resolve em 3s)
# ------------------------------------------------------------
function Test-PortaTcp {
    param(
        [Parameter(Mandatory = $true)][string]$Computador,
        [Parameter(Mandatory = $true)][int]$Porta,
        [int]$TimeoutMs = 3000
    )
    $cliente = New-Object System.Net.Sockets.TcpClient
    try {
        $async = $cliente.BeginConnect($Computador, $Porta, $null, $null)
        $ok    = $async.AsyncWaitHandle.WaitOne($TimeoutMs, $false)
        if ($ok -and $cliente.Connected) {
            $cliente.EndConnect($async)
            return $true
        }
        return $false
    } catch {
        return $false
    } finally {
        $cliente.Close()
    }
}

# ============================================================
#  WORKGROUP E RESOLUÇÃO DE NOMES
# ============================================================

# ------------------------------------------------------------
# Define o grupo de trabalho do host (exige reboot)
# ------------------------------------------------------------
function Set-WorkgroupHost {
    param(
        [Parameter(Mandatory = $true)][string]$Nome,
        [Parameter(Mandatory = $true)]$Estado
    )
    $atual = (Get-CimInstance -ClassName Win32_ComputerSystem).Workgroup
    if ($atual -and ($atual.ToUpper() -eq $Nome.ToUpper())) {
        Write-Status -Tipo OK -Mensagem "Host já pertence ao workgroup '$Nome' (já configurado — pulando)."
        return $true
    }
    Write-Host ""
    Write-Status -Tipo AVISO -Mensagem "O host será movido do workgroup '$atual' para '$Nome'."
    Write-Status -Tipo AVISO -Mensagem "Essa alteração exige REINICIALIZAÇÃO do servidor."
    if (-not (Confirm-Operacao -Mensagem "Alterar o workgroup para '$Nome'?")) {
        Write-Status -Tipo AVISO -Mensagem "Alteração de workgroup cancelada."
        return $false
    }
    # O try/catch cobre SOMENTE a alteração do workgroup — reboot tratado à parte
    try {
        Add-Computer -WorkgroupName $Nome -Force -ErrorAction Stop
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao alterar o workgroup: $($_.Exception.Message)"
        return $false
    }

    Write-Status -Tipo OK -Mensagem "Workgroup alterado para '$Nome'. Reinicialização necessária."
    $Estado.NomeWorkgroup  = $Nome
    $Estado.RebootPendente = [pscustomobject]@{
        Motivo   = "Alteracao de workgroup"
        DataHora = (Get-Date -Format 'yyyy-MM-dd HH:mm:ss')
    }
    Save-EstadoImplantacao -Estado $Estado

    Invoke-ReinicioServidor -Motivo "a alteração do workgroup"
    return $true
}

# ------------------------------------------------------------
# Sufixo DNS primário do computador (dá FQDN estável ao host em
# workgroup — requisito para o certificado CN/SAN = FQDN)
# ------------------------------------------------------------
function Set-SufixoDnsPrimario {
    param([Parameter(Mandatory = $true)][string]$Sufixo)
    $chave = 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters'
    try {
        $atual = (Get-ItemProperty -Path $chave -ErrorAction Stop).'NV Domain'
        if ($atual -and ($atual.ToLower() -eq $Sufixo.ToLower())) {
            Write-Status -Tipo OK -Mensagem "Sufixo DNS primário já é '$Sufixo' (já configurado — pulando)."
            return $true
        }
        Set-ItemProperty -Path $chave -Name 'NV Domain' -Value $Sufixo -ErrorAction Stop
        Set-ItemProperty -Path $chave -Name 'Domain'    -Value $Sufixo -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Sufixo DNS primário definido: '$Sufixo'. FQDN local: $env:COMPUTERNAME.$Sufixo"
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao definir o sufixo DNS: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Acrescenta entrada FQDN->IP no arquivo hosts (idempotente).
# Grava em ASCII: BOM UTF-8 pode quebrar o resolvedor.
# ------------------------------------------------------------
function Add-EntradaHosts {
    param(
        [Parameter(Mandatory = $true)][string]$Fqdn,
        [Parameter(Mandatory = $true)][string]$Ip
    )
    $arquivoHosts = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    $marcador     = "# HyperV-Replica"
    try {
        $linhas = @()
        if (Test-Path $arquivoHosts) {
            $linhas = @(Get-Content -Path $arquivoHosts -ErrorAction Stop)
        }
        $linhaNova = "{0}`t{1}`t{2}" -f $Ip, $Fqdn, $marcador

        # Já existe exatamente este mapeamento?
        $existente = $linhas | Where-Object { $_ -match ('^\s*{0}\s+{1}(\s|$)' -f [regex]::Escape($Ip), [regex]::Escape($Fqdn)) }
        if ($existente) {
            Write-Status -Tipo OK -Mensagem "hosts: '$Fqdn -> $Ip' já presente (pulando)."
            return $true
        }

        # FQDN apontando para OUTRO IP? Remove a entrada gerenciada antiga.
        $conflito = $linhas | Where-Object { ($_ -match ('\s{0}(\s|$)' -f [regex]::Escape($Fqdn))) -and ($_ -match [regex]::Escape($marcador)) }
        if ($conflito) {
            $linhas = $linhas | Where-Object { $_ -notin $conflito }
            Write-Status -Tipo AVISO -Mensagem "hosts: entrada antiga de '$Fqdn' substituída."
        }

        $linhas += $linhaNova
        Set-Content -Path $arquivoHosts -Value $linhas -Encoding ASCII -Force -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "hosts: adicionado '$Fqdn -> $Ip'."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao editar o arquivo hosts: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Exibe as entradas gerenciadas pelo script no arquivo hosts
# ------------------------------------------------------------
function Show-EntradasHosts {
    $arquivoHosts = Join-Path $env:SystemRoot "System32\drivers\etc\hosts"
    Write-Host ""
    Write-Host "  ── Entradas gerenciadas no arquivo hosts ───────────────" -ForegroundColor DarkCyan
    try {
        $linhas = @(Get-Content -Path $arquivoHosts -ErrorAction Stop | Where-Object { $_ -match '# HyperV-Replica' })
        if ($linhas.Count -eq 0) {
            Write-Host "  (nenhuma entrada gerenciada pelo script)" -ForegroundColor DarkGray
        } else {
            $linhas | ForEach-Object { Write-Host "  $_" -ForegroundColor White }
        }
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível ler o arquivo hosts: $($_.Exception.Message)"
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}


# ============================================================
#  CERTIFICADO AUTOASSINADO (autenticação HTTPS / porta 443)
#
#  Estratégia: UM certificado com o FQDN de TODOS os hosts da
#  topologia no SAN, gerado no PRIMÁRIO e transportado no PFX
#  (na pasta do script) para os demais hosts.
#  Requisitos oficiais: EKU Client + Server Authentication,
#  chave privada, cadeia em raiz confiável, CN/SAN = FQDN.
# ============================================================

# ------------------------------------------------------------
# Valida um certificado contra os requisitos do Hyper-V Replica
# ------------------------------------------------------------
function Test-CertificadoReplica {
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificado,
        [string]$FqdnEsperado = ""
    )
    $resultado = [pscustomobject]@{ Valido = $true; Motivos = @() }

    if ($Certificado.NotAfter -le (Get-Date)) {
        $resultado.Valido  = $false
        $resultado.Motivos += "Certificado expirado em $($Certificado.NotAfter.ToString('dd/MM/yyyy'))."
    } elseif ($Certificado.NotAfter -le (Get-Date).AddDays(90)) {
        $resultado.Motivos += "AVISO: certificado expira em $($Certificado.NotAfter.ToString('dd/MM/yyyy')) (menos de 90 dias)."
    }

    if (-not $Certificado.HasPrivateKey) {
        $resultado.Valido  = $false
        $resultado.Motivos += "Certificado sem chave privada."
    }

    # EKU: Server Authentication (1.3.6.1.5.5.7.3.1) e Client Authentication (1.3.6.1.5.5.7.3.2)
    $oids = @()
    foreach ($ext in $Certificado.Extensions) {
        if ($ext.Oid.Value -eq '2.5.29.37') {
            $eku  = [System.Security.Cryptography.X509Certificates.X509EnhancedKeyUsageExtension]$ext
            $oids = @($eku.EnhancedKeyUsages | ForEach-Object { $_.Value })
        }
    }
    if ($oids -notcontains '1.3.6.1.5.5.7.3.1') {
        $resultado.Valido  = $false
        $resultado.Motivos += "EKU 'Server Authentication' ausente."
    }
    if ($oids -notcontains '1.3.6.1.5.5.7.3.2') {
        $resultado.Valido  = $false
        $resultado.Motivos += "EKU 'Client Authentication' ausente."
    }

    # O certificado NÃO pode ser autoassinado (emissor = requerente).
    # O Hyper-V Replica recusa com o erro 0x80092007 ("O certificado
    # especificado é autoassinado") — ele exige que o certificado
    # ENCADEIE até uma raiz, e não que SEJA a raiz.
    if ($Certificado.Issuer -eq $Certificado.Subject) {
        $resultado.Valido  = $false
        $resultado.Motivos += "Certificado AUTOASSINADO (emissor = requerente): '$($Certificado.Subject)'. O Hyper-V Replica exige um certificado emitido por uma CA."
    } else {
        # A CADEIA precisa FECHAR em uma raiz confiável desta máquina.
        # É exatamente esta checagem que o Hyper-V faz internamente: se a CA
        # raiz não estiver em LocalMachine\Root, o Set-VMReplicationServer
        # falha com 0x800B0109 ("terminou em um certificado raiz que não é
        # confiável"). A revogação é ignorada de propósito — a CA é local e
        # não publica CRL (por isso DisableCertRevocationCheck = 1).
        $cadeia = New-Object System.Security.Cryptography.X509Certificates.X509Chain
        try {
            $cadeia.ChainPolicy.RevocationMode = [System.Security.Cryptography.X509Certificates.X509RevocationMode]::NoCheck
            $cadeia.ChainPolicy.VerificationFlags = [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreCertificateAuthorityRevocationUnknown -bor `
                                                    [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreEndRevocationUnknown -bor `
                                                    [System.Security.Cryptography.X509Certificates.X509VerificationFlags]::IgnoreRootRevocationUnknown
            $cadeiaOk = $cadeia.Build($Certificado)
            if (-not $cadeiaOk) {
                $status = @($cadeia.ChainStatus | ForEach-Object { $_.Status.ToString() })
                if ($status -contains 'UntrustedRoot' -or $status -contains 'PartialChain') {
                    $resultado.Valido  = $false
                    $resultado.Motivos += "A CADEIA não é confiável nesta máquina (status: $($status -join ', ')). A CA raiz que emitiu este certificado precisa estar em 'Autoridades de Certificação Raiz Confiáveis' (LocalMachine\Root) — sem isso o Hyper-V recusa com 0x800B0109."
                } else {
                    $resultado.Valido  = $false
                    $resultado.Motivos += "Falha na validação da cadeia do certificado: $($status -join ', ')."
                }
            }
        } catch {
            $resultado.Motivos += "AVISO: não foi possível avaliar a cadeia do certificado: $($_.Exception.Message)"
        } finally {
            if ($cadeia) { $cadeia.Dispose() }
        }
    }

    # SAN deve conter o FQDN do host (DnsNameList com fallback na extensão 2.5.29.17)
    if (-not [string]::IsNullOrWhiteSpace($FqdnEsperado)) {
        $nomes = @()
        try { $nomes = @($Certificado.DnsNameList | ForEach-Object { $_.Unicode.ToLower() }) } catch { }
        if ($nomes.Count -eq 0) {
            foreach ($ext in $Certificado.Extensions) {
                if ($ext.Oid.Value -eq '2.5.29.17') {
                    $texto = $ext.Format($false)
                    $nomes = @($texto -split ',' | ForEach-Object {
                        ($_ -replace '.*=', '').Trim().ToLower()
                    })
                }
            }
        }
        if ($nomes -notcontains $FqdnEsperado.ToLower()) {
            $resultado.Valido  = $false
            $resultado.Motivos += "O SAN não contém o FQDN deste host ('$FqdnEsperado'). Nomes no certificado: $($nomes -join ', ')"
        }
    }

    return $resultado
}

# ------------------------------------------------------------
# Localiza um certificado do Replica na store My pelo thumbprint
# ------------------------------------------------------------
function Get-CertificadoInstalado {
    param([string]$Thumbprint)
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) { return $null }
    return Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1
}

# ------------------------------------------------------------
# Instala a CA RAIZ (arquivo .cer) em Autoridades Raiz Confiáveis.
# É a raiz que precisa ser confiável — o certificado do host encadeia
# até ela.
# ------------------------------------------------------------
function Install-RootCAReplica {
    param([Parameter(Mandatory = $true)][string]$CaminhoCer)

    if (-not (Test-Path $CaminhoCer)) {
        Write-Status -Tipo ERRO -Mensagem "Arquivo da CA raiz não encontrado: $CaminhoCer"
        return $false
    }
    try {
        $certRaiz = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $CaminhoCer
        $jaInstalada = Get-ChildItem -Path 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
            Where-Object { $_.Thumbprint -eq $certRaiz.Thumbprint }
        if ($jaInstalada) {
            Write-Status -Tipo OK -Mensagem "CA raiz já presente em Autoridades Raiz Confiáveis (pulando)."
            return $true
        }
        Import-Certificate -FilePath $CaminhoCer -CertStoreLocation 'Cert:\LocalMachine\Root' -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "CA raiz instalada em Autoridades de Certificação Raiz Confiáveis."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao instalar a CA raiz: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Confirma que a CA raiz está em LocalMachine\Root.
# Sem isso, o Hyper-V rejeita o certificado do host com 0x800B0109.
# ------------------------------------------------------------
function Test-RootCAPresente {
    param([string]$Thumbprint)
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) { return $false }
    return $null -ne (Get-ChildItem -Path 'Cert:\LocalMachine\Root' -ErrorAction SilentlyContinue |
        Where-Object { $_.Thumbprint -eq $Thumbprint } | Select-Object -First 1)
}

# ------------------------------------------------------------
# Remove um certificado antigo/inválido das stores indicadas
# (usado ao regerar o certificado, para não deixar lixo).
#
# ATENÇÃO: -Stores é OBRIGATORIAMENTE dirigido quando o alvo é a CA
# raiz recém-instalada. Varrer My E Root de uma vez apagava a CA raiz
# da store confiável logo depois de instalá-la, e o resultado era o
# erro 0x800B0109 no Set-VMReplicationServer ("a cadeia terminou em um
# certificado raiz que não é confiável").
# ------------------------------------------------------------
function Remove-CertificadoAntigo {
    param(
        [string]$Thumbprint,
        [string[]]$Stores = @('Cert:\LocalMachine\My', 'Cert:\LocalMachine\Root')
    )
    if ([string]::IsNullOrWhiteSpace($Thumbprint)) { return }
    foreach ($store in $Stores) {
        try {
            $alvo = Get-ChildItem -Path $store -ErrorAction SilentlyContinue |
                Where-Object { $_.Thumbprint -eq $Thumbprint }
            if ($alvo) {
                $alvo | Remove-Item -Force -ErrorAction Stop
                Write-Status -Tipo INFO -Mensagem "Certificado antigo removido de $store."
            }
        } catch {
            Write-Status -Tipo AVISO -Mensagem "Não foi possível remover o certificado antigo de ${store}: $($_.Exception.Message)"
        }
    }
}

# ------------------------------------------------------------
# Desabilita a checagem de revogação (obrigatório com autoassinado).
# Fonte oficial (KB 2767928): DisableCertRevocationCheck = 1 em
# HKLM\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Virtualization\Replication
# ------------------------------------------------------------
function Set-ChecagemRevogacaoDesabilitada {
    try {
        if (-not (Test-Path $script:RegReplicacao)) {
            New-Item -Path $script:RegReplicacao -Force -ErrorAction Stop | Out-Null
        }
        $atual = (Get-ItemProperty -Path $script:RegReplicacao -Name 'DisableCertRevocationCheck' -ErrorAction SilentlyContinue).DisableCertRevocationCheck
        if ($atual -eq 1) {
            Write-Status -Tipo OK -Mensagem "Checagem de revogação já desabilitada (pulando)."
            return $true
        }
        New-ItemProperty -Path $script:RegReplicacao -Name 'DisableCertRevocationCheck' -Value 1 -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "Checagem de revogação de certificado desabilitada (DisableCertRevocationCheck = 1)."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao gravar o registro: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# PRIMÁRIO: gera a CADEIA de certificados da replicação.
#
# São DOIS certificados, e isso é obrigatório: o Hyper-V Replica recusa
# certificado autoassinado (erro 0x80092007). A cadeia fica assim:
#
#   [CA raiz]  CN=Hyper-V Replica Root CA   -> LocalMachine\Root
#        |  assina
#   [Host]     CN=<fqdn primário>           -> LocalMachine\My
#              SAN = FQDN de TODOS os hosts da topologia
#              EKU = Server Auth + Client Auth
#
# 'New-SelfSignedCertificate -Signer' é o que faz o certificado do host
# ser emitido PELA raiz em vez de por ele mesmo. Sem -Signer, a doc diz:
# "If no signing certificate is specified, the first DNS name is also
#  saved as the Issuer Name" — ou seja, autoassinado.
# Fonte: https://learn.microsoft.com/powershell/module/pki/new-selfsignedcertificate
# ------------------------------------------------------------

# ------------------------------------------------------------
# Emite UM certificado de host assinado pela CA raiz informada.
# Isolado em função própria porque é usado na implantação (Menu 1) e na
# RENOVAÇÃO (Menu 2 -> 13), que reemite o host mantendo a mesma raiz.
# ------------------------------------------------------------
function New-CertificadoHost {
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Assinante,
        [Parameter(Mandatory = $true)][string[]]$Fqdns,
        [int]$Anos = $script:AnosCertHost
    )
    try {
        $cert = New-SelfSignedCertificate -Type Custom `
                                          -Subject "CN=$($Fqdns[0])" `
                                          -DnsName $Fqdns `
                                          -Signer $Assinante `
                                          -KeyUsage DigitalSignature, KeyEncipherment `
                                          -TextExtension @('2.5.29.37={text}1.3.6.1.5.5.7.3.1,1.3.6.1.5.5.7.3.2') `
                                          -KeyExportPolicy Exportable `
                                          -KeyLength 2048 `
                                          -KeyAlgorithm RSA `
                                          -HashAlgorithm SHA256 `
                                          -NotAfter (Get-Date).AddYears($Anos) `
                                          -FriendlyName 'Hyper-V Replica' `
                                          -CertStoreLocation 'Cert:\LocalMachine\My' `
                                          -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Certificado do host gerado. Thumbprint: $($cert.Thumbprint)"
        Write-Status -Tipo INFO -Mensagem "Emissor: $($cert.Issuer)"
        Write-Status -Tipo INFO -Mensagem "Validade: até $($cert.NotAfter.ToString('dd/MM/yyyy'))"
        return $cert
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao gerar o certificado do host: $($_.Exception.Message)"
        return $null
    }
}

# ------------------------------------------------------------
# Exporta a CHAVE PRIVADA da CA raiz para PFX. Sem este arquivo, a raiz
# não pode mais assinar nada e toda renovação exige cadeia NOVA (o que
# obriga a reimportar a raiz em todos os hosts).
# Precisa ser chamado ENQUANTO a raiz ainda está em LocalMachine\My —
# depois de removida de My, a chave privada não existe mais.
# ------------------------------------------------------------
function Export-RootCAReplica {
    param(
        [Parameter(Mandatory = $true)][System.Security.Cryptography.X509Certificates.X509Certificate2]$RootCA,
        [Parameter(Mandatory = $true)][System.Security.SecureString]$Senha
    )
    try {
        Export-PfxCertificate -Cert $RootCA -FilePath $script:ArquivoRootPfx -Password $Senha `
                              -ChainOption EndEntityCertOnly -Force -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "Chave da CA raiz exportada: $script:ArquivoRootPfx"
        Write-Status -Tipo AVISO -Mensagem "Este arquivo permite EMITIR novos certificados confiáveis — guarde-o"
        Write-Host "         com o mesmo cuidado de uma senha de administrador." -ForegroundColor Yellow
        return $true
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível exportar a chave da CA raiz: $($_.Exception.Message)"
        Write-Status -Tipo AVISO -Mensagem "A renovação futura exigirá gerar uma CADEIA NOVA nos dois hosts."
        return $false
    }
}

# ------------------------------------------------------------
# Devolve a CA raiz COM CHAVE PRIVADA, pronta para assinar:
#   1) se já estiver em LocalMachine\My, usa;
#   2) senão, importa do HyperV_Replica_RootCA.pfx (pede a senha).
# Devolve $null quando a chave não está disponível — nesse caso a
# renovação só pode gerar uma cadeia nova.
# ------------------------------------------------------------
function Get-RootCAAssinante {
    param([int]$Tentativas = 3)

    $comChave = Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=Hyper-V Replica Root CA' -and $_.HasPrivateKey } |
        Sort-Object NotAfter -Descending | Select-Object -First 1
    if ($comChave) {
        Write-Status -Tipo OK -Mensagem "CA raiz com chave privada encontrada na store (thumbprint $($comChave.Thumbprint))."
        return [pscustomobject]@{ Certificado = $comChave; ImportadaAgora = $false }
    }

    if (-not (Test-Path $script:ArquivoRootPfx)) { return $null }

    Write-Status -Tipo INFO -Mensagem "Chave da CA raiz disponível em $(Split-Path $script:ArquivoRootPfx -Leaf)."
    $importada = $null
    $n = 0
    while ($null -eq $importada -and $n -lt $Tentativas) {
        $n++
        $senha = Read-Host "  >> Senha do PFX da CA raiz [$n/$Tentativas]" -AsSecureString
        try {
            $importada = Import-PfxCertificate -FilePath $script:ArquivoRootPfx `
                                               -CertStoreLocation 'Cert:\LocalMachine\My' `
                                               -Password $senha -Exportable -ErrorAction Stop
        } catch {
            Write-Status -Tipo AVISO -Mensagem "Falha ao abrir o PFX da CA raiz (senha incorreta?): $($_.Exception.Message)"
        }
    }
    if ($null -eq $importada) {
        Write-Status -Tipo ERRO -Mensagem "Não foi possível abrir o PFX da CA raiz."
        return $null
    }
    return [pscustomobject]@{ Certificado = $importada; ImportadaAgora = $true }
}

function New-CertificadoReplica {
    param([Parameter(Mandatory = $true)]$Estado)

    $fqdns = @($Estado.Topologia | ForEach-Object { $_.Fqdn })
    if ($fqdns.Count -lt 2) {
        Write-Status -Tipo ERRO -Mensagem "Topologia incompleta — informe ao menos primário e secundário antes do certificado."
        return $false
    }

    Write-Host ""
    Write-Host "  ── Cadeia de certificados a ser gerada ─────────────────" -ForegroundColor DarkCyan
    Write-Host "  CA raiz          : CN=Hyper-V Replica Root CA (10 anos)"     -ForegroundColor White
    Write-Host "                     -> LocalMachine\Root (confiável)"         -ForegroundColor DarkGray
    Write-Host "  Certificado host : CN=$($fqdns[0]) (5 anos), emitido pela CA" -ForegroundColor White
    Write-Host "                     -> LocalMachine\My"                       -ForegroundColor DarkGray
    Write-Host "  SANs             : $($fqdns -join ', ')"                     -ForegroundColor White
    Write-Host "  EKU              : Server Authentication + Client Authentication" -ForegroundColor White
    Write-Host "  Chave            : RSA 2048, SHA-256, exportável"            -ForegroundColor White
    Write-Host "  Arquivos gerados : $(Split-Path $script:ArquivoRootCer -Leaf)  (CA raiz pública)" -ForegroundColor White
    Write-Host "                     $(Split-Path $script:ArquivoPfx -Leaf)  (certificado do host + chave)" -ForegroundColor White
    Write-Host "                     $(Split-Path $script:ArquivoRootPfx -Leaf)  (chave da CA — permite RENOVAR)" -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if ((Test-Path $script:ArquivoPfx)) {
        Write-Status -Tipo AVISO -Mensagem "Já existe um PFX na pasta do script."
        if (-not (Read-Confirmacao -Pergunta "Gerar uma NOVA cadeia e sobrescrever os arquivos existentes?" -Padrao 'N')) {
            Write-Status -Tipo AVISO -Mensagem "Geração cancelada — mantido o certificado existente."
            return $false
        }
    }

    if (-not (Confirm-Operacao -Mensagem "Gerar e instalar a cadeia de certificados agora?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return $false
    }

    # Remove uma cadeia anterior registrada no estado (evita lixo nas stores)
    if ($Estado.CertificadoThumbprint) {
        Remove-CertificadoAntigo -Thumbprint $Estado.CertificadoThumbprint
    }
    if ($Estado.RootCAThumbprint) {
        Remove-CertificadoAntigo -Thumbprint $Estado.RootCAThumbprint
    }

    # ---- 1) CA raiz (autoassinada, com BasicConstraints CA=1) ----
    $rootCA = $null
    try {
        $rootCA = New-SelfSignedCertificate -Type Custom `
                                            -Subject 'CN=Hyper-V Replica Root CA' `
                                            -KeyUsage CertSign, CRLSign, DigitalSignature `
                                            -TextExtension @('2.5.29.19={text}CA=1&pathlength=0') `
                                            -KeyExportPolicy Exportable `
                                            -KeyLength 2048 `
                                            -KeyAlgorithm RSA `
                                            -HashAlgorithm SHA256 `
                                            -NotAfter (Get-Date).AddYears(10) `
                                            -FriendlyName 'Hyper-V Replica Root CA' `
                                            -CertStoreLocation 'Cert:\LocalMachine\My' `
                                            -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "CA raiz gerada. Thumbprint: $($rootCA.Thumbprint)"
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao gerar a CA raiz: $($_.Exception.Message)"
        return $false
    }

    # ---- 2) Certificado do host, ASSINADO pela CA raiz ----
    $cert = New-CertificadoHost -Assinante $rootCA -Fqdns $fqdns -Anos $script:AnosCertHost
    if ($null -eq $cert) {
        Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint
        return $false
    }

    # ---- 3) Exporta a CA raiz (.cer) e a instala como raiz confiável ----
    try {
        Export-Certificate -Cert $rootCA -FilePath $script:ArquivoRootCer -Force -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "CA raiz exportada: $script:ArquivoRootCer"
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao exportar a CA raiz: $($_.Exception.Message)"
        return $false
    }
    if (-not (Install-RootCAReplica -CaminhoCer $script:ArquivoRootCer)) { return $false }

    # ---- 4) Exporta as chaves privadas (PFX protegidos por senha) ----
    # A CA raiz ainda está em My aqui — é a ÚNICA janela para exportar a
    # chave dela. Depois de removida de My, a chave deixa de existir e a
    # renovação futura só poderia gerar uma cadeia nova.
    Write-Host ""
    Write-Status -Tipo INFO -Mensagem "Defina a senha dos PFX. ANOTE-A: ela será pedida ao importar"
    Write-Host "         o certificado no servidor SECUNDÁRIO/ESTENDIDO e ao RENOVAR." -ForegroundColor Cyan
    Write-Host ""
    $senha = Read-SenhaConfirmada -Mensagem "Senha dos arquivos PFX"
    try {
        Export-PfxCertificate -Cert $cert -FilePath $script:ArquivoPfx -Password $senha `
                              -ChainOption EndEntityCertOnly -Force -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "PFX exportado: $script:ArquivoPfx"
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao exportar o PFX: $($_.Exception.Message)"
        return $false
    }

    # Chave da CA raiz (habilita a RENOVAÇÃO sem trocar a raiz)
    Export-RootCAReplica -RootCA $rootCA -Senha $senha | Out-Null

    # ---- 5) A CA raiz sai de "Pessoal"; seu lugar é a store Root ----
    # Remove SOMENTE de My: sem o -Stores dirigido, a mesma chamada apagaria
    # a CA da store Root e a cadeia ficaria órfã (erro 0x800B0109).
    Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint -Stores @('Cert:\LocalMachine\My')
    if (-not (Test-RootCAPresente -Thumbprint $rootCA.Thumbprint)) {
        Write-Status -Tipo ERRO -Mensagem "A CA raiz não está em Autoridades Raiz Confiáveis — a cadeia não seria válida."
        return $false
    }

    Write-Status -Tipo INFO -Mensagem "Copie a PASTA DO SCRIPT (com o .pfx E o .cer da CA raiz)"
    Write-Host "         para os demais servidores da topologia." -ForegroundColor Cyan

    if (-not (Set-ChecagemRevogacaoDesabilitada)) { return $false }

    # ---- 6) Validação final da cadeia gerada ----
    $validacao = Test-CertificadoReplica -Certificado $cert -FqdnEsperado (Get-HostFqdn)
    foreach ($motivo in $validacao.Motivos) {
        if ($motivo -like 'AVISO:*') { Write-Status -Tipo AVISO -Mensagem $motivo }
        else                          { Write-Status -Tipo ERRO  -Mensagem $motivo }
    }
    if (-not $validacao.Valido) {
        Write-Status -Tipo ERRO -Mensagem "A cadeia gerada não passou na validação — verifique os motivos acima."
        return $false
    }

    $Estado.CertificadoThumbprint = $cert.Thumbprint
    $Estado | Add-Member -MemberType NoteProperty -Name 'RootCAThumbprint' -Value $rootCA.Thumbprint -Force
    Save-EstadoImplantacao -Estado $Estado
    return $true
}

# ------------------------------------------------------------
# SECUNDÁRIO/ESTENDIDO: importa o PFX gerado no primário
# ------------------------------------------------------------
function Import-CertificadoReplica {
    param([Parameter(Mandatory = $true)]$Estado)

    # São necessários DOIS arquivos vindos do primário: a CA raiz (.cer)
    # e o certificado do host (.pfx, com a chave privada).
    $faltando = @()
    if (-not (Test-Path $script:ArquivoRootCer)) { $faltando += (Split-Path $script:ArquivoRootCer -Leaf) }
    if (-not (Test-Path $script:ArquivoPfx))     { $faltando += (Split-Path $script:ArquivoPfx -Leaf) }
    if ($faltando.Count -gt 0) {
        Write-Status -Tipo ERRO -Mensagem "Arquivo(s) de certificado não encontrado(s): $($faltando -join ', ')"
        Write-Host "         Copie a PASTA DO SCRIPT gerada no servidor PRIMÁRIO (ela contém" -ForegroundColor Red
        Write-Host "         a CA raiz e o certificado do host) e execute novamente."         -ForegroundColor Red
        return $false
    }

    $infoPfx  = Get-Item $script:ArquivoPfx
    $infoRoot = Get-Item $script:ArquivoRootCer
    Write-Host ""
    Write-Host "  ── Arquivos encontrados na pasta do script ─────────────" -ForegroundColor DarkCyan
    Write-Host "  CA raiz   : $($infoRoot.Name)  ($($infoRoot.LastWriteTime.ToString('dd/MM/yyyy HH:mm')))" -ForegroundColor White
    Write-Host "  Host      : $($infoPfx.Name)  ($($infoPfx.LastWriteTime.ToString('dd/MM/yyyy HH:mm')))"   -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Confirm-Operacao -Mensagem "Importar esta cadeia de certificados neste servidor?")) {
        Write-Status -Tipo AVISO -Mensagem "Importação cancelada."
        return $false
    }

    # A CA raiz precisa vir ANTES: sem ela na store Root, o certificado
    # do host não encadeia e a validação falha.
    if (-not (Install-RootCAReplica -CaminhoCer $script:ArquivoRootCer)) { return $false }

    $cert      = $null
    $tentativa = 0
    while ($null -eq $cert -and $tentativa -lt 3) {
        $tentativa++
        $senha = Read-Host "  >> Senha do PFX (definida no primário) [$tentativa/3]" -AsSecureString
        try {
            $cert = Import-PfxCertificate -FilePath $script:ArquivoPfx `
                                          -CertStoreLocation 'Cert:\LocalMachine\My' `
                                          -Password $senha -Exportable -ErrorAction Stop
        } catch {
            Write-Status -Tipo AVISO -Mensagem "Falha na importação (senha incorreta?): $($_.Exception.Message)"
        }
    }
    if ($null -eq $cert) {
        Write-Status -Tipo ERRO -Mensagem "Não foi possível importar o PFX após 3 tentativas."
        return $false
    }
    Write-Status -Tipo OK -Mensagem "Certificado importado em LocalMachine\My. Thumbprint: $($cert.Thumbprint)"

    # Valida contra os requisitos ANTES de seguir
    $fqdnLocal = Get-HostFqdn
    $validacao = Test-CertificadoReplica -Certificado $cert -FqdnEsperado $fqdnLocal
    foreach ($motivo in $validacao.Motivos) {
        if ($motivo -like 'AVISO:*') { Write-Status -Tipo AVISO -Mensagem $motivo }
        else                          { Write-Status -Tipo ERRO  -Mensagem $motivo }
    }
    if (-not $validacao.Valido) {
        Write-Host ""
        Write-Status -Tipo ERRO -Mensagem "O certificado não atende aos requisitos para ESTE host."
        Write-Host "         Se o FQDN deste host não está no SAN, gere novamente a"      -ForegroundColor Red
        Write-Host "         cadeia no PRIMÁRIO incluindo o FQDN '$fqdnLocal'."           -ForegroundColor Red
        return $false
    }

    if (-not (Set-ChecagemRevogacaoDesabilitada)) { return $false }

    $certRaiz = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2 $script:ArquivoRootCer
    $Estado.CertificadoThumbprint = $cert.Thumbprint
    $Estado | Add-Member -MemberType NoteProperty -Name 'RootCAThumbprint' -Value $certRaiz.Thumbprint -Force
    Save-EstadoImplantacao -Estado $Estado
    return $true
}

# ------------------------------------------------------------
# Orquestra a etapa de certificado conforme o papel do servidor
# ------------------------------------------------------------
function Invoke-EtapaCertificado {
    param([Parameter(Mandatory = $true)]$Estado)

    # Idempotência: thumbprint no estado + presente na store + válido
    $certAtual = Get-CertificadoInstalado -Thumbprint $Estado.CertificadoThumbprint
    if ($certAtual) {
        # AUTORREPARO: o certificado do host pode estar perfeito e a cadeia
        # quebrada apenas porque a CA raiz saiu de LocalMachine\Root. Nesse
        # caso basta reinstalá-la do .cer — não é preciso regerar nada.
        $tpRaiz = $null
        if ($Estado.PSObject.Properties['RootCAThumbprint']) { $tpRaiz = $Estado.RootCAThumbprint }
        if ($tpRaiz -and -not (Test-RootCAPresente -Thumbprint $tpRaiz)) {
            Write-Status -Tipo AVISO -Mensagem "A CA raiz da cadeia não está em Autoridades Raiz Confiáveis — reinstalando."
            if (Test-Path $script:ArquivoRootCer) {
                Install-RootCAReplica -CaminhoCer $script:ArquivoRootCer | Out-Null
            } else {
                Write-Status -Tipo AVISO -Mensagem "Arquivo da CA raiz não encontrado ($(Split-Path $script:ArquivoRootCer -Leaf)) — a cadeia terá de ser regerada."
            }
        }

        $fqdnLocal = Get-HostFqdn
        $validacao = Test-CertificadoReplica -Certificado $certAtual -FqdnEsperado $fqdnLocal
        if ($validacao.Valido) {
            Write-Status -Tipo OK -Mensagem "Certificado válido já instalado (thumbprint $($Estado.CertificadoThumbprint)) — pulando."
            foreach ($motivo in $validacao.Motivos) { Write-Status -Tipo AVISO -Mensagem $motivo }
            return $true
        }
        Write-Status -Tipo AVISO -Mensagem "Certificado registrado no estado não é mais válido — refazendo a etapa."
    }

    if ($Estado.Papel -eq 'Primario') {
        return (New-CertificadoReplica -Estado $Estado)
    }
    return (Import-CertificadoReplica -Estado $Estado)
}


# ============================================================
#  CONFIGURAÇÃO DO SERVIDOR REPLICA
# ============================================================

# ------------------------------------------------------------
# Localiza as regras de firewall do Hyper-V Replica.
#
# IMPORTANTE: o DisplayName da regra é TRADUZIDO conforme o idioma do
# Windows (em pt-BR vira "Ouvinte HTTPS da Réplica do Hyper-V (TCP-In)"),
# portanto NÃO pode ser usado para localizar a regra. Já o 'Name'
# (identificador interno) é o mesmo em qualquer idioma:
#   VIRT-HVRHTTPL-In-TCP*   -> HTTP  (Kerberos, porta 80)
#   VIRT-HVRHTTPSL-In-TCP*  -> HTTPS (Certificado, porta 443)
# O curinga cobre as variantes "-NoScope" e com escopo.
# ------------------------------------------------------------
function Get-RegraFirewallReplica {
    param([Parameter(Mandatory = $true)][ValidateSet('Kerberos', 'Certificate')][string]$Autenticacao)

    $padraoNome = 'VIRT-HVRHTTPL-In-TCP*'
    $porta      = $script:PortaKerberos
    if ($Autenticacao -eq 'Certificate') {
        $padraoNome = 'VIRT-HVRHTTPSL-In-TCP*'
        $porta      = $script:PortaCert
    }

    # 1ª tentativa: pelo identificador interno (idioma-independente)
    $regras = @(Get-NetFirewallRule -Name $padraoNome -ErrorAction SilentlyContinue)
    if ($regras.Count -gt 0) { return $regras }

    # 2ª tentativa (fallback): entre as regras do Hyper-V Replica, filtra pela porta
    $regras = @(Get-NetFirewallRule -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -like 'VIRT-HVR*' -and $_.Direction -eq 'Inbound' } |
        Where-Object {
            $filtro = $_ | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            $filtro -and ($filtro.LocalPort -contains [string]$porta)
        })
    return $regras
}

# ------------------------------------------------------------
# Habilita a regra de firewall correta conforme a autenticação.
# As regras já existem (criadas pela instalação do Hyper-V),
# porém vêm DESABILITADAS.
# ------------------------------------------------------------
function Enable-FirewallReplica {
    param([Parameter(Mandatory = $true)][ValidateSet('Kerberos', 'Certificate')][string]$Autenticacao)

    $porta = $script:PortaKerberos
    if ($Autenticacao -eq 'Certificate') { $porta = $script:PortaCert }

    try {
        $regras = @(Get-RegraFirewallReplica -Autenticacao $Autenticacao)
        if ($regras.Count -eq 0) {
            Write-Status -Tipo ERRO -Mensagem "Regra de firewall do Hyper-V Replica (porta $porta) não encontrada neste servidor."
            Write-Host "         Confirme que a função Hyper-V está instalada — as regras são" -ForegroundColor Red
            Write-Host "         criadas por ela. Alternativa manual:"                          -ForegroundColor Red
            Write-Host "         Enable-NetFirewallRule -Name 'VIRT-HVRHTTPSL-In-TCP*'"        -ForegroundColor Yellow
            return $false
        }

        # Exibe o nome no idioma do servidor, para o operador conferir no console do firewall
        $nomeExibicao = $regras[0].DisplayName

        $desabilitadas = @($regras | Where-Object { $_.Enabled -ne 'True' })
        if ($desabilitadas.Count -eq 0) {
            Write-Status -Tipo OK -Mensagem "Regra de firewall já habilitada (pulando): '$nomeExibicao'."
            return $true
        }

        $desabilitadas | Enable-NetFirewallRule -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Regra de firewall habilitada (porta $porta): '$nomeExibicao'."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao habilitar a regra de firewall: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Configura o host como servidor Replica (recebe replicação)
#
# ATENÇÃO ao modelo de armazenamento do Hyper-V Replica:
#   - ReplicationAllowedFromAnyServer = $true  -> a pasta é GLOBAL e vai
#     em 'DefaultStorageLocation' aqui.
#   - ReplicationAllowedFromAnyServer = $false -> a pasta é definida POR
#     SERVIDOR AUTORIZADO, no parâmetro 'ReplicaStorageLocation' de
#     New-VMReplicationAuthorizationEntry (obrigatório). Passar
#     'DefaultStorageLocation' neste modo FALHA com a mensagem:
#     "O parâmetro 'ReplicationAllowedFromAnyServer' deve ser definido
#      como 'True' para permitir alterações em 'DefaultStorageLocation'."
# Fonte: https://learn.microsoft.com/powershell/module/hyper-v/set-vmreplicationserver
#        https://learn.microsoft.com/powershell/module/hyper-v/new-vmreplicationauthorizationentry
# ------------------------------------------------------------
function Set-ServidorReplica {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('Kerberos', 'Certificate')][string]$Autenticacao,
        [string]$Thumbprint = "",
        [Parameter(Mandatory = $true)][string]$PastaArmazenamento,
        [bool]$PermitirQualquerServidor = $false
    )
    try {
        $parametros = @{
            ReplicationEnabled               = $true
            AllowedAuthenticationType        = $Autenticacao
            ReplicationAllowedFromAnyServer  = $PermitirQualquerServidor
            ErrorAction                      = 'Stop'
        }
        # Só é aceito quando a replicação é liberada para qualquer servidor
        if ($PermitirQualquerServidor) {
            $parametros['DefaultStorageLocation'] = $PastaArmazenamento
        }
        if ($Autenticacao -eq 'Kerberos') {
            $parametros['KerberosAuthenticationPort'] = $script:PortaKerberos
        } else {
            $parametros['CertificateAuthenticationPort'] = $script:PortaCert
            $parametros['CertificateThumbprint']         = $Thumbprint
        }
        Set-VMReplicationServer @parametros
        Write-Status -Tipo OK -Mensagem "Servidor Replica habilitado (autenticação: $Autenticacao)."
        if (-not $PermitirQualquerServidor) {
            Write-Status -Tipo INFO -Mensagem "A pasta das replicas será aplicada em cada autorização de servidor."
        }
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao configurar o servidor Replica: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Autorização granular: quais primários podem replicar para cá
# ------------------------------------------------------------
function Add-AutorizacaoReplica {
    param(
        [Parameter(Mandatory = $true)][string]$ServidorPrimario,
        [Parameter(Mandatory = $true)][string]$PastaArmazenamento,
        [string]$TrustGroup = "HyperVReplica"
    )
    try {
        $existentes = @(Get-VMReplicationAuthorizationEntry -ErrorAction SilentlyContinue)
        $jaExiste   = $existentes | Where-Object { $_.AllowedPrimaryServer -eq $ServidorPrimario }
        if ($jaExiste) {
            Write-Status -Tipo OK -Mensagem "Autorização para '$ServidorPrimario' já existe (pulando)."
            return $true
        }
        New-VMReplicationAuthorizationEntry -AllowedPrimaryServer $ServidorPrimario `
                                            -ReplicaStorageLocation $PastaArmazenamento `
                                            -TrustGroup $TrustGroup `
                                            -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "Autorização criada para o primário '$ServidorPrimario'."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao criar a autorização: $($_.Exception.Message)"
        return $false
    }
}

# ------------------------------------------------------------
# Exibe a configuração atual do servidor Replica
# ------------------------------------------------------------
function Show-ConfigServidorReplica {
    Write-Host ""
    Write-Host "  ── Configuração atual do servidor Replica ──────────────" -ForegroundColor DarkCyan
    try {
        $cfg = Get-VMReplicationServer -ErrorAction Stop
        $auth = [string]$cfg.AllowedAuthenticationType
        Write-Host ("  Replicação habilitada : {0}" -f $cfg.ReplicationEnabled)            -ForegroundColor White
        Write-Host ("  Autenticação          : {0}" -f $auth)                              -ForegroundColor White
        Write-Host ("  Porta Kerberos (HTTP) : {0}" -f $cfg.KerberosAuthenticationPort)    -ForegroundColor White
        Write-Host ("  Porta Cert.  (HTTPS)  : {0}" -f $cfg.CertificateAuthenticationPort) -ForegroundColor White
        Write-Host ("  Aceita qualquer origem: {0}" -f $cfg.ReplicationAllowedFromAnyServer) -ForegroundColor White
        $entradas = @(Get-VMReplicationAuthorizationEntry -ErrorAction SilentlyContinue)
        if ($entradas.Count -gt 0) {
            Write-Host "  Servidores autorizados:" -ForegroundColor White
            foreach ($e in $entradas) {
                Write-Host ("    - {0}  ->  {1}  (TrustGroup: {2})" -f $e.AllowedPrimaryServer, $e.ReplicaStorageLocation, $e.TrustGroup) -ForegroundColor White
            }
        } else {
            Write-Host "  Servidores autorizados: (nenhuma entrada granular)" -ForegroundColor DarkGray
        }
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível ler a configuração: $($_.Exception.Message)"
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}

# ============================================================
#  MENU 1 — PREPARAÇÃO DO SERVIDOR (orquestração com resume)
# ============================================================

# ------------------------------------------------------------
# Coleta os FQDNs e IPs de todos os hosts da topologia
# ------------------------------------------------------------
function Read-TopologiaReplica {
    param([Parameter(Mandatory = $true)]$Estado)

    Write-Host ""
    Write-Host "  Informe os servidores da topologia de replicação." -ForegroundColor Yellow
    Write-Host "  O FQDN informado aqui PRECISA ser o mesmo usado no certificado" -ForegroundColor DarkGray
    Write-Host "  e na resolução de nomes (DNS ou arquivo hosts)."               -ForegroundColor DarkGray
    Write-Host ""

    $fqdnLocal = Get-HostFqdn
    $topologia = @()

    $fqdnPrimario = Read-Fqdn -Mensagem "FQDN do servidor PRIMÁRIO" -Padrao $(if ($Estado.Papel -eq 'Primario') { $fqdnLocal } else { "" })
    $ipPrimario   = Read-IPv4 -Mensagem "IP do servidor PRIMÁRIO"
    $topologia   += [pscustomobject]@{ Funcao = 'Primario'; Fqdn = $fqdnPrimario; Ip = $ipPrimario }

    $fqdnSecundario = Read-Fqdn -Mensagem "FQDN do servidor SECUNDÁRIO (replica)" -Padrao $(if ($Estado.Papel -eq 'Secundario') { $fqdnLocal } else { "" })
    $ipSecundario   = Read-IPv4 -Mensagem "IP do servidor SECUNDÁRIO"
    $topologia     += [pscustomobject]@{ Funcao = 'Secundario'; Fqdn = $fqdnSecundario; Ip = $ipSecundario }

    if (Read-Confirmacao -Pergunta "A topologia terá um TERCEIRO servidor (replica ESTENDIDA)?" -Padrao 'N') {
        $fqdnEstendido = Read-Fqdn -Mensagem "FQDN do servidor ESTENDIDO" -Padrao $(if ($Estado.Papel -eq 'Estendido') { $fqdnLocal } else { "" })
        $ipEstendido   = Read-IPv4 -Mensagem "IP do servidor ESTENDIDO"
        $topologia    += [pscustomobject]@{ Funcao = 'Estendido'; Fqdn = $fqdnEstendido; Ip = $ipEstendido }
    }

    Write-Host ""
    Write-Host "  ── Topologia informada ─────────────────────────────────" -ForegroundColor DarkCyan
    foreach ($h in $topologia) {
        $marcaLocal = ""
        if ($h.Fqdn -eq $fqdnLocal) { $marcaLocal = "   <-- ESTE SERVIDOR" }
        Write-Host ("  {0,-10} : {1}  ({2}){3}" -f $h.Funcao, $h.Fqdn, $h.Ip, $marcaLocal) -ForegroundColor White
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Confirm-Operacao -Mensagem "Confirmar esta topologia?")) {
        return $false
    }
    $Estado.Topologia = $topologia
    Save-EstadoImplantacao -Estado $Estado
    return $true
}

# ------------------------------------------------------------
# Retorna o host "par" deste servidor na topologia (para testes):
#   Primario   -> Secundario
#   Secundario -> Primario
#   Estendido  -> Secundario
# ------------------------------------------------------------
function Get-HostPar {
    param([Parameter(Mandatory = $true)]$Estado)
    $funcaoPar = 'Secundario'
    if ($Estado.Papel -eq 'Secundario') { $funcaoPar = 'Primario' }
    return ($Estado.Topologia | Where-Object { $_.Funcao -eq $funcaoPar } | Select-Object -First 1)
}

# ------------------------------------------------------------
# Checklist final de saúde do servidor ([OK]/[ERRO] por requisito)
# ------------------------------------------------------------
function Show-ChecklistSaude {
    param([Parameter(Mandatory = $true)]$Estado)

    Show-Header -Titulo "CHECKLIST DE SAÚDE — HYPER-V REPLICA"
    Write-Host "  Verificando cada requisito no estado REAL do servidor..." -ForegroundColor DarkGray
    Write-Host ""

    $itens = @()

    # 1. Sistema operacional
    $so = Test-SOSuportado
    $itens += [pscustomobject]@{ Requisito = "Windows Server"; Ok = $so.Suportado; Detalhe = $so.Caption }

    # 2. Elevação
    $admin = Test-Administrador
    $itens += [pscustomobject]@{ Requisito = "Sessão como Administrador"; Ok = $admin; Detalhe = "" }

    # 3. Hyper-V
    $hv = Test-HyperVInstalado
    $itens += [pscustomobject]@{ Requisito = "Função Hyper-V instalada"; Ok = $hv.Instalado; Detalhe = $hv.Motivo }

    # 4. FQDN local e resolução dos hosts da topologia
    $fqdnLocal = Get-HostFqdn
    $temFqdn   = $fqdnLocal.Contains('.')
    $itens += [pscustomobject]@{ Requisito = "FQDN local definido"; Ok = $temFqdn; Detalhe = $fqdnLocal }
    foreach ($h in @($Estado.Topologia)) {
        if ($h.Fqdn -eq $fqdnLocal) { continue }
        $resolve = Test-ResolucaoNome -Nome $h.Fqdn
        $itens += [pscustomobject]@{ Requisito = "Resolução de '$($h.Fqdn)'"; Ok = $resolve; Detalhe = $h.Ip }
    }

    # 5. Certificado (quando autenticação por certificado)
    if ($Estado.Autenticacao -eq 'Certificate') {
        $cert = Get-CertificadoInstalado -Thumbprint $Estado.CertificadoThumbprint
        if ($cert) {
            $validacao = Test-CertificadoReplica -Certificado $cert -FqdnEsperado $fqdnLocal
            $detalhe   = "Expira em $($cert.NotAfter.ToString('dd/MM/yyyy'))"
            if ($validacao.Motivos.Count -gt 0) { $detalhe = ($validacao.Motivos -join ' | ') }
            $itens += [pscustomobject]@{ Requisito = "Certificado válido (My+EKU+SAN)"; Ok = $validacao.Valido; Detalhe = $detalhe }
            # Quem precisa estar em Root é a CA RAIZ, não o certificado do
            # host (esse fica só em My). Checar o thumbprint do host aqui
            # reportava falha permanente.
            $tpRaiz = $null
            if ($Estado.PSObject.Properties['RootCAThumbprint']) { $tpRaiz = $Estado.RootCAThumbprint }
            $naRaiz = Test-RootCAPresente -Thumbprint $tpRaiz
            $detRaiz = "thumbprint da CA raiz ausente no estado"
            if ($tpRaiz) { $detRaiz = $tpRaiz }
            $itens += [pscustomobject]@{ Requisito = "CA raiz em Autoridades Raiz Confiáveis"; Ok = $naRaiz; Detalhe = $detRaiz }
        } else {
            $itens += [pscustomobject]@{ Requisito = "Certificado válido (My+EKU+SAN)"; Ok = $false; Detalhe = "Thumbprint não encontrado na store" }
        }
        $reg = (Get-ItemProperty -Path $script:RegReplicacao -Name 'DisableCertRevocationCheck' -ErrorAction SilentlyContinue).DisableCertRevocationCheck
        $itens += [pscustomobject]@{ Requisito = "Revogação desabilitada (autoassinado)"; Ok = ($reg -eq 1); Detalhe = "DisableCertRevocationCheck" }
    }

    # 6. Firewall (localiza pelo identificador interno — DisplayName é traduzido)
    if ($Estado.Autenticacao) {
        $portaFw = $script:PortaKerberos
        if ($Estado.Autenticacao -eq 'Certificate') { $portaFw = $script:PortaCert }
        $regras = @(Get-RegraFirewallReplica -Autenticacao $Estado.Autenticacao)
        $fwOk   = ($regras.Count -gt 0) -and (-not ($regras | Where-Object { $_.Enabled -ne 'True' }))
        $detalheFw = "regra não encontrada"
        if ($regras.Count -gt 0) { $detalheFw = $regras[0].DisplayName }
        $itens += [pscustomobject]@{ Requisito = "Firewall: ouvinte da replicação (porta $portaFw)"; Ok = $fwOk; Detalhe = $detalheFw }
    }

    # 7. Servidor Replica habilitado (papéis que recebem replicação)
    if ($hv.Instalado) {
        $cfg = Get-VMReplicationServer -ErrorAction SilentlyContinue
        if ($Estado.Papel -in @('Secundario', 'Estendido')) {
            $repOk = ($null -ne $cfg) -and $cfg.ReplicationEnabled
            $itens += [pscustomobject]@{ Requisito = "Servidor Replica habilitado"; Ok = $repOk; Detalhe = "" }
        } elseif ($null -ne $cfg -and $cfg.ReplicationEnabled) {
            $itens += [pscustomobject]@{ Requisito = "Servidor Replica habilitado (p/ failover reverso)"; Ok = $true; Detalhe = "" }
        }
    }

    # 8. Porta do par alcançável
    $par = Get-HostPar -Estado $Estado
    if ($par) {
        $porta = $script:PortaKerberos
        if ($Estado.Autenticacao -eq 'Certificate') { $porta = $script:PortaCert }
        $alcancavel = Test-PortaTcp -Computador $par.Fqdn -Porta $porta
        $itens += [pscustomobject]@{ Requisito = "Porta $porta alcançável em '$($par.Fqdn)'"; Ok = $alcancavel; Detalhe = "Normal falhar até o par concluir a preparação" }
    }

    # Impressão do checklist
    $falhas = 0
    foreach ($item in $itens) {
        $detalhe = ""
        if (-not [string]::IsNullOrWhiteSpace($item.Detalhe)) { $detalhe = " — $($item.Detalhe)" }
        if ($item.Ok) {
            Write-Status -Tipo OK -Mensagem "$($item.Requisito)$detalhe"
        } else {
            Write-Status -Tipo ERRO -Mensagem "$($item.Requisito)$detalhe"
            $falhas++
        }
    }

    Write-Host ""
    if ($falhas -eq 0) {
        Write-Status -Tipo OK -Mensagem "TODOS os requisitos atendidos. Servidor pronto para o Hyper-V Replica!"
    } else {
        Write-Status -Tipo AVISO -Mensagem "$falhas requisito(s) pendente(s). Revise os itens [ERRO] acima."
    }
    return ($falhas -eq 0)
}

# ------------------------------------------------------------
# ORQUESTRADOR do Menu 1 — etapas numeradas com resume
# ------------------------------------------------------------
function Invoke-PreparacaoServidor {
    Show-Header -Titulo "MENU 1 — PREPARAÇÃO DO SERVIDOR PARA HYPER-V REPLICA"

    # [Etapa 1/12] Sistema operacional
    Write-Host "  [Etapa 1/12] Validação do sistema operacional" -ForegroundColor Cyan
    $so = Test-SOSuportado
    if (-not $so.Suportado) {
        Write-Status -Tipo ERRO -Mensagem $so.Motivo
        return
    }
    Write-Status -Tipo OK -Mensagem $so.Motivo

    # [Etapa 2/12] Elevação
    Write-Host ""
    Write-Host "  [Etapa 2/12] Validação de privilégios" -ForegroundColor Cyan
    if (-not (Test-Administrador)) {
        Write-Status -Tipo ERRO -Mensagem "Execute o PowerShell como ADMINISTRADOR e rode o script novamente."
        return
    }
    Write-Status -Tipo OK -Mensagem "Sessão elevada (Administrador)."

    # [Etapa 3/12] Estado / resume
    Write-Host ""
    Write-Host "  [Etapa 3/12] Estado da implantação" -ForegroundColor Cyan
    $estado = Get-EstadoImplantacao
    if ($estado.Papel) {
        Write-Host ""
        Write-Host "  ── Implantação anterior encontrada ─────────────────────" -ForegroundColor DarkCyan
        Write-Host ("  Papel        : {0}" -f $estado.Papel)        -ForegroundColor White
        Write-Host ("  Ambiente     : {0}" -f $estado.Ambiente)     -ForegroundColor White
        Write-Host ("  Autenticação : {0}" -f $estado.Autenticacao) -ForegroundColor White
        Write-Host ("  Atualizado em: {0}" -f $estado.AtualizadoEm) -ForegroundColor White
        $etapasFeitas = @($estado.Etapas.PSObject.Properties | ForEach-Object { $_.Name })
        Write-Host ("  Etapas feitas: {0}" -f $(if ($etapasFeitas.Count -gt 0) { $etapasFeitas -join ', ' } else { '(nenhuma)' })) -ForegroundColor White
        Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
        Write-Host ""
        if (-not (Read-Confirmacao -Pergunta "Continuar a implantação anterior?" -Padrao 'S')) {
            $backup = "$script:ArquivoEstado.bak"
            Move-Item -Path $script:ArquivoEstado -Destination $backup -Force
            Write-Status -Tipo INFO -Mensagem "Estado anterior arquivado em: $backup"
            $estado = New-EstadoImplantacao
        }
    }

    # Reboot pendente?
    if ($null -ne $estado.RebootPendente) {
        Write-Host ""
        Write-Status -Tipo INFO -Mensagem "Reinicialização pendente registrada: $($estado.RebootPendente.Motivo) ($($estado.RebootPendente.DataHora))"
        if ($estado.RebootPendente.Motivo -eq 'Instalacao Hyper-V') {
            $hvCheck = Test-HyperVInstalado
            if ($hvCheck.Instalado) {
                Write-Status -Tipo OK -Mensagem "Hyper-V instalado com sucesso após o reboot — continuando."
                $estado.RebootPendente = $null
                Save-EstadoImplantacao -Estado $estado
            } elseif ($hvCheck.PendenteReboot) {
                Write-Status -Tipo ERRO -Mensagem "O servidor ainda NÃO foi reiniciado. Reinicie e execute o script novamente."
                return
            }
        } else {
            # Workgroup: se o nome atual já é o desejado, o reboot ocorreu
            $wgAtual = (Get-CimInstance -ClassName Win32_ComputerSystem).Workgroup
            if ($wgAtual -and $estado.NomeWorkgroup -and ($wgAtual.ToUpper() -eq $estado.NomeWorkgroup.ToUpper())) {
                Write-Status -Tipo OK -Mensagem "Workgroup '$wgAtual' ativo após o reboot — continuando."
                $estado.RebootPendente = $null
                Save-EstadoImplantacao -Estado $estado
            } else {
                Write-Status -Tipo ERRO -Mensagem "O servidor ainda NÃO foi reiniciado. Reinicie e execute o script novamente."
                return
            }
        }
    }

    $logAtivo = Start-LogOperacao -Operacao "Preparacao"
    try {

        # [Etapa 4/12] Papel do servidor
        Write-Host ""
        Write-Host "  [Etapa 4/12] Papel deste servidor na topologia" -ForegroundColor Cyan
        if ($estado.Papel) {
            Write-Status -Tipo OK -Mensagem "Papel já definido: $($estado.Papel) (pulando)."
        } else {
            Write-Status -Tipo INFO -Mensagem "RECOMENDAÇÃO: execute este script PRIMEIRO no servidor PRIMÁRIO"
            Write-Host "         (ele coleta a topologia e gera o certificado). Depois copie a"   -ForegroundColor Cyan
            Write-Host "         pasta do script para o SECUNDÁRIO (e o ESTENDIDO) e execute lá." -ForegroundColor Cyan
            $escolha = Select-FromList -Titulo "Qual é o papel DESTE servidor?" -Itens @(
                "PRIMÁRIO   — executa as VMs de produção (origem da replicação)",
                "SECUNDÁRIO — recebe as replicas (destino / DR)",
                "ESTENDIDO  — terceiro nível (recebe replica do secundário)"
            )
            if ($escolha -like 'PRIM*')      { $estado.Papel = 'Primario' }
            elseif ($escolha -like 'SECUN*') { $estado.Papel = 'Secundario' }
            else                             { $estado.Papel = 'Estendido' }
            Save-EstadoImplantacao -Estado $estado
            Write-Status -Tipo OK -Mensagem "Papel definido: $($estado.Papel)"
        }

        # [Etapa 5/12] Ambiente: Domínio ou Workgroup
        Write-Host ""
        Write-Host "  [Etapa 5/12] Ambiente de identidade" -ForegroundColor Cyan
        if ($estado.Ambiente) {
            Write-Status -Tipo OK -Mensagem "Ambiente já definido: $($estado.Ambiente) (pulando)."
        } else {
            $cs = Get-CimInstance -ClassName Win32_ComputerSystem
            if ($cs.PartOfDomain) {
                Write-Status -Tipo INFO -Mensagem "Este servidor está ingressado no domínio '$($cs.Domain)'."
            } else {
                Write-Status -Tipo INFO -Mensagem "Este servidor está em WORKGROUP ('$($cs.Workgroup)')."
            }
            $escolha = Select-FromList -Titulo "Como os servidores da replicação se autenticarão?" -Itens @(
                "DOMÍNIO   — todos os hosts no mesmo domínio AD (ou domínios confiáveis)",
                "WORKGROUP — hosts fora de domínio (autenticação por CERTIFICADO)"
            )
            if ($escolha -like 'DOM*') {
                if (-not $cs.PartOfDomain) {
                    Write-Status -Tipo ERRO -Mensagem "Você escolheu DOMÍNIO, mas este servidor NÃO está ingressado em domínio."
                    Write-Host "         Ingresse o servidor no domínio primeiro (Add-Computer -DomainName) e execute novamente." -ForegroundColor Red
                    return
                }
                $estado.Ambiente = 'Dominio'
            } else {
                $estado.Ambiente = 'Workgroup'
            }
            Save-EstadoImplantacao -Estado $estado
            Write-Status -Tipo OK -Mensagem "Ambiente definido: $($estado.Ambiente)"
        }

        # [Etapa 6/12] Topologia
        Write-Host ""
        Write-Host "  [Etapa 6/12] Topologia da replicação" -ForegroundColor Cyan
        if (@($estado.Topologia).Count -ge 2) {
            Write-Status -Tipo OK -Mensagem "Topologia já registrada com $(@($estado.Topologia).Count) servidores (pulando)."
        } else {
            if (-not (Read-TopologiaReplica -Estado $estado)) {
                Write-Status -Tipo AVISO -Mensagem "Topologia não confirmada — preparação interrompida."
                return
            }
        }

        # [Etapa 7/12] Workgroup: nome, sufixo DNS e arquivo hosts
        Write-Host ""
        Write-Host "  [Etapa 7/12] Identidade de rede" -ForegroundColor Cyan
        if ($estado.Ambiente -eq 'Workgroup') {
            if (Test-EtapaConcluida -Estado $estado -Etapa 'RedeWorkgroup') {
                Write-Status -Tipo OK -Mensagem "Rede do workgroup já configurada (pulando)."
            } else {
                Write-Status -Tipo AVISO -Mensagem "O NOME DO WORKGROUP deve ser IDÊNTICO em todos os servidores da topologia."
                $wgAtual = (Get-CimInstance -ClassName Win32_ComputerSystem).Workgroup
                if (Read-Confirmacao -Pergunta "Configurar/ajustar o workgroup deste host (atual: '$wgAtual')?" -Padrao 'N') {
                    $nomeWg = (Read-NonEmpty -Mensagem "Nome do workgroup (igual em todos os servidores)").ToUpper()
                    $mudou  = Set-WorkgroupHost -Nome $nomeWg -Estado $estado
                    if ($mudou -and $null -ne $estado.RebootPendente) {
                        Write-Status -Tipo AVISO -Mensagem "Continue a preparação APÓS a reinicialização."
                        return
                    }
                } else {
                    $estado.NomeWorkgroup = $wgAtual
                    Save-EstadoImplantacao -Estado $estado
                }

                # Sufixo DNS primário — dá o FQDN estável exigido pelo certificado
                $fqdnLocalAtual = Get-HostFqdn
                if (-not $fqdnLocalAtual.Contains('.')) {
                    Write-Status -Tipo AVISO -Mensagem "Este host não tem sufixo DNS — o FQDN é obrigatório para o certificado."
                    $hostLocal = $estado.Topologia | Where-Object { $_.Fqdn -like "$($env:COMPUTERNAME.ToLower()).*" } | Select-Object -First 1
                    $sufixoPadrao = ""
                    if ($hostLocal) { $sufixoPadrao = ($hostLocal.Fqdn -split '\.', 2)[1] }
                    $sufixo = Read-Fqdn -Mensagem "Sufixo DNS primário (ex.: replica.local)" -Padrao $sufixoPadrao
                    if (Set-SufixoDnsPrimario -Sufixo $sufixo) {
                        $estado.SufixoDns = $sufixo
                        Save-EstadoImplantacao -Estado $estado
                    }
                } else {
                    Write-Status -Tipo OK -Mensagem "FQDN local: $fqdnLocalAtual"
                }

                # Arquivo hosts: entradas para os demais servidores
                Write-Status -Tipo INFO -Mensagem "Sem DNS central, a resolução dos FQDNs usa o arquivo hosts."
                $fqdnLocalAtual = Get-HostFqdn
                foreach ($h in @($estado.Topologia)) {
                    if ($h.Fqdn -eq $fqdnLocalAtual) { continue }
                    Add-EntradaHosts -Fqdn $h.Fqdn -Ip $h.Ip | Out-Null
                }
                Show-EntradasHosts
                Set-EtapaConcluida -Estado $estado -Etapa 'RedeWorkgroup'
            }
        } else {
            Write-Status -Tipo OK -Mensagem "Ambiente de domínio — resolução de nomes via DNS do AD (nada a fazer)."
        }

        # [Etapa 8/12] Função Hyper-V
        Write-Host ""
        Write-Host "  [Etapa 8/12] Função Hyper-V" -ForegroundColor Cyan
        $hv = Test-HyperVInstalado
        if ($hv.Instalado) {
            Write-Status -Tipo OK -Mensagem "Função Hyper-V instalada (pulando)."
        } elseif ($hv.PendenteReboot) {
            Write-Status -Tipo ERRO -Mensagem "Instalação do Hyper-V aguardando REINICIALIZAÇÃO. Reinicie e execute novamente."
            return
        } else {
            Write-Status -Tipo AVISO -Mensagem $hv.Motivo
            if (-not (Install-HyperVRole -Estado $estado)) { return }
            # Se chegou aqui sem reboot imediato, o operador reiniciará depois
            return
        }

        # [Etapa 9/12] Método de autenticação
        Write-Host ""
        Write-Host "  [Etapa 9/12] Método de autenticação da replicação" -ForegroundColor Cyan
        if ($estado.Autenticacao) {
            Write-Status -Tipo OK -Mensagem "Autenticação já definida: $($estado.Autenticacao) (pulando)."
        } else {
            if ($estado.Ambiente -eq 'Workgroup') {
                Write-Status -Tipo INFO -Mensagem "Em WORKGROUP a autenticação por CERTIFICADO (HTTPS/443) é obrigatória."
                $estado.Autenticacao = 'Certificate'
            } else {
                $escolha = Select-FromList -Titulo "Escolha o método de autenticação:" -Itens @(
                    "KERBEROS    — HTTP/80, recomendado em domínio (tráfego NÃO criptografado)",
                    "CERTIFICADO — HTTPS/443, criptografa o tráfego de replicação"
                )
                if ($escolha -like 'KERB*') { $estado.Autenticacao = 'Kerberos' }
                else                        { $estado.Autenticacao = 'Certificate' }
            }
            Save-EstadoImplantacao -Estado $estado
            Write-Status -Tipo OK -Mensagem "Autenticação definida: $($estado.Autenticacao)"
        }

        # [Etapa 10/12] Certificado (somente autenticação por certificado)
        Write-Host ""
        Write-Host "  [Etapa 10/12] Certificado digital" -ForegroundColor Cyan
        if ($estado.Autenticacao -eq 'Certificate') {
            if (-not (Invoke-EtapaCertificado -Estado $estado)) {
                Write-Status -Tipo AVISO -Mensagem "Etapa de certificado não concluída — preparação interrompida."
                return
            }
        } else {
            Write-Status -Tipo OK -Mensagem "Autenticação Kerberos — certificado não é necessário."
        }

        # [Etapa 11/12] Servidor Replica (firewall, armazenamento, autorização)
        Write-Host ""
        Write-Host "  [Etapa 11/12] Configuração do servidor Replica" -ForegroundColor Cyan
        $configurarReplica = $true
        if ($estado.Papel -eq 'Primario') {
            Write-Status -Tipo INFO -Mensagem "Este é o PRIMÁRIO. Habilitá-lo TAMBÉM como servidor Replica é"
            Write-Host "         recomendado para permitir o FAILOVER REVERSO no futuro."      -ForegroundColor Cyan
            $configurarReplica = Read-Confirmacao -Pergunta "Habilitar este primário também como servidor Replica?" -Padrao 'S'
        }
        if ($configurarReplica) {
            if (-not (Enable-FirewallReplica -Autenticacao $estado.Autenticacao)) { return }

            if ([string]::IsNullOrWhiteSpace($estado.PastaReplicas)) {
                $pasta = Read-NonEmpty -Mensagem "Pasta local para armazenar as replicas (ex.: D:\Replicas)"
                if (-not (Test-Path $pasta)) {
                    if (Read-Confirmacao -Pergunta "A pasta '$pasta' não existe. Criar agora?" -Padrao 'S') {
                        try {
                            New-Item -ItemType Directory -Path $pasta -Force -ErrorAction Stop | Out-Null
                            Write-Status -Tipo OK -Mensagem "Pasta criada: $pasta"
                        } catch {
                            Write-Status -Tipo ERRO -Mensagem "Falha ao criar a pasta: $($_.Exception.Message)"
                            return
                        }
                    } else {
                        Write-Status -Tipo AVISO -Mensagem "Preparação interrompida — pasta de replicas é obrigatória."
                        return
                    }
                }
                $estado.PastaReplicas = $pasta
                Save-EstadoImplantacao -Estado $estado
            } else {
                Write-Status -Tipo OK -Mensagem "Pasta de replicas: $($estado.PastaReplicas) (já definida)."
            }

            # Autorização: granular (recomendado) ou qualquer servidor
            $escolhaAut = Select-FromList -Titulo "Quais servidores PODEM replicar para este host?" -Itens @(
                "SOMENTE os servidores da topologia (RECOMENDADO — mais seguro)",
                "QUALQUER servidor autenticado (menos seguro)"
            )
            $permitirQualquer = ($escolhaAut -like 'QUALQUER*')
            if ($permitirQualquer) {
                Write-Status -Tipo AVISO -Mensagem "Qualquer servidor autenticado poderá replicar para este host."
            }

            Write-Host ""
            Write-Host "  ── Resumo da configuração do servidor Replica ──────────" -ForegroundColor DarkCyan
            Write-Host ("  Autenticação        : {0}" -f $estado.Autenticacao)   -ForegroundColor White
            $portaResumo = $script:PortaKerberos
            if ($estado.Autenticacao -eq 'Certificate') { $portaResumo = $script:PortaCert }
            Write-Host ("  Porta               : {0}" -f $portaResumo)           -ForegroundColor White
            Write-Host ("  Pasta das replicas  : {0}" -f $estado.PastaReplicas)  -ForegroundColor White
            Write-Host ("  Origem autorizada   : {0}" -f $(if ($permitirQualquer) { 'Qualquer servidor' } else { 'Somente a topologia' })) -ForegroundColor White
            if ($permitirQualquer) {
                Write-Host  "  Aplicação da pasta  : global (DefaultStorageLocation)" -ForegroundColor DarkGray
            } else {
                Write-Host  "  Aplicação da pasta  : por servidor autorizado (ReplicaStorageLocation)" -ForegroundColor DarkGray
            }
            Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
            Write-Host ""
            if (-not (Confirm-Operacao -Mensagem "Aplicar a configuração do servidor Replica?")) {
                Write-Status -Tipo AVISO -Mensagem "Configuração cancelada."
                return
            }

            $okReplica = Set-ServidorReplica -Autenticacao $estado.Autenticacao `
                                             -Thumbprint $estado.CertificadoThumbprint `
                                             -PastaArmazenamento $estado.PastaReplicas `
                                             -PermitirQualquerServidor $permitirQualquer
            if (-not $okReplica) { return }

            if (-not $permitirQualquer) {
                $fqdnLocal = Get-HostFqdn
                foreach ($h in @($estado.Topologia)) {
                    if ($h.Fqdn -eq $fqdnLocal) { continue }
                    Add-AutorizacaoReplica -ServidorPrimario $h.Fqdn -PastaArmazenamento $estado.PastaReplicas | Out-Null
                }
            }
            Set-EtapaConcluida -Estado $estado -Etapa 'ServidorReplicaConfigurado'
        } else {
            Write-Status -Tipo INFO -Mensagem "Primário não habilitado como Replica (failover reverso exigirá esta etapa depois)."
        }

        # [Etapa 12/12] Verificação final
        Write-Host ""
        Write-Host "  [Etapa 12/12] Verificação final" -ForegroundColor Cyan
        Show-ConfigServidorReplica
        Wait-EnterContinuar
        $tudoOk = Show-ChecklistSaude -Estado $estado
        if ($tudoOk) {
            Set-EtapaConcluida -Estado $estado -Etapa 'TesteFinalOk'
            Write-Host ""
            if ($estado.Papel -eq 'Primario') {
                Write-Status -Tipo INFO -Mensagem "PRÓXIMO PASSO: copie a pasta do script para o servidor SECUNDÁRIO,"
                Write-Host "         execute a preparação lá e depois use o Menu 2 AQUI para"   -ForegroundColor Cyan
                Write-Host "         habilitar a replicação das VMs."                          -ForegroundColor Cyan
            } else {
                Write-Status -Tipo INFO -Mensagem "PRÓXIMO PASSO: no servidor PRIMÁRIO, use o Menu 2 para habilitar"
                Write-Host "         a replicação das VMs para este servidor."                 -ForegroundColor Cyan
            }
        }

    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}


# ============================================================
#  MENU 2 — ADMINISTRAR O HYPER-V REPLICA
# ============================================================

# ------------------------------------------------------------
# Getter padrão do projeto: lista de VMs locais ou $null
# ------------------------------------------------------------
function Get-VMNamesLocais {
    $vms = @(Get-VM -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -ExpandProperty Name)
    if ($vms.Count -eq 0) {
        Write-Host ""
        Write-Status -Tipo ERRO -Mensagem "Nenhuma máquina virtual encontrada neste host."
        return $null
    }
    return $vms
}

# ------------------------------------------------------------
# Lista de VMs COM replicação configurada (ou $null)
# ------------------------------------------------------------
function Get-VMNamesComReplica {
    $vms = @(Get-VMReplication -ErrorAction SilentlyContinue | Sort-Object VMName | Select-Object -ExpandProperty VMName -Unique)
    if ($vms.Count -eq 0) {
        Write-Host ""
        Write-Status -Tipo ERRO -Mensagem "Nenhuma VM com replicação configurada neste host."
        return $null
    }
    return $vms
}

# ------------------------------------------------------------
# Exibe o estado de replicação atual de uma VM (antes de alterar)
# ------------------------------------------------------------
function Show-ReplicaInfo {
    param([Parameter(Mandatory = $true)][string]$VMName)
    Write-Host ""
    Write-Host "  ── Estado atual da replicação de '$VMName' ─────────────" -ForegroundColor DarkCyan
    try {
        $rep = Get-VMReplication -VMName $VMName -ErrorAction Stop
        Write-Host ("  Modo           : {0}" -f $rep.ReplicationMode)      -ForegroundColor White
        Write-Host ("  Estado         : {0}" -f $rep.ReplicationState)     -ForegroundColor White
        Write-Host ("  Saúde          : {0}" -f $rep.ReplicationHealth)    -ForegroundColor White
        Write-Host ("  Primário       : {0}" -f $rep.PrimaryServerName)        -ForegroundColor White
        Write-Host ("  Replica        : {0}" -f $rep.ReplicaServerName)        -ForegroundColor White
        Write-Host ("  Porta          : {0}" -f $rep.ReplicaServerPort)    -ForegroundColor White
        Write-Host ("  Autenticação   : {0}" -f $rep.AuthenticationType)   -ForegroundColor White
        Write-Host ("  Frequência (s) : {0}" -f $rep.ReplicationFrequencySec)         -ForegroundColor White
        Write-Host ("  Relacionamento : {0}" -f $rep.ReplicationRelationshipType)     -ForegroundColor White
    } catch {
        Write-Host "  (VM sem replicação configurada)" -ForegroundColor DarkGray
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}

# ------------------------------------------------------------
# OPÇÃO 2.1 — Habilitar a replicação de uma VM (wizard completo)
# Executar no servidor PRIMÁRIO.
# ------------------------------------------------------------
function Enable-ReplicacaoVM {
    Show-Header -Titulo "[ MENU 2.1 ] HABILITAR REPLICAÇÃO DE UMA VM"
    Write-Status -Tipo INFO -Mensagem "Execute esta opção no servidor PRIMÁRIO (onde a VM roda)."
    $estado = Get-EstadoImplantacao

    $vms = Get-VMNamesLocais
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM a replicar:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $jaReplica = Get-VMReplication -VMName $vmEscolhida -ErrorAction SilentlyContinue
    if ($jaReplica) {
        Write-Status -Tipo AVISO -Mensagem "Esta VM já possui replicação configurada. Use a opção 10 para alterar."
        return
    }

    # Servidor replica (pré-preenchido a partir da topologia do estado)
    $padraoReplica = ""
    $hostSecundario = @($estado.Topologia) | Where-Object { $_.Funcao -eq 'Secundario' } | Select-Object -First 1
    if ($hostSecundario) { $padraoReplica = $hostSecundario.Fqdn }
    $servidorReplica = Read-Fqdn -Mensagem "FQDN do servidor REPLICA (destino)" -Padrao $padraoReplica

    # Autenticação e porta (pré-preenchidas do estado)
    $autenticacao = $estado.Autenticacao
    if ([string]::IsNullOrWhiteSpace($autenticacao)) {
        $escolhaAuth = Select-FromList -Titulo "Autenticação da replicação:" -Itens @("Kerberos (HTTP/80)", "Certificado (HTTPS/443)")
        if ($escolhaAuth -like 'Kerb*') { $autenticacao = 'Kerberos' } else { $autenticacao = 'Certificate' }
    }
    $porta = $script:PortaKerberos
    if ($autenticacao -eq 'Certificate') { $porta = $script:PortaCert }

    # Frequência de replicação
    $escolhaFreq = Select-FromList -Titulo "Frequência de replicação (RPO):" -Itens @(
        "30 segundos — menor perda de dados, maior consumo de rede",
        "5 minutos   — equilíbrio recomendado (padrão)",
        "15 minutos  — links lentos / muitas VMs"
    )
    $frequencia = 300
    if ($escolhaFreq -like '30 seg*')  { $frequencia = 30 }
    if ($escolhaFreq -like '15 min*')  { $frequencia = 900 }

    # Pontos de recuperação
    $recoveryHistory = 0
    if (Read-Confirmacao -Pergunta "Manter PONTOS DE RECUPERAÇÃO adicionais (voltar a horários anteriores)?" -Padrao 'N') {
        do {
            $entradaRh = (Read-Host "  >> Quantos pontos horários adicionais (1-24)").Trim()
            $rhValido  = [int]::TryParse($entradaRh, [ref]$recoveryHistory) -and $recoveryHistory -ge 1 -and $recoveryHistory -le 24
            if (-not $rhValido) { Write-Status -Tipo AVISO -Mensagem "Informe um número entre 1 e 24." }
        } while (-not $rhValido)
    }

    # VSS (consistência de aplicação) — só faz sentido com RecoveryHistory
    $vssHoras = 0
    if ($recoveryHistory -gt 0) {
        if (Read-Confirmacao -Pergunta "Criar pontos CONSISTENTES POR APLICAÇÃO (VSS) para cargas como SQL Server?" -Padrao 'N') {
            do {
                $entradaVss = (Read-Host "  >> Intervalo do VSS em horas (1-12)").Trim()
                $vssValido  = [int]::TryParse($entradaVss, [ref]$vssHoras) -and $vssHoras -ge 1 -and $vssHoras -le 12
                if (-not $vssValido) { Write-Status -Tipo AVISO -Mensagem "Informe um número entre 1 e 12." }
            } while (-not $vssValido)
        }
    }

    # Compressão
    $compressao = Read-Confirmacao -Pergunta "Habilitar COMPRESSÃO do tráfego de replicação?" -Padrao 'S'

    # Exclusão de VHDs
    $vhdsExcluidos = @()
    $todosVhds = @(Get-VMHardDiskDrive -VMName $vmEscolhida -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Path)
    if ($todosVhds.Count -gt 1) {
        if (Read-Confirmacao -Pergunta "A VM tem $($todosVhds.Count) discos. Deseja EXCLUIR algum da replicação (ex.: disco de page file)?" -Padrao 'N') {
            foreach ($vhd in $todosVhds) {
                if (Read-Confirmacao -Pergunta "Excluir da replicação: '$vhd'?" -Padrao 'N') {
                    $vhdsExcluidos += $vhd
                }
            }
            if ($vhdsExcluidos.Count -eq $todosVhds.Count) {
                Write-Status -Tipo ERRO -Mensagem "Não é possível excluir TODOS os discos da replicação."
                return
            }
        }
    }

    # Resumo + confirmação
    Write-Host ""
    Write-Host "  ── Resumo da replicação a habilitar ────────────────────" -ForegroundColor DarkCyan
    Write-Host ("  VM                 : {0}" -f $vmEscolhida)      -ForegroundColor White
    Write-Host ("  Servidor replica   : {0}" -f $servidorReplica)  -ForegroundColor White
    Write-Host ("  Autenticação/Porta : {0} / {1}" -f $autenticacao, $porta) -ForegroundColor White
    Write-Host ("  Frequência         : {0} segundos" -f $frequencia)        -ForegroundColor White
    Write-Host ("  Pontos adicionais  : {0}" -f $recoveryHistory)  -ForegroundColor White
    Write-Host ("  VSS (horas)        : {0}" -f $(if ($vssHoras -gt 0) { $vssHoras } else { 'desabilitado' })) -ForegroundColor White
    Write-Host ("  Compressão         : {0}" -f $(if ($compressao) { 'SIM' } else { 'NÃO' }))                   -ForegroundColor White
    Write-Host ("  VHDs excluídos     : {0}" -f $(if ($vhdsExcluidos.Count -gt 0) { $vhdsExcluidos -join '; ' } else { 'nenhum' })) -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""
    if (-not (Confirm-Operacao -Mensagem "Habilitar a replicação da VM '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }

    $logAtivo = Start-LogOperacao -Operacao "HabilitarReplicacao"
    try {
        $parametros = @{
            VMName                  = $vmEscolhida
            ReplicaServerName       = $servidorReplica
            ReplicaServerPort       = $porta
            AuthenticationType      = $autenticacao
            ReplicationFrequencySec = $frequencia
            CompressionEnabled      = $compressao
            ErrorAction             = 'Stop'
        }
        if ($autenticacao -eq 'Certificate') {
            $estadoCert = Get-EstadoImplantacao
            $certLocal  = Get-CertificadoInstalado -Thumbprint $estadoCert.CertificadoThumbprint
            if (-not $certLocal) {
                Write-Status -Tipo ERRO -Mensagem "Certificado do estado não encontrado — execute o Menu 1 (etapa de certificado)."
                return
            }
            $parametros['CertificateThumbprint'] = $certLocal.Thumbprint
        }
        if ($recoveryHistory -gt 0) { $parametros['RecoveryHistory'] = $recoveryHistory }
        if ($vssHoras -gt 0)        { $parametros['VSSSnapshotFrequencyHour'] = $vssHoras }
        if ($vhdsExcluidos.Count -gt 0) { $parametros['ExcludedVhdPath'] = $vhdsExcluidos }

        Enable-VMReplication @parametros
        Write-Status -Tipo OK -Mensagem "Replicação habilitada para '$vmEscolhida'."
        Write-Host ""
        if (Read-Confirmacao -Pergunta "Iniciar a REPLICAÇÃO INICIAL agora (pela rede)?" -Padrao 'S') {
            Start-VMInitialReplication -VMName $vmEscolhida -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Replicação inicial iniciada. Acompanhe no Menu 3."
        } else {
            Write-Status -Tipo INFO -Mensagem "Use a opção 2 do Menu 2 para iniciar a replicação inicial depois."
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao habilitar a replicação: $($_.Exception.Message)"
    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.2 — Iniciar a replicação inicial (agora/agendada/mídia)
# ------------------------------------------------------------
function Start-ReplicacaoInicial {
    Show-Header -Titulo "[ MENU 2.2 ] INICIAR REPLICAÇÃO INICIAL"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $escolha = Select-FromList -Titulo "Como enviar a cópia inicial?" -Itens @(
        "AGORA, pela rede",
        "AGENDAR o envio pela rede (até 7 dias)",
        "MÍDIA EXTERNA (exportar para HD/pendrive e importar no replica)"
    )
    if (-not (Confirm-Operacao -Mensagem "Iniciar a replicação inicial de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        if ($escolha -like 'AGORA*') {
            Start-VMInitialReplication -VMName $vmEscolhida -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Replicação inicial iniciada pela rede."
        } elseif ($escolha -like 'AGENDAR*') {
            do {
                $entradaData = (Read-Host "  >> Data/hora do envio (formato dd/MM/yyyy HH:mm)").Trim()
                $dataAgendada = New-Object DateTime 0
                $dataValida = [datetime]::TryParseExact($entradaData, 'dd/MM/yyyy HH:mm', [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$dataAgendada)
                if ($dataValida -and ($dataAgendada -le (Get-Date) -or $dataAgendada -gt (Get-Date).AddDays(7))) {
                    Write-Status -Tipo AVISO -Mensagem "A data deve estar no futuro e dentro de 7 dias."
                    $dataValida = $false
                } elseif (-not $dataValida) {
                    Write-Status -Tipo AVISO -Mensagem "Formato inválido. Exemplo: 25/12/2026 22:30"
                }
            } while (-not $dataValida)
            Start-VMInitialReplication -VMName $vmEscolhida -InitialReplicationStartTime $dataAgendada -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Replicação inicial agendada para $($dataAgendada.ToString('dd/MM/yyyy HH:mm'))."
        } else {
            $caminho = Read-NonEmpty -Mensagem "Caminho da mídia externa (ex.: E:\SeedReplica)"
            if (-not (Test-Path $caminho)) {
                New-Item -ItemType Directory -Path $caminho -Force -ErrorAction Stop | Out-Null
            }
            Start-VMInitialReplication -VMName $vmEscolhida -DestinationPath $caminho -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Exportação da cópia inicial iniciada para: $caminho"
            Write-Status -Tipo INFO -Mensagem "Transporte a mídia ao servidor replica e importe-a pelo Hyper-V Manager"
            Write-Host "         (Replicação > Importar Replicação Inicial) apontando para a pasta da VM." -ForegroundColor Cyan
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.3 — Status das replicações (leitura, sem confirmação)
# ------------------------------------------------------------
function Show-StatusReplicacao {
    Show-Header -Titulo "[ MENU 2.3 ] STATUS DAS REPLICAÇÕES"
    $reps = @(Get-VMReplication -ErrorAction SilentlyContinue | Sort-Object VMName)
    if ($reps.Count -eq 0) {
        Write-Status -Tipo AVISO -Mensagem "Nenhuma VM com replicação configurada neste host."
        return
    }
    Write-Host ("  {0,-25} {1,-12} {2,-10} {3,-10} {4,-8} {5}" -f 'VM', 'MODO', 'ESTADO', 'SAÚDE', 'FREQ(s)', 'PAR') -ForegroundColor Yellow
    Write-Host ("  " + "-" * 95) -ForegroundColor DarkGray
    foreach ($r in $reps) {
        $corSaude = 'Green'
        if ([string]$r.ReplicationHealth -eq 'Warning')  { $corSaude = 'Yellow' }
        if ([string]$r.ReplicationHealth -eq 'Critical') { $corSaude = 'Red' }
        $par = $r.ReplicaServerName
        if ([string]$r.ReplicationMode -eq 'Replica') { $par = $r.PrimaryServerName }
        Write-Host ("  {0,-25} {1,-12} {2,-10} " -f $r.VMName, $r.ReplicationMode, $r.ReplicationState) -NoNewline -ForegroundColor White
        Write-Host ("{0,-10} " -f $r.ReplicationHealth) -NoNewline -ForegroundColor $corSaude
        Write-Host ("{0,-8} {1}" -f $r.ReplicationFrequencySec, $par) -ForegroundColor White
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.4 — Teste de failover (executar no REPLICA)
# ------------------------------------------------------------
function Start-TesteFailover {
    Show-Header -Titulo "[ MENU 2.4 ] TESTE DE FAILOVER"
    Write-Status -Tipo INFO -Mensagem "Execute esta opção no servidor REPLICA. O teste cria uma VM"
    Write-Host "         temporária '<VM> - Test' ISOLADA — a produção continua intacta." -ForegroundColor Cyan
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM para o teste:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $rep = Get-VMReplication -VMName $vmEscolhida -ErrorAction SilentlyContinue
    if ($rep -and ([string]$rep.ReplicationMode -notin @('Replica', 'ExtendedReplica'))) {
        Write-Status -Tipo ERRO -Mensagem "O teste de failover deve ser executado no servidor REPLICA desta VM (aqui ela é '$($rep.ReplicationMode)')."
        return
    }

    if (-not (Confirm-Operacao -Mensagem "Criar a VM de teste a partir da replica de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    $logAtivo = Start-LogOperacao -Operacao "TesteFailover"
    try {
        $vmTeste = Start-VMFailover -VMName $vmEscolhida -AsTest -Passthru -Confirm:$false -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "VM de teste criada: '$($vmTeste.Name)' (sem rede, por segurança)."

        if (Read-Confirmacao -Pergunta "Conectar a VM de teste a um switch virtual (rede ISOLADA recomendada)?" -Padrao 'N') {
            $switches = @(Get-VMSwitch -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name)
            if ($switches.Count -gt 0) {
                $swEscolhido = Select-FromList -Titulo "Selecione o switch para a VM de teste:" -Itens $switches
                Get-VMNetworkAdapter -VMName $vmTeste.Name -ErrorAction Stop |
                    Connect-VMNetworkAdapter -SwitchName $swEscolhido -ErrorAction Stop
                Write-Status -Tipo OK -Mensagem "VM de teste conectada ao switch '$swEscolhido'."
                Write-Status -Tipo AVISO -Mensagem "Se o switch alcança a produção, pode haver CONFLITO de IP/nome!"
            } else {
                Write-Status -Tipo AVISO -Mensagem "Nenhum switch virtual disponível."
            }
        }

        if (Read-Confirmacao -Pergunta "Ligar a VM de teste agora?" -Padrao 'S') {
            Start-VM -Name $vmTeste.Name -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "VM de teste '$($vmTeste.Name)' em execução. Valide o funcionamento."
        }
        Write-Status -Tipo INFO -Mensagem "Ao terminar, use a opção 5 (Encerrar teste) — ela APAGA a VM de teste."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha no teste de failover: $($_.Exception.Message)"
    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.5 — Encerrar teste de failover (apaga a VM de teste)
# ------------------------------------------------------------
function Stop-TesteFailover {
    Show-Header -Titulo "[ MENU 2.5 ] ENCERRAR TESTE DE FAILOVER"
    # A propriedade TestVirtualMachine é preenchida enquanto um teste
    # de failover está ativo para a VM (validado por reflexão no tipo
    # Microsoft.HyperV.PowerShell.VMReplication)
    $emTeste = @(Get-VMReplication -ErrorAction SilentlyContinue |
        Where-Object { $null -ne $_.TestVirtualMachine } |
        Select-Object -ExpandProperty VMName -Unique)
    $vms = $emTeste
    if ($vms.Count -eq 0) {
        # Fallback: deixa o operador escolher entre as VMs replicadas
        $vms = Get-VMNamesComReplica
        if (-not $vms) { return }
    }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM cujo TESTE será encerrado:" -Itens $vms
    Write-Status -Tipo AVISO -Mensagem "Encerrar o teste APAGA a VM '<nome> - Test' e descarta os dados do teste."
    if (-not (Confirm-Operacao -Mensagem "Encerrar o teste de failover de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        Stop-VMFailover -VMName $vmEscolhida -Confirm:$false -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Teste encerrado — VM de teste removida."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao encerrar o teste: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.6 — Failover PLANEJADO (guiado, sem perda de dados)
# ------------------------------------------------------------
function Invoke-FailoverPlanejado {
    Show-Header -Titulo "[ MENU 2.6 ] FAILOVER PLANEJADO (SEM PERDA DE DADOS)"
    Write-Host "  O failover planejado tem etapas NO PRIMÁRIO e NO REPLICA:"        -ForegroundColor Yellow
    Write-Host ""
    Write-Host "    NO PRIMÁRIO : 1) Desligar a VM   2) Preparar (replicar pendências)" -ForegroundColor White
    Write-Host "    NO REPLICA  : 3) Failover        4) Reverter direção   5) Ligar VM" -ForegroundColor White
    Write-Host ""
    Write-Status -Tipo INFO -Mensagem "Este script executa apenas as etapas do LADO EM QUE ESTÁ RODANDO"
    Write-Host "         e mostra o que fazer no outro servidor." -ForegroundColor Cyan

    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $rep = Get-VMReplication -VMName $vmEscolhida -ErrorAction SilentlyContinue
    if (-not $rep) {
        Write-Status -Tipo ERRO -Mensagem "Não foi possível ler a replicação da VM."
        return
    }
    $modo = [string]$rep.ReplicationMode

    $logAtivo = Start-LogOperacao -Operacao "FailoverPlanejado"
    try {
        if ($modo -eq 'Primary') {
            # ---------------- LADO PRIMÁRIO ----------------
            Write-Host ""
            Write-Status -Tipo AVISO -Mensagem "A VM '$vmEscolhida' será DESLIGADA para o failover planejado."
            if (-not (Confirm-Operacao -Mensagem "Desligar a VM e preparar o failover AGORA?")) {
                Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
                return
            }
            if (-not (Confirm-Operacao -Mensagem "CONFIRMAÇÃO FINAL: prosseguir com o failover planejado?")) {
                Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
                return
            }
            $vm = Get-VM -Name $vmEscolhida -ErrorAction Stop
            if ([string]$vm.State -ne 'Off') {
                Stop-VM -Name $vmEscolhida -Force -ErrorAction Stop
                Write-Status -Tipo OK -Mensagem "VM desligada."
            } else {
                Write-Status -Tipo OK -Mensagem "VM já estava desligada."
            }
            Start-VMFailover -VMName $vmEscolhida -Prepare -Confirm:$false -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Preparação concluída — alterações pendentes replicadas."
            Write-Host ""
            Write-Host "  ─── PRÓXIMAS ETAPAS (execute NO SERVIDOR REPLICA) ──────" -ForegroundColor Yellow
            Write-Host "  Abra este script no servidor REPLICA e rode esta MESMA"    -ForegroundColor White
            Write-Host "  opção (Menu 2 > 6) para concluir: failover, reversão da"   -ForegroundColor White
            Write-Host "  direção e inicialização da VM."                            -ForegroundColor White
            Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor Yellow
        } elseif ($modo -in @('Replica', 'ExtendedReplica')) {
            # ---------------- LADO REPLICA ----------------
            $estadoRep = [string]$rep.ReplicationState
            Write-Host ""
            if ($estadoRep -notlike '*Prepared*' -and $estadoRep -ne 'PreparedForFailover') {
                Write-Status -Tipo AVISO -Mensagem "Estado atual: '$estadoRep'. Se a preparação no PRIMÁRIO ainda não"
                Write-Host "          foi feita, execute lá primeiro (Menu 2 > 6)." -ForegroundColor Yellow
                if (-not (Read-Confirmacao -Pergunta "O primário JÁ concluiu a etapa de preparação?" -Padrao 'N')) {
                    Write-Status -Tipo AVISO -Mensagem "Conclua a preparação no primário e volte aqui."
                    return
                }
            }
            if (-not (Confirm-Operacao -Mensagem "Executar o failover de '$vmEscolhida' NESTE servidor?")) {
                Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
                return
            }
            Start-VMFailover -VMName $vmEscolhida -Confirm:$false -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Failover executado — esta cópia assumirá como PRIMÁRIA."
            if (Read-Confirmacao -Pergunta "REVERTER a direção da replicação agora (recomendado)?" -Padrao 'S') {
                Set-VMReplication -VMName $vmEscolhida -Reverse -ErrorAction Stop
                Write-Status -Tipo OK -Mensagem "Direção revertida — este servidor agora é o PRIMÁRIO da VM."
            }
            if (Read-Confirmacao -Pergunta "Ligar a VM '$vmEscolhida' agora?" -Padrao 'S') {
                Start-VM -Name $vmEscolhida -ErrorAction Stop
                Write-Status -Tipo OK -Mensagem "VM em execução neste servidor."
                Write-Status -Tipo AVISO -Mensagem "Verifique a conexão de REDE da VM (conecte ao switch se necessário)."
            }
        } else {
            Write-Status -Tipo ERRO -Mensagem "Modo de replicação inesperado: '$modo'."
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha no failover planejado: $($_.Exception.Message)"
    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.7 — Failover NÃO PLANEJADO (desastre; executar no REPLICA)
# ------------------------------------------------------------
function Invoke-FailoverNaoPlanejado {
    Show-Header -Titulo "[ MENU 2.7 ] FAILOVER NÃO PLANEJADO (DESASTRE)"
    Write-Status -Tipo AVISO -Mensagem "Use apenas quando o PRIMÁRIO está INDISPONÍVEL. Pode haver perda"
    Write-Host "          de dados desde a última replicação. Execute NO REPLICA." -ForegroundColor Yellow

    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $rep = Get-VMReplication -VMName $vmEscolhida -ErrorAction SilentlyContinue
    if ($rep -and ([string]$rep.ReplicationMode -notin @('Replica', 'ExtendedReplica'))) {
        Write-Status -Tipo ERRO -Mensagem "O failover não planejado deve ser executado no servidor REPLICA."
        return
    }

    if (-not (Confirm-Operacao -Mensagem "O primário está realmente INDISPONÍVEL?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada. Se o primário está ativo, use o failover PLANEJADO."
        return
    }

    # Ponto de recuperação
    $usarSnapshot = $null
    $snapshots = @(Get-VMSnapshot -VMName $vmEscolhida -ErrorAction SilentlyContinue | Sort-Object CreationTime -Descending)
    if ($snapshots.Count -gt 0) {
        if (Read-Confirmacao -Pergunta "Existem $($snapshots.Count) pontos de recuperação. Usar um ponto ESPECÍFICO (em vez do mais recente)?" -Padrao 'N') {
            $itensSnap = @($snapshots | ForEach-Object { "{0}  ({1})" -f $_.Name, $_.CreationTime.ToString('dd/MM/yyyy HH:mm:ss') })
            $snapEscolhido = Select-FromList -Titulo "Selecione o ponto de recuperação:" -Itens $itensSnap
            $indice = [array]::IndexOf($itensSnap, $snapEscolhido)
            $usarSnapshot = $snapshots[$indice]
        }
    }

    if (-not (Confirm-Operacao -Mensagem "CONFIRMAÇÃO FINAL: executar o failover NÃO PLANEJADO de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    $logAtivo = Start-LogOperacao -Operacao "FailoverNaoPlanejado"
    try {
        if ($null -ne $usarSnapshot) {
            Start-VMFailover -VMRecoverySnapshot $usarSnapshot -Confirm:$false -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Failover executado no ponto '$($usarSnapshot.Name)'."
        } else {
            Start-VMFailover -VMName $vmEscolhida -Confirm:$false -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Failover executado no ponto mais recente."
        }
        if (Read-Confirmacao -Pergunta "Ligar a VM agora para validar o ponto escolhido?" -Padrao 'S') {
            Start-VM -Name $vmEscolhida -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "VM em execução. Valide o sistema e os dados ANTES de completar."
        }
        Write-Host ""
        Write-Status -Tipo AVISO -Mensagem "COMPLETAR o failover remove os pontos de recuperação (não há volta"
        Write-Host "          a pontos anteriores depois disso)." -ForegroundColor Yellow
        if (Read-Confirmacao -Pergunta "A VM está OK — COMPLETAR o failover agora?" -Padrao 'N') {
            Complete-VMFailover -VMName $vmEscolhida -Confirm:$false -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Failover completado."
        } else {
            Write-Status -Tipo INFO -Mensagem "Você pode completar depois executando novamente esta opção."
        }
        Write-Host ""
        Write-Host "  ─── ROTEIRO DE REVERSÃO (quando o primário voltar) ─────" -ForegroundColor Yellow
        Write-Host "  1. No PRIMÁRIO original:  Set-VMReplication -VMName '$vmEscolhida' -AsReplica" -ForegroundColor White
        Write-Host "  2. NESTE servidor:        Set-VMReplication -VMName '$vmEscolhida' -Reverse -ReplicaServerName '<FQDN do primário original>'" -ForegroundColor White
        Write-Host "  3. NESTE servidor:        Start-VMInitialReplication -VMName '$vmEscolhida'" -ForegroundColor White
        Write-Host "  Depois, um failover PLANEJADO devolve a VM ao servidor original." -ForegroundColor DarkGray
        Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor Yellow
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha no failover: $($_.Exception.Message)"
    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}

# ------------------------------------------------------------
# OPÇÕES 2.8/2.9 — Suspender / Retomar replicação
# ------------------------------------------------------------
function Suspend-ReplicacaoVM {
    Show-Header -Titulo "[ MENU 2.8 ] SUSPENDER REPLICAÇÃO"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    if (-not (Confirm-Operacao -Mensagem "Suspender a replicação de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        Suspend-VMReplication -VMName $vmEscolhida -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Replicação suspensa. As alterações acumulam até a retomada."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

function Resume-ReplicacaoVM {
    Show-Header -Titulo "[ MENU 2.9 ] RETOMAR REPLICAÇÃO"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    if (-not (Confirm-Operacao -Mensagem "Retomar a replicação de '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        Resume-VMReplication -VMName $vmEscolhida -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Replicação retomada."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.10 — Alterar configurações da replicação de uma VM
# ------------------------------------------------------------
function Set-ConfiguracaoReplicacao {
    Show-Header -Titulo "[ MENU 2.10 ] ALTERAR CONFIGURAÇÕES DA REPLICAÇÃO"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $parametros = @{ VMName = $vmEscolhida; ErrorAction = 'Stop' }
    $alterou = $false

    if (Read-Confirmacao -Pergunta "Alterar a FREQUÊNCIA de replicação?" -Padrao 'N') {
        $escolhaFreq = Select-FromList -Titulo "Nova frequência:" -Itens @("30 segundos", "5 minutos", "15 minutos")
        $novaFreq = 300
        if ($escolhaFreq -like '30*') { $novaFreq = 30 }
        if ($escolhaFreq -like '15*') { $novaFreq = 900 }
        $parametros['ReplicationFrequencySec'] = $novaFreq
        $alterou = $true
    }
    if (Read-Confirmacao -Pergunta "Alterar os PONTOS DE RECUPERAÇÃO adicionais?" -Padrao 'N') {
        do {
            $entradaRh = (Read-Host "  >> Pontos horários adicionais (0-24)").Trim()
            $novoRh = 0
            $rhValido = [int]::TryParse($entradaRh, [ref]$novoRh) -and $novoRh -ge 0 -and $novoRh -le 24
            if (-not $rhValido) { Write-Status -Tipo AVISO -Mensagem "Informe um número entre 0 e 24." }
        } while (-not $rhValido)
        $parametros['RecoveryHistory'] = $novoRh
        $alterou = $true
    }
    if (Read-Confirmacao -Pergunta "Alterar a COMPRESSÃO?" -Padrao 'N') {
        $parametros['CompressionEnabled'] = (Read-Confirmacao -Pergunta "Habilitar compressão?" -Padrao 'S')
        $alterou = $true
    }

    if (-not $alterou) {
        Write-Status -Tipo AVISO -Mensagem "Nenhuma alteração selecionada."
        return
    }
    if (-not (Confirm-Operacao -Mensagem "Aplicar as alterações em '$vmEscolhida'?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        Set-VMReplication @parametros
        Write-Status -Tipo OK -Mensagem "Configurações aplicadas."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.11 — Remover a replicação (confirmação reforçada)
# ------------------------------------------------------------
function Remove-ReplicacaoVM {
    Show-Header -Titulo "[ MENU 2.11 ] REMOVER REPLICAÇÃO DE UMA VM"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida
    Write-Status -Tipo AVISO -Mensagem "A remoção NÃO apaga a VM nem os discos — apenas o vínculo de replicação."
    Write-Host "          Remova nos DOIS servidores (primário e replica)." -ForegroundColor Yellow
    Write-Host ""
    $digitado = Read-Host "  >> Para confirmar, digite o NOME EXATO da VM"
    if ($digitado.Trim() -cne $vmEscolhida) {
        Write-Status -Tipo AVISO -Mensagem "Nome não confere — operação cancelada."
        return
    }
    if (-not (Confirm-Operacao -Mensagem "REMOVER a replicação de '$vmEscolhida' neste servidor?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        Remove-VMReplication -VMName $vmEscolhida -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Replicação removida neste servidor."
        Write-Status -Tipo INFO -Mensagem "Lembre-se de remover também no outro servidor da relação."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# ============================================================
#  OPÇÃO 2.13 — RENOVAR O CERTIFICADO DA REPLICAÇÃO
#
#  Por que existe: o certificado do host vale 5 anos. Renovar à mão exige
#  gerar a cadeia, distribuir, atualizar o servidor Replica E cada VM
#  replicada (o thumbprint fica gravado na configuração de CADA VM) — e
#  errar a ORDEM derruba a replicação.
#
#  A REGRA que comanda todo o fluxo:
#    a CA raiz nova precisa estar confiável em TODOS os hosts ANTES de
#    qualquer host passar a APRESENTAR o certificado novo.
#
#  A autenticação é TLS mútuo: o primário apresenta seu certificado (EKU
#  Client Auth) e o replica valida contra a store Root; o replica
#  apresenta o dele (EKU Server Auth) e o primário valida. Por isso os
#  DOIS lados precisam confiar na raiz antes da troca.
#
#  Daí os dois modos:
#   [A] REEMITIR o certificado do host mantendo a MESMA CA raiz
#       (exige a chave da CA — HyperV_Replica_RootCA.pfx). O par já
#       confia na raiz, então NÃO há ordem obrigatória nem janela de
#       risco: cada host pode ser renovado quando der.
#   [B] CADEIA NOVA completa (raiz + host), usada quando a chave da CA
#       não está disponível. Aqui a ordem é obrigatória:
#         1. primário GERA (não aplica)
#         2. copiar a pasta para o par
#         3. par IMPORTA e aplica
#         4. primário APLICA (com Test-VMReplicationConnection de trava)
#
#  Fontes oficiais:
#   - https://learn.microsoft.com/powershell/module/hyper-v/set-vmreplicationserver
#   - https://learn.microsoft.com/powershell/module/hyper-v/set-vmreplication
#   - https://learn.microsoft.com/powershell/module/hyper-v/test-vmreplicationconnection
# ============================================================

# ------------------------------------------------------------
# Renomeia um arquivo para .anterior_<data>, preservando rollback
# ------------------------------------------------------------
function Backup-ArquivoCertificado {
    param([Parameter(Mandatory = $true)][string]$Caminho)
    if (-not (Test-Path $Caminho)) { return }
    try {
        $destino = "{0}.anterior_{1}" -f $Caminho, (Get-Date -Format 'yyyyMMdd_HHmmss')
        Move-Item -Path $Caminho -Destination $destino -Force -ErrorAction Stop
        Write-Status -Tipo INFO -Mensagem "Arquivo anterior preservado: $(Split-Path $destino -Leaf)"
    } catch {
        Write-Status -Tipo AVISO -Mensagem "Não foi possível preservar '$(Split-Path $Caminho -Leaf)': $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# Lê o thumbprint de um PFX SEM importá-lo (Get-PfxData). Serve para
# mostrar ao operador se o arquivo da pasta é mais novo que o instalado.
# ------------------------------------------------------------
function Get-ThumbprintPfx {
    param(
        [Parameter(Mandatory = $true)][string]$Caminho,
        [Parameter(Mandatory = $true)][System.Security.SecureString]$Senha
    )
    try {
        $dados = Get-PfxData -FilePath $Caminho -Password $Senha -ErrorAction Stop
        $folha = @($dados.EndEntityCertificates) | Select-Object -First 1
        if ($folha) { return $folha.Thumbprint }
        return $null
    } catch {
        return $null
    }
}

# ------------------------------------------------------------
# Mostra o retrato do certificado NESTE host: o que o estado diz, o que
# está na store, o que o servidor Replica usa e o que cada VM usa.
# Divergência entre esses quatro é a causa mais comum de falha após uma
# renovação feita pela metade.
# ------------------------------------------------------------
function Show-DiagnosticoCertificado {
    param([Parameter(Mandatory = $true)]$Estado)

    Write-Host ""
    Write-Host "  ── Certificado atual deste host ────────────────────────" -ForegroundColor DarkCyan

    $cert = Get-CertificadoInstalado -Thumbprint $Estado.CertificadoThumbprint
    if ($cert) {
        $dias = [int]([math]::Floor(($cert.NotAfter - (Get-Date)).TotalDays))
        $corDias = 'Green'
        if ($dias -le 0)       { $corDias = 'Red' }
        elseif ($dias -le 90)  { $corDias = 'Yellow' }
        Write-Host ("  Requerente       : {0}" -f $cert.Subject)               -ForegroundColor White
        Write-Host ("  Emissor          : {0}" -f $cert.Issuer)                -ForegroundColor White
        Write-Host ("  Thumbprint       : {0}" -f $cert.Thumbprint)            -ForegroundColor White
        Write-Host ("  Expira em        : {0}  ({1} dia(s))" -f $cert.NotAfter.ToString('dd/MM/yyyy'), $dias) -ForegroundColor $corDias
        try { Write-Host ("  SANs             : {0}" -f (@($cert.DnsNameList | ForEach-Object { $_.Unicode }) -join ', ')) -ForegroundColor White } catch { }
        $val = Test-CertificadoReplica -Certificado $cert -FqdnEsperado (Get-HostFqdn)
        if ($val.Valido) {
            Write-Host  "  Validação        : OK (cadeia, EKU e SAN)"          -ForegroundColor Green
        } else {
            Write-Host  "  Validação        : FALHOU"                          -ForegroundColor Red
            foreach ($m in $val.Motivos) { Write-Host "                     . $m" -ForegroundColor Red }
        }
    } else {
        Write-Host "  (nenhum certificado do estado encontrado em LocalMachine\My)" -ForegroundColor Yellow
    }

    $tpRaiz = $null
    if ($Estado.PSObject.Properties['RootCAThumbprint']) { $tpRaiz = $Estado.RootCAThumbprint }
    if ($tpRaiz) {
        $naRaiz = Test-RootCAPresente -Thumbprint $tpRaiz
        $corRaiz = 'Green'; $txtRaiz = 'confiável'
        if (-not $naRaiz) { $corRaiz = 'Red'; $txtRaiz = 'AUSENTE de LocalMachine\Root' }
        Write-Host ("  CA raiz          : {0}  ({1})" -f $tpRaiz, $txtRaiz) -ForegroundColor $corRaiz
    }

    # Chave da CA raiz: define se a renovação pode manter a mesma raiz
    $temChaveNaStore = $null -ne (Get-ChildItem -Path 'Cert:\LocalMachine\My' -ErrorAction SilentlyContinue |
        Where-Object { $_.Subject -eq 'CN=Hyper-V Replica Root CA' -and $_.HasPrivateKey })
    if ($temChaveNaStore) {
        Write-Host "  Chave da CA      : disponível na store (permite reemitir só o host)" -ForegroundColor Green
    } elseif (Test-Path $script:ArquivoRootPfx) {
        Write-Host ("  Chave da CA      : disponível em {0} (permite reemitir só o host)" -f (Split-Path $script:ArquivoRootPfx -Leaf)) -ForegroundColor Green
    } else {
        Write-Host "  Chave da CA      : INDISPONÍVEL — a renovação exigirá cadeia nova" -ForegroundColor Yellow
    }

    # O que o SERVIDOR Replica usa hoje
    $cfg = Get-VMReplicationServer -ErrorAction SilentlyContinue
    if ($null -ne $cfg) {
        $tpServidor = [string]$cfg.CertificateThumbprint
        if ([string]::IsNullOrWhiteSpace($tpServidor)) { $tpServidor = '(vazio)' }
        $corSrv = 'White'
        if ($cert -and $tpServidor -ne $cert.Thumbprint) { $corSrv = 'Yellow' }
        Write-Host ("  Servidor Replica : {0}" -f $tpServidor) -ForegroundColor $corSrv
    }

    # O que cada VM replicada usa hoje
    $reps = @(Get-VMReplication -ErrorAction SilentlyContinue | Sort-Object VMName)
    if ($reps.Count -gt 0) {
        Write-Host "  VMs replicadas   :" -ForegroundColor White
        foreach ($r in $reps) {
            $tpVm = [string]$r.CertificateThumbprint
            if ([string]::IsNullOrWhiteSpace($tpVm)) { $tpVm = '(vazio)' }
            $corVm = 'White'
            if ($cert -and $tpVm -ne $cert.Thumbprint) { $corVm = 'Yellow' }
            Write-Host ("    {0,-22} {1,-8} {2}" -f $r.VMName, [string]$r.ReplicationMode, $tpVm) -ForegroundColor $corVm
        }
    } else {
        Write-Host "  VMs replicadas   : (nenhuma neste host)" -ForegroundColor DarkGray
    }

    $pend = $null
    if ($Estado.PSObject.Properties['RenovacaoPendente']) { $pend = $Estado.RenovacaoPendente }
    if ($null -ne $pend) {
        Write-Host ("  RENOVAÇÃO PENDENTE: {0} (modo {1}, gerada em {2})" -f $pend.Thumbprint, $pend.Modo, $pend.GeradoEm) -ForegroundColor Yellow
    }
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
}

# ------------------------------------------------------------
# Aplica um thumbprint no servidor Replica e em TODAS as VMs replicadas
# deste host. Os dois lugares importam: o servidor define o certificado
# do ouvinte; cada VM guarda o seu próprio thumbprint na configuração de
# replicação (Get-VMReplication.CertificateThumbprint).
# ------------------------------------------------------------
function Set-ThumbprintReplicacao {
    param([Parameter(Mandatory = $true)][string]$Thumbprint)

    $tudoOk = $true

    try {
        Set-VMReplicationServer -CertificateThumbprint $Thumbprint -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Servidor Replica atualizado para o novo certificado."
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao atualizar o servidor Replica: $($_.Exception.Message)"
        $tudoOk = $false
    }

    $reps = @(Get-VMReplication -ErrorAction SilentlyContinue | Sort-Object VMName)
    if ($reps.Count -eq 0) {
        Write-Status -Tipo INFO -Mensagem "Nenhuma VM replicada neste host — nada a atualizar por VM."
        return $tudoOk
    }

    $ok = 0; $falhas = 0
    foreach ($r in $reps) {
        try {
            Set-VMReplication -VMName $r.VMName -CertificateThumbprint $Thumbprint -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "VM '$($r.VMName)' atualizada."
            $ok++
        } catch {
            Write-Status -Tipo ERRO -Mensagem "VM '$($r.VMName)': $($_.Exception.Message)"
            $falhas++
        }
    }
    Write-Host ""
    Write-Status -Tipo INFO -Mensagem "VMs atualizadas: $ok | falhas: $falhas"
    if ($falhas -gt 0) { $tudoOk = $false }
    return $tudoOk
}

# ------------------------------------------------------------
# Trava de segurança: antes de trocar o certificado ativo, prova que o
# PAR aceita o thumbprint novo. Se o par ainda não confia na raiz nova,
# o teste falha aqui e nada é alterado — a replicação atual continua de
# pé com o certificado antigo.
# ------------------------------------------------------------
function Test-CertificadoNoPar {
    param(
        [Parameter(Mandatory = $true)]$Estado,
        [Parameter(Mandatory = $true)][string]$Thumbprint
    )
    $par = Get-HostPar -Estado $Estado
    if (-not $par) {
        Write-Status -Tipo AVISO -Mensagem "Par não identificado na topologia — não foi possível testar o certificado remotamente."
        return $null
    }
    Write-Status -Tipo INFO -Mensagem "Testando o certificado novo contra '$($par.Fqdn)' (porta $($script:PortaCert))..."
    try {
        Test-VMReplicationConnection -ReplicaServerName $par.Fqdn `
                                     -ReplicaServerPort $script:PortaCert `
                                     -AuthenticationType Certificate `
                                     -CertificateThumbprint $Thumbprint `
                                     -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "O par '$($par.Fqdn)' ACEITOU o certificado novo."
        return $true
    } catch {
        Write-Status -Tipo ERRO -Mensagem "O par '$($par.Fqdn)' NÃO aceitou o certificado novo:"
        Write-Host "         $($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

# ------------------------------------------------------------
# FASE 1 (no PRIMÁRIO) — gera o certificado novo e NÃO aplica nada.
# ------------------------------------------------------------
function New-RenovacaoCertificado {
    param([Parameter(Mandatory = $true)]$Estado)

    $fqdns = @($Estado.Topologia | ForEach-Object { $_.Fqdn })
    if ($fqdns.Count -lt 2) {
        Write-Status -Tipo ERRO -Mensagem "Topologia incompleta no estado — rode o Menu 1 antes de renovar."
        return $false
    }

    # Modo: com a chave da CA reemitimos só o host; sem ela, cadeia nova.
    $assinante = Get-RootCAAssinante
    $modo = 'CadeiaNova'
    if ($null -ne $assinante) {
        Write-Host ""
        $escolha = Select-FromList -Titulo "Como renovar?" -Itens @(
            "REEMITIR o certificado do host mantendo a MESMA CA raiz (RECOMENDADO)",
            "Gerar uma CADEIA NOVA completa (CA raiz + certificado do host)"
        )
        if ($escolha -like 'REEMITIR*') { $modo = 'ReemitirHost' }
    } else {
        Write-Status -Tipo AVISO -Mensagem "A chave da CA raiz não está disponível — só é possível gerar CADEIA NOVA."
        Write-Host "         (cadeias criadas antes da v1.1.0 não preservavam a chave da CA)" -ForegroundColor Yellow
    }

    $anos = Read-Inteiro -Mensagem "Validade do novo certificado do host, em anos" -Padrao $script:AnosCertHost -Minimo 1 -Maximo 30

    Write-Host ""
    Write-Host "  ── Resumo da renovação ─────────────────────────────────" -ForegroundColor DarkCyan
    if ($modo -eq 'ReemitirHost') {
        Write-Host "  Modo             : reemitir SÓ o certificado do host"     -ForegroundColor White
        Write-Host "  CA raiz          : MANTIDA (o par já confia nela)"        -ForegroundColor White
        Write-Host "  No par           : basta importar o novo .pfx — SEM ordem obrigatória" -ForegroundColor Green
    } else {
        Write-Host "  Modo             : CADEIA NOVA (CA raiz + certificado do host)" -ForegroundColor White
        Write-Host "  CA raiz          : NOVA — todos os hosts terão de confiar nela" -ForegroundColor Yellow
        Write-Host "  No par           : importar .cer E .pfx ANTES de aplicar aqui"  -ForegroundColor Yellow
    }
    Write-Host ("  Validade         : {0} ano(s)" -f $anos)                     -ForegroundColor White
    Write-Host ("  SANs             : {0}" -f ($fqdns -join ', '))              -ForegroundColor White
    Write-Host "  Aplicação        : NADA é aplicado agora (fase 2 é separada)" -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""

    if (-not (Confirm-Operacao -Mensagem "Gerar o novo certificado agora?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        if ($null -ne $assinante -and $assinante.ImportadaAgora) {
            Remove-CertificadoAntigo -Thumbprint $assinante.Certificado.Thumbprint -Stores @('Cert:\LocalMachine\My')
        }
        return $false
    }

    $rootCA        = $null
    $rootCANova    = $false
    $limparRootMy  = $false

    if ($modo -eq 'ReemitirHost') {
        $rootCA = $assinante.Certificado
        $limparRootMy = $assinante.ImportadaAgora
        # A raiz que vai assinar TEM de ser confiável neste host, senão o
        # certificado emitido não encadeia (0x800B0109).
        if (-not (Test-RootCAPresente -Thumbprint $rootCA.Thumbprint)) {
            Write-Status -Tipo ERRO -Mensagem "A CA raiz que assinaria não está em Autoridades Raiz Confiáveis."
            Write-Host "         Instale-a antes (Menu 1, etapa 10) ou escolha CADEIA NOVA." -ForegroundColor Red
            if ($limparRootMy) { Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint -Stores @('Cert:\LocalMachine\My') }
            return $false
        }
    } else {
        try {
            $rootCA = New-SelfSignedCertificate -Type Custom `
                                                -Subject 'CN=Hyper-V Replica Root CA' `
                                                -KeyUsage CertSign, CRLSign, DigitalSignature `
                                                -TextExtension @('2.5.29.19={text}CA=1&pathlength=0') `
                                                -KeyExportPolicy Exportable `
                                                -KeyLength 2048 `
                                                -KeyAlgorithm RSA `
                                                -HashAlgorithm SHA256 `
                                                -NotAfter (Get-Date).AddYears($script:AnosCertRaiz) `
                                                -FriendlyName 'Hyper-V Replica Root CA' `
                                                -CertStoreLocation 'Cert:\LocalMachine\My' `
                                                -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "CA raiz nova gerada. Thumbprint: $($rootCA.Thumbprint)"
            $rootCANova   = $true
            $limparRootMy = $true
        } catch {
            Write-Status -Tipo ERRO -Mensagem "Falha ao gerar a CA raiz: $($_.Exception.Message)"
            return $false
        }
    }

    # ---- Emite o certificado do host ----
    $certNovo = New-CertificadoHost -Assinante $rootCA -Fqdns $fqdns -Anos $anos
    if ($null -eq $certNovo) {
        if ($rootCANova) { Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint }
        elseif ($limparRootMy) { Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint -Stores @('Cert:\LocalMachine\My') }
        return $false
    }

    # ---- Arquivos para distribuição (preserva os anteriores) ----
    Write-Host ""
    Write-Status -Tipo INFO -Mensagem "Defina a senha dos NOVOS arquivos PFX (pode ser diferente da antiga)."
    $senhaNova = Read-SenhaConfirmada -Mensagem "Senha dos novos arquivos PFX"

    Backup-ArquivoCertificado -Caminho $script:ArquivoPfx
    try {
        Export-PfxCertificate -Cert $certNovo -FilePath $script:ArquivoPfx -Password $senhaNova `
                              -ChainOption EndEntityCertOnly -Force -ErrorAction Stop | Out-Null
        Write-Status -Tipo OK -Mensagem "Novo PFX do host exportado: $script:ArquivoPfx"
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao exportar o novo PFX: $($_.Exception.Message)"
        return $false
    }

    if ($rootCANova) {
        Backup-ArquivoCertificado -Caminho $script:ArquivoRootCer
        Backup-ArquivoCertificado -Caminho $script:ArquivoRootPfx
        try {
            Export-Certificate -Cert $rootCA -FilePath $script:ArquivoRootCer -Force -ErrorAction Stop | Out-Null
            Write-Status -Tipo OK -Mensagem "Nova CA raiz exportada: $script:ArquivoRootCer"
        } catch {
            Write-Status -Tipo ERRO -Mensagem "Falha ao exportar a nova CA raiz: $($_.Exception.Message)"
            return $false
        }
        if (-not (Install-RootCAReplica -CaminhoCer $script:ArquivoRootCer)) { return $false }
        Export-RootCAReplica -RootCA $rootCA -Senha $senhaNova | Out-Null
    }

    # A raiz não fica em "Pessoal" (a chave dela vive no PFX)
    if ($limparRootMy) {
        Remove-CertificadoAntigo -Thumbprint $rootCA.Thumbprint -Stores @('Cert:\LocalMachine\My')
    }

    Set-ChecagemRevogacaoDesabilitada | Out-Null

    # ---- Validação do que foi gerado ----
    $val = Test-CertificadoReplica -Certificado $certNovo -FqdnEsperado (Get-HostFqdn)
    foreach ($m in $val.Motivos) {
        if ($m -like 'AVISO:*') { Write-Status -Tipo AVISO -Mensagem $m } else { Write-Status -Tipo ERRO -Mensagem $m }
    }
    if (-not $val.Valido) {
        Write-Status -Tipo ERRO -Mensagem "O certificado gerado não passou na validação — nada foi aplicado."
        return $false
    }

    # ---- Registra a renovação PENDENTE (fase 2 usa isso) ----
    $Estado | Add-Member -MemberType NoteProperty -Name 'RenovacaoPendente' -Force -Value ([pscustomobject]@{
        Thumbprint       = $certNovo.Thumbprint
        RootCAThumbprint = $rootCA.Thumbprint
        Modo             = $modo
        GeradoEm         = (Get-Date).ToString('dd/MM/yyyy HH:mm:ss')
        NotAfter         = $certNovo.NotAfter.ToString('dd/MM/yyyy')
    })
    Save-EstadoImplantacao -Estado $Estado

    # ---- Instruções: é aqui que o operador não pode errar ----
    Write-Host ""
    Write-Host "  ═══ PRÓXIMOS PASSOS ═══════════════════════════════════" -ForegroundColor Yellow
    Write-Host ("  Novo thumbprint : {0}" -f $certNovo.Thumbprint) -ForegroundColor White
    Write-Host ("  Expira em       : {0}" -f $certNovo.NotAfter.ToString('dd/MM/yyyy')) -ForegroundColor White
    Write-Host ""
    if ($modo -eq 'ReemitirHost') {
        Write-Host "  A CA raiz NÃO mudou — o par já confia nela. Não há ordem"    -ForegroundColor Green
        Write-Host "  obrigatória e a replicação atual não corre risco."           -ForegroundColor Green
        Write-Host ""
        Write-Host "  1) NESTE host: opção 13 -> 'Aplicar o certificado gerado'."  -ForegroundColor White
        Write-Host ("  2) Copie {0} para a pasta do script do PAR." -f (Split-Path $script:ArquivoPfx -Leaf)) -ForegroundColor White
        Write-Host "  3) NO PAR: opção 13 -> 'Importar e aplicar' (para que ele"   -ForegroundColor White
        Write-Host "     também apresente o certificado novo — necessário para o"  -ForegroundColor White
        Write-Host "     FAILOVER REVERSO e para a replicação estendida)."         -ForegroundColor White
    } else {
        Write-Host "  A CA raiz MUDOU. Siga EXATAMENTE esta ordem, senão a"        -ForegroundColor Yellow
        Write-Host "  replicação para de autenticar:"                              -ForegroundColor Yellow
        Write-Host ""
        Write-Host ("  1) Copie a PASTA DO SCRIPT (com {0} E {1})" -f (Split-Path $script:ArquivoRootCer -Leaf), (Split-Path $script:ArquivoPfx -Leaf)) -ForegroundColor White
        Write-Host "     para o servidor PAR."                                     -ForegroundColor White
        Write-Host "  2) NO PAR: opção 13 -> 'Importar e aplicar'. Isso instala a" -ForegroundColor White
        Write-Host "     raiz nova e faz o par confiar nela."                      -ForegroundColor White
        Write-Host "  3) VOLTE AQUI: opção 13 -> 'Aplicar o certificado gerado'."  -ForegroundColor White
        Write-Host "     O script testa o par antes de aplicar e aborta se ele"    -ForegroundColor White
        Write-Host "     ainda não estiver pronto."                                -ForegroundColor White
    }
    Write-Host ""
    Write-Host "  O certificado ANTIGO continua ativo até você aplicar o novo."    -ForegroundColor Cyan
    Write-Host "  ═══════════════════════════════════════════════════════" -ForegroundColor Yellow
    return $true
}

# ------------------------------------------------------------
# FASE 2 — aplica o certificado já instalado nesta máquina (servidor
# Replica + cada VM). Funciona no primário (após gerar) e no par (após
# importar).
# ------------------------------------------------------------
function Invoke-AplicacaoCertificadoRenovado {
    param(
        [Parameter(Mandatory = $true)]$Estado,
        [Parameter(Mandatory = $true)][string]$Thumbprint,
        [string]$Modo = 'CadeiaNova'
    )

    $cert = Get-CertificadoInstalado -Thumbprint $Thumbprint
    if (-not $cert) {
        Write-Status -Tipo ERRO -Mensagem "O certificado $Thumbprint não está em LocalMachine\My deste host."
        return $false
    }
    $val = Test-CertificadoReplica -Certificado $cert -FqdnEsperado (Get-HostFqdn)
    foreach ($m in $val.Motivos) {
        if ($m -like 'AVISO:*') { Write-Status -Tipo AVISO -Mensagem $m } else { Write-Status -Tipo ERRO -Mensagem $m }
    }
    if (-not $val.Valido) {
        Write-Status -Tipo ERRO -Mensagem "O certificado não atende aos requisitos neste host — aplicação abortada."
        return $false
    }

    # Trava: o par precisa aceitar o certificado novo ANTES da troca.
    # No modo ReemitirHost a raiz não mudou, então o teste é informativo.
    $reps = @(Get-VMReplication -ErrorAction SilentlyContinue)
    if ($reps.Count -gt 0) {
        $aceito = Test-CertificadoNoPar -Estado $Estado -Thumbprint $Thumbprint
        if ($aceito -eq $false) {
            Write-Host ""
            if ($Modo -eq 'CadeiaNova') {
                Write-Status -Tipo ERRO -Mensagem "PARE: aplique primeiro no PAR (opção 13 -> Importar e aplicar)."
                Write-Host "         Aplicar aqui agora derrubaria a autenticação da replicação." -ForegroundColor Red
                return $false
            }
            # Aqui a falha NÃO é necessariamente confiança de certificado: o
            # par pode simplesmente não estar habilitado como servidor
            # Replica (só é obrigatório no host que RECEBE), ou a porta 443
            # pode estar fechada. Por isso avisa em vez de abortar.
            Write-Status -Tipo AVISO -Mensagem "O teste contra o par falhou. Causas possíveis:"
            Write-Host "         - o par não está habilitado como servidor Replica (normal no primário);" -ForegroundColor Yellow
            Write-Host "         - porta 443 bloqueada ou FQDN não resolvendo;"                           -ForegroundColor Yellow
            Write-Host "         - o par ainda não instalou esta cadeia."                                 -ForegroundColor Yellow
            if (-not (Read-Confirmacao -Pergunta "Aplicar mesmo assim?" -Padrao 'N')) {
                Write-Status -Tipo AVISO -Mensagem "Aplicação cancelada."
                return $false
            }
        }
    } else {
        Write-Status -Tipo INFO -Mensagem "Nenhuma VM replicada aqui — o teste contra o par foi dispensado."
    }

    Write-Host ""
    Write-Host "  ── O que será alterado ─────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ("  Novo thumbprint  : {0}" -f $Thumbprint)                  -ForegroundColor White
    Write-Host ("  Expira em        : {0}" -f $cert.NotAfter.ToString('dd/MM/yyyy')) -ForegroundColor White
    Write-Host ("  Servidor Replica : Set-VMReplicationServer")             -ForegroundColor White
    Write-Host ("  VMs a atualizar  : {0}" -f $reps.Count)                  -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""
    if (-not (Confirm-Operacao -Mensagem "Aplicar o novo certificado neste host?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return $false
    }

    $tpAntigo = $Estado.CertificadoThumbprint
    if (-not (Set-ThumbprintReplicacao -Thumbprint $Thumbprint)) {
        Write-Status -Tipo AVISO -Mensagem "A aplicação terminou com falhas — reveja os itens acima antes de seguir."
    }

    # Estado: o novo passa a ser o oficial e a pendência é encerrada
    $Estado.CertificadoThumbprint = $Thumbprint
    $pend = $null
    if ($Estado.PSObject.Properties['RenovacaoPendente']) { $pend = $Estado.RenovacaoPendente }
    if ($null -ne $pend -and $pend.RootCAThumbprint) {
        $Estado | Add-Member -MemberType NoteProperty -Name 'RootCAThumbprint' -Value $pend.RootCAThumbprint -Force
    }
    $Estado | Add-Member -MemberType NoteProperty -Name 'RenovacaoPendente' -Value $null -Force
    Save-EstadoImplantacao -Estado $Estado

    Show-DiagnosticoCertificado -Estado $Estado

    # Limpeza do antigo: só depois de tudo validado, e nunca por padrão
    if ($tpAntigo -and $tpAntigo -ne $Thumbprint) {
        Write-Host ""
        Write-Status -Tipo INFO -Mensagem "O certificado antigo ($tpAntigo) ficou inativo, mas segue instalado."
        Write-Host "         Só remova depois de confirmar a saúde da replicação nos DOIS hosts" -ForegroundColor Cyan
        Write-Host "         (Menu 3 -> 1). Ele é o seu caminho de volta se algo der errado."     -ForegroundColor Cyan
        if (Read-Confirmacao -Pergunta "Remover o certificado ANTIGO agora?" -Padrao 'N') {
            Remove-CertificadoAntigo -Thumbprint $tpAntigo -Stores @('Cert:\LocalMachine\My')
        }
    }
    return $true
}

# ------------------------------------------------------------
# No PAR (secundário/estendido) — importa a cadeia trazida do primário e
# aplica. Reaproveita Import-CertificadoReplica, que instala a raiz ANTES
# do PFX e valida SAN/EKU/cadeia para ESTE host.
# ------------------------------------------------------------
function Import-RenovacaoCertificado {
    param([Parameter(Mandatory = $true)]$Estado)

    Write-Status -Tipo INFO -Mensagem "Esta opção instala a cadeia que está na PASTA DO SCRIPT e a ativa neste host."
    $tpAntes = $Estado.CertificadoThumbprint

    if (-not (Import-CertificadoReplica -Estado $Estado)) { return $false }

    $tpNovo = $Estado.CertificadoThumbprint
    if ($tpNovo -eq $tpAntes) {
        Write-Status -Tipo AVISO -Mensagem "O certificado importado é o MESMO já registrado ($tpNovo)."
        Write-Host "         Verifique se você copiou os arquivos NOVOS do primário." -ForegroundColor Yellow
        if (-not (Read-Confirmacao -Pergunta "Continuar e reaplicar este thumbprint?" -Padrao 'N')) {
            return $false
        }
    }
    return (Invoke-AplicacaoCertificadoRenovado -Estado $Estado -Thumbprint $tpNovo -Modo 'Importado')
}

# ------------------------------------------------------------
# OPÇÃO 2.13 — orquestrador da renovação
# ------------------------------------------------------------
function Invoke-RenovacaoCertificado {
    Show-Header -Titulo "[ MENU 2.13 ] RENOVAR O CERTIFICADO DA REPLICAÇÃO"

    if (-not (Test-Administrador)) {
        Write-Status -Tipo ERRO -Mensagem "Execute o PowerShell como ADMINISTRADOR."
        return
    }

    $estado = Get-EstadoImplantacao
    if ([string]::IsNullOrWhiteSpace($estado.Papel)) {
        Write-Status -Tipo ERRO -Mensagem "Estado da implantação não encontrado — rode o Menu 1 neste servidor primeiro."
        return
    }
    if ($estado.Autenticacao -ne 'Certificate') {
        Write-Status -Tipo ERRO -Mensagem "Este host usa autenticação '$($estado.Autenticacao)' — não há certificado a renovar."
        Write-Host "         A renovação só se aplica à autenticação por CERTIFICADO (HTTPS/443)." -ForegroundColor Red
        return
    }

    Write-Status -Tipo INFO -Mensagem "Papel deste host: $($estado.Papel) | FQDN: $(Get-HostFqdn)"
    Show-DiagnosticoCertificado -Estado $estado

    $pend = $null
    if ($estado.PSObject.Properties['RenovacaoPendente']) { $pend = $estado.RenovacaoPendente }

    $itens = @()
    if ($estado.Papel -eq 'Primario') {
        $itens += "GERAR um certificado novo (fase 1 — não aplica nada)"
    }
    if ($null -ne $pend) {
        $itens += "APLICAR o certificado gerado neste host (fase 2)"
    }
    $itens += "IMPORTAR a cadeia da pasta do script e aplicar (host que RECEBE a cadeia)"
    $itens += "Somente rever o diagnóstico acima"

    Write-Host ""
    $escolha = Select-FromList -Titulo "O que deseja fazer?" -Itens $itens

    $logAtivo = Start-LogOperacao -Operacao "RenovacaoCertificado"
    try {
        if ($escolha -like 'GERAR*') {
            New-RenovacaoCertificado -Estado $estado | Out-Null
        } elseif ($escolha -like 'APLICAR*') {
            Invoke-AplicacaoCertificadoRenovado -Estado $estado -Thumbprint $pend.Thumbprint -Modo $pend.Modo | Out-Null
        } elseif ($escolha -like 'IMPORTAR*') {
            Import-RenovacaoCertificado -Estado $estado | Out-Null
        } else {
            Write-Status -Tipo INFO -Mensagem "Nenhuma alteração feita."
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha na renovação: $($_.Exception.Message)"
    } finally {
        Stop-LogOperacao -LogAtivo $logAtivo
    }
}

# ------------------------------------------------------------
# OPÇÃO 2.12 — Replicação ESTENDIDA (executar no REPLICA)
# ------------------------------------------------------------
function Enable-ReplicacaoEstendida {
    Show-Header -Titulo "[ MENU 2.12 ] REPLICAÇÃO ESTENDIDA (3º SERVIDOR)"
    Write-Status -Tipo INFO -Mensagem "A replicação estendida parte do servidor REPLICA para um TERCEIRO"
    Write-Host "         host (primário -> replica -> estendido). Execute NO REPLICA." -ForegroundColor Cyan

    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $vmEscolhida = Select-FromList -Titulo "Selecione a VM replica a estender:" -Itens $vms
    Show-ReplicaInfo -VMName $vmEscolhida

    $rep = Get-VMReplication -VMName $vmEscolhida -ErrorAction SilentlyContinue
    if (-not $rep -or ([string]$rep.ReplicationMode -ne 'Replica')) {
        Write-Status -Tipo ERRO -Mensagem "A VM precisa estar em modo 'Replica' NESTE host para ser estendida."
        return
    }

    $estado = Get-EstadoImplantacao
    $padraoEstendido = ""
    $hostEstendido = @($estado.Topologia) | Where-Object { $_.Funcao -eq 'Estendido' } | Select-Object -First 1
    if ($hostEstendido) { $padraoEstendido = $hostEstendido.Fqdn }
    $servidorEstendido = Read-Fqdn -Mensagem "FQDN do servidor ESTENDIDO (3º host)" -Padrao $padraoEstendido

    $autenticacao = $estado.Autenticacao
    if ([string]::IsNullOrWhiteSpace($autenticacao)) { $autenticacao = 'Kerberos' }
    $porta = $script:PortaKerberos
    if ($autenticacao -eq 'Certificate') { $porta = $script:PortaCert }

    # Estendida aceita apenas 5 ou 15 minutos
    $escolhaFreq = Select-FromList -Titulo "Frequência da replicação estendida:" -Itens @("5 minutos", "15 minutos")
    $frequencia = 300
    if ($escolhaFreq -like '15*') { $frequencia = 900 }

    Write-Host ""
    Write-Host "  ── Resumo da replicação estendida ──────────────────────" -ForegroundColor DarkCyan
    Write-Host ("  VM                : {0}" -f $vmEscolhida)        -ForegroundColor White
    Write-Host ("  Servidor estendido: {0}" -f $servidorEstendido)  -ForegroundColor White
    Write-Host ("  Autenticação/Porta: {0} / {1}" -f $autenticacao, $porta) -ForegroundColor White
    Write-Host ("  Frequência        : {0} segundos" -f $frequencia) -ForegroundColor White
    Write-Host "  ────────────────────────────────────────────────────────" -ForegroundColor DarkCyan
    Write-Host ""
    if (-not (Confirm-Operacao -Mensagem "Habilitar a replicação estendida?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        $parametros = @{
            VMName                  = $vmEscolhida
            ReplicaServerName       = $servidorEstendido
            ReplicaServerPort       = $porta
            AuthenticationType      = $autenticacao
            ReplicationFrequencySec = $frequencia
            ErrorAction             = 'Stop'
        }
        if ($autenticacao -eq 'Certificate') {
            $certLocal = Get-CertificadoInstalado -Thumbprint $estado.CertificadoThumbprint
            if (-not $certLocal) {
                Write-Status -Tipo ERRO -Mensagem "Certificado não encontrado — execute o Menu 1 neste servidor."
                return
            }
            $parametros['CertificateThumbprint'] = $certLocal.Thumbprint
        }
        Enable-VMReplication @parametros
        Write-Status -Tipo OK -Mensagem "Replicação estendida habilitada para '$servidorEstendido'."
        if (Read-Confirmacao -Pergunta "Iniciar a replicação inicial estendida agora?" -Padrao 'S') {
            Start-VMInitialReplication -VMName $vmEscolhida -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Replicação inicial estendida iniciada."
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# SUBMENU 2 — Administração
# ------------------------------------------------------------
function Invoke-MenuAdministracao {
    do {
        Show-Header -Titulo "MENU 2 — ADMINISTRAR O HYPER-V REPLICA"
        Write-Host "  Selecione a operação desejada:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1]   Habilitar replicação de uma VM (no PRIMÁRIO)"        -ForegroundColor White
        Write-Host "  [2]   Iniciar replicação inicial (agora/agendada/mídia)"   -ForegroundColor White
        Write-Host "  [3]   Status das replicações"                              -ForegroundColor White
        Write-Host "  [4]   Teste de failover (no REPLICA)"                      -ForegroundColor White
        Write-Host "  [5]   Encerrar teste de failover"                          -ForegroundColor White
        Write-Host "  [6]   Failover PLANEJADO (guiado, sem perda de dados)"     -ForegroundColor White
        Write-Host "  [7]   Failover NÃO PLANEJADO (desastre, no REPLICA)"       -ForegroundColor White
        Write-Host "  [8]   Suspender replicação"                                -ForegroundColor White
        Write-Host "  [9]   Retomar replicação"                                  -ForegroundColor White
        Write-Host "  [10]  Alterar configurações da replicação"                 -ForegroundColor White
        Write-Host "  [11]  Remover replicação de uma VM"                        -ForegroundColor White
        Write-Host "  [12]  Replicação ESTENDIDA para 3º servidor (no REPLICA)"  -ForegroundColor White
        Write-Host "  [13]  RENOVAR o certificado da replicação (antes de expirar)" -ForegroundColor White
        Write-Host "  [0]   Voltar ao menu principal"                            -ForegroundColor DarkGray
        Write-Host ""
        $opcaoAdmin = (Read-Host "  >> Digite a opção").Trim()
        switch ($opcaoAdmin) {
            "1"  { Enable-ReplicacaoVM }
            "2"  { Start-ReplicacaoInicial }
            "3"  { Show-StatusReplicacao }
            "4"  { Start-TesteFailover }
            "5"  { Stop-TesteFailover }
            "6"  { Invoke-FailoverPlanejado }
            "7"  { Invoke-FailoverNaoPlanejado }
            "8"  { Suspend-ReplicacaoVM }
            "9"  { Resume-ReplicacaoVM }
            "10" { Set-ConfiguracaoReplicacao }
            "11" { Remove-ReplicacaoVM }
            "12" { Enable-ReplicacaoEstendida }
            "13" { Invoke-RenovacaoCertificado }
            "0"  { }
            default {
                Write-Host ""
                Write-Status -Tipo AVISO -Mensagem "Opção inválida. Tente novamente."
            }
        }
        if ($opcaoAdmin -ne "0") { Wait-EnterContinuar }
    } while ($opcaoAdmin -ne "0")
}


# ============================================================
#  MENU 3 — MONITORAMENTO E RELATÓRIOS
# ============================================================

# ------------------------------------------------------------
# Junta Get-VMReplication + Measure-VMReplication num array único
# ------------------------------------------------------------
function Get-DadosMonitoramento {
    $dados = @()
    $reps  = @(Get-VMReplication -ErrorAction SilentlyContinue | Sort-Object VMName)
    foreach ($r in $reps) {
        $medida = $null
        try { $medida = Measure-VMReplication -VMName $r.VMName -ErrorAction Stop | Select-Object -First 1 } catch { }
        $ultimaRepl = $null
        $tamMedioMB = 0
        $tamPendMB  = 0
        $latencia   = ""
        if ($null -ne $medida) {
            $ultimaRepl = $medida.LastReplicationTime
            if ($medida.AverageReplicationSize -gt 0) { $tamMedioMB = [math]::Round($medida.AverageReplicationSize / 1MB, 2) }
            if ($medida.PendingReplicationSize -gt 0) { $tamPendMB  = [math]::Round($medida.PendingReplicationSize / 1MB, 2) }
            if ($null -ne $medida.AverageReplicationLatency) { $latencia = [string]$medida.AverageReplicationLatency }
        }
        $par = [string]$r.ReplicaServerName
        if ([string]$r.ReplicationMode -eq 'Replica') { $par = [string]$r.PrimaryServerName }
        $dados += [pscustomobject]@{
            VM             = [string]$r.VMName
            Modo           = [string]$r.ReplicationMode
            Estado         = [string]$r.ReplicationState
            Saude          = [string]$r.ReplicationHealth
            UltimaRepl     = $ultimaRepl
            TamMedioMB     = $tamMedioMB
            TamPendenteMB  = $tamPendMB
            Latencia       = $latencia
            FrequenciaSec  = [int]$r.ReplicationFrequencySec
            ServidorPar    = $par
            Autenticacao   = [string]$r.AuthenticationType
            Relacionamento = [string]$r.ReplicationRelationshipType
        }
    }
    return ,$dados
}

# ------------------------------------------------------------
# Badge HTML por estado de saúde (padrão do Inventário)
# ------------------------------------------------------------
function Get-BadgeSaude {
    param([string]$Saude)
    $map = @{
        "Normal"        = @{ css = "badge-normal";   label = "Normal"   }
        "Warning"       = @{ css = "badge-warning";  label = "Atenção"  }
        "Critical"      = @{ css = "badge-critical"; label = "Crítico"  }
        "NotApplicable" = @{ css = "badge-na";       label = "N/A"      }
    }
    $entry = $map[$Saude]
    if (-not $entry) { $entry = @{ css = "badge-na"; label = $Saude } }
    return "<span class='badge $($entry.css)'>$($entry.label)</span>"
}

# ------------------------------------------------------------
# "há 3 min / há 2 h / há 1 d" a partir de uma data
# ------------------------------------------------------------
function Get-TempoDecorrido {
    param($DataHora)
    if ($null -eq $DataHora) { return "nunca" }
    try { $dt = [datetime]$DataHora } catch { return [string]$DataHora }
    $delta = (Get-Date) - $dt
    if ($delta.TotalSeconds -lt 0)  { return $dt.ToString('dd/MM/yyyy HH:mm') }
    if ($delta.TotalMinutes -lt 1)  { return ("há {0} s" -f [int]$delta.TotalSeconds) }
    if ($delta.TotalHours   -lt 1)  { return ("há {0} min" -f [int]$delta.TotalMinutes) }
    if ($delta.TotalDays    -lt 1)  { return ("há {0} h" -f [math]::Round($delta.TotalHours, 1)) }
    return ("há {0} d" -f [math]::Round($delta.TotalDays, 1))
}

# ------------------------------------------------------------
# OPÇÃO 3.1 — Visão rápida no console
# ------------------------------------------------------------
function Show-MonitorConsole {
    Show-Header -Titulo "[ MENU 3.1 ] VISÃO RÁPIDA DA REPLICAÇÃO"
    $dados = Get-DadosMonitoramento
    if ($dados.Count -eq 0) {
        Write-Status -Tipo AVISO -Mensagem "Nenhuma VM com replicação configurada neste host."
        return
    }
    Write-Host ("  {0,-22} {1,-9} {2,-13} {3,-8} {4,-19} {5,-10} {6}" -f 'VM', 'MODO', 'ESTADO', 'SAÚDE', 'ÚLTIMA REPLICAÇÃO', 'PEND(MB)', 'PAR') -ForegroundColor Yellow
    Write-Host ("  " + "-" * 100) -ForegroundColor DarkGray
    foreach ($d in $dados) {
        $corSaude = 'Green'
        if ($d.Saude -eq 'Warning')       { $corSaude = 'Yellow' }
        if ($d.Saude -eq 'Critical')      { $corSaude = 'Red' }
        if ($d.Saude -eq 'NotApplicable') { $corSaude = 'DarkGray' }
        $quando = Get-TempoDecorrido -DataHora $d.UltimaRepl
        Write-Host ("  {0,-22} {1,-9} {2,-13} " -f $d.VM, $d.Modo, $d.Estado) -NoNewline -ForegroundColor White
        Write-Host ("{0,-8} " -f $d.Saude) -NoNewline -ForegroundColor $corSaude
        Write-Host ("{0,-19} {1,-10} {2}" -f $quando, $d.TamPendenteMB, $d.ServidorPar) -ForegroundColor White
    }
    Write-Host ""
    $criticas = @($dados | Where-Object { $_.Saude -eq 'Critical' }).Count
    $avisos   = @($dados | Where-Object { $_.Saude -eq 'Warning' }).Count
    if ($criticas -gt 0)     { Write-Status -Tipo ERRO  -Mensagem "$criticas VM(s) com saúde CRÍTICA — verifique os eventos (opção 3)." }
    elseif ($avisos -gt 0)   { Write-Status -Tipo AVISO -Mensagem "$avisos VM(s) em estado de ATENÇÃO." }
    else                     { Write-Status -Tipo OK    -Mensagem "Todas as replicações saudáveis." }
}

# ------------------------------------------------------------
# OPÇÃO 3.3 — Últimos eventos de replicação (log VMMS)
# ------------------------------------------------------------
function Get-EventosReplica {
    param([int]$Ultimos = 20)
    $eventos = @()
    try {
        $eventos = @(Get-WinEvent -FilterHashtable @{
            LogName = 'Microsoft-Windows-Hyper-V-VMMS-Admin'
            Level   = @(2, 3)   # 2=Error, 3=Warning
        } -MaxEvents 200 -ErrorAction Stop |
            Where-Object { $_.Message -match '(?i)replica|replic' } |
            Select-Object -First $Ultimos)
    } catch { }
    return ,$eventos
}

function Show-EventosReplica {
    Show-Header -Titulo "[ MENU 3.3 ] ÚLTIMOS EVENTOS DE REPLICAÇÃO (ERROS/AVISOS)"
    $eventos = Get-EventosReplica -Ultimos 20
    if ($eventos.Count -eq 0) {
        Write-Status -Tipo OK -Mensagem "Nenhum erro/aviso de replicação no log VMMS. Bom sinal!"
        return
    }
    foreach ($ev in $eventos) {
        $cor = 'Yellow'
        if ($ev.Level -eq 2) { $cor = 'Red' }
        $primeiraLinha = ($ev.Message -split "`r?`n")[0]
        Write-Host ("  [{0}] Evento {1} — {2}" -f $ev.TimeCreated.ToString('dd/MM HH:mm:ss'), $ev.Id, $primeiraLinha) -ForegroundColor $cor
    }
}

# ------------------------------------------------------------
# OPÇÃO 3.4 — Exportar CSV do monitoramento
# ------------------------------------------------------------
function Export-CsvReplicacao {
    Show-Header -Titulo "[ MENU 3.4 ] EXPORTAR MONITORAMENTO PARA CSV"
    $dados = Get-DadosMonitoramento
    if ($dados.Count -eq 0) {
        Write-Status -Tipo AVISO -Mensagem "Nenhuma VM com replicação configurada — nada a exportar."
        return
    }
    $arquivo = Join-Path $script:PastaScript ("Replica_Monitor_{0}.csv" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $dados | Export-Csv -Path $arquivo -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "CSV exportado: $arquivo"
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao exportar: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 3.5 — Zerar estatísticas de replicação
# ------------------------------------------------------------
function Reset-EstatisticasReplicacao {
    Show-Header -Titulo "[ MENU 3.5 ] ZERAR ESTATÍSTICAS DE REPLICAÇÃO"
    $vms = Get-VMNamesComReplica
    if (-not $vms) { return }
    $itens = @("TODAS as VMs replicadas") + $vms
    $escolha = Select-FromList -Titulo "Zerar estatísticas de:" -Itens $itens
    if (-not (Confirm-Operacao -Mensagem "Zerar as estatísticas ($escolha)?")) {
        Write-Status -Tipo AVISO -Mensagem "Operação cancelada."
        return
    }
    try {
        if ($escolha -like 'TODAS*') {
            Get-VMReplication -ErrorAction Stop | Reset-VMReplicationStatistics -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Estatísticas zeradas para todas as VMs."
        } else {
            Reset-VMReplicationStatistics -VMName $escolha -ErrorAction Stop
            Write-Status -Tipo OK -Mensagem "Estatísticas zeradas para '$escolha'."
        }
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# OPÇÃO 3.2 — Dashboard HTML completo
# ------------------------------------------------------------
function New-DashboardHtml {
    Show-Header -Titulo "[ MENU 3.2 ] DASHBOARD HTML DO HYPER-V REPLICA"
    Write-Status -Tipo INFO -Mensagem "Coletando dados de replicação..."

    $estado    = Get-EstadoImplantacao
    $dados     = Get-DadosMonitoramento
    $nomeHost  = $env:COMPUTERNAME
    $dataColeta = Get-Date -Format "dd/MM/yyyy HH:mm:ss"

    # Totalizadores
    $totalVMs      = $dados.Count
    $totalNormal   = @($dados | Where-Object { $_.Saude -eq 'Normal' }).Count
    $totalWarning  = @($dados | Where-Object { $_.Saude -eq 'Warning' }).Count
    $totalCritical = @($dados | Where-Object { $_.Saude -eq 'Critical' }).Count
    $totalPrimario = @($dados | Where-Object { $_.Modo -eq 'Primary' }).Count
    $totalReplica  = @($dados | Where-Object { $_.Modo -in @('Replica', 'ExtendedReplica') }).Count
    $pendenteTotal = [math]::Round((@($dados | ForEach-Object { $_.TamPendenteMB }) | Measure-Object -Sum).Sum, 1)

    # Configuração do servidor
    $cfgHtml = "<p class='na'>Servidor Replica não habilitado neste host.</p>"
    $cfg = Get-VMReplicationServer -ErrorAction SilentlyContinue
    if ($null -ne $cfg -and $cfg.ReplicationEnabled) {
        $entradasAut = @(Get-VMReplicationAuthorizationEntry -ErrorAction SilentlyContinue)
        $listaAut = "(aceita qualquer servidor autenticado)"
        if ($entradasAut.Count -gt 0) {
            $listaAut = ($entradasAut | ForEach-Object { $_.AllowedPrimaryServer }) -join ', '
        }
        $cfgHtml = @"
<table class='config-table'>
  <tr><td>Replicação habilitada</td><td><strong>Sim</strong></td></tr>
  <tr><td>Autenticação</td><td>$($cfg.AllowedAuthenticationType)</td></tr>
  <tr><td>Porta Kerberos (HTTP)</td><td>$($cfg.KerberosAuthenticationPort)</td></tr>
  <tr><td>Porta Certificado (HTTPS)</td><td>$($cfg.CertificateAuthenticationPort)</td></tr>
  <tr><td>Origens autorizadas</td><td>$listaAut</td></tr>
</table>
"@
    }

    # Certificado (aviso de expiração)
    $certHtml = ""
    if ($estado.Autenticacao -eq 'Certificate' -and $estado.CertificadoThumbprint) {
        $cert = Get-CertificadoInstalado -Thumbprint $estado.CertificadoThumbprint
        if ($cert) {
            $diasRestantes = [int]($cert.NotAfter - (Get-Date)).TotalDays
            $classeCert = "cert-ok"
            if ($diasRestantes -lt 90) { $classeCert = "cert-warn" }
            if ($diasRestantes -lt 0)  { $classeCert = "cert-bad" }
            $certHtml = @"
<p class='cert-info $classeCert'>Certificado da replicação: expira em <strong>$($cert.NotAfter.ToString('dd/MM/yyyy'))</strong> ($diasRestantes dias) &nbsp;|&nbsp; Thumbprint: $($cert.Thumbprint)</p>
"@
        }
    }

    # Topologia
    $topoHtml = ""
    if (@($estado.Topologia).Count -ge 2) {
        $blocos = @()
        foreach ($h in @($estado.Topologia)) {
            $classeTopo = "topo-node"
            if ($h.Fqdn -eq (Get-HostFqdn)) { $classeTopo = "topo-node topo-local" }
            $blocos += "<div class='$classeTopo'><span class='topo-funcao'>$($h.Funcao.ToUpper())</span><span class='topo-fqdn'>$($h.Fqdn)</span><span class='topo-ip'>$($h.Ip)</span></div>"
        }
        $topoHtml = "<p class='section-title'>Topologia da Replicação</p><div class='topo-wrap'>" + ($blocos -join "<div class='topo-seta'>&#10132;</div>") + "</div>"
    }

    # Linhas da tabela
    $tabelaLinhas = ""
    $rowIndex = 0
    foreach ($d in $dados) {
        $rowClass = "row-even"
        if ($rowIndex % 2 -ne 0) { $rowClass = "row-odd" }
        $badge  = Get-BadgeSaude -Saude $d.Saude
        $quando = Get-TempoDecorrido -DataHora $d.UltimaRepl
        $dataUltima = "<span class='na'>nunca</span>"
        if ($null -ne $d.UltimaRepl) {
            $dataUltima = ([datetime]$d.UltimaRepl).ToString('dd/MM/yyyy HH:mm:ss') + " <span class='quando'>($quando)</span>"
        }
        $freqTexto = "$($d.FrequenciaSec) s"
        if ($d.FrequenciaSec -ge 60) { $freqTexto = "$([int]($d.FrequenciaSec / 60)) min" }
        $tabelaLinhas += @"
<tr class='$rowClass'>
  <td class='td-name'>$($d.VM)</td>
  <td class='td-center'>$($d.Modo)</td>
  <td class='td-center'>$($d.Estado)</td>
  <td class='td-center'>$badge</td>
  <td>$dataUltima</td>
  <td class='td-center'>$($d.TamMedioMB)</td>
  <td class='td-center'>$($d.TamPendenteMB)</td>
  <td class='td-center'>$($d.Latencia)</td>
  <td class='td-center'>$freqTexto</td>
  <td>$($d.ServidorPar)</td>
  <td class='td-center'>$($d.Autenticacao)</td>
  <td class='td-center'>$($d.Relacionamento)</td>
</tr>
"@
        $rowIndex++
    }
    if ($totalVMs -eq 0) {
        $tabelaLinhas = "<tr><td colspan='12' class='na' style='text-align:center;padding:24px'>Nenhuma VM com replicação configurada neste host.</td></tr>"
    }

    # Eventos
    $eventosHtml = "<p class='na'>Nenhum erro ou aviso de replicação no log VMMS.</p>"
    $eventos = Get-EventosReplica -Ultimos 15
    if ($eventos.Count -gt 0) {
        $linhasEv = ""
        foreach ($ev in $eventos) {
            $classeEv = "ev-warn"
            $rotuloEv = "AVISO"
            if ($ev.Level -eq 2) { $classeEv = "ev-error"; $rotuloEv = "ERRO" }
            $msg = [System.Web.HttpUtility]::HtmlEncode((($ev.Message -split "`r?`n")[0]))
            $linhasEv += "<li class='$classeEv'><span class='ev-data'>$($ev.TimeCreated.ToString('dd/MM HH:mm:ss'))</span> <span class='ev-tipo'>[$rotuloEv $($ev.Id)]</span> $msg</li>"
        }
        $eventosHtml = "<ul class='ev-lista'>$linhasEv</ul>"
    }

    # Documento
    $html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Hyper-V Replica - $nomeHost</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Segoe UI', system-ui, -apple-system, sans-serif; background: #f0f2f5; color: #1a1a2e; min-height: 100vh; }
    header { background: linear-gradient(135deg, #0d1117 0%, #161b22 60%, #1f2937 100%); color: #e6edf3; padding: 28px 36px; display: flex; align-items: center; gap: 24px; box-shadow: 0 4px 20px rgba(0,0,0,.45); }
    header .icone { font-size: 2.6rem; }
    header h1 { font-size: 1.45rem; }
    header .sub { margin-top: 6px; font-size: .85rem; color: #9ca3af; }
    header .sub span { color: #58a6ff; font-weight: 600; }
    main { max-width: 1650px; margin: 0 auto; padding: 32px 24px; }
    .section-title { font-size: .75rem; font-weight: 700; text-transform: uppercase; letter-spacing: 1.2px; color: #6b7280; margin: 28px 0 14px 0; }
    .cards-grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(160px, 1fr)); gap: 16px; }
    .card { background: #fff; border-radius: 12px; padding: 20px 18px; box-shadow: 0 2px 8px rgba(0,0,0,.07); border-top: 4px solid #58a6ff; text-align: center; transition: transform .15s, box-shadow .15s; }
    .card:hover { transform: translateY(-3px); box-shadow: 0 6px 18px rgba(0,0,0,.12); }
    .card-normal   { border-top-color: #27ae60; }
    .card-warning  { border-top-color: #f39c12; }
    .card-critical { border-top-color: #e74c3c; }
    .card-primary  { border-top-color: #2980b9; }
    .card-replica  { border-top-color: #8e44ad; }
    .card-value { font-size: 1.9rem; font-weight: 800; color: #0d1117; line-height: 1; }
    .card-label { font-size: .75rem; color: #6b7280; margin-top: 8px; font-weight: 600; text-transform: uppercase; letter-spacing: .6px; }
    .table-wrapper { background: #fff; border-radius: 14px; box-shadow: 0 2px 12px rgba(0,0,0,.08); overflow-x: auto; }
    table { width: 100%; border-collapse: collapse; font-size: .875rem; }
    thead tr { background: #0d1117; color: #c9d1d9; }
    thead th { padding: 14px 12px; text-align: left; font-size: .7rem; font-weight: 700; text-transform: uppercase; letter-spacing: 1px; white-space: nowrap; }
    tbody tr.row-even { background: #fff; }
    tbody tr.row-odd  { background: #f8fafc; }
    tbody tr:hover    { background: #eef4ff; }
    td { padding: 12px; vertical-align: middle; border-bottom: 1px solid #e5e7eb; }
    .td-name { font-weight: 700; }
    .td-center { text-align: center; }
    .na { color: #9ca3af; font-style: italic; }
    .quando { color: #6b7280; font-size: .8rem; }
    .badge { display: inline-block; padding: 3px 10px; border-radius: 20px; font-size: .72rem; font-weight: 700; letter-spacing: .5px; text-transform: uppercase; }
    .badge-normal   { background: #dcfce7; color: #166534; }
    .badge-warning  { background: #fef3c7; color: #92400e; }
    .badge-critical { background: #fee2e2; color: #991b1b; }
    .badge-na       { background: #f3f4f6; color: #374151; }
    .config-table { background: #fff; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.07); font-size: .875rem; width: 100%; max-width: 640px; }
    .config-table td { padding: 10px 16px; }
    .config-table td:first-child { color: #6b7280; width: 46%; }
    .cert-info { margin-top: 12px; padding: 10px 16px; border-radius: 10px; font-size: .85rem; }
    .cert-ok   { background: #dcfce7; color: #166534; }
    .cert-warn { background: #fef3c7; color: #92400e; }
    .cert-bad  { background: #fee2e2; color: #991b1b; }
    .topo-wrap { display: flex; align-items: center; gap: 14px; flex-wrap: wrap; background: #fff; border-radius: 12px; padding: 20px; box-shadow: 0 2px 8px rgba(0,0,0,.07); }
    .topo-node { display: flex; flex-direction: column; gap: 3px; border: 2px solid #d1d5db; border-radius: 10px; padding: 12px 18px; min-width: 190px; }
    .topo-local { border-color: #2980b9; background: #eef6fc; }
    .topo-funcao { font-size: .7rem; font-weight: 800; letter-spacing: 1px; color: #2980b9; }
    .topo-fqdn { font-weight: 700; }
    .topo-ip { font-size: .8rem; color: #6b7280; }
    .topo-seta { font-size: 1.6rem; color: #9ca3af; }
    .ev-lista { list-style: none; background: #fff; border-radius: 12px; box-shadow: 0 2px 8px rgba(0,0,0,.07); padding: 10px 0; font-size: .85rem; }
    .ev-lista li { padding: 8px 18px; border-bottom: 1px solid #f1f5f9; }
    .ev-lista li:last-child { border-bottom: none; }
    .ev-data { color: #6b7280; margin-right: 8px; }
    .ev-tipo { font-weight: 700; margin-right: 8px; }
    .ev-error .ev-tipo { color: #b91c1c; }
    .ev-warn  .ev-tipo { color: #b45309; }
    footer { text-align: center; padding: 24px; font-size: .78rem; color: #9ca3af; }
  </style>
</head>
<body>

<header>
  <div class="icone">&#128260;</div>
  <div>
    <h1>Dashboard Hyper-V Replica</h1>
    <div class="sub">
      Host: <span>$nomeHost</span>
      &nbsp;&nbsp;|&nbsp;&nbsp; Papel: <span>$(if ($estado.Papel) { $estado.Papel } else { 'não definido' })</span>
      &nbsp;&nbsp;|&nbsp;&nbsp; Coleta: <span>$dataColeta</span>
    </div>
  </div>
</header>

<main>
  <p class="section-title">Resumo da Replicação</p>
  <div class="cards-grid">
    <div class="card"><div class="card-value">$totalVMs</div><div class="card-label">VMs replicadas</div></div>
    <div class="card card-normal"><div class="card-value">$totalNormal</div><div class="card-label">Normais</div></div>
    <div class="card card-warning"><div class="card-value">$totalWarning</div><div class="card-label">Atenção</div></div>
    <div class="card card-critical"><div class="card-value">$totalCritical</div><div class="card-label">Críticas</div></div>
    <div class="card card-primary"><div class="card-value">$totalPrimario</div><div class="card-label">Como primário</div></div>
    <div class="card card-replica"><div class="card-value">$totalReplica</div><div class="card-label">Como replica</div></div>
    <div class="card"><div class="card-value">$pendenteTotal</div><div class="card-label">Pendente (MB)</div></div>
  </div>

  $topoHtml

  <p class="section-title">Estado das VMs Replicadas</p>
  <div class="table-wrapper">
    <table>
      <thead>
        <tr>
          <th>VM</th><th>Modo</th><th>Estado</th><th>Saúde</th>
          <th>Última replicação</th><th>Média (MB)</th><th>Pendente (MB)</th>
          <th>Latência média</th><th>Frequência</th><th>Servidor par</th>
          <th>Autenticação</th><th>Relação</th>
        </tr>
      </thead>
      <tbody>
        $tabelaLinhas
      </tbody>
    </table>
  </div>

  <p class="section-title">Configuração do Servidor Replica</p>
  $cfgHtml
  $certHtml

  <p class="section-title">Últimos Eventos de Replicação (erros e avisos)</p>
  $eventosHtml
</main>

<footer>
  Dashboard gerado automaticamente por <strong>Automatiza_Hyper-v_Replica.ps1</strong> &nbsp;|&nbsp; $dataColeta
</footer>

</body>
</html>
"@

    $arquivoRelatorio = Join-Path $script:PastaScript ("Dashboard_Replica_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))
    try {
        $html | Out-File -FilePath $arquivoRelatorio -Encoding UTF8 -ErrorAction Stop
        Write-Status -Tipo OK -Mensagem "Dashboard salvo em: $arquivoRelatorio"
        Write-Status -Tipo INFO -Mensagem "Abrindo no navegador padrão..."
        Start-Process $arquivoRelatorio
    } catch {
        Write-Status -Tipo ERRO -Mensagem "Falha ao salvar o dashboard: $($_.Exception.Message)"
    }
}

# ------------------------------------------------------------
# SUBMENU 3 — Monitoramento
# ------------------------------------------------------------
function Invoke-MenuMonitoramento {
    do {
        Show-Header -Titulo "MENU 3 — MONITORAMENTO E RELATÓRIOS"
        Write-Host "  Selecione a operação desejada:" -ForegroundColor Yellow
        Write-Host ""
        Write-Host "  [1]  Visão rápida da replicação (console)"                -ForegroundColor White
        Write-Host "  [2]  Gerar DASHBOARD HTML completo"                       -ForegroundColor White
        Write-Host "  [3]  Últimos eventos de replicação (erros/avisos)"        -ForegroundColor White
        Write-Host "  [4]  Exportar monitoramento para CSV"                     -ForegroundColor White
        Write-Host "  [5]  Zerar estatísticas de replicação"                    -ForegroundColor White
        Write-Host "  [6]  Verificar pré-requisitos novamente (checklist)"      -ForegroundColor White
        Write-Host "  [0]  Voltar ao menu principal"                            -ForegroundColor DarkGray
        Write-Host ""
        $opcaoMon = (Read-Host "  >> Digite a opção").Trim()
        switch ($opcaoMon) {
            "1" { Show-MonitorConsole }
            "2" { New-DashboardHtml }
            "3" { Show-EventosReplica }
            "4" { Export-CsvReplicacao }
            "5" { Reset-EstatisticasReplicacao }
            "6" {
                $estadoCk = Get-EstadoImplantacao
                Show-ChecklistSaude -Estado $estadoCk | Out-Null
            }
            "0" { }
            default {
                Write-Host ""
                Write-Status -Tipo AVISO -Mensagem "Opção inválida. Tente novamente."
            }
        }
        if ($opcaoMon -ne "0") { Wait-EnterContinuar }
    } while ($opcaoMon -ne "0")
}

# ============================================================
#  MENU PRINCIPAL
# ============================================================

# Carrega o encoder HTML usado no dashboard (System.Web)
Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

# Guarda de entrada: elevação
if (-not (Test-Administrador)) {
    Write-Host ""
    Write-Host "  [ERRO] Este script precisa ser executado como Administrador." -ForegroundColor Red
    Write-Host "         Abra o PowerShell com 'Executar como administrador' e tente novamente." -ForegroundColor Yellow
    Write-Host ""
    return
}

# Guarda de entrada: Windows Server
$soInicial = Test-SOSuportado
if (-not $soInicial.Suportado) {
    Write-Host ""
    Write-Host "  [ERRO] $($soInicial.Motivo)" -ForegroundColor Red
    Write-Host ""
    return
}

do {
    Show-Header
    Write-Host "  Selecione a operação desejada:" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  [1]  PREPARAR este servidor para o Hyper-V Replica"          -ForegroundColor White
    Write-Host "       (domínio/workgroup, certificado HTTPS, firewall, funções)" -ForegroundColor DarkGray
    Write-Host "  [2]  ADMINISTRAR o Hyper-V Replica"                          -ForegroundColor White
    Write-Host "       (habilitar replicação, failover de teste/planejado/desastre)" -ForegroundColor DarkGray
    Write-Host "  [3]  MONITORAMENTO e relatórios"                             -ForegroundColor White
    Write-Host "       (dashboard HTML, eventos, CSV, checklist)"              -ForegroundColor DarkGray
    Write-Host "  [0]  Sair"                                                   -ForegroundColor DarkGray
    Write-Host ""
    $opcao = (Read-Host "  >> Digite a opção").Trim()
    switch ($opcao) {
        "1" {
            Invoke-PreparacaoServidor
            Wait-EnterContinuar
        }
        "2" { Invoke-MenuAdministracao }
        "3" { Invoke-MenuMonitoramento }
        "0" {
            Write-Host ""
            Write-Host "  Encerrando o script. Até logo!" -ForegroundColor Cyan
            Write-Host ""
        }
        default {
            Write-Host ""
            Write-Status -Tipo AVISO -Mensagem "Opção inválida. Tente novamente."
            Wait-EnterContinuar
        }
    }
} while ($opcao -ne "0")
