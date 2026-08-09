# ============================================================
#  Criação de Máquinas Virtuais no Hyper-V a partir de TEMPLATES (.vhdx)
#  Ambiente: Windows Server 2019 ou superior / Windows 10-11 com Hyper-V
#  Autor...: Fagner Nascimento - Especialista Microsoft Datacenter
#
#  v2.0 - Reescrita a partir de "Automariza_Criacao_Vms_no_Hyperv_Interativo.ps1" (v4.1).
#         A origem do boot deixa de ser uma ISO e passa a ser um TEMPLATE .vhdx.
#
#         Novidades desta versão:
#           * Lista os templates (.vhdx) encontrados no diretório de templates,
#             com tipo do disco, tamanho em disco e tamanho virtual
#           * Copia o template para a pasta da nova VM com BARRA DE PROGRESSO
#             (percentual, taxa em MB/s e tempo restante estimado)
#           * Renomeia a cópia para <NomeDaVM>.vhdx e a anexa como disco de boot
#             - o arquivo de template NUNCA é usado nem alterado pela VM
#           * Trusted Platform Module virtual (vTPM) opcional - Windows 11
#           * Identificação de LAN virtual (VLAN) opcional, com ID 1-4094
#           * Geração 1 (BIOS/MBR) ou Geração 2 (UEFI/GPT) selecionável
#           * Secure Boot com template por sistema operacional (Windows/Linux)
#           * RAM, vCPU e memória dinâmica interativos, validados contra o host
#           * Expansão opcional do disco copiado (Resize-VHD)
#           * Verificação de espaço livre antes e integridade da cópia depois
#           * Checkpoints automáticos desabilitáveis
#           * ISO opcional como mídia ADICIONAL (não é mais a origem do boot)
#           * Criação de várias VMs em sequência, sem sair do script
#
#         Mantidos da v1:
#           * Seleção interativa do Switch Virtual
#           * Virtualização Aninhada (Nested) com checagem de pré-requisitos
#           * MAC Address Spoofing
#           * Secure Boot, ordem de boot, início da VM e resumo final
#
#  v2.1 - Modo rapido para VMs em sequencia.
#         A partir da segunda VM, o script mostra a configuracao da anterior e
#         oferece reaproveita-la: quando aceito, pergunta APENAS o nome da nova
#         VM e reusa template, switch, VLAN, memoria, vCPU, geracao, TPM e todo
#         o resto. Recusando, o assistente completo roda normalmente.
#         O resumo e a confirmacao (S/N) continuam sendo exibidos nos dois
#         caminhos - nada e criado sem o operador conferir.
#         Antes de reaproveitar, o script revalida o que pode ter mudado desde
#         a VM anterior: existencia do template, do switch virtual e da ISO.
#
#  Referências oficiais consultadas:
#    Geração 1 x 2 / VHDX pré-construído:
#      https://learn.microsoft.com/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v
#    Recursos de segurança da Geração 2 (Secure Boot / vTPM):
#      https://learn.microsoft.com/windows-server/virtualization/hyper-v/generation-2-virtual-machine-security-features
#    Set-VMKeyProtector / Enable-VMTPM:
#      https://learn.microsoft.com/powershell/module/hyper-v/set-vmkeyprotector
#      https://learn.microsoft.com/powershell/module/hyper-v/enable-vmtpm
#    Virtualização Aninhada:
#      https://learn.microsoft.com/windows-server/virtualization/hyper-v/enable-nested-virtualization
#    Set-VMNetworkAdapterVlan:
#      https://learn.microsoft.com/powershell/module/hyper-v/set-vmnetworkadaptervlan
# ============================================================

# ============================================================
#  VALORES PADRÃO (ajuste aqui o seu ambiente)
#  Todos podem ser alterados durante a execução - estes são apenas
#  os valores oferecidos no ENTER de cada pergunta.
# ============================================================
$Padroes = [ordered]@{
    TemplateDir  = 'E:\TEMPLATES'   # onde ficam os discos .vhdx de template
    VMPath       = 'E:\VMS'         # raiz onde as VMs serão criadas
    ISODir       = 'E:\ISOS'        # ISOs para mídia adicional (opcional)
    MemoriaGB    = 4                # RAM inicial sugerida
    vCPU         = 4                # vCPUs sugeridas
    NICName      = 'vNIC1'          # nome do adaptador de rede da VM
    Geracao      = 2                # 1 = BIOS/MBR | 2 = UEFI/GPT
    BlocoCopiaMB = 8                # tamanho do bloco de cópia do VHDX
}

$ErrorActionPreference = 'Stop'

# Controle de numeração das etapas de execução
$script:EtapaAtual   = 0
$script:TotalEtapas  = 0


# ============================================================
#  Funções auxiliares - apresentação
# ============================================================
function Show-Header {
    <#
        Cabeçalho principal em destaque.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Titulo)

    Write-Host ""
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ("   {0}" -f $Titulo)                                          -ForegroundColor Cyan
    Write-Host "============================================================" -ForegroundColor Cyan
    Write-Host ""
}

function Show-Secao {
    <#
        Subtítulo de cada etapa do assistente.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Titulo)

    Write-Host ""
    Write-Host ("  --- {0} ---" -f $Titulo) -ForegroundColor Cyan
}

function Write-Status {
    <#
        Feedback padronizado do projeto: [OK] / [AVISO] / [ERRO] / informativo.
    #>
    param(
        [Parameter(Mandatory = $true, Position = 0)][ValidateSet('OK', 'AVISO', 'ERRO', 'INFO')][string]$Tipo,
        [Parameter(Mandatory = $true, Position = 1)][string]$Mensagem
    )

    switch ($Tipo) {
        'OK'    { Write-Host ("  [OK] {0}"    -f $Mensagem) -ForegroundColor Green }
        'AVISO' { Write-Host ("  [AVISO] {0}" -f $Mensagem) -ForegroundColor Yellow }
        'ERRO'  { Write-Host ("  [ERRO] {0}"  -f $Mensagem) -ForegroundColor Red }
        'INFO'  { Write-Host ("  {0}"         -f $Mensagem) -ForegroundColor DarkGray }
    }
}

function Write-Etapa {
    <#
        Marca o início de cada etapa da fase de execução, numerada.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][string]$Titulo)

    $script:EtapaAtual++
    Write-Host ""
    Write-Host ("  [{0,2}/{1}] {2}" -f $script:EtapaAtual, $script:TotalEtapas, $Titulo) -ForegroundColor Cyan
}

function Format-Tamanho {
    <#
        Converte bytes para a maior unidade legível (KB/MB/GB/TB).
    #>
    param([Parameter(Mandatory = $true, Position = 0)][double]$Bytes)

    if ($Bytes -ge 1TB) { return ('{0:N2} TB' -f ($Bytes / 1TB)) }
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0:N0} B' -f $Bytes)
}

function Format-Duracao {
    <#
        Formata segundos como mm:ss ou hh:mm:ss. Devolve '--:--' quando o
        valor ainda não pôde ser estimado.
    #>
    param([Parameter(Mandatory = $true, Position = 0)][double]$Segundos)

    if ($Segundos -lt 0 -or [double]::IsNaN($Segundos) -or [double]::IsInfinity($Segundos)) { return '--:--' }

    $ts = [TimeSpan]::FromSeconds([math]::Round($Segundos))
    if ($ts.TotalHours -ge 1) {
        return ('{0:00}:{1:00}:{2:00}' -f [int]$ts.TotalHours, $ts.Minutes, $ts.Seconds)
    }
    return ('{0:00}:{1:00}' -f $ts.Minutes, $ts.Seconds)
}


# ============================================================
#  Funções auxiliares - entrada do operador
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

        Write-Status AVISO "Resposta inválida. Informe 'S' ou 'N'."
    }
}

function Read-Inteiro {
    <#
        Lê um número inteiro dentro de uma faixa, com valor padrão no ENTER.
        Usa TryParse em [long] para não estourar na conversão quando o
        operador digita uma sequência absurda de dígitos.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Pergunta,
        [Parameter(Mandatory = $true)][int]$Padrao,
        [int]$Minimo = 1,
        [int]$Maximo = 2147483647,
        [string]$Unidade = ''
    )

    $rotuloPadrao = if ($Unidade) { "$Padrao $Unidade" } else { "$Padrao" }

    while ($true) {
        $resposta = (Read-Host ("  >> {0} [ENTER = {1}]" -f $Pergunta, $rotuloPadrao)).Trim()

        if ([string]::IsNullOrWhiteSpace($resposta)) { return $Padrao }

        if ($resposta -notmatch '^\d+$') {
            Write-Status AVISO 'Informe apenas números inteiros positivos.'
            continue
        }

        $valor = [long]0
        if (-not [long]::TryParse($resposta, [ref]$valor)) {
            Write-Status AVISO 'Número fora do intervalo suportado.'
            continue
        }

        if ($valor -lt $Minimo -or $valor -gt $Maximo) {
            Write-Status AVISO ("Informe um valor entre {0} e {1}." -f $Minimo, $Maximo)
            continue
        }

        return [int]$valor
    }
}

function Select-FromList {
    <#
        Exibe uma lista numerada e devolve o item escolhido.
        -Rotulo recebe o item e devolve o texto que será exibido.
        -PermitirCancelar acrescenta a opção [0] e devolve $null.
    #>
    param(
        [Parameter(Mandatory = $true)][array]$Itens,
        [Parameter(Mandatory = $true)][string]$Pergunta,
        [scriptblock]$Rotulo,
        [switch]$PermitirCancelar
    )

    if (-not $Rotulo) { $Rotulo = { param($item) "$item" } }

    for ($i = 0; $i -lt $Itens.Count; $i++) {
        Write-Host ("    [{0}] {1}" -f ($i + 1), (& $Rotulo $Itens[$i])) -ForegroundColor White
    }
    if ($PermitirCancelar) {
        Write-Host "    [0] Cancelar" -ForegroundColor DarkGray
    }

    $minimo = if ($PermitirCancelar) { 0 } else { 1 }

    while ($true) {
        $opcao = (Read-Host ("  >> {0}" -f $Pergunta)).Trim()

        if ($opcao -match '^\d{1,6}$') {
            $numero = [int]$opcao
            if ($PermitirCancelar -and $numero -eq 0) { return $null }
            if ($numero -ge 1 -and $numero -le $Itens.Count) { return $Itens[$numero - 1] }
        }

        Write-Status AVISO ("Opção inválida. Informe um número entre {0} e {1}." -f $minimo, $Itens.Count)
    }
}

function Read-Diretorio {
    <#
        Lê um caminho de diretório com valor padrão. Com -CriarSeNecessario,
        oferece criar o diretório quando ele não existir (sempre confirmando).
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Pergunta,
        [Parameter(Mandatory = $true)][string]$Padrao,
        [switch]$CriarSeNecessario
    )

    while ($true) {
        $caminho = (Read-Host ("  >> {0} [ENTER = {1}]" -f $Pergunta, $Padrao)).Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($caminho)) { $caminho = $Padrao }

        if (Test-Path -LiteralPath $caminho -PathType Container) {
            return (Resolve-Path -LiteralPath $caminho).Path
        }

        if (Test-Path -LiteralPath $caminho -PathType Leaf) {
            Write-Status AVISO ("'{0}' é um arquivo, não um diretório." -f $caminho)
            continue
        }

        Write-Status AVISO ("Diretório não encontrado: {0}" -f $caminho)

        if ($CriarSeNecessario) {
            if (Read-Confirmacao -Pergunta 'Deseja criá-lo agora?' -Padrao 'S') {
                try {
                    New-Item -ItemType Directory -Path $caminho -Force -ErrorAction Stop | Out-Null
                    Write-Status OK ("Diretório criado: {0}" -f $caminho)
                    return (Resolve-Path -LiteralPath $caminho).Path
                }
                catch {
                    Write-Status ERRO ("Não foi possível criar o diretório: {0}" -f $_.Exception.Message)
                }
            }
        }
    }
}

function Read-NomeVM {
    <#
        Lê o nome da VM validando: não vazio, tamanho, caracteres válidos para
        nome de pasta/arquivo (o nome também vira o nome do VHDX) e ausência
        de outra VM homônima neste host.
    #>
    $invalidos = [System.IO.Path]::GetInvalidFileNameChars()

    while ($true) {
        $nome = (Read-Host '  >> Informe o nome da nova Maquina Virtual').Trim()

        if ([string]::IsNullOrWhiteSpace($nome)) {
            Write-Status AVISO 'O nome não pode ser vazio. Tente novamente.'
            continue
        }

        if ($nome.Length -gt 64) {
            Write-Status AVISO 'Use no máximo 64 caracteres.'
            continue
        }

        $temInvalido = $false
        foreach ($c in $invalidos) {
            if ($nome.IndexOf($c) -ge 0) { $temInvalido = $true; break }
        }
        if ($temInvalido -or $nome.EndsWith('.') -or $nome.EndsWith(' ')) {
            Write-Status AVISO 'O nome contém caracteres inválidos para nome de pasta/arquivo.'
            Write-Status INFO 'Evite  \ / : * ? " < > |  e não termine com ponto ou espaço.'
            continue
        }

        $existente = Get-VM -Name $nome -ErrorAction SilentlyContinue
        if ($existente) {
            Write-Status AVISO ("Já existe uma VM chamada '{0}' neste host. Escolha outro nome." -f $nome)
            continue
        }

        return $nome
    }
}


# ============================================================
#  Funções auxiliares - ambiente e hardware do host
# ============================================================
function Test-Administrador {
    <#
        Os cmdlets do módulo Hyper-V exigem elevação. Sem isso o script
        falharia só lá na frente, depois de copiar dezenas de GB.
    #>
    $identidade = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal  = New-Object System.Security.Principal.WindowsPrincipal($identidade)
    return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-AmbienteHyperV {
    <#
        Confere módulo Hyper-V, serviço vmms e elevação antes de qualquer
        pergunta ao operador.
    #>
    if (-not (Test-Administrador)) {
        Write-Status ERRO 'Este script precisa ser executado como Administrador.'
        Write-Status INFO 'Abra o PowerShell com "Executar como administrador" e rode novamente.'
        return $false
    }

    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        Write-Status ERRO 'Módulo PowerShell do Hyper-V não encontrado neste host.'
        Write-Status INFO 'Instale as ferramentas de gerenciamento do Hyper-V e tente novamente.'
        return $false
    }

    try {
        Import-Module Hyper-V -ErrorAction Stop
    }
    catch {
        Write-Status ERRO ("Falha ao carregar o módulo Hyper-V: {0}" -f $_.Exception.Message)
        return $false
    }

    $vmms = Get-Service -Name vmms -ErrorAction SilentlyContinue
    if (-not $vmms) {
        Write-Status ERRO 'Serviço "vmms" (Gerenciamento de Máquinas Virtuais do Hyper-V) não encontrado.'
        Write-Status INFO 'A função Hyper-V parece não estar instalada neste servidor.'
        return $false
    }
    if ($vmms.Status -ne 'Running') {
        Write-Status ERRO ("Serviço vmms está em '{0}'. Ele precisa estar em execução." -f $vmms.Status)
        return $false
    }

    Write-Status OK ("Ambiente validado: Hyper-V ativo em '{0}' (sessão elevada)." -f $env:COMPUTERNAME)
    return $true
}

function Get-InfoHost {
    <#
        Coleta memória total/livre e processadores lógicos para dimensionar
        os limites das perguntas de RAM e vCPU. Somente leitura.
    #>
    $info = [pscustomobject]@{
        RamTotalGB   = 0
        RamLivreGB   = 0.0
        CPUsLogicas  = 1
        Fabricante   = 'Desconhecido'
    }

    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem   -ErrorAction Stop
        $os = Get-CimInstance -ClassName Win32_OperatingSystem  -ErrorAction Stop

        $info.RamTotalGB  = [int][math]::Floor($cs.TotalPhysicalMemory / 1GB)
        $info.RamLivreGB  = [math]::Round(($os.FreePhysicalMemory * 1KB) / 1GB, 1)
        $info.CPUsLogicas = [int]$cs.NumberOfLogicalProcessors
        $info.Fabricante  = $cs.Manufacturer
    }
    catch {
        Write-Status AVISO ("Não foi possível ler o hardware do host: {0}" -f $_.Exception.Message)
    }

    return $info
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
        $cpu   = Get-CimInstance -ClassName Win32_Processor        -ErrorAction Stop | Select-Object -First 1
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
                # AMD exige host bem mais novo que Intel - build 20348 = Windows Server 2022
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

function Get-EspacoLivreBytes {
    <#
        Espaço livre no volume que contém o caminho informado.
        Devolve $null quando o caminho é UNC (não há como medir com DriveInfo).
    #>
    param([Parameter(Mandatory = $true)][string]$Caminho)

    try {
        $raiz = [System.IO.Path]::GetPathRoot($Caminho)
        if ([string]::IsNullOrWhiteSpace($raiz) -or $raiz.StartsWith('\\')) { return $null }

        $drive = New-Object System.IO.DriveInfo($raiz)
        return [long]$drive.AvailableFreeSpace
    }
    catch {
        return $null
    }
}


# ============================================================
#  Funções auxiliares - templates (.vhdx)
# ============================================================
function Get-TemplatesDisponiveis {
    <#
        Lê os arquivos .vhdx do diretório de templates e enriquece cada um com
        os metadados do disco virtual (Get-VHD é somente leitura).

        Dois estados merecem atenção e são sinalizados:
          Diferencial : disco filho (ParentPath preenchido). Copiar só o filho
                        gera um disco inútil, pois os dados estão no pai.
          Anexado     : o arquivo está em uso por alguma VM. Copiar um disco em
                        uso produz uma imagem inconsistente.
    #>
    param([Parameter(Mandatory = $true)][string]$Diretorio)

    $arquivos = @(Get-ChildItem -LiteralPath $Diretorio -Filter '*.vhdx' -File -ErrorAction SilentlyContinue |
                  Sort-Object Name)

    $lista = @()

    foreach ($arquivo in $arquivos) {
        $tipo       = 'Desconhecido'
        $virtual    = 0
        $pai        = $null
        $anexado    = $false
        $legivel    = $true

        try {
            $vhd     = Get-VHD -Path $arquivo.FullName -ErrorAction Stop
            $tipo    = [string]$vhd.VhdType
            $virtual = [long]$vhd.Size
            $pai     = $vhd.ParentPath
            $anexado = [bool]$vhd.Attached
        }
        catch {
            $legivel = $false
        }

        $lista += [pscustomobject]@{
            Nome           = $arquivo.Name
            Caminho        = $arquivo.FullName
            TamanhoArquivo = [long]$arquivo.Length
            TamanhoVirtual = $virtual
            Tipo           = $tipo
            Diferencial    = -not [string]::IsNullOrWhiteSpace($pai)
            Anexado        = $anexado
            Legivel        = $legivel
            SomenteLeitura = $arquivo.IsReadOnly
        }
    }

    return $lista
}

function Show-BarraProgresso {
    <#
        Desenha, em UMA única linha do console, a barra de progresso da cópia
        com percentual, volume copiado, taxa em MB/s e tempo restante.

        O retorno de carro (`r) reposiciona o cursor no início da linha, então
        cada atualização sobrescreve a anterior em vez de rolar a tela.
        A linha é truncada à largura da janela para não quebrar em duas.
    #>
    param(
        [Parameter(Mandatory = $true)][long]$Copiado,
        [Parameter(Mandatory = $true)][long]$Total,
        [Parameter(Mandatory = $true)][double]$Segundos,
        [int]$Largura = 28
    )

    $pct = 0.0
    if ($Total -gt 0) { $pct = [math]::Min(100.0, ([double]$Copiado / [double]$Total) * 100.0) }

    $cheio = [int][math]::Floor(($pct / 100.0) * $Largura)
    if ($cheio -gt $Largura) { $cheio = $Largura }
    $barra = ('#' * $cheio) + ('.' * ($Largura - $cheio))

    $mbs = 0.0
    if ($Segundos -gt 0.5) { $mbs = ($Copiado / 1MB) / $Segundos }

    $eta = -1.0
    if ($mbs -gt 0) { $eta = (($Total - $Copiado) / 1MB) / $mbs }

    $linha = ('  [{0}] {1,5:N1}%  {2} de {3}  |  {4,7:N1} MB/s  |  restam {5}' -f `
                 $barra, $pct, (Format-Tamanho $Copiado), (Format-Tamanho $Total), $mbs, (Format-Duracao $eta))

    # Preenche com espaços para apagar resquícios de uma linha anterior maior
    $linha = $linha.PadRight(90)

    $larguraMax = 100
    try { $larguraMax = $Host.UI.RawUI.WindowSize.Width - 1 } catch { }
    if ($larguraMax -gt 20 -and $linha.Length -gt $larguraMax) {
        $linha = $linha.Substring(0, $larguraMax)
    }

    Write-Host ("`r" + $linha) -NoNewline -ForegroundColor Cyan
}

function Copy-ArquivoComProgresso {
    <#
        Copia um arquivo grande exibindo barra de progresso em tempo real.

        Por que não usar Copy-Item?
        O Copy-Item não expõe progresso algum. Em um template de 40, 100 ou
        200 GB o operador ficaria muitos minutos olhando um cursor parado,
        sem saber se a cópia avança ou travou. Aqui a cópia é feita em blocos
        via FileStream, e o total já transferido é conhecido a cada bloco.

        Detalhes que importam:
          FileOptions::SequentialScan  - avisa o cache do Windows que a leitura
                                         é sequencial, melhorando o throughput.
          SetLength() no destino       - pré-aloca o arquivo inteiro de uma vez,
                                         reduzindo a fragmentação do VHDX final.
          Flush($true)                 - força a gravação até o disco físico
                                         antes de considerar a cópia concluída.

        Devolve um objeto com o resultado, o tempo gasto e a taxa média.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$Origem,
        [Parameter(Mandatory = $true)][string]$Destino,
        [ValidateRange(1, 64)][int]$BlocoMB = 8
    )

    $bloco   = $BlocoMB * 1MB
    $buffer  = New-Object byte[] $bloco
    $entrada = $null
    $saida   = $null
    $relogio = [System.Diagnostics.Stopwatch]::StartNew()
    $ultimo  = [long](-1000)
    $copiado = [long]0

    $resultado = [pscustomobject]@{
        Sucesso      = $false
        BytesTotal   = [long]0
        BytesCopiado = [long]0
        Segundos     = 0.0
        TaxaMBs      = 0.0
        Erro         = ''
    }

    try {
        $entrada = New-Object System.IO.FileStream -ArgumentList @(
                        $Origem,
                        [System.IO.FileMode]::Open,
                        [System.IO.FileAccess]::Read,
                        [System.IO.FileShare]::Read,
                        $bloco,
                        [System.IO.FileOptions]::SequentialScan)

        $saida = New-Object System.IO.FileStream -ArgumentList @(
                        $Destino,
                        [System.IO.FileMode]::Create,
                        [System.IO.FileAccess]::Write,
                        [System.IO.FileShare]::None,
                        $bloco,
                        [System.IO.FileOptions]::SequentialScan)

        $total                  = [long]$entrada.Length
        $resultado.BytesTotal   = $total

        $saida.SetLength($total)
        $saida.Position = 0

        Show-BarraProgresso -Copiado 0 -Total $total -Segundos 0

        $lidos = 0
        while (($lidos = $entrada.Read($buffer, 0, $bloco)) -gt 0) {
            $saida.Write($buffer, 0, $lidos)
            $copiado += $lidos

            # Redesenha no máximo ~5x por segundo. Atualizar a cada bloco
            # faria o console custar mais tempo que a própria cópia.
            if ((($relogio.ElapsedMilliseconds - $ultimo) -ge 200) -or ($copiado -ge $total)) {
                $ultimo = $relogio.ElapsedMilliseconds
                Show-BarraProgresso -Copiado $copiado -Total $total -Segundos $relogio.Elapsed.TotalSeconds
            }
        }

        $saida.Flush($true)
        $relogio.Stop()

        $resultado.BytesCopiado = $copiado
        $resultado.Segundos     = $relogio.Elapsed.TotalSeconds
        if ($resultado.Segundos -gt 0) {
            $resultado.TaxaMBs = ($copiado / 1MB) / $resultado.Segundos
        }
        $resultado.Sucesso = ($copiado -eq $total)
    }
    catch {
        $relogio.Stop()
        $resultado.Erro         = $_.Exception.Message
        $resultado.BytesCopiado = $copiado
        $resultado.Segundos     = $relogio.Elapsed.TotalSeconds
    }
    finally {
        if ($saida)   { $saida.Dispose() }
        if ($entrada) { $entrada.Dispose() }
        Write-Host ""   # encerra a linha da barra de progresso
    }

    return $resultado
}


# ============================================================
#  Funções auxiliares - limpeza em caso de falha
# ============================================================
function Remove-CriacaoParcial {
    <#
        Chamada apenas quando a criação falha no meio do caminho. Remove a VM
        registrada e o VHDX já copiado, SEMPRE mediante confirmação explícita
        do operador - nada é apagado silenciosamente.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$VMName,
        [string]$CaminhoVHDX,
        [string]$PastaVM
    )

    Write-Host ""
    Write-Status AVISO 'A criação foi interrompida e o ambiente ficou incompleto.'
    Write-Status INFO  ("VM registrada..: {0}" -f $VMName)
    if ($CaminhoVHDX) { Write-Status INFO ("Disco copiado..: {0}" -f $CaminhoVHDX) }

    if (-not (Read-Confirmacao -Pergunta 'Deseja remover a VM e o disco copiado (desfazer)?' -Padrao 'N')) {
        Write-Status INFO 'Nada foi removido. Verifique manualmente antes de tentar novamente.'
        return
    }

    $vm = Get-VM -Name $VMName -ErrorAction SilentlyContinue
    if ($vm) {
        try {
            if ($vm.State -ne 'Off') { Stop-VM -Name $VMName -TurnOff -Force -ErrorAction Stop }
            Remove-VM -Name $VMName -Force -ErrorAction Stop
            Write-Status OK ("VM '{0}' removida." -f $VMName)
        }
        catch {
            Write-Status ERRO ("Falha ao remover a VM: {0}" -f $_.Exception.Message)
        }
    }

    if ($CaminhoVHDX -and (Test-Path -LiteralPath $CaminhoVHDX)) {
        try {
            Remove-Item -LiteralPath $CaminhoVHDX -Force -ErrorAction Stop
            Write-Status OK 'Disco copiado removido.'
        }
        catch {
            Write-Status ERRO ("Falha ao remover o disco: {0}" -f $_.Exception.Message)
        }
    }

    if ($PastaVM -and (Test-Path -LiteralPath $PastaVM)) {
        $restante = @(Get-ChildItem -LiteralPath $PastaVM -Recurse -Force -ErrorAction SilentlyContinue)
        if ($restante.Count -eq 0) {
            try {
                Remove-Item -LiteralPath $PastaVM -Recurse -Force -ErrorAction Stop
                Write-Status OK 'Pasta da VM (vazia) removida.'
            }
            catch { }
        } else {
            Write-Status INFO ("A pasta '{0}' ainda contém arquivos e foi preservada." -f $PastaVM)
        }
    }
}


# ============================================================
#  ASSISTENTE - coleta das opções da nova VM
# ============================================================
function Read-ConfiguracaoVM {
    <#
        Conduz o operador por todas as perguntas e devolve um objeto com a
        configuração completa da VM. Nenhuma alteração é feita no host aqui -
        esta função apenas pergunta e valida.
        Devolve $null se o operador cancelar.
    #>
    param(
        [Parameter(Mandatory = $true)][string]$TemplateDir,
        [Parameter(Mandatory = $true)][string]$VMPath,
        [Parameter(Mandatory = $true)][string]$ISODir,
        [Parameter(Mandatory = $true)][hashtable]$Padroes,
        [Parameter(Mandatory = $true)][psobject]$InfoHost
    )

    # ---------- Nome da VM ----------
    Show-Secao 'Identificação da Máquina Virtual'
    $VMName = Read-NomeVM
    Write-Status OK ("Nome definido: '{0}'" -f $VMName)

    # ---------- Template (.vhdx) ----------
    Show-Secao ("Templates de Disco Virtual disponíveis em '{0}'" -f $TemplateDir)

    $templates = @(Get-TemplatesDisponiveis -Diretorio $TemplateDir)

    if ($templates.Count -eq 0) {
        Write-Status ERRO ("Nenhum arquivo .vhdx encontrado em '{0}'." -f $TemplateDir)
        Write-Status INFO 'Copie ao menos um disco de template para o diretório e tente novamente.'
        return $null
    }

    $rotuloTemplate = {
        param($t)
        $marcas = @()
        if ($t.Diferencial)    { $marcas += 'DISCO DIFERENCIAL' }
        if ($t.Anexado)        { $marcas += 'EM USO' }
        if (-not $t.Legivel)   { $marcas += 'ILEGIVEL' }
        if ($t.SomenteLeitura) { $marcas += 'somente leitura' }

        $texto = ('{0,-38} {1,10} em disco  |  virtual {2,10}  |  {3}' -f `
                    $t.Nome, (Format-Tamanho $t.TamanhoArquivo), (Format-Tamanho $t.TamanhoVirtual), $t.Tipo)

        if ($marcas.Count -gt 0) { $texto += ('  <<< ' + ($marcas -join ' / ')) }
        return $texto
    }

    $template = $null
    while ($null -eq $template) {
        $escolhido = Select-FromList -Itens $templates `
                                     -Pergunta 'Selecione o template que será a base desta VM' `
                                     -Rotulo $rotuloTemplate -PermitirCancelar

        if ($null -eq $escolhido) {
            Write-Status INFO 'Criação cancelada pelo operador.'
            return $null
        }

        if (-not $escolhido.Legivel) {
            Write-Status ERRO 'Não foi possível ler os metadados deste VHDX (arquivo corrompido ou sem permissão).'
            continue
        }

        if ($escolhido.Diferencial) {
            # Um disco diferencial guarda apenas as diferenças em relação ao pai.
            # Copiado sozinho, ele não contém o sistema operacional.
            Write-Status ERRO 'Este é um DISCO DIFERENCIAL (filho de outro VHDX) e não serve como template.'
            Write-Status INFO 'Faça o merge com o disco pai (Merge-VHD) antes de usá-lo como template.'
            continue
        }

        if ($escolhido.Anexado) {
            Write-Status AVISO 'Este VHDX está ANEXADO a alguma VM ou montado no host.'
            Write-Status AVISO 'Copiá-lo agora pode gerar uma imagem inconsistente (dados em cache não gravados).'
            if (-not (Read-Confirmacao -Pergunta 'Deseja usá-lo mesmo assim?' -Padrao 'N')) { continue }
        }

        $template = $escolhido
    }

    Write-Status OK ("Template selecionado: {0}" -f $template.Nome)
    Write-Status INFO ("O arquivo original NÃO será alterado - será copiado para a pasta da VM como '{0}.vhdx'." -f $VMName)

    # ---------- Geração da VM ----------
    Show-Secao 'Geração da Máquina Virtual'
    Write-Host "  A geração é propriedade da VM, não do disco: não há como saber, apenas"        -ForegroundColor DarkGray
    Write-Host "  olhando o arquivo, se um VHDX foi preparado para BIOS/MBR ou para UEFI/GPT."   -ForegroundColor DarkGray
    Write-Host "  Escolher errado gera uma VM que simplesmente não dá boot."                      -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "    [1] Geracao 1  - BIOS legado, controladora IDE, disco MBR"                   -ForegroundColor White
    Write-Host "    [2] Geracao 2  - UEFI, SCSI, disco GPT, Secure Boot e vTPM  (recomendado)"   -ForegroundColor White
    Write-Host ""

    $Geracao = Read-Inteiro -Pergunta 'Selecione a geracao da VM' -Padrao $Padroes.Geracao -Minimo 1 -Maximo 2
    Write-Status OK ("Geração {0} selecionada." -f $Geracao)

    if ($Geracao -eq 1) {
        Write-Status AVISO 'Geração 1 não suporta Secure Boot nem vTPM (Windows 11 não é compatível).'
    }

    # ---------- Recursos: memória e processador ----------
    Show-Secao 'Recursos da Máquina Virtual'
    Write-Host ("  Host: {0} GB de RAM total  |  {1} GB livres  |  {2} processadores lógicos" -f `
                    $InfoHost.RamTotalGB, $InfoHost.RamLivreGB, $InfoHost.CPUsLogicas) -ForegroundColor DarkGray
    Write-Host ""

    $maxRam    = [math]::Max(1, $InfoHost.RamTotalGB)
    $MemoriaGB = Read-Inteiro -Pergunta 'Memoria RAM da VM em GB' -Padrao $Padroes.MemoriaGB `
                              -Minimo 1 -Maximo $maxRam -Unidade 'GB'

    if ($MemoriaGB -gt $InfoHost.RamLivreGB) {
        Write-Status AVISO ("O host tem apenas {0} GB livres agora. A VM pode não iniciar." -f $InfoHost.RamLivreGB)
    }

    $MemoriaDinamica = Read-Confirmacao -Pergunta 'Usar memoria dinamica?' -Padrao 'N'
    $MemoriaMinGB    = $MemoriaGB
    $MemoriaMaxGB    = $MemoriaGB

    if ($MemoriaDinamica) {
        $sugestaoMin  = [math]::Max(1, [int][math]::Floor($MemoriaGB / 2))
        $sugestaoMax  = [math]::Min($maxRam, $MemoriaGB * 2)

        $MemoriaMinGB = Read-Inteiro -Pergunta 'Memoria MINIMA em GB' -Padrao $sugestaoMin `
                                     -Minimo 1 -Maximo $MemoriaGB -Unidade 'GB'
        $MemoriaMaxGB = Read-Inteiro -Pergunta 'Memoria MAXIMA em GB' -Padrao $sugestaoMax `
                                     -Minimo $MemoriaGB -Maximo $maxRam -Unidade 'GB'
    }

    $maxCPU = [math]::Max(1, $InfoHost.CPUsLogicas)
    $vCPU   = Read-Inteiro -Pergunta 'Quantidade de vCPUs' -Padrao $Padroes.vCPU -Minimo 1 -Maximo $maxCPU

    # ---------- Expansão do disco ----------
    Show-Secao 'Tamanho do Disco Virtual'
    Write-Host ("  O template '{0}' tem {1} de tamanho virtual." -f `
                    $template.Nome, (Format-Tamanho $template.TamanhoVirtual)) -ForegroundColor DarkGray
    Write-Host ""

    $ExpandirDisco = $false
    $NovoTamanhoGB = 0

    $tamanhoAtualGB = [int][math]::Floor($template.TamanhoVirtual / 1GB)
    if ($tamanhoAtualGB -lt 1) { $tamanhoAtualGB = 1 }

    # 65536 GB = 64 TB, teto do formato VHDX. Sem este limite, um template já no
    # tamanho máximo faria o mínimo ficar acima do máximo e o reprompt nunca sairia.
    $limiteVHDXGB = 65536

    if ($tamanhoAtualGB -ge $limiteVHDXGB) {
        Write-Status INFO 'O disco já está no tamanho máximo suportado pelo formato VHDX (64 TB).'
    }
    elseif (Read-Confirmacao -Pergunta 'Deseja EXPANDIR o disco da nova VM apos a copia?' -Padrao 'N') {
        $sugestao = [math]::Min($limiteVHDXGB, ($tamanhoAtualGB + 50))
        if ($sugestao -le $tamanhoAtualGB) { $sugestao = $tamanhoAtualGB + 1 }

        $NovoTamanhoGB = Read-Inteiro -Pergunta 'Novo tamanho do disco em GB' `
                                      -Padrao $sugestao `
                                      -Minimo ($tamanhoAtualGB + 1) -Maximo $limiteVHDXGB -Unidade 'GB'
        $ExpandirDisco = $true

        Write-Status AVISO 'Expandir o VHDX aumenta apenas o CONTÊINER do disco.'
        Write-Status INFO  'Dentro do sistema convidado ainda será preciso estender a partição'
        Write-Status INFO  '(Gerenciamento de Disco  ou  Resize-Partition / Extend-Partition).'
    }

    # ---------- Switch Virtual ----------
    Show-Secao 'Switches Virtuais disponíveis neste servidor Hyper-V'

    $switches = @(Get-VMSwitch | Sort-Object Name)
    if ($switches.Count -eq 0) {
        Write-Status ERRO 'Nenhum Switch Virtual encontrado neste servidor Hyper-V.'
        Write-Status INFO 'Crie um Switch Virtual antes de prosseguir.'
        return $null
    }

    $switch = Select-FromList -Itens $switches -Pergunta 'Selecione o Switch Virtual desejado' -Rotulo {
        param($sw) ('{0,-32} (Tipo: {1})' -f $sw.Name, $sw.SwitchType)
    }
    Write-Status OK ("Switch selecionado: '{0}'" -f $switch.Name)

    # ---------- VLAN ----------
    Show-Secao 'Identificação de LAN Virtual (VLAN)'
    Write-Host "  Equivale a marcar 'Habilitar identificacao de LAN virtual' nas configuracoes" -ForegroundColor DarkGray
    Write-Host "  do adaptador de rede e informar o ID da VLAN (modo Access)."                  -ForegroundColor DarkGray
    Write-Host "  Todo o trafego da VM por este adaptador sera marcado com a VLAN informada."   -ForegroundColor DarkGray
    Write-Host ""

    $HabilitarVlan = Read-Confirmacao -Pergunta 'Deseja habilitar a identificacao de LAN virtual (VLAN)?' -Padrao 'N'
    $VlanId        = 0

    if ($HabilitarVlan) {
        $VlanId = Read-Inteiro -Pergunta 'Informe o ID da VLAN' -Padrao 1 -Minimo 1 -Maximo 4094

        if ($switch.SwitchType -eq 'External') {
            Write-Status INFO 'Switch Externo: a porta física correspondente precisa estar em TRUNK'
            Write-Status INFO ("no switch de rede, permitindo a VLAN {0}." -f $VlanId)
        } else {
            Write-Status INFO ("Switch {0}: a VLAN isolará esta VM das demais que usarem outros IDs." -f $switch.SwitchType)
        }
    }

    # ---------- Virtualização Aninhada ----------
    Show-Secao 'Virtualização Aninhada (Nested)'
    Write-Host "  Permite executar Hyper-V, WSL2, Sandbox ou containers Hyper-V DENTRO desta VM." -ForegroundColor DarkGray
    Write-Host ""

    $suporteNested = Test-NestedVirtualizationSupport

    if ($suporteNested.Suportado) {
        Write-Status OK ("Host compatível. {0}" -f $suporteNested.Motivo)
    } else {
        Write-Status AVISO $suporteNested.Motivo
        Write-Status AVISO 'Habilitar mesmo assim pode falhar ao aplicar ou ao iniciar a VM.'
    }
    Write-Host ""

    $EnableNested = Read-Confirmacao -Pergunta 'Deseja habilitar a Virtualizacao Aninhada nesta VM?' -Padrao 'N'

    if ($EnableNested -and $MemoriaDinamica) {
        # Pré-requisito documentado: memória dinâmica precisa estar desligada.
        Write-Status AVISO 'A Virtualização Aninhada exige memória dinâmica DESLIGADA.'
        Write-Status INFO  ("A memória será fixada em {0} GB." -f $MemoriaGB)
        $MemoriaDinamica = $false
        $MemoriaMinGB    = $MemoriaGB
        $MemoriaMaxGB    = $MemoriaGB
    }

    # ---------- MAC Address Spoofing ----------
    Show-Secao 'MAC Address Spoofing'
    if ($EnableNested) {
        Write-Status AVISO 'Sem MAC Address Spoofing, as VMs criadas DENTRO desta VM não'
        Write-Status AVISO 'conseguem trafegar pela rede através do switch do host.'
    } else {
        Write-Status INFO 'Necessário para VMs aninhadas, clusters NLB e alguns appliances virtuais.'
    }

    $padraoSpoof       = if ($EnableNested) { 'S' } else { 'N' }
    $EnableMacSpoofing = Read-Confirmacao -Pergunta ("Habilitar MAC Address Spoofing no adaptador '{0}'?" -f $Padroes.NICName) -Padrao $padraoSpoof

    # ---------- Secure Boot e vTPM (somente Geração 2) ----------
    $SecureBoot         = 'Off'
    $SecureBootTemplate = 'MicrosoftWindows'
    $HabilitarTPM       = $false

    if ($Geracao -eq 2) {
        Show-Secao 'Secure Boot'
        Write-Host "    [1] Windows  - template 'MicrosoftWindows' (Windows Server / Windows 10-11)" -ForegroundColor White
        Write-Host "    [2] Linux    - template 'MicrosoftUEFICertificateAuthority'"                 -ForegroundColor White
        Write-Host "    [3] Desabilitar Secure Boot"                                                 -ForegroundColor White
        Write-Host ""

        $opcaoSB = Read-Inteiro -Pergunta 'Como configurar o Secure Boot?' -Padrao 1 -Minimo 1 -Maximo 3

        switch ($opcaoSB) {
            1 { $SecureBoot = 'On';  $SecureBootTemplate = 'MicrosoftWindows' }
            2 { $SecureBoot = 'On';  $SecureBootTemplate = 'MicrosoftUEFICertificateAuthority' }
            3 { $SecureBoot = 'Off'; $SecureBootTemplate = '' }
        }

        if ($SecureBoot -eq 'On') {
            Write-Status OK ("Secure Boot ligado com o template '{0}'." -f $SecureBootTemplate)
        } else {
            Write-Status OK 'Secure Boot desligado.'
        }

        # ---------- vTPM ----------
        Show-Secao 'Trusted Platform Module virtual (vTPM)'
        Write-Host "  Obrigatorio para templates de Windows 11 e para BitLocker dentro da VM."     -ForegroundColor DarkGray
        Write-Host "  O script cria um key protector LOCAL (Set-VMKeyProtector -NewLocalKeyProtector)" -ForegroundColor DarkGray
        Write-Host "  e em seguida habilita o vTPM (Enable-VMTPM)."                                 -ForegroundColor DarkGray
        Write-Host ""
        Write-Status AVISO 'Com vTPM local, a VM fica ATRELADA a este host: para movê-la depois'
        Write-Status AVISO 'será preciso exportar/importar o key protector no host de destino.'
        Write-Host ""

        $HabilitarTPM = Read-Confirmacao -Pergunta 'Deseja habilitar o Trusted Platform Module (TPM) nesta VM?' -Padrao 'N'

        if ($HabilitarTPM -and $SecureBoot -eq 'Off') {
            Write-Status AVISO 'O Windows 11 exige Secure Boot ligado ALÉM do vTPM.'
            Write-Status AVISO 'Com Secure Boot desligado a instalação/boot pode ser recusada.'
        }
    }

    # ---------- Mídia adicional (ISO opcional) ----------
    Show-Secao 'Mídia adicional (opcional)'
    Write-Host "  A VM dara boot pelo DISCO copiado do template. Uma ISO aqui e apenas" -ForegroundColor DarkGray
    Write-Host "  midia extra: drivers, agentes, ferramentas ou arquivo de unattend."    -ForegroundColor DarkGray
    Write-Host ""

    $AnexarISO = $false
    $ISOPath   = ''

    if (Read-Confirmacao -Pergunta 'Deseja anexar uma ISO a esta VM?' -Padrao 'N') {
        if (-not (Test-Path -LiteralPath $ISODir -PathType Container)) {
            Write-Status AVISO ("Diretório de ISOs não encontrado: {0}" -f $ISODir)
            Write-Status INFO  'A VM será criada sem drive de DVD.'
        }
        else {
            $isos = @(Get-ChildItem -LiteralPath $ISODir -Filter '*.iso' -File -ErrorAction SilentlyContinue |
                      Sort-Object Name)

            if ($isos.Count -eq 0) {
                Write-Status AVISO ("Nenhum arquivo .iso encontrado em '{0}'." -f $ISODir)
                Write-Status INFO  'A VM será criada sem drive de DVD.'
            }
            else {
                $iso = Select-FromList -Itens $isos -Pergunta 'Selecione a ISO' -PermitirCancelar -Rotulo {
                    param($f) ('{0,-46} {1}' -f $f.Name, (Format-Tamanho $f.Length))
                }

                if ($iso) {
                    $AnexarISO = $true
                    $ISOPath   = $iso.FullName
                    Write-Status OK ("ISO selecionada: {0}" -f $iso.Name)
                }
            }
        }
    }

    # ---------- Ajustes finais ----------
    Show-Secao 'Ajustes finais'

    $DesabilitarCheckpoints = $true
    if ((Get-Command Set-VM).Parameters.ContainsKey('AutomaticCheckpointsEnabled')) {
        Write-Status INFO 'Checkpoints automáticos criam um ponto de verificação a cada início da VM,'
        Write-Status INFO 'consumindo disco e poluindo o histórico de VMs de laboratório.'
        $DesabilitarCheckpoints = Read-Confirmacao -Pergunta 'Desabilitar os checkpoints automaticos desta VM?' -Padrao 'S'
    } else {
        $DesabilitarCheckpoints = $false
        Write-Status INFO 'Este host não expõe checkpoints automáticos (recurso mais novo). Etapa ignorada.'
    }

    $IniciarVM = Read-Confirmacao -Pergunta 'Iniciar a VM automaticamente ao final da criacao?' -Padrao 'S'

    # ---------- Objeto de configuração ----------
    return [pscustomobject]@{
        VMName                 = $VMName
        VMPath                 = $VMPath
        PastaVM                = (Join-Path $VMPath $VMName)
        PastaDiscos            = (Join-Path (Join-Path $VMPath $VMName) 'Virtual Hard Disks')
        VHDXDestino            = (Join-Path (Join-Path (Join-Path $VMPath $VMName) 'Virtual Hard Disks') ("{0}.vhdx" -f $VMName))
        Template               = $template
        Geracao                = $Geracao
        MemoriaGB              = $MemoriaGB
        MemoriaDinamica        = $MemoriaDinamica
        MemoriaMinGB           = $MemoriaMinGB
        MemoriaMaxGB           = $MemoriaMaxGB
        vCPU                   = $vCPU
        ExpandirDisco          = $ExpandirDisco
        NovoTamanhoGB          = $NovoTamanhoGB
        SwitchName             = $switch.Name
        SwitchType             = [string]$switch.SwitchType
        NICName                = $Padroes.NICName
        HabilitarVlan          = $HabilitarVlan
        VlanId                 = $VlanId
        EnableNested           = $EnableNested
        SuporteNested          = $suporteNested
        EnableMacSpoofing      = $EnableMacSpoofing
        SecureBoot             = $SecureBoot
        SecureBootTemplate     = $SecureBootTemplate
        HabilitarTPM           = $HabilitarTPM
        AnexarISO              = $AnexarISO
        ISOPath                = $ISOPath
        DesabilitarCheckpoints = $DesabilitarCheckpoints
        IniciarVM              = $IniciarVM
        BlocoCopiaMB           = $Padroes.BlocoCopiaMB
    }
}


# ============================================================
#  ASSISTENTE - resumo e confirmação
# ============================================================
function Show-ResumoConfiguracao {
    <#
        Mostra tudo o que será feito ANTES de tocar no host, e só então
        pede a confirmação final.
    #>
    param([Parameter(Mandatory = $true)][psobject]$Cfg)

    Write-Host ""
    Write-Host "  ============================================================" -ForegroundColor Cyan
    Write-Host "   RESUMO DA CONFIGURACAO"                                      -ForegroundColor Cyan
    Write-Host "  ============================================================" -ForegroundColor Cyan

    $memoria = if ($Cfg.MemoriaDinamica) {
        "{0} GB (dinamica: {1} a {2} GB)" -f $Cfg.MemoriaGB, $Cfg.MemoriaMinGB, $Cfg.MemoriaMaxGB
    } else {
        "{0} GB (fixa)" -f $Cfg.MemoriaGB
    }

    $disco = if ($Cfg.ExpandirDisco) {
        "{0}  ->  expandir para {1} GB" -f (Format-Tamanho $Cfg.Template.TamanhoVirtual), $Cfg.NovoTamanhoGB
    } else {
        "{0} (tamanho do template)" -f (Format-Tamanho $Cfg.Template.TamanhoVirtual)
    }

    $vlan = if ($Cfg.HabilitarVlan) { "Habilitada - ID {0} (modo Access)" -f $Cfg.VlanId } else { 'Desabilitada' }

    $secureBoot = if ($Cfg.Geracao -ne 2) {
        'N/A (Geracao 1)'
    } elseif ($Cfg.SecureBoot -eq 'On') {
        "Ligado ({0})" -f $Cfg.SecureBootTemplate
    } else {
        'Desligado'
    }

    $tpm = if ($Cfg.Geracao -ne 2) { 'N/A (Geracao 1)' } elseif ($Cfg.HabilitarTPM) { 'HABILITADO' } else { 'Desabilitado' }
    $iso = if ($Cfg.AnexarISO) { $Cfg.ISOPath } else { 'Nenhuma (boot pelo disco do template)' }

    Write-Host ""
    Write-Host ("    Nome da VM.........: {0}" -f $Cfg.VMName)
    Write-Host ("    Geracao............: {0}" -f $Cfg.Geracao)
    Write-Host ("    Template (origem)..: {0}" -f $Cfg.Template.Caminho)     -ForegroundColor Yellow
    Write-Host ("    Copia sera criada..: {0}" -f $Cfg.VHDXDestino)          -ForegroundColor Yellow
    Write-Host ("    Dados a copiar.....: {0}" -f (Format-Tamanho $Cfg.Template.TamanhoArquivo))
    Write-Host ("    Disco virtual......: {0}" -f $disco)
    Write-Host ("    Memoria RAM........: {0}" -f $memoria)
    Write-Host ("    vCPUs..............: {0}" -f $Cfg.vCPU)
    Write-Host ("    Switch Virtual.....: {0} ({1})" -f $Cfg.SwitchName, $Cfg.SwitchType)
    Write-Host ("    Adaptador de rede..: {0}" -f $Cfg.NICName)
    Write-Host ("    VLAN...............: {0}" -f $vlan)
    Write-Host ("    Virt. Aninhada.....: {0}" -f $(if ($Cfg.EnableNested) { 'SIM' } else { 'NAO' }))
    Write-Host ("    MAC Spoofing.......: {0}" -f $(if ($Cfg.EnableMacSpoofing) { 'ON' } else { 'OFF' }))
    Write-Host ("    Secure Boot........: {0}" -f $secureBoot)
    Write-Host ("    TPM (vTPM).........: {0}" -f $tpm)
    Write-Host ("    Midia adicional....: {0}" -f $iso)
    Write-Host ("    Checkpoints auto...: {0}" -f $(if ($Cfg.DesabilitarCheckpoints) { 'DESABILITADOS' } else { 'Padrao do host' }))
    Write-Host ("    Iniciar ao final...: {0}" -f $(if ($Cfg.IniciarVM) { 'SIM' } else { 'NAO' }))
    Write-Host ""
    Write-Status INFO 'O arquivo de template permanece intacto - ele apenas serve de origem para a copia.'
    Write-Host ""

    return (Read-Confirmacao -Pergunta ("Confirma a criacao da VM '{0}'?" -f $Cfg.VMName) -Padrao 'N')
}


# ============================================================
#  MODO RÁPIDO - reaproveitar a configuração da VM anterior
# ============================================================
function Show-ConfiguracaoAnterior {
    <#
        Resumo compacto da última VM criada, para o operador decidir se quer
        repetir a mesma configuração mudando apenas o nome.
    #>
    param([Parameter(Mandatory = $true)][psobject]$Cfg)

    $memoria = if ($Cfg.MemoriaDinamica) {
        "{0} GB dinamica ({1}-{2} GB)" -f $Cfg.MemoriaGB, $Cfg.MemoriaMinGB, $Cfg.MemoriaMaxGB
    } else {
        "{0} GB fixa" -f $Cfg.MemoriaGB
    }

    $rede = $Cfg.SwitchName
    if ($Cfg.HabilitarVlan) { $rede += ("  |  VLAN {0}" -f $Cfg.VlanId) }
    if ($Cfg.EnableMacSpoofing) { $rede += '  |  MAC Spoofing ON' }

    $seguranca = "Geracao {0}" -f $Cfg.Geracao
    if ($Cfg.Geracao -eq 2) {
        $seguranca += if ($Cfg.SecureBoot -eq 'On') { "  |  Secure Boot {0}" -f $Cfg.SecureBootTemplate } else { '  |  Secure Boot OFF' }
        if ($Cfg.HabilitarTPM) { $seguranca += '  |  vTPM ON' }
    }

    $extras = @()
    if ($Cfg.EnableNested)  { $extras += 'Nested' }
    if ($Cfg.ExpandirDisco) { $extras += ("disco {0} GB" -f $Cfg.NovoTamanhoGB) }
    if ($Cfg.AnexarISO)     { $extras += ("ISO {0}" -f (Split-Path -Leaf $Cfg.ISOPath)) }
    if ($Cfg.DesabilitarCheckpoints) { $extras += 'sem checkpoints automaticos' }
    if ($Cfg.IniciarVM)     { $extras += 'inicia ao final' }

    Show-Secao ("Configuracao da VM anterior ({0})" -f $Cfg.VMName)
    Write-Host ("    Template.......: {0}" -f $Cfg.Template.Nome)
    Write-Host ("    Memoria / vCPU.: {0}  |  {1} vCPUs" -f $memoria, $Cfg.vCPU)
    Write-Host ("    Rede...........: {0}" -f $rede)
    Write-Host ("    Seguranca......: {0}" -f $seguranca)
    if ($extras.Count -gt 0) {
        Write-Host ("    Extras.........: {0}" -f ($extras -join '  |  '))
    }
    Write-Host ""
}

function Copy-ConfiguracaoVM {
    <#
        Clona a configuração de uma VM já criada, trocando apenas o nome e os
        caminhos derivados dele.

        Não basta copiar o objeto: entre uma VM e outra o operador pode ter
        movido o template, removido o switch virtual ou desmontado o
        compartilhamento das ISOs. Reaproveitar às cegas faria a criação falhar
        lá na frente, depois de a cópia do disco já ter começado. Por isso tudo
        o que é caminho ou recurso externo é revalidado aqui.

        Devolve $null quando um pré-requisito essencial não existe mais - nesse
        caso o chamador cai no assistente completo.
    #>
    param(
        [Parameter(Mandatory = $true)][psobject]$Base,
        [Parameter(Mandatory = $true)][string]$NovoNome
    )

    if (-not (Test-Path -LiteralPath $Base.Template.Caminho -PathType Leaf)) {
        Write-Status ERRO ("O template '{0}' não está mais acessível." -f $Base.Template.Caminho)
        return $null
    }

    if (-not (Get-VMSwitch -Name $Base.SwitchName -ErrorAction SilentlyContinue)) {
        Write-Status ERRO ("O switch virtual '{0}' não existe mais neste host." -f $Base.SwitchName)
        return $null
    }

    # Cópia rasa basta: só trocamos valores escalares. Template é clonado à
    # parte porque o tamanho do arquivo é atualizado abaixo.
    $novo = $Base.PSObject.Copy()

    $novo.VMName      = $NovoNome
    $novo.PastaVM     = Join-Path $Base.VMPath $NovoNome
    $novo.PastaDiscos = Join-Path $novo.PastaVM 'Virtual Hard Disks'
    $novo.VHDXDestino = Join-Path $novo.PastaDiscos ("{0}.vhdx" -f $NovoNome)

    # Se o template foi substituído por uma versão mais nova, a checagem de
    # espaço livre precisa do tamanho atual, não do que valia na VM anterior.
    $novo.Template = $Base.Template.PSObject.Copy()
    $arquivoAtual  = Get-Item -LiteralPath $Base.Template.Caminho
    if ($arquivoAtual.Length -ne $novo.Template.TamanhoArquivo) {
        Write-Status INFO ("O template mudou de tamanho desde a última VM: {0} -> {1}" -f `
                            (Format-Tamanho $novo.Template.TamanhoArquivo), (Format-Tamanho $arquivoAtual.Length))
        $novo.Template.TamanhoArquivo = [long]$arquivoAtual.Length
    }

    if ($novo.AnexarISO -and -not (Test-Path -LiteralPath $novo.ISOPath -PathType Leaf)) {
        Write-Status AVISO ("A ISO '{0}' não está mais acessível." -f $novo.ISOPath)
        Write-Status INFO  'A VM será criada sem mídia adicional.'
        $novo.AnexarISO = $false
        $novo.ISOPath   = ''
    }

    return $novo
}


# ============================================================
#  EXECUÇÃO - cria a VM de fato
# ============================================================
function Invoke-CriacaoVM {
    <#
        Aplica no host tudo o que foi coletado pelo assistente, na ordem:
        copiar o disco primeiro (é a etapa longa e a que mais pode falhar por
        espaço/IO) e só depois montar a VM em volta dele.
        Devolve $true em caso de sucesso.
    #>
    param([Parameter(Mandatory = $true)][psobject]$Cfg)

    # Numeração dinâmica das etapas
    $script:EtapaAtual  = 0
    $script:TotalEtapas = 10
    if ($Cfg.ExpandirDisco)          { $script:TotalEtapas++ }
    if ($Cfg.AnexarISO)              { $script:TotalEtapas++ }
    if ($Cfg.DesabilitarCheckpoints) { $script:TotalEtapas++ }
    if ($Cfg.IniciarVM)              { $script:TotalEtapas++ }

    $vmCriada     = $false
    $discoCopiado = $false

    try {
        # ---------- 1. Diretórios ----------
        Write-Etapa 'Preparando os diretorios da VM'

        if (-not (Test-Path -LiteralPath $Cfg.PastaDiscos)) {
            New-Item -ItemType Directory -Path $Cfg.PastaDiscos -Force -ErrorAction Stop | Out-Null
            Write-Status OK ("Diretório criado: {0}" -f $Cfg.PastaDiscos)
        } else {
            Write-Status AVISO ("Diretório já existe: {0}" -f $Cfg.PastaDiscos)
        }

        if (Test-Path -LiteralPath $Cfg.VHDXDestino) {
            Write-Status AVISO ("Já existe um disco em: {0}" -f $Cfg.VHDXDestino)
            if (-not (Read-Confirmacao -Pergunta 'SOBRESCREVER este arquivo? (o conteudo atual sera perdido)' -Padrao 'N')) {
                Write-Status INFO 'Operação cancelada. Escolha outro nome de VM e tente novamente.'
                return $false
            }
        }

        # ---------- 2. Espaço livre ----------
        Write-Etapa 'Verificando espaco livre no destino'

        $margem     = 1GB
        $necessario = $Cfg.Template.TamanhoArquivo + $margem

        # Um VHDX dinâmico só ocupa o espaço realmente usado, mesmo depois do
        # Resize-VHD. Já um disco fixo passa a ocupar o novo tamanho inteiro.
        if ($Cfg.ExpandirDisco -and $Cfg.Template.Tipo -eq 'Fixed') {
            $necessario = ($Cfg.NovoTamanhoGB * 1GB) + $margem
        }

        $livre = Get-EspacoLivreBytes -Caminho $Cfg.PastaDiscos

        if ($null -eq $livre) {
            Write-Status AVISO 'Não foi possível medir o espaço livre do destino (caminho de rede?).'
            if (-not (Read-Confirmacao -Pergunta 'Prosseguir mesmo assim?' -Padrao 'N')) { return $false }
        }
        elseif ($livre -lt $necessario) {
            Write-Status ERRO ("Espaço insuficiente. Necessário {0}, disponível {1}." -f `
                                (Format-Tamanho $necessario), (Format-Tamanho $livre))
            return $false
        }
        else {
            Write-Status OK ("Espaço livre: {0}  |  necessário: {1}" -f `
                              (Format-Tamanho $livre), (Format-Tamanho $necessario))
        }

        # ---------- 3. Cópia do template ----------
        Write-Etapa 'Copiando o disco de template para a pasta da VM'
        Write-Status INFO ("Origem..: {0}" -f $Cfg.Template.Caminho)
        Write-Status INFO ("Destino.: {0}" -f $Cfg.VHDXDestino)
        Write-Host ""

        $copia = Copy-ArquivoComProgresso -Origem  $Cfg.Template.Caminho `
                                          -Destino $Cfg.VHDXDestino `
                                          -BlocoMB $Cfg.BlocoCopiaMB

        if (-not $copia.Sucesso) {
            Write-Status ERRO ("Falha ao copiar o template: {0}" -f $copia.Erro)
            if (Test-Path -LiteralPath $Cfg.VHDXDestino) {
                Remove-Item -LiteralPath $Cfg.VHDXDestino -Force -ErrorAction SilentlyContinue
                Write-Status INFO 'Cópia parcial removida.'
            }
            return $false
        }

        $discoCopiado = $true
        Write-Status OK ("Cópia concluída: {0} em {1} ({2:N1} MB/s de média)" -f `
                          (Format-Tamanho $copia.BytesCopiado), (Format-Duracao $copia.Segundos), $copia.TaxaMBs)

        # ---------- 4. Verificação da cópia ----------
        Write-Etapa 'Verificando a integridade da copia'

        # Templates costumam ficar marcados como somente-leitura. O Hyper-V não
        # conseguiria gravar no disco da VM se o atributo viesse junto.
        $arquivoCopia = Get-Item -LiteralPath $Cfg.VHDXDestino -ErrorAction Stop
        if ($arquivoCopia.IsReadOnly) {
            $arquivoCopia.IsReadOnly = $false
            Write-Status OK 'Atributo somente-leitura removido da cópia.'
        }

        if ($arquivoCopia.Length -ne $Cfg.Template.TamanhoArquivo) {
            Write-Status ERRO ("Tamanho divergente: origem {0}, cópia {1}." -f `
                                (Format-Tamanho $Cfg.Template.TamanhoArquivo), (Format-Tamanho $arquivoCopia.Length))
            throw 'A cópia do template não confere com o arquivo de origem.'
        }
        Write-Status OK ("Tamanho conferido: {0}" -f (Format-Tamanho $arquivoCopia.Length))

        # Get-VHD lê e valida o cabeçalho do VHDX - se a cópia estiver corrompida,
        # falha aqui em vez de falhar no boot da VM.
        $vhdCopia = Get-VHD -Path $Cfg.VHDXDestino -ErrorAction Stop
        Write-Status OK ("Disco válido: {0}, {1} virtual, formato {2}" -f `
                          $vhdCopia.VhdType, (Format-Tamanho $vhdCopia.Size), $vhdCopia.VhdFormat)

        # ---------- 5. Expansão (opcional) ----------
        if ($Cfg.ExpandirDisco) {
            Write-Etapa 'Expandindo o disco copiado'

            $novoBytes = [long]$Cfg.NovoTamanhoGB * 1GB
            Resize-VHD -Path $Cfg.VHDXDestino -SizeBytes $novoBytes -ErrorAction Stop

            $vhdCopia = Get-VHD -Path $Cfg.VHDXDestino -ErrorAction Stop
            Write-Status OK ("Disco expandido para {0}" -f (Format-Tamanho $vhdCopia.Size))
            Write-Status AVISO 'Lembre-se de estender a partição DENTRO do sistema convidado.'
        }

        # ---------- 6. Criar a VM ----------
        Write-Etapa 'Criando a Maquina Virtual'

        New-VM -Name               $Cfg.VMName `
               -Generation         $Cfg.Geracao `
               -MemoryStartupBytes ([long]$Cfg.MemoriaGB * 1GB) `
               -Path               $Cfg.VMPath `
               -NoVHD `
               -ErrorAction Stop | Out-Null

        $vmCriada = $true
        Write-Status OK ("VM '{0}' criada (Geração {1})" -f $Cfg.VMName, $Cfg.Geracao)

        # O New-VM sempre cria um adaptador "Network Adapter" padrão; removê-lo
        # para que a VM fique apenas com o adaptador personalizado.
        Get-VMNetworkAdapter -VMName $Cfg.VMName | Remove-VMNetworkAdapter -ErrorAction Stop
        Write-Status OK 'Adaptador de rede padrão removido'

        # ---------- 7. Processador ----------
        Write-Etapa 'Configurando o processador'

        Set-VMProcessor -VMName $Cfg.VMName -Count $Cfg.vCPU -ErrorAction Stop
        Write-Status OK ("vCPUs configuradas: {0}" -f $Cfg.vCPU)

        if ($Cfg.EnableNested) {
            # A VM PRECISA estar desligada - este é o momento correto, antes do Start-VM.
            # https://learn.microsoft.com/windows-server/virtualization/hyper-v/enable-nested-virtualization
            try {
                Set-VMProcessor -VMName $Cfg.VMName -ExposeVirtualizationExtensions $true -ErrorAction Stop

                $nestedAtivo = (Get-VMProcessor -VMName $Cfg.VMName).ExposeVirtualizationExtensions
                $versaoVM    = (Get-VM -Name $Cfg.VMName).Version

                if ($nestedAtivo) {
                    Write-Status OK ("Virtualização Aninhada habilitada (versão de configuração da VM: {0})" -f $versaoVM)
                } else {
                    Write-Status AVISO 'O comando foi aceito, mas a propriedade não ficou ativa.'
                }

                if ([version]$versaoVM -lt [version]$Cfg.SuporteNested.VersaoMinimaVM) {
                    Write-Status AVISO ("Versão de configuração {0} é inferior à mínima {1} exigida para esta CPU." -f `
                                         $versaoVM, $Cfg.SuporteNested.VersaoMinimaVM)
                    Write-Status INFO  ("Atualize com: Update-VMVersion -Name '{0}'" -f $Cfg.VMName)
                }
            }
            catch {
                Write-Status ERRO ("Falha ao habilitar a Virtualização Aninhada: {0}" -f $_.Exception.Message)
                Write-Status AVISO 'A VM continuará sendo criada SEM o recurso.'
            }
        } else {
            Write-Status INFO 'Virtualização Aninhada não solicitada (mantida desabilitada)'
        }

        # ---------- 8. Memória ----------
        Write-Etapa 'Configurando a memoria'

        if ($Cfg.MemoriaDinamica) {
            Set-VMMemory -VMName $Cfg.VMName `
                         -DynamicMemoryEnabled $true `
                         -StartupBytes ([long]$Cfg.MemoriaGB    * 1GB) `
                         -MinimumBytes ([long]$Cfg.MemoriaMinGB * 1GB) `
                         -MaximumBytes ([long]$Cfg.MemoriaMaxGB * 1GB) `
                         -ErrorAction Stop

            Write-Status OK ("Memória dinâmica: inicial {0} GB, mínima {1} GB, máxima {2} GB" -f `
                              $Cfg.MemoriaGB, $Cfg.MemoriaMinGB, $Cfg.MemoriaMaxGB)
        }
        else {
            Set-VMMemory -VMName $Cfg.VMName `
                         -DynamicMemoryEnabled $false `
                         -StartupBytes ([long]$Cfg.MemoriaGB * 1GB) `
                         -ErrorAction Stop

            Write-Status OK ("Memória RAM fixada em {0} GB" -f $Cfg.MemoriaGB)
        }

        # ---------- 9. Anexar o disco copiado ----------
        Write-Etapa 'Anexando o disco copiado do template'

        # Geração 2 dá boot por SCSI; Geração 1 dá boot pela IDE 0.
        $controlador = if ($Cfg.Geracao -eq 2) { 'SCSI' } else { 'IDE' }

        Add-VMHardDiskDrive -VMName            $Cfg.VMName `
                            -Path              $Cfg.VHDXDestino `
                            -ControllerType    $controlador `
                            -ControllerNumber  0 `
                            -ControllerLocation 0 `
                            -ErrorAction Stop

        Write-Status OK ("Disco anexado em {0} 0:0 -> {1}" -f $controlador, (Split-Path -Leaf $Cfg.VHDXDestino))

        # ---------- 10. Mídia adicional (opcional) ----------
        if ($Cfg.AnexarISO) {
            Write-Etapa 'Anexando a midia adicional (ISO)'

            if (-not (Test-Path -LiteralPath $Cfg.ISOPath)) {
                Write-Status AVISO ("ISO não encontrada: {0}. Drive de DVD não será criado." -f $Cfg.ISOPath)
            }
            else {
                # A VM de Geração 2 criada por New-VM NÃO tem unidade de DVD, mas a de
                # Geração 1 já nasce com uma na IDE 1:0. Tentar adicionar outra na mesma
                # posição falharia, então só criamos o drive quando não existir nenhum.
                # https://learn.microsoft.com/windows-server/virtualization/hyper-v/plan/should-i-create-a-generation-1-or-2-virtual-machine-in-hyper-v
                $drives = @(Get-VMDvdDrive -VMName $Cfg.VMName -ErrorAction SilentlyContinue)

                if ($drives.Count -eq 0) {
                    # Gen 2: DVD no SCSI 0:1  |  Gen 1: DVD na IDE 1:0 (a IDE 0:0 é o disco)
                    if ($Cfg.Geracao -eq 2) {
                        Add-VMDvdDrive -VMName $Cfg.VMName -ControllerNumber 0 -ControllerLocation 1 -ErrorAction Stop
                    } else {
                        Add-VMDvdDrive -VMName $Cfg.VMName -ControllerNumber 1 -ControllerLocation 0 -ErrorAction Stop
                    }
                    $drives = @(Get-VMDvdDrive -VMName $Cfg.VMName)
                }
                else {
                    Write-Status INFO 'Reutilizando a unidade de DVD que a VM já possui.'
                }

                $dvd = $drives | Select-Object -First 1
                Set-VMDvdDrive -VMName             $Cfg.VMName `
                               -ControllerNumber   $dvd.ControllerNumber `
                               -ControllerLocation $dvd.ControllerLocation `
                               -Path               $Cfg.ISOPath `
                               -ErrorAction Stop

                Write-Status OK ("ISO montada: {0}" -f (Split-Path -Leaf $Cfg.ISOPath))
            }
        }

        # ---------- 11. Rede ----------
        Write-Etapa 'Configurando a rede'

        Add-VMNetworkAdapter -VMName     $Cfg.VMName `
                             -Name       $Cfg.NICName `
                             -SwitchName $Cfg.SwitchName `
                             -ErrorAction Stop

        Write-Status OK ("Adaptador '{0}' vinculado ao switch '{1}'" -f $Cfg.NICName, $Cfg.SwitchName)

        if ($Cfg.HabilitarVlan) {
            # ATENÇÃO: Set-VMNetworkAdapterVlan SUBSTITUI a configuração de VLAN
            # do adaptador, não acrescenta. Aqui o adaptador acabou de nascer,
            # então -Access com um único ID é exatamente o comportamento da caixa
            # "Habilitar identificacao de LAN virtual" do Hyper-V Manager.
            try {
                Set-VMNetworkAdapterVlan -VMName               $Cfg.VMName `
                                         -VMNetworkAdapterName $Cfg.NICName `
                                         -Access `
                                         -VlanId               $Cfg.VlanId `
                                         -ErrorAction Stop

                $vlanAtual = Get-VMNetworkAdapterVlan -VMName $Cfg.VMName -VMNetworkAdapterName $Cfg.NICName
                Write-Status OK ("VLAN habilitada: modo {0}, ID {1}" -f $vlanAtual.OperationMode, $vlanAtual.AccessVlanId)
            }
            catch {
                Write-Status ERRO ("Falha ao configurar a VLAN: {0}" -f $_.Exception.Message)
                Write-Status AVISO 'A VM continuará sem identificação de LAN virtual.'
            }
        }
        else {
            Write-Status INFO 'Identificação de LAN virtual não solicitada (adaptador sem marcação de VLAN)'
        }

        if ($Cfg.EnableMacSpoofing) {
            try {
                Set-VMNetworkAdapter -VMName $Cfg.VMName `
                                     -Name   $Cfg.NICName `
                                     -MacAddressSpoofing On `
                                     -ErrorAction Stop

                Write-Status OK ("MAC Address Spoofing habilitado no adaptador '{0}'" -f $Cfg.NICName)
            }
            catch {
                Write-Status AVISO ("Não foi possível habilitar o MAC Address Spoofing: {0}" -f $_.Exception.Message)
                Write-Status AVISO 'As VMs aninhadas podem ficar sem acesso à rede.'
            }
        }

        # ---------- 12. Firmware / BIOS, segurança e ordem de boot ----------
        Write-Etapa 'Configurando firmware, seguranca e ordem de boot'

        if ($Cfg.Geracao -eq 2) {

            # Secure Boot
            if ($Cfg.SecureBoot -eq 'On') {
                Set-VMFirmware -VMName $Cfg.VMName `
                               -EnableSecureBoot On `
                               -SecureBootTemplate $Cfg.SecureBootTemplate `
                               -ErrorAction Stop

                Write-Status OK ("Secure Boot habilitado (template: {0})" -f $Cfg.SecureBootTemplate)
            }
            else {
                Set-VMFirmware -VMName $Cfg.VMName -EnableSecureBoot Off -ErrorAction Stop
                Write-Status OK 'Secure Boot desabilitado'
            }

            # vTPM: primeiro o key protector, depois o TPM. Sem key protector,
            # o Enable-VMTPM falha - é ele que fornece as chaves do dispositivo.
            if ($Cfg.HabilitarTPM) {
                try {
                    Set-VMKeyProtector -VMName $Cfg.VMName -NewLocalKeyProtector -ErrorAction Stop
                    Write-Status OK 'Key protector local criado'

                    Enable-VMTPM -VMName $Cfg.VMName -ErrorAction Stop

                    $seguranca = Get-VMSecurity -VMName $Cfg.VMName
                    if ($seguranca.TpmEnabled) {
                        Write-Status OK 'Trusted Platform Module (vTPM) HABILITADO'
                    } else {
                        Write-Status AVISO 'O comando foi aceito, mas o vTPM não ficou ativo.'
                    }
                }
                catch {
                    Write-Status ERRO ("Falha ao habilitar o vTPM: {0}" -f $_.Exception.Message)
                    Write-Status AVISO 'A VM continuará sendo criada SEM o TPM virtual.'
                    Write-Status INFO  'Templates de Windows 11 podem se recusar a iniciar sem ele.'
                }
            }
            else {
                Write-Status INFO 'TPM virtual não solicitado (mantido desabilitado)'
            }

            # Ordem de boot: o DISCO vem primeiro - a VM já traz o sistema pronto.
            $bootDisco = Get-VMHardDiskDrive -VMName $Cfg.VMName | Select-Object -First 1
            $bootDvd   = Get-VMDvdDrive      -VMName $Cfg.VMName -ErrorAction SilentlyContinue | Select-Object -First 1

            if ($bootDvd) {
                Set-VMFirmware -VMName $Cfg.VMName -BootOrder $bootDisco, $bootDvd -ErrorAction Stop
                Write-Status OK 'Ordem de boot: Disco (template) -> DVD'
            } else {
                Set-VMFirmware -VMName $Cfg.VMName -BootOrder $bootDisco -ErrorAction Stop
                Write-Status OK 'Ordem de boot: Disco (template)'
            }
        }
        else {
            # Geração 1 usa BIOS legado: a ordem é definida por tipo de dispositivo
            # e a lista precisa conter todos os dispositivos suportados.
            Set-VMBios -VMName $Cfg.VMName `
                       -StartupOrder @('IDE', 'CD', 'LegacyNetworkAdapter', 'Floppy') `
                       -ErrorAction Stop

            Write-Status OK 'Ordem de boot (BIOS): IDE (template) -> CD -> Rede -> Disquete'
            Write-Status INFO 'Geração 1 não possui Secure Boot nem vTPM.'
        }

        # ---------- 13. Ajustes finais ----------
        if ($Cfg.DesabilitarCheckpoints) {
            Write-Etapa 'Desabilitando checkpoints automaticos'
            Set-VM -Name $Cfg.VMName -AutomaticCheckpointsEnabled $false -ErrorAction Stop
            Write-Status OK 'Checkpoints automáticos desabilitados'
        }

        # Rastreabilidade: fica registrado na própria VM de qual template ela nasceu.
        $nota = "Criada em {0} por {1} a partir do template '{2}'." -f `
                    (Get-Date -Format 'dd/MM/yyyy HH:mm'), $env:USERNAME, $Cfg.Template.Nome
        try {
            Set-VM -Name $Cfg.VMName -Notes $nota -ErrorAction Stop
        }
        catch { }

        # ---------- 14. Iniciar a VM ----------
        if ($Cfg.IniciarVM) {
            Write-Etapa 'Iniciando a Maquina Virtual'

            Start-VM -Name $Cfg.VMName -ErrorAction Stop
            Write-Status OK ("VM '{0}' iniciada! Aguardando o estado 'Running'..." -f $Cfg.VMName)

            $timeout  = 60
            $decorrido = 0
            $intervalo = 5

            while ($decorrido -lt $timeout) {
                Start-Sleep -Seconds $intervalo
                $decorrido += $intervalo
                $estado = (Get-VM -Name $Cfg.VMName).State
                Write-Status INFO ("Estado atual: {0} ({1} s)" -f $estado, $decorrido)
                if ($estado -eq 'Running') { break }
            }
        }

        return $true
    }
    catch {
        Write-Host ""
        Write-Status ERRO ("Falha durante a criação: {0}" -f $_.Exception.Message)

        if ($vmCriada -or $discoCopiado) {
            $vhdParaLimpar = if ($discoCopiado) { $Cfg.VHDXDestino } else { $null }
            $vmParaLimpar  = if ($vmCriada)     { $Cfg.VMName }      else { '' }

            if ($vmParaLimpar) {
                Remove-CriacaoParcial -VMName $vmParaLimpar -CaminhoVHDX $vhdParaLimpar -PastaVM $Cfg.PastaVM
            }
            elseif ($vhdParaLimpar) {
                Write-Status AVISO ("O disco já copiado permaneceu em: {0}" -f $vhdParaLimpar)
                if (Read-Confirmacao -Pergunta 'Deseja remover o disco copiado?' -Padrao 'N') {
                    Remove-Item -LiteralPath $vhdParaLimpar -Force -ErrorAction SilentlyContinue
                    Write-Status OK 'Disco copiado removido.'
                }
            }
        }

        return $false
    }
}


# ============================================================
#  Resumo final da VM criada
# ============================================================
function Show-ResumoFinal {
    param([Parameter(Mandatory = $true)][psobject]$Cfg)

    Show-Header ("RESUMO DA VM CRIADA: {0}" -f $Cfg.VMName)

    $vm = Get-VM -Name $Cfg.VMName -ErrorAction SilentlyContinue
    if (-not $vm) {
        Write-Status AVISO 'A VM não pôde ser consultada para o resumo.'
        return
    }

    $proc = Get-VMProcessor -VMName $Cfg.VMName
    $mem  = Get-VMMemory    -VMName $Cfg.VMName
    $nic  = Get-VMNetworkAdapter -VMName $Cfg.VMName | Select-Object -First 1

    Write-Host ("    Nome...............: {0}" -f $vm.Name)
    Write-Host ("    Estado.............: {0}" -f $vm.State)
    Write-Host ("    Geracao / versao...: {0} / {1}" -f $vm.Generation, $vm.Version)
    Write-Host ("    vCPUs..............: {0}" -f $proc.Count)
    Write-Host ("    Virt. Aninhada.....: {0}" -f $(if ($proc.ExposeVirtualizationExtensions) { 'Habilitada' } else { 'Desabilitada' }))

    if ($mem.DynamicMemoryEnabled) {
        Write-Host ("    Memoria............: dinamica {0} GB a {1} GB (inicial {2} GB)" -f `
                        [math]::Round($mem.Minimum/1GB,0), [math]::Round($mem.Maximum/1GB,0), [math]::Round($mem.Startup/1GB,0))
    } else {
        Write-Host ("    Memoria............: {0} GB (fixa)" -f [math]::Round($mem.Startup/1GB, 0))
    }

    Write-Host ("    Diretorio da VM....: {0}" -f $vm.Path)
    Write-Host ("    Origem (template)..: {0}" -f $Cfg.Template.Nome) -ForegroundColor Yellow

    Write-Host ""
    Write-Host "    --- Discos ---" -ForegroundColor Cyan
    foreach ($hd in (Get-VMHardDiskDrive -VMName $Cfg.VMName)) {
        $tam = ''
        try {
            $v = Get-VHD -Path $hd.Path -ErrorAction Stop
            $tam = "{0} virtual  |  {1} em disco  |  {2}" -f (Format-Tamanho $v.Size), (Format-Tamanho $v.FileSize), $v.VhdType
        } catch { $tam = '(nao foi possivel ler o VHDX)' }

        Write-Host ("      {0} {1}:{2}  ->  {3}" -f $hd.ControllerType, $hd.ControllerNumber, $hd.ControllerLocation, $hd.Path)
        Write-Host ("          {0}" -f $tam) -ForegroundColor DarkGray
    }

    $dvds = @(Get-VMDvdDrive -VMName $Cfg.VMName -ErrorAction SilentlyContinue)
    if ($dvds.Count -gt 0) {
        Write-Host ""
        Write-Host "    --- Unidades de DVD ---" -ForegroundColor Cyan
        foreach ($d in $dvds) {
            $midia = if ($d.Path) { $d.Path } else { '(vazia)' }
            Write-Host ("      {0}:{1}  ->  {2}" -f $d.ControllerNumber, $d.ControllerLocation, $midia)
        }
    }

    Write-Host ""
    Write-Host "    --- Rede ---" -ForegroundColor Cyan
    Write-Host ("      Adaptador........: {0}" -f $nic.Name)
    Write-Host ("      Switch...........: {0}" -f $nic.SwitchName)
    Write-Host ("      MAC Spoofing.....: {0}" -f $nic.MacAddressSpoofing)

    try {
        $vlan = Get-VMNetworkAdapterVlan -VMName $Cfg.VMName -VMNetworkAdapterName $Cfg.NICName -ErrorAction Stop
        if ($vlan.OperationMode -eq 'Access') {
            Write-Host ("      VLAN.............: Access, ID {0}" -f $vlan.AccessVlanId) -ForegroundColor Yellow
        } else {
            Write-Host ("      VLAN.............: {0}" -f $vlan.OperationMode)
        }
    }
    catch { }

    if ($vm.Generation -eq 2) {
        Write-Host ""
        Write-Host "    --- Seguranca ---" -ForegroundColor Cyan
        try {
            $fw  = Get-VMFirmware -VMName $Cfg.VMName
            $sec = Get-VMSecurity -VMName $Cfg.VMName
            Write-Host ("      Secure Boot......: {0}" -f $fw.SecureBoot)
            Write-Host ("      TPM (vTPM).......: {0}" -f $(if ($sec.TpmEnabled) { 'Habilitado' } else { 'Desabilitado' })) -ForegroundColor $(if ($sec.TpmEnabled) { 'Yellow' } else { 'Gray' })
        }
        catch { }
    }

    Write-Host ""
    Write-Host "  ------------------------------------------------------------" -ForegroundColor DarkGray

    if ($vm.State -eq 'Running') {
        Write-Host "  A VM esta rodando e dando boot pelo disco copiado do template."          -ForegroundColor Cyan
        Write-Host ("  Abra o Hyper-V Manager e conecte-se a '{0}' para concluir o OOBE/Sysprep." -f $Cfg.VMName) -ForegroundColor Cyan
    } else {
        Write-Host ("  A VM foi criada e esta DESLIGADA. Inicie com: Start-VM -Name '{0}'" -f $Cfg.VMName) -ForegroundColor Cyan
    }

    if ($Cfg.ExpandirDisco) {
        Write-Host ""
        Write-Host "  Disco expandido: estenda a particao dentro do sistema convidado." -ForegroundColor Yellow
        Write-Host "    Windows: diskmgmt.msc  ou  Resize-Partition"                     -ForegroundColor DarkGray
        Write-Host "    Linux..: growpart + resize2fs / xfs_growfs"                       -ForegroundColor DarkGray
    }

    if ($Cfg.HabilitarTPM) {
        Write-Host ""
        Write-Host "  vTPM ativo: esta VM esta vinculada ao key protector deste host." -ForegroundColor Yellow
        Write-Host "  Para move-la, exporte o key protector antes (Get-VMKeyProtector)." -ForegroundColor DarkGray
    }

    if ($Cfg.EnableNested) {
        Write-Host ""
        Write-Host "  Virtualizacao Aninhada ATIVA. Dentro da VM, habilite o Hyper-V:"                      -ForegroundColor Cyan
        Write-Host "    Windows Server : Install-WindowsFeature -Name Hyper-V -IncludeManagementTools -Restart" -ForegroundColor DarkGray
        Write-Host "    Windows 10/11  : Enable-WindowsOptionalFeature -Online -FeatureName Microsoft-Hyper-V -All" -ForegroundColor DarkGray
    }
}


# ============================================================
#  PROGRAMA PRINCIPAL
# ============================================================
Clear-Host
Show-Header 'CRIACAO DE MAQUINAS VIRTUAIS A PARTIR DE TEMPLATES (.VHDX) - HYPER-V  v2.0'

if (-not (Test-AmbienteHyperV)) {
    Write-Host ""
    Write-Host "  Execucao interrompida." -ForegroundColor Red
    Write-Host ""
    exit 1
}

$InfoHost = Get-InfoHost

# ---------- Diretórios de trabalho (perguntados uma única vez) ----------
Show-Secao 'Diretorios de trabalho'

$TemplateDir = Read-Diretorio -Pergunta 'Diretorio dos TEMPLATES (.vhdx)'   -Padrao $Padroes.TemplateDir
$VMPath      = Read-Diretorio -Pergunta 'Diretorio raiz das MAQUINAS VIRTUAIS' -Padrao $Padroes.VMPath -CriarSeNecessario
$ISODir      = $Padroes.ISODir

Write-Status OK ("Templates: {0}" -f $TemplateDir)
Write-Status OK ("VMs......: {0}" -f $VMPath)

# ---------- Laço principal: cria quantas VMs o operador quiser ----------
$criadas   = @()
$ultimaCfg = $null

do {
    Show-Header 'ASSISTENTE DE CRIACAO DE MAQUINA VIRTUAL'

    $cfg = $null

    # A partir da segunda VM, oferece repetir tudo o que já foi respondido.
    # Útil para subir um laboratório inteiro do mesmo template: só o nome muda.
    if ($ultimaCfg) {
        Show-ConfiguracaoAnterior -Cfg $ultimaCfg

        if (Read-Confirmacao -Pergunta 'Reaproveitar esta configuracao e mudar so o nome?' -Padrao 'S') {
            Show-Secao 'Identificação da Máquina Virtual'
            $novoNome = Read-NomeVM

            $cfg = Copy-ConfiguracaoVM -Base $ultimaCfg -NovoNome $novoNome

            if ($null -eq $cfg) {
                Write-Status AVISO 'Não foi possível reaproveitar a configuração anterior.'
                Write-Status INFO  'Abrindo o assistente completo.'
            }
        }
    }

    if ($null -eq $cfg) {
        $cfg = Read-ConfiguracaoVM -TemplateDir $TemplateDir `
                                   -VMPath      $VMPath `
                                   -ISODir      $ISODir `
                                   -Padroes     $Padroes `
                                   -InfoHost    $InfoHost
    }

    if ($null -eq $cfg) {
        Write-Host ""
        Write-Status INFO 'Assistente encerrado sem criar a VM.'
    }
    elseif (-not (Show-ResumoConfiguracao -Cfg $cfg)) {
        Write-Host ""
        Write-Status AVISO 'Operação cancelada pelo operador. Nada foi alterado no host.'
    }
    else {
        Show-Header ("CRIANDO A VM '{0}'" -f $cfg.VMName)

        if (Invoke-CriacaoVM -Cfg $cfg) {
            # A VM já está criada. Uma falha ao apenas CONSULTAR dados para o
            # relatório não pode derrubar o script (e perder o laço de criação
            # em série) depois de uma cópia que pode ter levado muitos minutos.
            try {
                Show-ResumoFinal -Cfg $cfg
            }
            catch {
                Write-Status AVISO ("A VM foi criada, mas o resumo final falhou: {0}" -f $_.Exception.Message)
                Write-Status INFO  ("Consulte com: Get-VM -Name '{0}' | Format-List *" -f $cfg.VMName)
            }
            $criadas  += $cfg.VMName

            # Só uma criação bem-sucedida vira base para o modo rápido: repetir
            # uma configuração que acabou de falhar apenas repetiria a falha.
            $ultimaCfg = $cfg
        }
        else {
            Write-Host ""
            Write-Status ERRO ("A VM '{0}' não foi criada." -f $cfg.VMName)
        }
    }

    Write-Host ""
    $outra = Read-Confirmacao -Pergunta 'Deseja criar OUTRA maquina virtual a partir de um template?' -Padrao 'N'

} while ($outra)

# ---------- Encerramento ----------
Write-Host ""
Show-Header 'ENCERRAMENTO'

if ($criadas.Count -gt 0) {
    Write-Status OK ("{0} máquina(s) virtual(is) criada(s) nesta sessão:" -f $criadas.Count)
    foreach ($n in $criadas) { Write-Host ("      - {0}" -f $n) -ForegroundColor White }
} else {
    Write-Status INFO 'Nenhuma máquina virtual foi criada nesta sessão.'
}

Write-Host ""
Write-Host "  Obrigado por usar o assistente. Ate a proxima!" -ForegroundColor Cyan
Write-Host ""
