


# =============================================================================
# CONFIGURAÇÃO DE LOG
# =============================================================================
$LogFile = "$env:SystemDrive\Logs\Reverse-Config_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"
New-Item -ItemType Directory -Force -Path (Split-Path $LogFile) | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'SECTION')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'INFO' { '[INFO ]' }
        'WARN' { '[AVISO]' }
        'ERROR' { '[ERRO ]' }
        'OK' { '[ OK  ]' }
        'SECTION' { "`n[=====]" }
    }
    $line = "$timestamp $prefix $Message"
    $line | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor $(
        switch ($Level) {
            'OK' { 'Green' }
            'WARN' { 'Yellow' }
            'ERROR' { 'Red' }
            'SECTION' { 'Cyan' }
            default { 'White' }
        }
    )
}

# =============================================================================
# HELPERS
# =============================================================================
function Invoke-SafeCommand {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Log "Iniciando: $Description"
    try {
        & $Action
        Write-Log "Concluído: $Description" -Level OK
        return $true
    }
    catch {
        Write-Log "Falha em: $Description | Erro: $_" -Level ERROR
        return $false
    }
}

function Set-GPRegistryValue {
    param([string]$Path, [string]$Name, [string]$Type, $Value)
    if (-not (Test-Path $Path)) {
        New-Item -Path $Path -Force | Out-Null
    }
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Type $Type -Force
}

function Remove-GPRegistryKey {
    param([string]$Path, [string]$Name)
    if (Test-Path $Path) {
        $prop = Get-ItemProperty -Path $Path -Name $Name -ErrorAction SilentlyContinue
        if ($prop) {
            Remove-ItemProperty -Path $Path -Name $Name -Force
            Write-Log "Chave removida: $Path\$Name" -Level OK
        }
        else {
            Write-Log "Chave não encontrada (já limpa): $Path\$Name" -Level WARN
        }
    }
    else {
        Write-Log "Caminho não existe (já limpo): $Path" -Level WARN
    }
}

# =============================================================================
# MÓDULO 1 — REVERSÃO DAS POLÍTICAS DE GRUPO (GPEDIT)
# =============================================================================
function Invoke-RevertGroupPolicies {
    Write-Log "MÓDULO 1 — Reversão das Políticas de Grupo (gpedit)" -Level SECTION

    # ------------------------------------------------------------------
    # 1.1 POLÍTICA DE SENHA (Configuração do Computador > Configurações
    #     do Windows > Configurações de Segurança > Diretivas de Conta
    #     > Política de Senha)
    # Configurações aplicadas:
    #   - Histórico de senhas habilitado (imposição de histórico)
    #   - Comprimento mínimo de senha (típico: 8 caracteres)
    #   - Senha deve satisfazer requisitos de complexidade: Habilitado
    # Reversão: restaurar valores padrão do Windows 11 (sem restrições)
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter política de senha — histórico, complexidade, comprimento" {
        # Ferramenta nativa: net accounts
        net accounts /MINPWLEN:0 /MAXPWAGE:UNLIMITED /MINPWAGE:0 /UNIQUEPW:0 | Out-Null
        Write-Log "  net accounts: histórico=0, complexidade=off, comprimento mín=0" -Level INFO

        # Via secedit — desabilitar complexidade e histórico no registro de segurança local
        $seceditInf = @"
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordAge = 0
MaximumPasswordAge = -1
MinimumPasswordLength = 0
PasswordComplexity = 0
PasswordHistorySize = 0
[Version]
signature="`$CHICAGO`$"
Revision = 1
"@
        $tmpInf = "$env:TEMP\reverse_passwd.inf"
        $tmpDb = "$env:TEMP\reverse_passwd.sdb"
        $seceditInf | Out-File -FilePath $tmpInf -Encoding Unicode -Force
        secedit /configure /db $tmpDb /cfg $tmpInf /areas SECURITYPOLICY /quiet
        Remove-Item $tmpInf, $tmpDb -Force -ErrorAction SilentlyContinue
    }

    # ------------------------------------------------------------------
    # 1.2 DIRETIVA DE BLOQUEIO DE CONTA
    # Configurações aplicadas no manual: bloqueio de conta habilitado
    # Reversão: zerar limiar de bloqueio (desabilita o recurso)
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter diretiva de bloqueio de conta" {
        net accounts /LOCKOUTTHRESHOLD:0 | Out-Null
        Write-Log "  Limiar de bloqueio definido como 0 (desabilitado)" -Level INFO
    }

    # ------------------------------------------------------------------
    # 1.3 LOG DE AUDITORIA (Audit Policy)
    # Configurações aplicadas: auditoria de logon, acesso a objetos, etc.
    # Reversão: desabilitar todas as categorias de auditoria
    # ⚠ AMBIGUIDADE: O PDF menciona "Log de Auditoria" e "Diretivas de Log"
    #   mas não lista valores exatos. A reversão abaixo desabilita o que
    #   tipicamente é habilitado em manuais de AR ICP-Brasil.
    #   Revise se necessário antes de executar em produção.
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter auditoria — desabilitar todas as categorias" {
        # 1. Desabilitar via secedit (políticas básicas de auditoria — visível no gpedit.msc)
        $seceditAuditInf = @"
[Unicode]
Unicode=yes
[Event Audit]
AuditSystemEvents = 0
AuditLogonEvents = 0
AuditObjectAccess = 0
AuditPrivilegeUse = 0
AuditPolicyChange = 0
AuditAccountManage = 0
AuditProcessTracking = 0
AuditDSAccess = 0
AuditAccountLogon = 0
[Version]
signature="`$CHICAGO`$"
Revision=1
"@
        $tmpAuditInf = "$env:TEMP\reverse_audit.inf"
        $tmpAuditDb = "$env:TEMP\reverse_audit.sdb"

        $seceditAuditInf | Out-File -FilePath $tmpAuditInf -Encoding Unicode -Force
        $seceditResult = secedit /configure /db $tmpAuditDb /cfg $tmpAuditInf /areas SECURITYPOLICY /quiet 2>&1
        Remove-Item $tmpAuditInf, $tmpAuditDb -Force -ErrorAction SilentlyContinue

        if ($LASTEXITCODE -ne 0) {
            Write-Log "  AVISO: secedit retornou código $LASTEXITCODE — $seceditResult" -Level WARN
        }

        # 2. Desabilitar explicitamente Êxito e Falha em TODAS as categorias (auditpol básico)
        auditpol /set /category:* /success:disable /failure:disable | Out-Null

        # 3. Limpar também as subcategorias avançadas de auditoria
        auditpol /clear /y | Out-Null

        Write-Log "  Auditorias desabilitadas (Eventos, Logon, Acesso a Objetos, Privilégios, etc.)" -Level INFO
    }

    # ------------------------------------------------------------------
    # 1.3.9  (LOG E BACKUP E LIMPEZA DO GPEDIT)
    # Configurações aplicadas:
    #   - Especificar o tamanho máximo do arquivo de log (KB)
    #   - Fazer backup do log automaticamente quando cheio
    # Reversão: Limpar o Registry.pol (GPO Local) e as chaves de registro
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter log de eventos e limpar cache do gpedit" {
        $regPath = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security"

        # 1. Remove as chaves de registro efetivas
        $valuesToRemove = @("MaxSize", "AutoBackupLogFiles")
        foreach ($value in $valuesToRemove) {
            if (Test-Path $regPath) {
                Remove-ItemProperty -Path $regPath -Name $value -Force -ErrorAction SilentlyContinue
                Write-Log "  Removido registro: $regPath\$value" -Level INFO
            }
        }

        # 2. Deleta o arquivo Registry.pol para refletir no gpedit.msc como "Não configurado"
        $machinePol = "$env:windir\System32\GroupPolicy\Machine\Registry.pol"
        if (Test-Path $machinePol) {
            Remove-Item -Path $machinePol -Force -ErrorAction SilentlyContinue
            Write-Log "  Arquivo de cache do GPO (Machine\Registry.pol) removido." -Level INFO
        }
        
        # Opcional: Se quiser limpar também as políticas de Usuário do gpedit
        $userPol = "$env:windir\System32\GroupPolicy\User\Registry.pol"
        if (Test-Path $userPol) {
            Remove-Item -Path $userPol -Force -ErrorAction SilentlyContinue
            Write-Log "  Arquivo de cache do GPO (User\Registry.pol) removido." -Level INFO
        }

        Write-Log "  Políticas revertidas para Não-configurado no gpedit." -Level INFO
    }

    # ------------------------------------------------------------------
    # 1.4 PROTEÇÃO DE TELA (Screen Saver)
    # Configurações aplicadas: timeout padrão 120 segundos, protegida por senha
    # Reversão: desabilitar proteção de tela via GPO
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter proteção de tela (GPO)" {

        # Caminhos de política (GPO local) — HKLM e HKCU
        $gpoPathLM = "HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop"
        $gpoPathCU = "HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop"

        # Valores que a configuração original aplicou
        $ssValues = @("ScreenSaveActive", "ScreenSaverIsSecure", "ScreenSaveTimeOut")

        # Remove os valores de GPO local (HKLM e HKCU), se existirem
        foreach ($regPath in @($gpoPathLM, $gpoPathCU)) {
            if (Test-Path $regPath) {
                foreach ($val in $ssValues) {
                    $exists = Get-ItemProperty -Path $regPath -Name $val -ErrorAction SilentlyContinue
                    if ($null -ne $exists) {
                        Remove-ItemProperty -Path $regPath -Name $val -Force -ErrorAction SilentlyContinue
                        Write-Log "  Removido: $regPath\$val" -Level INFO
                    }
                }
            }
            else {
                Write-Log "  GPO já limpa (caminho ausente): $regPath" -Level INFO
            }
        }

        # Aplica a preferência real do usuário — desliga proteção de tela
        $userDesktop = "HKCU:\Control Panel\Desktop"
        Set-ItemProperty -Path $userDesktop -Name "ScreenSaveActive"    -Value "0" -Type String
        Set-ItemProperty -Path $userDesktop -Name "ScreenSaverIsSecure" -Value "0" -Type String
        Set-ItemProperty -Path $userDesktop -Name "ScreenSaveTimeOut"   -Value "900" -Type String  # padrão Windows: 15min (nunca ativa pois ScreenSaveActive=0)

        Write-Log "  Proteção de tela desabilitada via registro do usuário" -Level INFO
    }

    # ------------------------------------------------------------------
    # 1.5 SERVIÇO NTP (Sincronização de horário)
    # Configurações aplicadas: servidores tic.syngularid.com.br,
    #   tac.syngularid.com.br, a.ntp.br
    # Reversão: restaurar servidores NTP padrão da Microsoft
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Reverter serviço NTP — restaurar servidores padrão" {

        # 1. Parar o serviço antes de alterar registros
        Stop-Service W32Time -Force -ErrorAction SilentlyContinue

        # 2. Desregistrar e re-registrar o W32Time para limpar configurações customizadas
        #    Isso restaura os valores padrão do registro sem precisar editar chave por chave
        w32tm /unregister | Out-Null
        w32tm /register   | Out-Null

        # 3. Restaurar chave Parameters (servidor e tipo)
        $paramsPath = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\Parameters"
        Set-ItemProperty -Path $paramsPath -Name "NtpServer" -Value "time.windows.com,0x9" -Type String
        Set-ItemProperty -Path $paramsPath -Name "Type"      -Value "NTP"                  -Type String

        # 4. Restaurar NtpClient (usado pelo painel de controle — Internet Time)
        $ntpClientPath = "HKLM:\SYSTEM\CurrentControlSet\Services\W32Time\TimeProviders\NtpClient"
        Set-ItemProperty -Path $ntpClientPath -Name "Enabled"              -Value 1          -Type DWord
        Set-ItemProperty -Path $ntpClientPath -Name "NtpServer"            -Value "time.windows.com,0x9" -Type String
        Set-ItemProperty -Path $ntpClientPath -Name "SpecialPollInterval"  -Value 604800     -Type DWord

        # 5. Restaurar lista de servidores visível no painel de controle (Data e Hora → Internet Time)
        $dateTimePath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\DateTime\Servers"
        if (-not (Test-Path $dateTimePath)) {
            New-Item -Path $dateTimePath -Force | Out-Null
        }
        # Remove entradas antigas e recria com o padrão
        Get-Item -Path $dateTimePath | Select-Object -ExpandProperty Property |
        Where-Object { $_ -match '^\d+$' } |
        ForEach-Object { Remove-ItemProperty -Path $dateTimePath -Name $_ -Force -ErrorAction SilentlyContinue }

        Set-ItemProperty -Path $dateTimePath -Name "(Default)" -Value "0"              -Type String
        Set-ItemProperty -Path $dateTimePath -Name "0"         -Value "time.windows.com" -Type String
        Set-ItemProperty -Path $dateTimePath -Name "1"         -Value "time.nist.gov"    -Type String

        # 6. Remover possíveis políticas de GPO local que sobrescrevem a config
        $gpNtpPath = "HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters"
        if (Test-Path $gpNtpPath) {
            Remove-Item -Path $gpNtpPath -Recurse -Force -ErrorAction SilentlyContinue
            Write-Log "  Política de GPO local de NTP removida" -Level INFO
        }

        # 7. Aplicar via w32tm e reiniciar
        Start-Service W32Time
        w32tm /config /manualpeerlist:"time.windows.com,0x9" /syncfromflags:manual /reliable:YES /update | Out-Null
        Restart-Service W32Time -Force
        w32tm /resync /force | Out-Null
        Write-Log "  NTP reconfigurado para time.windows.com" -Level INFO
    }


    # ------------------------------------------------------------------
    # 1.6 FORÇAR ATUALIZAÇÃO DO GPEDIT (gpupdate)
    # Aplica todas as remoções de política imediatamente
    # ------------------------------------------------------------------
    Invoke-SafeCommand "Executar gpupdate /force para aplicar remoções de política" {
        gpupdate /force /wait:0 | Out-Null
    }
}

# =============================================================================
# MÓDULO 2 — ELEVAR CONTAS LOCAIS ATIVAS AO GRUPO ADMINISTRADORES
# =============================================================================
function Invoke-ElevateLocalAccounts {
    Write-Log "MÓDULO 2 — Elevar contas locais ativas ao grupo Administradores" -Level SECTION

    # Contas a EXCLUIR da elevação automática:
    #   - PC_Admin  → será desabilitada no Módulo 4 (não elevar antes)
    #   - Contas já desabilitadas → ignorar conforme requisito
    $excludedAccounts = @("PC_Admin")

    $localUsers = Get-LocalUser | Where-Object {
        $_.Enabled -eq $true -and
        $_.Name -notin $excludedAccounts
    }

    if (-not $localUsers) {
        Write-Log "Nenhuma conta local ativa encontrada (exceto PC_Admin)." -Level WARN
        return
    }

    foreach ($user in $localUsers) {
        Invoke-SafeCommand "Elevar '$($user.Name)' ao grupo Administradores" {
            $isMember = (Get-LocalGroupMember -Group "Administradores" -ErrorAction SilentlyContinue) +
            (Get-LocalGroupMember -Group "Administrators"  -ErrorAction SilentlyContinue) |
            Where-Object { $_.Name -like "*$($user.Name)" }
            if ($isMember) {
                Write-Log "  '$($user.Name)' já é membro de Administradores — sem alteração." -Level WARN
            }
            else {
                try {
                    Add-LocalGroupMember -Group "Administradores" -Member $user.Name -ErrorAction Stop
                }
                catch {
                    Add-LocalGroupMember -Group "Administrators" -Member $user.Name -ErrorAction Stop
                }
                Write-Log "  '$($user.Name)' adicionado ao grupo Administradores." -Level OK
            }
        }
    }
}

# =============================================================================
# MÓDULO 3 — REMOVER PREFIXO "AGR-" E SENHA DO USUÁRIO CRIADO
# =============================================================================
function Invoke-ResetUsuarioAGR {
    Write-Log "MÓDULO 3 — Remover prefixo 'AGR-' e senha do usuário local" -Level SECTION

    $usuariosAGR = Get-LocalUser | Where-Object { $_.Name -like "*AGR-*" -or $_.FullName -like "*AGR-*" }

    if (-not $usuariosAGR) {
        Write-Log "Nenhum usuário com 'AGR-' no nome foi encontrado." -Level WARN
        return
    }

    foreach ($user in $usuariosAGR) {
        $nomeAntigo = $user.Name
        $nomeNovo = $nomeAntigo -replace "AGR-", ""
        $fullNameAntigo = $user.FullName
        $fullNameNovo = $fullNameAntigo -replace "AGR-", ""

        Invoke-SafeCommand "Renomear '$nomeAntigo' para '$nomeNovo', ajustar Nome completo e remover senha" {
            if ($nomeNovo -ne $nomeAntigo) {
                if (Get-LocalUser -Name $nomeNovo -ErrorAction SilentlyContinue) {
                    throw "Já existe um usuário chamado '$nomeNovo' — renomeação cancelada."
                }
                Rename-LocalUser -Name $nomeAntigo -NewName $nomeNovo -ErrorAction Stop
                Write-Log "  Usuário renomeado: '$nomeAntigo' -> '$nomeNovo'" -Level OK
            }

            if ($fullNameNovo -ne $fullNameAntigo) {
                Set-LocalUser -Name $nomeNovo -FullName $fullNameNovo -ErrorAction Stop
                Write-Log "  Nome completo ajustado: '$fullNameAntigo' -> '$fullNameNovo'" -Level OK
            }

            net user "$nomeNovo" "" | Out-Null
            Write-Log "  Senha removida do usuário '$nomeNovo'." -Level OK
        }
    }
}

# =============================================================================
# MÓDULO 4 — DESABILITAR BITLOCKER
# =============================================================================
function Invoke-DisableBitLocker {
    Write-Log "MÓDULO 4 — Desabilitar BitLocker" -Level SECTION

    $drives = Get-BitLockerVolume -ErrorAction SilentlyContinue
    if (-not $drives) {
        Write-Log "Nenhum volume BitLocker encontrado ou módulo não disponível." -Level WARN
        return
    }

    foreach ($vol in $drives) {
        $drive = $vol.MountPoint
        $status = $vol.VolumeStatus

        Write-Log "Volume $drive — Status: $status"

        if ($status -eq "FullyDecrypted") {
            Write-Log "  $drive já está descriptografado — ignorando." -Level WARN
            continue
        }

        Invoke-SafeCommand "Desabilitar BitLocker no volume $drive" {
            Disable-BitLocker -MountPoint $drive -ErrorAction Stop | Out-Null
            Write-Log "  Descriptografia iniciada em $drive (pode levar alguns minutos)." -Level OK
        }
    }

    Write-Log "A descriptografia foi iniciada e continuará em segundo plano. O script prosseguirá imediatamente." -Level INFO
    Write-Log "Verifique o progresso manualmente com 'manage-bde -status' se necessário." -Level INFO
}

# =============================================================================
# MÓDULO 6 — REMOVER SENHA DE ACESSO NAO SUPERVISIONADO DO ANYDESK
# =============================================================================
function Invoke-RemoveAnyDeskPassword {
    Write-Log "MÓDULO 6 — Remover senha do AnyDesk" -Level SECTION

    $exeCandidates = @(
        "$env:ProgramFiles(x86)\AnyDesk\AnyDesk.exe",
        "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
        "$env:ProgramData\AnyDesk\AnyDesk.exe"
    )
    $anydeskExe = $exeCandidates | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

    if (-not $anydeskExe) {
        Write-Log "AnyDesk não encontrado nesta máquina — nada a fazer." -Level WARN
        return
    }

    Invoke-SafeCommand "Remover senha de acesso não supervisionado do AnyDesk" {
        & $anydeskExe --remove-password | Out-Null
        Write-Log "  Comando '--remove-password' executado em: $anydeskExe" -Level OK
    }
}

# =============================================================================
# MÓDULO 7 — ATIVAR CONTA ADMINISTRATOR PADRAO DO WINDOWS
# =============================================================================
function Invoke-EnableDefaultAdministrator {
    Write-Log "MÓDULO 7 — Ativar conta Administrator padrão do Windows" -Level SECTION

    # RID 500 identifica a conta Administrator built-in independente de idioma/renomeação
    $account = Get-LocalUser | Where-Object { $_.SID -like "*-500" }

    if (-not $account) {
        Write-Log "Conta Administrator (RID 500) não encontrada." -Level WARN
        return
    }

    if ($account.Enabled) {
        Write-Log "Conta '$($account.Name)' já está habilitada — sem alteração." -Level WARN
        return
    }

    Invoke-SafeCommand "Habilitar conta '$($account.Name)' (Administrator padrão)" {
        Enable-LocalUser -Name $account.Name -ErrorAction Stop
        Write-Log "  Conta '$($account.Name)' habilitada com sucesso." -Level OK
    }
}

# =============================================================================
# MÓDULO 5 — DESABILITAR CONTA PC_Admin (SEMPRE POR ÚLTIMO)
# =============================================================================
function Invoke-DisablePCAdmin {
    Write-Log "MÓDULO 4 — Desabilitar conta PC_Admin (etapa final)" -Level SECTION

    $account = Get-LocalUser -Name "PC_Admin" -ErrorAction SilentlyContinue
    if (-not $account) {
        Write-Log "Conta 'PC_Admin' não encontrada na máquina." -Level WARN
        return
    }

    if (-not $account.Enabled) {
        Write-Log "Conta 'PC_Admin' já está desabilitada — sem alteração." -Level WARN
        return
    }

    Invoke-SafeCommand "Desabilitar conta 'PC_Admin'" {
        Disable-LocalUser -Name "PC_Admin" -ErrorAction Stop
        Write-Log "  Conta 'PC_Admin' desabilitada com sucesso." -Level OK
    }
}

# =============================================================================
# PONTO DE ENTRADA — EXECUÇÃO SEQUENCIAL OBRIGATÓRIA
# =============================================================================
Write-Log "==========================================================" -Level SECTION
Write-Log "  INÍCIO DO PROCESSO DE REVERSÃO — Syngular Config v1.4"
Write-Log "  Máquina  : $env:COMPUTERNAME"
Write-Log "  Usuário  : $env:USERNAME"
Write-Log "  Data/Hora: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss')"
Write-Log "  Log      : $LogFile"
Write-Log "==========================================================" -Level SECTION

# Verificação de privilégio administrativo
if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Log "ERRO CRÍTICO: Execute este script como Administrador!" -Level ERROR
    exit 1
}

# ── Execução na ordem obrigatória ─────────────────────────────────────────────
Invoke-RevertGroupPolicies    # Módulo 1 — GPO / gpedit
Invoke-ElevateLocalAccounts   # Módulo 2 — Contas locais → Administradores
Invoke-ResetUsuarioAGR        # Módulo 3 — Remover prefixo AGR- e senha
Invoke-DisableBitLocker       # Módulo 4 — BitLocker
Invoke-RemoveAnyDeskPassword  # Módulo 6 — Senha AnyDesk
Invoke-EnableDefaultAdministrator  # Módulo 7 — Ativar Administrator padrão
Invoke-DisablePCAdmin         # Módulo 5 — PC_Admin (SEMPRE POR ÚLTIMO)

Write-Log "==========================================================" -Level SECTION
Write-Log "  REVERSÃO CONCLUÍDA"
Write-Log "  Log completo salvo em: $LogFile"
Write-Log "==========================================================" -Level SECTION
