
[CmdletBinding()]
param(
    [switch]$Apply,
    [ValidateSet('All', 'SecurityPolicy', 'LocalGpo', 'ScreenSaver', 'TimeService', 'LocalAccounts', 'BitLocker', 'AnyDesk')]
    [string[]]$Modules = @('All'),
    [switch]$AllowSecurityWeakening,
    [switch]$AllowAccountChanges,
    [switch]$AllowBlankPassword,
    [switch]$AllowBitLockerDecryption,
    [switch]$AllowRemoteAccessChange,
    [string[]]$ElevateUser = @(),
    [string[]]$BitLockerDrive = @(),
    [switch]$NormalizeAgrUser,
    [switch]$RemoveAgrPassword,
    [switch]$EnableBuiltInAdministrator,
    [switch]$DisablePCAdmin,
    [string]$RollbackPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:Failures = 0
$script:ChangedModules = New-Object System.Collections.Generic.List[string]
$script:SkippedModules = New-Object System.Collections.Generic.List[string]
$script:LogFile = $null
$script:BackupPath = $null

function Get-WindowsEdition {
    if ($env:OS -ne 'Windows_NT') {
        throw 'Este script so pode ser executado no Windows.'
    }

    $os = Get-CimInstance -ClassName Win32_OperatingSystem
    $currentVersion = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
    [pscustomobject]@{
        Caption   = [string]$os.Caption
        Build     = [string]$os.BuildNumber
        EditionId = [string]$currentVersion.EditionID
        Product   = [string]$currentVersion.ProductName
        Sku       = [int]$os.OperatingSystemSKU
    }
}

$script:Edition = Get-WindowsEdition
if ($script:Edition.EditionId -notin @('Professional', 'ProfessionalN')) {
    Write-Error ("Execucao interrompida: este script aceita somente Windows Pro/Pro N. " +
        "Edicao detectada: '{0}' ({1}). Nenhuma alteracao foi feita." -f
        $script:Edition.EditionId, $script:Edition.Caption)
    exit 2
}

$script:BasePath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$script:ScriptPath = if ($PSCommandPath) { $PSCommandPath } else { $null }
$script:LogFile = Join-Path $script:BasePath 'debloat_execution.log'

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK', 'SECTION')][string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $prefix = switch ($Level) {
        'INFO'    { '[INFO ]' }
        'WARN'    { '[AVISO]' }
        'ERROR'   { '[ERRO ]' }
        'OK'      { '[ OK  ]' }
        'SECTION' { '[=====]' }
    }
    $line = "$timestamp $prefix $Message"
    Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    $color = switch ($Level) {
        'OK'      { 'Green' }
        'WARN'    { 'Yellow' }
        'ERROR'   { 'Red' }
        'SECTION' { 'Cyan' }
        default   { 'White' }
    }
    Write-Host $line -ForegroundColor $color
}

function Test-Administrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Abra o PowerShell como Administrador e execute o script novamente.'
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [string]$Description = $FilePath
    )
    if (-not (Get-Command $FilePath -ErrorAction SilentlyContinue)) {
        throw "Comando nativo nao encontrado: $FilePath"
    }

    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }

    if ($exitCode -ne 0) {
        $detail = (($output | Out-String).Trim() -replace '\s+', ' ')
        throw "$Description falhou com codigo $exitCode. $detail"
    }
    return $output
}

function Invoke-ModuleSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    Write-Log "MODULO: $Name" -Level SECTION
    $succeeded = $false
    try {
        Test-EssentialIntegrity -Stage "antes de $Name"
        & $Action
        Test-EssentialIntegrity -Stage "depois de $Name"
        $script:ChangedModules.Add($Name)
        $succeeded = $true
        Write-Log "Concluido: $Name" -Level OK
    }
    catch {
        $script:Failures++
        Write-Log "Falha no modulo '$Name': $($_.Exception.Message)" -Level ERROR
    }
    finally {
        if (-not $succeeded) {
            Write-Log "Finally: '$Name' terminou sem confirmacao de integridade." -Level WARN
        }
    }
}

function Convert-RegKeyToProviderPath {
    param([Parameter(Mandatory)][string]$RegKey)
    switch -Regex ($RegKey) {
        '^HKLM\\' { return $RegKey -replace '^HKLM', 'Registry::HKEY_LOCAL_MACHINE' }
        '^HKCU\\' { return $RegKey -replace '^HKCU', 'Registry::HKEY_CURRENT_USER' }
        '^HKCR\\' { return $RegKey -replace '^HKCR', 'Registry::HKEY_CLASSES_ROOT' }
        default { throw "Raiz de registro nao suportada: $RegKey" }
    }
}

function Backup-RegistryKey {
    param(
        [Parameter(Mandatory)][string]$RegKey,
        [Parameter(Mandatory)][string]$Destination
    )
    $providerPath = Convert-RegKeyToProviderPath $RegKey
    if (-not (Test-Path -LiteralPath $providerPath)) {
        Write-Log "Backup ignorado; chave ausente: $RegKey" -Level INFO
        return
    }
    $output = Invoke-Native -FilePath 'reg.exe' -ArgumentList @('export', $RegKey, $Destination, '/y') `
        -Description "Backup do registro $RegKey"
    Write-Log "Backup do registro criado: $Destination" -Level OK
}

function Remove-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$RegKey,
        [Parameter(Mandatory)][string]$Name
    )
    $path = Convert-RegKeyToProviderPath $RegKey
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Log "Chave ausente; nada a remover: $RegKey" -Level INFO
        return
    }
    $item = Get-Item -LiteralPath $path
    if ($item.GetValueNames() -contains $Name) {
        Remove-ItemProperty -LiteralPath $path -Name $Name -Force -ErrorAction Stop
        Write-Log "Valor removido: $RegKey\$Name" -Level OK
    }
    else {
        Write-Log "Valor ja ausente: $RegKey\$Name" -Level INFO
    }
}

function Set-RegistryValueSafe {
    param(
        [Parameter(Mandatory)][string]$RegKey,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][ValidateSet('String', 'DWord')][string]$Type,
        [Parameter(Mandatory)]$Value
    )
    $path = Convert-RegKeyToProviderPath $RegKey
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -Path $path -Force | Out-Null
    }
    New-ItemProperty -LiteralPath $path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
}

function Test-EssentialIntegrity {
    param([Parameter(Mandatory)][string]$Stage)
    $os = Get-WindowsEdition
    if ($os.EditionId -notin @('Professional', 'ProfessionalN')) {
        throw "A edicao do Windows mudou durante a execucao: $($os.EditionId)."
    }

    foreach ($serviceName in @('RpcSs', 'EventLog', 'CryptSvc', 'BFE', 'Winmgmt')) {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            throw "Servico essencial ausente apos ${Stage}: $serviceName"
        }
    }

    $defender = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if ($null -ne $defender) {
        Write-Log "Integridade ${Stage}: WinDefend=$($defender.Status), StartType=$($defender.StartType)" -Level INFO
    }
    Write-Log "Integridade validada ${Stage}: $($os.Caption), build $($os.Build)" -Level OK
}

function New-RestorePointRequired {
    if ($WhatIfPreference) {
        Write-Log 'WhatIf: ponto de restauracao nao sera criado.' -Level INFO
        return
    }
    try {
        Checkpoint-Computer -Description 'Reverse-Config.Safe pre-change' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de restauracao criado.' -Level OK
    }
    catch {
        throw ("Nao foi possivel criar o ponto de restauracao. Nenhuma alteracao sera aplicada. " +
            "O Windows pode limitar a um ponto a cada 24 horas ou estar com a Protecao do Sistema desativada. " +
            $_.Exception.Message)
    }
}

function Save-SafetyBackup {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $script:BackupPath = Join-Path (Join-Path $script:BasePath 'backups') $stamp
    New-Item -ItemType Directory -Path $script:BackupPath -Force | Out-Null

    $registryKeys = @(
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security',
        'HKLM\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop',
        'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop',
        'HKCU\Control Panel\Desktop',
        'HKLM\SYSTEM\CurrentControlSet\Services\W32Time',
        'HKLM\SOFTWARE\Policies\Microsoft\W32Time',
        'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\DateTime\Servers'
    )
    $index = 0
    foreach ($key in $registryKeys) {
        $index++
        $file = Join-Path $script:BackupPath ("registry_{0:D2}.reg" -f $index)
        Backup-RegistryKey -RegKey $key -Destination $file
    }

    Invoke-Native -FilePath 'secedit.exe' -ArgumentList @(
        '/export', '/cfg', (Join-Path $script:BackupPath 'security_policy.inf'),
        '/areas', 'SECURITYPOLICY', 'USER_RIGHTS'
    ) -Description 'Export da politica de seguranca local' | Out-Null
    $auditBackup = Join-Path $script:BackupPath 'audit_policy.csv'
    Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @(
        '/backup', "/file:$auditBackup"
    ) -Description 'Backup da auditoria de seguranca' | Out-Null

    if (Get-Command Get-LocalUser -ErrorAction SilentlyContinue) {
        Get-LocalUser | Select-Object Name, Enabled, SID, Description, FullName, PasswordRequired |
            ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:BackupPath 'local_users.json') -Encoding UTF8
        Get-LocalGroup | ForEach-Object {
            $group = $_
            Get-LocalGroupMember -Group $group.Name -ErrorAction SilentlyContinue |
                Select-Object @{Name='Group'; Expression={$group.Name}}, Name, SID, ObjectClass
        } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $script:BackupPath 'local_groups.json') -Encoding UTF8
    }

    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        Get-BitLockerVolume | Select-Object MountPoint, VolumeStatus, EncryptionPercentage, ProtectionStatus, VolumeType,
            @{Name='KeyProtectorSummary'; Expression={ $_.KeyProtector | Select-Object KeyProtectorType, KeyProtectorId }} |
            ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $script:BackupPath 'bitlocker_state.json') -Encoding UTF8
    }

    $scriptHash = if ($script:ScriptPath -and (Test-Path -LiteralPath $script:ScriptPath -PathType Leaf)) {
        (Get-FileHash -LiteralPath $script:ScriptPath -Algorithm SHA256).Hash
    }
    else {
        'unavailable-scriptblock-execution'
    }

    [pscustomobject]@{
        CreatedAt = (Get-Date).ToString('o')
        Computer  = $env:COMPUTERNAME
        User      = "$env:USERDOMAIN\$env:USERNAME"
        Edition   = $script:Edition
        ScriptSha256 = $scriptHash
        Warning   = 'Backups HKCU representam somente o usuario que executou este script; nenhum segredo foi exportado.'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $script:BackupPath 'manifest.json') -Encoding UTF8

    Write-Log "Backups concluídos em: $script:BackupPath" -Level OK
}

function Invoke-SecurityPolicy {
    if (-not $AllowSecurityWeakening) {
        $script:SkippedModules.Add('SecurityPolicy')
        Write-Log 'SecurityPolicy ignorado: exige -AllowSecurityWeakening.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'SecurityPolicy' {
        $inf = Join-Path $env:TEMP ('reverse_security_{0}.inf' -f [guid]::NewGuid())
        $sdb = Join-Path $env:TEMP ('reverse_security_{0}.sdb' -f [guid]::NewGuid())
        try {
            @'
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordAge = 0
MaximumPasswordAge = -1
MinimumPasswordLength = 0
PasswordComplexity = 0
PasswordHistorySize = 0
[Version]
signature="$CHICAGO$"
Revision = 1
'@ | Set-Content -LiteralPath $inf -Encoding Unicode
            Invoke-Native -FilePath 'secedit.exe' -ArgumentList @('/configure', '/db', $sdb, '/cfg', $inf, '/areas', 'SECURITYPOLICY') `
                -Description 'Reversao da politica de senha' | Out-Null
            Invoke-Native -FilePath 'net.exe' -ArgumentList @('accounts', '/LOCKOUTTHRESHOLD:0') `
                -Description 'Desativacao do bloqueio de conta' | Out-Null
            Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @('/set', '/category:*', '/success:disable', '/failure:disable') `
                -Description 'Desativacao da auditoria' | Out-Null
            Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @('/clear', '/y') `
                -Description 'Limpeza da politica avancada de auditoria' | Out-Null
            Write-Log 'ATENCAO: politicas de senha, bloqueio e auditoria foram enfraquecidas.' -Level WARN
        }
        finally {
            Remove-Item -LiteralPath $inf, $sdb -Force -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-LocalGpo {
    if (-not $AllowSecurityWeakening) {
        $script:SkippedModules.Add('LocalGpo')
        Write-Log 'LocalGpo ignorado: exige -AllowSecurityWeakening.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'LocalGpo' {
        $targets = @(
            @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security'; Name = 'MaxSize' },
            @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security'; Name = 'AutoBackupLogFiles' },
            @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveActive' },
            @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaverIsSecure' },
            @{ Key = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveTimeOut' },
            @{ Key = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveActive' },
            @{ Key = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaverIsSecure' },
            @{ Key = 'HKCU\Software\Policies\Microsoft\Windows\Control Panel\Desktop'; Name = 'ScreenSaveTimeOut' }
        )
        foreach ($target in $targets) {
            Remove-RegistryValueSafe -RegKey $target.Key -Name $target.Name
        }
        Write-Log 'Registry.pol nao foi removido; somente valores conhecidos foram tratados.' -Level INFO
        Invoke-Native -FilePath 'gpupdate.exe' -ArgumentList @('/target:computer', '/force', '/wait:0') `
            -Description 'Atualizacao da politica do computador' | Out-Null
    }
}

function Invoke-ScreenSaver {
    if (-not $AllowSecurityWeakening) {
        $script:SkippedModules.Add('ScreenSaver')
        Write-Log 'ScreenSaver ignorado: exige -AllowSecurityWeakening.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'ScreenSaver' {
        $desktop = 'HKCU\Control Panel\Desktop'
        Set-RegistryValueSafe -RegKey $desktop -Name 'ScreenSaveActive' -Type String -Value '0'
        Set-RegistryValueSafe -RegKey $desktop -Name 'ScreenSaverIsSecure' -Type String -Value '0'
        Set-RegistryValueSafe -RegKey $desktop -Name 'ScreenSaveTimeOut' -Type String -Value '900'
        $check = Get-ItemProperty -Path (Convert-RegKeyToProviderPath $desktop)
        if ($check.ScreenSaveActive -ne '0' -or $check.ScreenSaverIsSecure -ne '0') {
            throw 'A preferencia da protecao de tela nao foi confirmada.'
        }
        Write-Log 'Protecao de tela e exigencia de senha desativadas para o usuario atual.' -Level WARN
    }
}

function Invoke-TimeService {
    Invoke-ModuleSafe 'TimeService' {
        $computer = Get-CimInstance -ClassName Win32_ComputerSystem
        if ($computer.PartOfDomain) {
            Write-Log 'Computador ingressado em dominio: usando hierarquia do dominio.' -Level INFO
            Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/config', '/manualpeerlist:', '/syncfromflags:DOMHIER', '/reliable:NO', '/update') `
                -Description 'Configuracao do W32Time para hierarquia do dominio' | Out-Null
        }
        else {
            Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/config', '/manualpeerlist:time.windows.com,0x9', '/syncfromflags:MANUAL', '/reliable:NO', '/update') `
                -Description 'Configuracao do W32Time para time.windows.com' | Out-Null
        }
        Restart-Service -Name W32Time -Force -ErrorAction Stop
        try {
            Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/resync', '/force') -Description 'Sincronizacao do W32Time' | Out-Null
        }
        catch {
            Write-Log "Sincronizacao imediata nao confirmada; o servico foi configurado. $($_.Exception.Message)" -Level WARN
        }
        $service = Get-Service -Name W32Time
        if ($service.Status -ne 'Running') { throw 'W32Time nao esta em execucao apos a configuracao.' }
        Write-Log "Fonte atual do horario: $((w32tm.exe /query /source 2>&1 | Out-String).Trim())" -Level INFO
    }
}

function Get-AdministratorsGroup {
    $group = Get-LocalGroup | Where-Object { $_.SID.Value -eq 'S-1-5-32-544' } | Select-Object -First 1
    if (-not $group) { throw 'Grupo local Administrators/Administradores nao encontrado.' }
    return $group
}

function Invoke-LocalAccounts {
    if (-not $AllowAccountChanges) {
        $script:SkippedModules.Add('LocalAccounts')
        Write-Log 'LocalAccounts ignorado: exige -AllowAccountChanges.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'LocalAccounts' {
        if ($ElevateUser.Count -gt 0) {
            $group = Get-AdministratorsGroup
            foreach ($name in $ElevateUser) {
                $user = Get-LocalUser -Name $name -ErrorAction Stop
                if (-not $user.Enabled) { throw "Conta desabilitada nao sera elevada: $name" }
                $members = Get-LocalGroupMember -Group $group.Name -ErrorAction Stop
                if (-not ($members | Where-Object { $_.SID.Value -eq $user.SID.Value })) {
                    Add-LocalGroupMember -Group $group.Name -Member $user.Name -ErrorAction Stop
                    Write-Log "Conta adicionada ao grupo de administradores: $name" -Level WARN
                }
                else { Write-Log "Conta ja e administradora: $name" -Level INFO }
            }
        }
        elseif ($EnableBuiltInAdministrator -or $DisablePCAdmin -or $NormalizeAgrUser -or $RemoveAgrPassword) {
            Write-Log 'Nenhuma elevacao em massa sera feita; use -ElevateUser para contas especificas.' -Level INFO
        }

        if ($NormalizeAgrUser) {
            foreach ($user in @(Get-LocalUser | Where-Object { $_.Name -like '*AGR-*' -or $_.FullName -like '*AGR-*' })) {
                $newName = $user.Name -replace 'AGR-', ''
                if ([string]::IsNullOrWhiteSpace($newName)) { throw "Nome resultante invalido para $($user.Name)." }
                if ($newName -ne $user.Name -and (Get-LocalUser -Name $newName -ErrorAction SilentlyContinue)) {
                    throw "Renomeacao cancelada; ja existe a conta $newName."
                }
                if ($newName -ne $user.Name) { Rename-LocalUser -Name $user.Name -NewName $newName -ErrorAction Stop }
                $full = ([string]$user.FullName) -replace 'AGR-', ''
                if ($full -and $full -ne $user.FullName) { Set-LocalUser -Name $newName -FullName $full -ErrorAction Stop }
                Write-Log "Conta normalizada: $($user.Name) -> $newName" -Level WARN
                if ($RemoveAgrPassword) {
                    if (-not $AllowBlankPassword) { throw 'Remocao de senha exige -AllowBlankPassword.' }
                    Invoke-Native -FilePath 'net.exe' -ArgumentList @('user', $newName, '""') `
                        -Description "Remocao da senha de $newName" | Out-Null
                    Write-Log "ATENCAO: senha removida da conta $newName." -Level WARN
                }
            }
        }

        if ($EnableBuiltInAdministrator) {
            $builtin = Get-LocalUser | Where-Object { $_.SID.Value -like '*-500' } | Select-Object -First 1
            if (-not $builtin) { throw 'Conta interna RID 500 nao encontrada.' }
            if (-not $builtin.Enabled) { Enable-LocalUser -Name $builtin.Name -ErrorAction Stop }
            Write-Log "Conta interna habilitada: $($builtin.Name). Garanta que ela possui senha forte." -Level WARN
        }

        if ($DisablePCAdmin) {
            $pcAdmin = Get-LocalUser -Name 'PC_Admin' -ErrorAction SilentlyContinue
            if ($pcAdmin -and $pcAdmin.Enabled) {
                $group = Get-AdministratorsGroup
                $members = Get-LocalGroupMember -Group $group.Name -ErrorAction Stop
                $otherEnabledAdmin = foreach ($localUser in (Get-LocalUser | Where-Object {
                    $_.Enabled -and $_.Name -ne 'PC_Admin'
                })) {
                    if ($members | Where-Object { $_.SID.Value -eq $localUser.SID.Value }) {
                        $localUser
                    }
                }
                if (-not $otherEnabledAdmin) {
                    throw 'PC_Admin nao sera desabilitado: nenhuma outra conta local habilitada foi confirmada como administradora.'
                }
                Disable-LocalUser -Name 'PC_Admin' -ErrorAction Stop
                Write-Log 'PC_Admin desabilitado.' -Level WARN
            }
            else { Write-Log 'PC_Admin ausente ou ja desabilitado.' -Level INFO }
        }
    }
}

function Invoke-BitLocker {
    if (-not $AllowBitLockerDecryption) {
        $script:SkippedModules.Add('BitLocker')
        Write-Log 'BitLocker ignorado: exige -AllowBitLockerDecryption.' -Level WARN
        return
    }
    if ($BitLockerDrive.Count -eq 0) {
        $script:SkippedModules.Add('BitLocker')
        Write-Log 'BitLocker ignorado: informe volumes explicitamente com -BitLockerDrive C:.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'BitLocker' {
        foreach ($drive in $BitLockerDrive) {
            $volume = Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop
            if ($volume.VolumeStatus -eq 'FullyDecrypted') {
                Write-Log "$drive ja esta descriptografado." -Level INFO
                continue
            }
            $recovery = @($volume.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' })
            if ($recovery.Count -eq 0) {
                throw "$drive nao possui protetor RecoveryPassword confirmado; descriptografia cancelada."
            }
            Disable-BitLocker -MountPoint $drive -ErrorAction Stop | Out-Null
            Write-Log "Descriptificacao iniciada em $drive. Nenhuma chave de recuperacao foi gravada no log." -Level WARN
        }
    }
}

function Invoke-AnyDesk {
    if (-not $AllowRemoteAccessChange) {
        $script:SkippedModules.Add('AnyDesk')
        Write-Log 'AnyDesk ignorado: exige -AllowRemoteAccessChange.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'AnyDesk' {
        $candidates = @()
        foreach ($root in @(${env:ProgramFiles(x86)}, $env:ProgramFiles, $env:ProgramData)) {
            if ($root) { $candidates += (Join-Path $root 'AnyDesk\AnyDesk.exe') }
        }
        $candidates = $candidates | Where-Object { Test-Path -LiteralPath $_ }
        $exe = $candidates | Select-Object -First 1
        if (-not $exe) { Write-Log 'AnyDesk nao encontrado; nada a fazer.' -Level INFO; return }
        Invoke-Native -FilePath $exe -ArgumentList @('--remove-password') -Description 'Remocao da senha do AnyDesk' | Out-Null
        Write-Log 'Comando do AnyDesk executado; valide a politica de acesso remoto manualmente.' -Level WARN
    }
}

function Invoke-Rollback {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Container)) { throw "Backup nao encontrado: $Path" }
    Write-Log "Rollback iniciado a partir de $Path" -Level SECTION
    New-RestorePointRequired
    foreach ($file in Get-ChildItem -LiteralPath $Path -Filter 'registry_*.reg' -File) {
        Invoke-Native -FilePath 'reg.exe' -ArgumentList @('import', $file.FullName) -Description "Importacao de $($file.Name)" | Out-Null
    }
    $security = Join-Path $Path 'security_policy.inf'
    if (Test-Path $security) {
        $db = Join-Path $env:TEMP ('rollback_{0}.sdb' -f [guid]::NewGuid())
        try { Invoke-Native -FilePath 'secedit.exe' -ArgumentList @('/configure', '/db', $db, '/cfg', $security, '/areas', 'SECURITYPOLICY', 'USER_RIGHTS') -Description 'Rollback da politica de seguranca' | Out-Null }
        finally { Remove-Item -LiteralPath $db -Force -ErrorAction SilentlyContinue }
    }
    $audit = Join-Path $Path 'audit_policy.csv'
    if (Test-Path $audit) { Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @('/restore', "/file:$audit") -Description 'Rollback da auditoria' | Out-Null }
    Invoke-Native -FilePath 'gpupdate.exe' -ArgumentList @('/force', '/wait:0') -Description 'Atualizacao apos rollback' | Out-Null
    Test-EssentialIntegrity -Stage 'rollback'
    Write-Log 'Rollback de registro, politica local e auditoria concluido.' -Level OK
    Write-Log 'Rollback manual ainda necessario para contas, BitLocker e AnyDesk.' -Level WARN
}

try {
    Test-Administrator
    New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    Write-Log "Inicio: $($script:Edition.Caption), build $($script:Edition.Build)" -Level SECTION
    Write-Log "Log: $script:LogFile" -Level INFO

    if ($RollbackPath) {
        if ($Apply) { throw 'Use -RollbackPath sem -Apply; o rollback ja e uma operacao de alteracao controlada.' }
        Invoke-Rollback -Path (Resolve-Path -LiteralPath $RollbackPath).Path
        return
    }

    if (-not $Apply) {
        Write-Log 'Modo seguro: nenhuma alteracao sera feita. Use -Apply para prosseguir.' -Level WARN
        Write-Log "Modulos selecionados: $($Modules -join ', ')" -Level INFO
        return
    }

    Test-EssentialIntegrity -Stage 'pre-flight'
    New-RestorePointRequired
    Save-SafetyBackup

    $selected = if ($Modules -contains 'All') {
        @('SecurityPolicy', 'LocalGpo', 'ScreenSaver', 'TimeService', 'LocalAccounts', 'BitLocker', 'AnyDesk')
    }
    else { @($Modules | Select-Object -Unique) }

    foreach ($module in $selected) {
        switch ($module) {
            'SecurityPolicy' { Invoke-SecurityPolicy }
            'LocalGpo'       { Invoke-LocalGpo }
            'ScreenSaver'    { Invoke-ScreenSaver }
            'TimeService'    { Invoke-TimeService }
            'LocalAccounts'  { Invoke-LocalAccounts }
            'BitLocker'      { Invoke-BitLocker }
            'AnyDesk'        { Invoke-AnyDesk }
        }
    }

    Write-Log "Modulos concluidos: $($script:ChangedModules -join ', ')" -Level OK
    Write-Log "Modulos ignorados: $($script:SkippedModules -join ', ')" -Level INFO
    if ($script:Failures -gt 0) {
        throw "Execucao terminou com $($script:Failures) falha(s). Consulte o log e o backup em $script:BackupPath."
    }
}
catch {
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        Write-Log "ERRO FATAL: $($_.Exception.Message)" -Level ERROR
    }
    else { Write-Error $_.Exception.Message }
    exit 1
}
finally {
    if ($script:LogFile -and (Test-Path -LiteralPath $script:LogFile)) {
        Write-Log 'Finally global: execucao encerrada.' -Level SECTION
    }
}
