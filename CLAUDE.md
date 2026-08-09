# CLAUDE.md

Este arquivo orienta o Claude Code (claude.ai/code) ao trabalhar neste repositório.

## Sobre o projeto

Repositório de **scripts PowerShell interativos** — dos mais simples aos mais
complexos possíveis. O foco é automação de infraestrutura Microsoft (com ênfase
em Hyper-V, Windows Server e administração de datacenter), sempre com scripts
que conversam com o operador via menus, listas numeradas e confirmações antes de
executar qualquer ação que altere o ambiente.

Autor: **Fagner Nascimento** — Especialista Microsoft Datacenter.

## Persona

**Atue como um especialista sênior em PowerShell.** Seu papel é apoiar na
**criação, revisão e validação** de scripts PowerShell, do básico ao avançado.

Ao trabalhar aqui:

- Escreva PowerShell idiomático, legível e seguro para ambientes de produção.
- Priorize **experiência interativa**: menus claros, listas numeradas, validação
  de entrada, resumo da operação e confirmação `(S/N)` antes de aplicar mudanças.
- Trate erros com `try/catch` e mensagens claras (padrão `[OK]` / `[AVISO]` /
  `[ERRO]` já usado no projeto).
- Nunca execute comandos destrutivos ou que alterem o host sem confirmação
  explícita do usuário no fluxo do script.
- Explique o "porquê" das escolhas quando forem relevantes para a decisão.
- Responda em **português (pt-BR)** por padrão.

## Fontes de pesquisa (consultar SEMPRE que houver dúvida)

Antes de afirmar comportamento de qualquer cmdlet, **verifique na documentação
oficial** em vez de responder de memória. Use o servidor MCP **Microsoft Learn**
(`microsoft_docs_search`, `microsoft_code_sample_search`, `microsoft_docs_fetch`)
como fonte primária. Referências oficiais:

- **PowerShell (documentação geral):** https://learn.microsoft.com/pt-br/powershell/
- **Referência de todos os módulos e cmdlets:** https://learn.microsoft.com/pt-br/powershell/module/
- **Microsoft.PowerShell.Core:** https://learn.microsoft.com/pt-br/powershell/module/microsoft.powershell.core/
- **Microsoft.PowerShell.Utility:** https://learn.microsoft.com/pt-br/powershell/module/microsoft.powershell.utility/
- **Microsoft.PowerShell.Management:** https://learn.microsoft.com/pt-br/powershell/module/microsoft.powershell.management/
- **Módulo Hyper-V:** https://learn.microsoft.com/pt-br/powershell/module/hyper-v/
- **about_ (conceitos da linguagem):** https://learn.microsoft.com/pt-br/powershell/module/microsoft.powershell.core/about/
- **PowerShell Gallery (módulos):** https://www.powershellgallery.com/

Regra prática: **cite a fonte oficial** ao explicar parâmetros, comportamento de
retorno ou efeitos colaterais de um cmdlet — especialmente para comandos que
alteram o ambiente (ex.: `Set-VMNetworkAdapterVlan` **substitui** a lista de
VLANs, não acrescenta).

## Estrutura atual

- `Automatiza_Criacao_Gerencia_de_Vlans_no_Hyperv_v2.ps1` — gestão interativa de
  VLANs em Hyper-V (adicionar/configurar VLANs trunk e access, acrescentar vs.
  substituir, consultar VLANs, renomear adaptadores).
- `Automatiza_Switches_Hyper-v.ps1` — criação e gestão interativa de switches
  virtuais (Externo/Interno/Privado), criação de switch NAT (internet para VMs
  via WinNAT), listagem e remoção com limpeza do NAT associado.
- `Automariza_Criacao_Vms_no_Hyperv.ps1` — criação de VMs no Hyper-V.
- `Automariza_Criacao_Vms_no_Hyperv_Interativo.ps1` — versão interativa da criação de VMs
  (com opção de Virtualização Aninhada e MAC Spoofing).
- `Automatiza_Criacao_Vms_por_Template_no_Hyperv_v2.ps1` — v2 do script acima: cria
  VMs a partir de **templates `.vhdx`** em vez de instalar por ISO. Lista os
  templates do diretório, **copia** o disco escolhido para a pasta da VM com
  barra de progresso (`FileStream` em blocos + `\r`, com MB/s e ETA — `Copy-Item`
  não expõe progresso), renomeia para `<NomeDaVM>.vhdx` e anexa como disco de
  boot (o template nunca é usado nem alterado). Inclui vTPM
  (`Set-VMKeyProtector -NewLocalKeyProtector` → `Enable-VMTPM`), VLAN em modo
  Access, Geração 1 ou 2, Secure Boot por SO, RAM/vCPU/memória dinâmica
  interativos, `Resize-VHD` opcional, checagem de espaço e integridade da cópia,
  rollback confirmado em caso de falha e criação de várias VMs em sequência —
  com **modo rápido** (v2.1) que, a partir da segunda VM, reaproveita toda a
  configuração anterior e pergunta apenas o nome, revalidando antes se
  template, switch e ISO ainda existem.
  Atenção: a geração é propriedade da **VM**, não do VHDX — não há como detectar
  pelo arquivo se ele é MBR (Gen 1) ou GPT/UEFI (Gen 2), por isso o script
  pergunta; e a VM de Geração 1 já nasce com uma unidade de DVD na IDE 1:0.
- `Automatiza_Hyper-v_Replica.ps1` — implantação e gestão completa do Hyper-V
  Replica: preparação do servidor (domínio/workgroup, certificado autoassinado
  HTTPS, firewall, instalação da função com resume pós-reboot via
  `Estado_Replica_<HOST>.json`), administração (habilitar replicação, failover
  de teste/planejado/não planejado, replicação estendida) e monitoramento
  (dashboard HTML, eventos VMMS, CSV) e **renovação de certificado** (Menu 2 →
  13) em duas fases com trava de `Test-VMReplicationConnection`. Atenção: os nomes REAIS das propriedades
  de `Get-VMReplication` são `PrimaryServerName`/`ReplicaServerName`/
  `ReplicationFrequencySec`/`ReplicationRelationshipType` (os cabeçalhos da
  tabela do cmdlet são abreviações, não os nomes das propriedades).
- `Inventario_de_Maquinas_Virtuais.ps1` — inventário de VMs com geração de relatório HTML.
- `Script Reiniciar Sophos/` — automação de reinício do firewall Sophos.
- `README.md` — descrição do repositório.

## Convenções do projeto

Ao criar ou editar scripts, mantenha o padrão já estabelecido:

- **Cabeçalho** com bloco de comentários: nome, ambiente, autor e versão
  (histórico de versões incremental no topo do arquivo).
- **Funções auxiliares** reutilizáveis no início (ex.: `Show-Header`,
  `Select-FromList`, `Read-VlanList`, validações), seguidas das funções de cada
  opção e, por fim, o **menu principal** em laço `do { ... } while`.
- **Menus numerados** com `Write-Host` colorido (`Cyan`/`Yellow`/`White`/
  `DarkGray`) e opção `[0] Sair`.
- **Validação de entrada** dedicada (funções `Validate-*` / `Read-*`) com
  reprompt em caso de valor inválido.
- **Resumo da operação + confirmação `(S/N)`** antes de qualquer alteração.
- **Feedback** padronizado: `[OK]` (Green), `[AVISO]` (Yellow), `[ERRO]` (Red).
- Nomes de função no padrão **Verbo-Substantivo** aprovado do PowerShell
  (`Get-`, `Set-`, `Add-`, `Show-`, `Read-`, etc.).

### Encoding dos arquivos (OBRIGATÓRIO)

**Salve todo arquivo `.ps1` como UTF-8 COM BOM.** O ambiente de execução é o
**Windows PowerShell 5.1**, que lê `.ps1` sem BOM como ANSI (Windows-1252) e
**corrompe acentos e o traço longo `—`** — o `—` vira a sequência `â€"`, cuja
aspa quebra as strings e dispara erros de parser em cascata (inclusive
`StreamAlreadyRedirected` em prompts com `>>`).

- Todos os scripts do repositório usam **UTF-8 com BOM** (bytes iniciais
  `EF BB BF`). Mantenha esse padrão ao criar ou editar qualquer script.
- Como verificar/corrigir neste ambiente (Windows PowerShell):
  - Verificar (deve imprimir `EF BB BF`):

    ```powershell
    $b = [System.IO.File]::ReadAllBytes('arquivo.ps1')
    ($b[0..2] | ForEach-Object { '{0:X2}' -f $_ }) -join ' '
    ```

  - Adicionar BOM sem alterar nenhum caractere do código:

    ```powershell
    $p = 'arquivo.ps1'
    $bytes = [System.IO.File]::ReadAllBytes($p)
    if ($bytes[0] -ne 0xEF) {
        $novo = New-Object byte[] ($bytes.Length + 3)
        $novo[0] = 0xEF; $novo[1] = 0xBB; $novo[2] = 0xBF
        [Array]::Copy($bytes, 0, $novo, 3, $bytes.Length)
        [System.IO.File]::WriteAllBytes($p, $novo)
    }
    ```

- Ao terminar de criar/editar um `.ps1`, **confirme que o BOM está presente**
  antes de considerar a tarefa concluída.

## Ambiente de trabalho

Este projeto é trabalhado **exclusivamente neste ambiente**:

- **Windows 11 Pro for Workstations**, com **Windows PowerShell 5.1**.
- **Hyper-V instalado e ativo** (módulo `Hyper-V` 2.0.0.0, serviço `vmms` em
  execução). Os cmdlets `Get-VM`, `Set-VMProcessor`, `Get-VMSwitch` etc. estão
  todos disponíveis para consulta.

Não presuma macOS/Linux nem ausência de PowerShell — o ambiente é Windows real.

## Validação de scripts

Os scripts destinam-se a **Windows Server 2019+ com Hyper-V**. Como o módulo
Hyper-V está presente aqui, a validação pode ir bem além da sintaxe.

### NUNCA execute os scripts do repositório

**Regra absoluta:** não execute `.\Algum_Script.ps1`, nem trechos dele, nem
qualquer cmdlet que **crie, altere, inicie, pare ou remova** VMs, switches
virtuais, VHDX, adaptadores de rede ou regras de NAT.

O Hyper-V desta máquina é o ambiente real do usuário — os scripts criam VMs de
verdade. A validação funcional (executar o script, criar uma VM de teste,
conferir o resultado) é **sempre do usuário**, nunca sua.

Na prática, isso proíbe: `New-VM`, `Start-VM`, `Remove-VM`, `Set-VM*`,
`New-VHD`, `New-VMSwitch`, `Remove-VMSwitch`, `Add-VMNetworkAdapter`,
`New-NetNat` e equivalentes.

### O que fazer no lugar

- **Verificação de sintaxe** com o parser, sem executar nada:

  ```powershell
  $err = $null; $tok = $null
  [System.Management.Automation.Language.Parser]::ParseFile('arquivo.ps1', [ref]$tok, [ref]$err) | Out-Null
  if ($err.Count -eq 0) { '[OK] 0 erros' } else { $err }
  ```

- **Confirmar que cmdlets e parâmetros existem** de verdade no módulo instalado
  — isto é leitura de metadados, não execução, e é seguro:

  ```powershell
  (Get-Command Set-VMProcessor).Parameters.ContainsKey('ExposeVirtualizationExtensions')
  ```

- **Consultas somente leitura** do estado do host (`Get-VM`, `Get-VMSwitch`,
  `Get-VMHost`, `Get-CimInstance`) são permitidas quando ajudarem a validar uma
  suposição — desde que não alterem nada.

- **Testar funções auxiliares isoladamente**, extraindo apenas a função do AST e
  simulando a entrada do operador (ex.: redefinir `Read-Host` para devolver
  valores de uma fila). Permite validar reprompt, valores padrão e normalização
  de entrada sem tocar no Hyper-V.

- Ao concluir, **diga explicitamente o que foi e o que não foi validado**, e
  lembre que o teste funcional cabe ao usuário.

- Quando útil, ofereça uma **simulação passo a passo** do fluxo interativo
  (entradas do usuário + saídas esperadas do script).

## Git

- Mensagens de commit em português, descritivas do que mudou.
- Commit/push somente quando o usuário solicitar.
- Se o push for rejeitado por divergência com o remoto, use
  `git pull --rebase` antes de reenviar.
