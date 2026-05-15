# ============================================================
#  Inventario de Maquinas Virtuais - Hyper-V
#  Ambiente: Windows Server 2019 ou superior / Hyper-V instalado
#  v1.1 - Relatorio HTML5 gerado localmente
# Instrucoes de uso abaixo::
# Salve o arquivo em um diretorio abra o powershell como administrador e exeute .\Inventario-de_Maquinas_Virtuais.ps1
# ============================================================

# ============================================================
# 0. Verificar disponibilidade do modulo Hyper-V
# ============================================================
Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   INVENTARIO DE MAQUINAS VIRTUAIS - HYPER-V" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Try {
    if (-not (Get-Module -ListAvailable -Name Hyper-V)) {
        Write-Host "[ERRO] O modulo Hyper-V nao esta disponivel neste sistema." -ForegroundColor Red
        Write-Host "       Execute este script diretamente no host Hyper-V com o papel instalado." -ForegroundColor Red
        exit 1
    }

    Import-Module Hyper-V -ErrorAction Stop
    Write-Host "[OK] Modulo Hyper-V carregado com sucesso." -ForegroundColor Green
}
Catch {
    Write-Host "[ERRO] Falha ao carregar o modulo Hyper-V: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# ============================================================
# 1. Coletar todas as VMs do host local
# ============================================================
Write-Host ""
Write-Host "[INFO] Coletando informacoes das maquinas virtuais..." -ForegroundColor Cyan

Try {
    $VMs = @(Get-VM | Sort-Object Name)
}
Catch {
    Write-Host "[ERRO] Falha ao listar as VMs: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

if ($VMs.Count -eq 0) {
    Write-Host "[AVISO] Nenhuma maquina virtual encontrada neste host Hyper-V." -ForegroundColor Yellow
    exit 0
}

Write-Host "[OK] $($VMs.Count) VM(s) encontrada(s)." -ForegroundColor Green

# ============================================================
# 2. Montar estrutura de dados de cada VM
# ============================================================
$DataColeta  = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
$NomeHost    = $env:COMPUTERNAME
$RegistrosVM = [System.Collections.Generic.List[hashtable]]::new()

$totalVCPU      = 0
$totalMemGB     = 0.0
$totalDiskMaxGB = 0.0
$totalDiskUsGB  = 0.0
$countRunning   = 0
$countOff       = 0
$countOther     = 0
$countGen1      = 0
$countGen2      = 0

foreach ($VM in $VMs) {
    Write-Host "  >> Processando: $($VM.Name)" -ForegroundColor DarkGray

    # --- Discos ---
    $DisksHTML = ""
    Try {
        $HDs = @(Get-VMHardDiskDrive -VMName $VM.Name -ErrorAction Stop)
        if ($HDs.Count -gt 0) {
            $DisksHTML = "<ul class='disk-list'>"
            foreach ($HD in $HDs) {
                Try {
                    $VHDInfo   = Get-VHD -Path $HD.Path -ErrorAction Stop
                    $MaxGB     = [math]::Round($VHDInfo.Size          / 1GB, 2)
                    $UsedGB    = [math]::Round($VHDInfo.FileSize      / 1GB, 2)
                    $PctUsed   = if ($MaxGB -gt 0) { [math]::Round(($UsedGB / $MaxGB) * 100, 0) } else { 0 }
                    $BarColor  = if ($PctUsed -ge 85) { "#e74c3c" } elseif ($PctUsed -ge 65) { "#f39c12" } else { "#27ae60" }
                    $FileName  = Split-Path $HD.Path -Leaf

                    $totalDiskMaxGB += $MaxGB
                    $totalDiskUsGB  += $UsedGB

                    $DisksHTML += @"
<li>
  <span class='disk-name'>$FileName</span>
  <span class='disk-info'>Max: <strong>${MaxGB} GB</strong> &nbsp;|&nbsp; Em disco: <strong>${UsedGB} GB</strong></span>
  <div class='disk-bar-bg'><div class='disk-bar-fill' style='width:${PctUsed}%;background:${BarColor}'></div></div>
  <span class='disk-pct' style='color:${BarColor}'>${PctUsed}%</span>
</li>
"@
                }
                Catch {
                    $DisksHTML += "<li><span class='disk-name'>$(Split-Path $HD.Path -Leaf)</span> <span class='disk-err'>(sem acesso ao VHD)</span></li>"
                }
            }
            $DisksHTML += "</ul>"
        } else {
            $DisksHTML = "<span class='na'>Sem discos</span>"
        }
    }
    Catch {
        $DisksHTML = "<span class='disk-err'>Erro ao ler discos</span>"
    }

    # --- Sistema Operacional (via Notas da VM) ---
    $SistemaOP = "-"
    Try {
        if ($VM.Notes -and $VM.Notes.Trim() -ne "") {
            $SistemaOP = $VM.Notes.Trim()
        }
    }
    Catch { }

    # --- Tempo de Atividade ---
    $UptimeHTML = "<span class='na'>&mdash;</span>"
    if ($VM.State -eq "Running" -and $VM.Uptime.TotalSeconds -gt 0) {
        $up = $VM.Uptime
        $UptimeHTML = "$($up.Days)d $($up.Hours)h $($up.Minutes)m"
    }

    # --- Memoria ---
    $MemGB = [math]::Round($VM.MemoryAssigned / 1GB, 2)

    # --- Acumuladores de totalizadores ---
    $totalVCPU  += $VM.ProcessorCount
    $totalMemGB += $MemGB

    switch ($VM.State) {
        "Running" { $countRunning++ }
        "Off"     { $countOff++ }
        Default   { $countOther++ }
    }

    if ($VM.Generation -eq 1) { $countGen1++ } else { $countGen2++ }

    $RegistrosVM.Add(@{
        Name          = $VM.Name
        State         = $VM.State.ToString()
        OS            = $SistemaOP
        Generation    = $VM.Generation
        ProcessorCount= $VM.ProcessorCount
        MemGB         = $MemGB
        DynMem        = $VM.DynamicMemoryEnabled
        DisksHTML     = $DisksHTML
        UptimeHTML    = $UptimeHTML
    })
}

Write-Host ""
Write-Host "[OK] Coleta de dados concluida." -ForegroundColor Green

# ============================================================
# 3. Helpers para o HTML
# ============================================================
function Get-StateBadge {
    param([string]$State)
    $map = @{
        "Running" = @{ css = "badge-running"; label = "Running"  }
        "Off"     = @{ css = "badge-off";     label = "Off"      }
        "Saved"   = @{ css = "badge-saved";   label = "Saved"    }
        "Paused"  = @{ css = "badge-paused";  label = "Paused"   }
    }
    $entry = $map[$State]
    if (-not $entry) { $entry = @{ css = "badge-other"; label = $State } }
    return "<span class='badge $($entry.css)'>$($entry.label)</span>"
}

function Format-StorageDisplay {
    param([double]$GB)
    if ($GB -ge 1024) {
        return "$([math]::Round($GB / 1024, 2)) TB"
    }
    return "$([math]::Round($GB, 2)) GB"
}

# ============================================================
# 4. Montar as linhas da tabela HTML
# ============================================================
$TabelaLinhas = ""
$rowIndex     = 0

foreach ($r in $RegistrosVM) {
    $rowClass  = if ($rowIndex % 2 -eq 0) { "row-even" } else { "row-odd" }
    $dynMem    = if ($r.DynMem) { "<span class='badge badge-dyn'>Sim</span>" } else { "<span class='na'>Nao</span>" }
    $stateBadge = Get-StateBadge -State $r.State

    $TabelaLinhas += @"
<tr class='$rowClass'>
  <td class='td-name'>$($r.Name)</td>
  <td class='td-center'>$stateBadge</td>
  <td>$($r.OS)</td>
  <td class='td-center'>Gen $($r.Generation)</td>
  <td class='td-center'>$($r.ProcessorCount)</td>
  <td class='td-center'>$($r.MemGB) GB</td>
  <td class='td-center'>$dynMem</td>
  <td>$($r.DisksHTML)</td>
  <td class='td-center'>$($r.UptimeHTML)</td>
</tr>
"@
    $rowIndex++
}

# ============================================================
# 5. Montar cards de totalizadores
# ============================================================
$StorageMaxDisplay = Format-StorageDisplay -GB $totalDiskMaxGB
$StorageUsDisplay  = Format-StorageDisplay -GB $totalDiskUsGB
$TotalMemDisplay   = "$([math]::Round($totalMemGB, 2)) GB"

$CardsHTML = @"
<div class='cards-grid'>
  <div class='card'>
    <div class='card-value'>$($VMs.Count)</div>
    <div class='card-label'>Total de VMs</div>
  </div>
  <div class='card card-running'>
    <div class='card-value'>$countRunning</div>
    <div class='card-label'>Em Execucao</div>
  </div>
  <div class='card card-off'>
    <div class='card-value'>$countOff</div>
    <div class='card-label'>Desligadas</div>
  </div>
  <div class='card card-other'>
    <div class='card-value'>$countOther</div>
    <div class='card-label'>Outros Estados</div>
  </div>
  <div class='card'>
    <div class='card-value'>$totalVCPU</div>
    <div class='card-label'>Total vCPUs</div>
  </div>
  <div class='card'>
    <div class='card-value'>$TotalMemDisplay</div>
    <div class='card-label'>Memoria Total Alocada</div>
  </div>
  <div class='card'>
    <div class='card-value'>$StorageMaxDisplay</div>
    <div class='card-label'>Armazenamento Provisionado</div>
  </div>
  <div class='card'>
    <div class='card-value'>$StorageUsDisplay</div>
    <div class='card-label'>Armazenamento Consumido</div>
  </div>
  <div class='card'>
    <div class='card-value'>$countGen1 <small>/ $countGen2</small></div>
    <div class='card-label'>VMs Gen 1 / Gen 2</div>
  </div>
</div>
"@

# ============================================================
# 6. Montar o documento HTML completo
# ============================================================
$HTML = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>Inventario Hyper-V - $NomeHost</title>
  <style>
    *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }

    body {
      font-family: 'Segoe UI', system-ui, -apple-system, sans-serif;
      background: #f0f2f5;
      color: #1a1a2e;
      min-height: 100vh;
    }

    /* ---- Cabecalho ---- */
    header {
      background: linear-gradient(135deg, #0d1117 0%, #161b22 60%, #1f2937 100%);
      color: #e6edf3;
      padding: 28px 36px;
      display: flex;
      align-items: center;
      gap: 24px;
      box-shadow: 0 4px 20px rgba(0,0,0,.45);
    }
    .header-icon {
      font-size: 2.8rem;
      flex-shrink: 0;
    }
    header h1 {
      font-size: 1.55rem;
      font-weight: 700;
      letter-spacing: .3px;
      line-height: 1.2;
    }
    header .sub {
      font-size: .85rem;
      color: #8b949e;
      margin-top: 6px;
    }
    header .sub span {
      color: #58a6ff;
      font-weight: 600;
    }

    /* ---- Layout principal ---- */
    main {
      max-width: 1600px;
      margin: 0 auto;
      padding: 32px 24px;
    }

    /* ---- Cards totalizadores ---- */
    .section-title {
      font-size: .75rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 1.2px;
      color: #6b7280;
      margin-bottom: 14px;
    }

    .cards-grid {
      display: grid;
      grid-template-columns: repeat(auto-fill, minmax(160px, 1fr));
      gap: 16px;
      margin-bottom: 36px;
    }
    .card {
      background: #fff;
      border-radius: 12px;
      padding: 20px 18px;
      box-shadow: 0 2px 8px rgba(0,0,0,.07);
      border-top: 4px solid #58a6ff;
      text-align: center;
      transition: transform .15s, box-shadow .15s;
    }
    .card:hover { transform: translateY(-3px); box-shadow: 0 6px 18px rgba(0,0,0,.12); }
    .card-running { border-top-color: #27ae60; }
    .card-off     { border-top-color: #e74c3c; }
    .card-other   { border-top-color: #f39c12; }
    .card-value {
      font-size: 1.9rem;
      font-weight: 800;
      color: #0d1117;
      line-height: 1;
    }
    .card-value small { font-size: 1.1rem; color: #6b7280; }
    .card-label {
      font-size: .75rem;
      color: #6b7280;
      margin-top: 8px;
      font-weight: 600;
      text-transform: uppercase;
      letter-spacing: .6px;
    }

    /* ---- Tabela ---- */
    .table-wrapper {
      background: #fff;
      border-radius: 14px;
      box-shadow: 0 2px 12px rgba(0,0,0,.08);
      overflow-x: auto;
    }
    table {
      width: 100%;
      border-collapse: collapse;
      font-size: .875rem;
    }
    thead tr {
      background: #0d1117;
      color: #c9d1d9;
    }
    thead th {
      padding: 14px 16px;
      text-align: left;
      font-size: .72rem;
      font-weight: 700;
      text-transform: uppercase;
      letter-spacing: 1px;
      white-space: nowrap;
    }
    tbody tr.row-even { background: #fff; }
    tbody tr.row-odd  { background: #f8fafc; }
    tbody tr:hover    { background: #eef4ff; }
    td {
      padding: 12px 16px;
      vertical-align: top;
      border-bottom: 1px solid #e5e7eb;
    }
    .td-name {
      font-weight: 700;
      color: #1a1a2e;
      white-space: nowrap;
    }
    .td-center { text-align: center; vertical-align: middle; }
    .na { color: #9ca3af; font-style: italic; }

    /* ---- Badges de estado ---- */
    .badge {
      display: inline-block;
      padding: 3px 10px;
      border-radius: 20px;
      font-size: .72rem;
      font-weight: 700;
      letter-spacing: .5px;
      text-transform: uppercase;
    }
    .badge-running { background: #dcfce7; color: #166534; }
    .badge-off     { background: #fee2e2; color: #991b1b; }
    .badge-saved   { background: #fef9c3; color: #713f12; }
    .badge-paused  { background: #ffedd5; color: #7c2d12; }
    .badge-other   { background: #f3f4f6; color: #374151; }
    .badge-dyn     { background: #dbeafe; color: #1e40af; }

    /* ---- Lista de discos ---- */
    .disk-list {
      list-style: none;
      padding: 0;
      display: flex;
      flex-direction: column;
      gap: 10px;
      min-width: 260px;
    }
    .disk-list li {
      display: flex;
      flex-direction: column;
      gap: 3px;
    }
    .disk-name {
      font-size: .78rem;
      font-weight: 700;
      color: #374151;
      word-break: break-all;
    }
    .disk-info {
      font-size: .75rem;
      color: #6b7280;
    }
    .disk-bar-bg {
      height: 6px;
      background: #e5e7eb;
      border-radius: 4px;
      overflow: hidden;
      margin-top: 2px;
    }
    .disk-bar-fill {
      height: 100%;
      border-radius: 4px;
      transition: width .3s;
    }
    .disk-pct {
      font-size: .7rem;
      font-weight: 700;
    }
    .disk-err { color: #ef4444; font-size: .78rem; }

    /* ---- Footer ---- */
    footer {
      text-align: center;
      padding: 24px;
      font-size: .78rem;
      color: #9ca3af;
    }
  </style>
</head>
<body>

<header>
  <div class="header-icon">&#128187;</div>
  <div>
    <h1>Inventario de Maquinas Virtuais - Hyper-V</h1>
    <div class="sub">
      Host: <span>$NomeHost</span>
      &nbsp;&nbsp;|&nbsp;&nbsp;
      Coleta realizada em: <span>$DataColeta</span>
    </div>
  </div>
</header>

<main>

  <p class="section-title">Resumo do Host</p>
  $CardsHTML

  <p class="section-title">Maquinas Virtuais</p>
  <div class="table-wrapper">
    <table>
      <thead>
        <tr>
          <th>Nome da VM</th>
          <th>Estado</th>
          <th>Sistema Operacional</th>
          <th>Geracao</th>
          <th>vCPUs</th>
          <th>Memoria Atribuida</th>
          <th>Mem. Dinamica</th>
          <th>Discos Virtuais</th>
          <th>Tempo de Atividade</th>
        </tr>
      </thead>
      <tbody>
        $TabelaLinhas
      </tbody>
    </table>
  </div>

</main>

<footer>
  Inventario gerado automaticamente pelo script <strong>Inventario-MaquinasVirtuais.ps1</strong>
  &nbsp;|&nbsp; $DataColeta
</footer>

</body>
</html>
"@

# ============================================================
# 7. Salvar o arquivo HTML e abrir no navegador
# ============================================================
$ReportPath = Join-Path $PSScriptRoot "Inventario-MaquinasVirtuais_$(Get-Date -Format 'yyyyMMdd_HHmmss').html"

Try {
    $HTML | Out-File -FilePath $ReportPath -Encoding UTF8 -ErrorAction Stop
    Write-Host "[OK] Relatorio salvo em: $ReportPath" -ForegroundColor Green
}
Catch {
    Write-Host "[ERRO] Nao foi possivel salvar o relatorio: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

Write-Host "[INFO] Abrindo relatorio no navegador padrao..." -ForegroundColor Cyan
Start-Process $ReportPath

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  INVENTARIO CONCLUIDO COM SUCESSO!"         -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "  Total de VMs...........: $($VMs.Count)"
Write-Host "  Em execucao............: $countRunning"
Write-Host "  Desligadas..............: $countOff"
Write-Host "  Outros estados..........: $countOther"
Write-Host "  Total de vCPUs..........: $totalVCPU"
Write-Host "  Memoria total alocada...: $TotalMemDisplay"
Write-Host "  Storage provisionado....: $StorageMaxDisplay"
Write-Host "  Storage consumido.......: $StorageUsDisplay"
Write-Host ""
