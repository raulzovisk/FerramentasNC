<#
Uso seguro:
  .\Reverse-Config.ps1
  .\Reverse-Config.ps1 -Apply -Modules TimeService
  .\Reverse-Config.ps1 -Apply -AllowSecurityWeakening -Modules SecurityPolicy,LocalGpo,ScreenSaver
  .\Reverse-Config.ps1 -Apply -AllowAccountChanges -ElevateUser Raul -DisablePCAdmin
#>
[CmdletBinding()]
param(
    [switch]$Apply,
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
    [switch]$DisablePCAdmin
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:BasePath = 'C:\logs\desconfig'
try {
    New-Item -ItemType Directory -Force -Path $script:BasePath | Out-Null
}
catch {
    $script:BasePath = Join-Path $env:TEMP 'desconfig'
    New-Item -ItemType Directory -Force -Path $script:BasePath | Out-Null
}

$script:LogFile = Join-Path $script:BasePath 'debloat_execution.log'
$script:Failures = 0
$script:ChangedModules = New-Object System.Collections.Generic.List[string]
$script:SkippedModules = New-Object System.Collections.Generic.List[string]

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
    $principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute este script como Administrador.'
    }
}

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

function Test-WindowsProOnly {
    $edition = Get-WindowsEdition
    if ($edition.EditionId -notin @('Professional', 'ProfessionalN')) {
        throw ("Execucao interrompida: somente Windows Pro/Pro N e suportado. " +
            "Detectado: EditionId='{0}', Caption='{1}'. Nenhuma alteracao foi feita." -f
            $edition.EditionId, $edition.Caption)
    }
    Write-Log "Edicao validada: $($edition.Caption), build $($edition.Build), EditionId=$($edition.EditionId)" -Level OK
    return $edition
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][string[]]$ArgumentList,
        [Parameter(Mandatory)][string]$Description,
        [switch]$AllowNonZeroExit
    )

    Write-Log "Executando: $Description -> $FilePath $($ArgumentList -join ' ')" -Level INFO
    $previousErrorAction = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $FilePath @ArgumentList 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousErrorAction
    }
    if ($output) {
        Write-Log (($output | Out-String).Trim()) -Level INFO
    }
    if (($exitCode -ne 0) -and (-not $AllowNonZeroExit)) {
        throw "$Description falhou com codigo $exitCode."
    }
    return $output
}

function Invoke-ModuleSafe {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][scriptblock]$Action
    )

    Write-Log "MODULO: $Name" -Level SECTION
    try {
        & $Action
        $script:ChangedModules.Add($Name)
        Write-Log "Concluido: $Name" -Level OK
    }
    catch {
        $script:Failures++
        Write-Log "Falha no modulo '$Name': $($_.Exception.Message)" -Level ERROR
    }
    finally {
        Write-Log "Fim do modulo: $Name" -Level INFO
    }
}

function Test-EssentialIntegrity {
    param([Parameter(Mandatory)][string]$Stage)

    $edition = Get-WindowsEdition
    if ($edition.EditionId -notin @('Professional', 'ProfessionalN')) {
        throw "A edicao do Windows mudou durante a execucao: $($edition.EditionId)."
    }

    foreach ($serviceName in @('RpcSs', 'EventLog', 'CryptSvc', 'BFE', 'Winmgmt')) {
        if (-not (Get-Service -Name $serviceName -ErrorAction SilentlyContinue)) {
            throw "Servico essencial ausente em ${Stage}: $serviceName"
        }
    }

    $defender = Get-Service -Name 'WinDefend' -ErrorAction SilentlyContinue
    if ($defender) {
        Write-Log "Integridade ${Stage}: WinDefend=$($defender.Status), StartType=$($defender.StartType)" -Level INFO
    }
    Write-Log "Integridade validada ${Stage}: $($edition.Caption), build $($edition.Build)" -Level OK
}

function New-RestorePointBestEffort {
    foreach ($serviceName in @('VSS', 'swprv', 'srservice')) {
        $service = Get-Service -Name $serviceName -ErrorAction SilentlyContinue
        if ($service) {
            try {
                Set-Service -Name $serviceName -StartupType Manual -ErrorAction Stop
                Start-Service -Name $serviceName -ErrorAction SilentlyContinue
                Write-Log "Servico preparado para ponto de restauracao: $serviceName" -Level INFO
            }
            catch {
                Write-Log "Nao foi possivel preparar ${serviceName}: $($_.Exception.Message)" -Level WARN
            }
        }
    }

    try {
        Enable-ComputerRestore -Drive "$env:SystemDrive\" -ErrorAction Stop
        Checkpoint-Computer -Description 'Reverse-Config pre-change' -RestorePointType MODIFY_SETTINGS -ErrorAction Stop
        Write-Log 'Ponto de restauracao criado.' -Level OK
    }
    catch {
        Write-Log "Ponto de restauracao nao criado; prosseguindo somente com log detalhado. Erro: $($_.Exception.Message)" -Level WARN
    }
}

function Remove-RegistryValueIfExists {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-Log "Caminho ausente; nada a remover: $Path" -Level INFO
        return
    }
    $value = Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue
    if ($null -eq $value) {
        Write-Log "Valor ja ausente: $Path\$Name" -Level INFO
        return
    }
    Remove-ItemProperty -LiteralPath $Path -Name $Name -Force
    Write-Log "Valor removido: $Path\$Name" -Level OK
}

function Get-AdministratorsGroupName {
    $group = Get-LocalGroup -SID ([Security.Principal.SecurityIdentifier]'S-1-5-32-544') -ErrorAction SilentlyContinue
    if ($group) { return $group.Name }
    foreach ($name in @('Administradores', 'Administrators')) {
        if (Get-LocalGroup -Name $name -ErrorAction SilentlyContinue) { return $name }
    }
    throw 'Grupo local de administradores nao encontrado.'
}

function Invoke-SecurityPolicy {
    if (-not $AllowSecurityWeakening) {
        $script:SkippedModules.Add('SecurityPolicy')
        Write-Log 'SecurityPolicy ignorado: exige -AllowSecurityWeakening.' -Level WARN
        return
    }

    Invoke-ModuleSafe 'SecurityPolicy' {
        Invoke-Native -FilePath 'net.exe' -ArgumentList @('accounts', '/MINPWLEN:0', '/MAXPWAGE:UNLIMITED', '/MINPWAGE:0', '/UNIQUEPW:0') -Description 'Politica de senha via net accounts' | Out-Null
        Invoke-Native -FilePath 'net.exe' -ArgumentList @('accounts', '/LOCKOUTTHRESHOLD:0') -Description 'Desabilitar bloqueio de conta' | Out-Null

        $inf = Join-Path $env:TEMP ('reverse_security_{0}.inf' -f [guid]::NewGuid())
        $sdb = Join-Path $env:TEMP ('reverse_security_{0}.sdb' -f [guid]::NewGuid())
        @'
[Unicode]
Unicode=yes
[System Access]
MinimumPasswordAge = 0
MaximumPasswordAge = -1
MinimumPasswordLength = 0
PasswordComplexity = 0
PasswordHistorySize = 0
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
signature="$CHICAGO$"
Revision = 1
'@ | Set-Content -LiteralPath $inf -Encoding Unicode

        try {
            Invoke-Native -FilePath 'secedit.exe' -ArgumentList @('/configure', '/db', $sdb, '/cfg', $inf, '/areas', 'SECURITYPOLICY') -Description 'Aplicacao da politica de seguranca' | Out-Null
            Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @('/set', '/category:*', '/success:disable', '/failure:disable') -Description 'Desabilitar auditoria' | Out-Null
            Invoke-Native -FilePath 'auditpol.exe' -ArgumentList @('/clear', '/y') -Description 'Limpar subcategorias de auditoria' | Out-Null
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
        foreach ($item in @(
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security'; Name = 'MaxSize' },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\EventLog\Security'; Name = 'AutoBackupLogFiles' },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'; Name = 'NtpServer' },
            @{ Path = 'HKLM:\SOFTWARE\Policies\Microsoft\W32Time\Parameters'; Name = 'Type' }
        )) {
            Remove-RegistryValueIfExists -Path $item.Path -Name $item.Name
        }
        Write-Log 'Registry.pol nao foi apagado; somente valores conhecidos foram tratados.' -Level INFO
        Invoke-Native -FilePath 'gpupdate.exe' -ArgumentList @('/target:computer', '/force', '/wait:0') -Description 'Atualizacao de GPO local' -AllowNonZeroExit | Out-Null
    }
}

function Invoke-ScreenSaver {
    if (-not $AllowSecurityWeakening) {
        $script:SkippedModules.Add('ScreenSaver')
        Write-Log 'ScreenSaver ignorado: exige -AllowSecurityWeakening.' -Level WARN
        return
    }

    Invoke-ModuleSafe 'ScreenSaver' {
        foreach ($path in @(
            'HKLM:\SOFTWARE\Policies\Microsoft\Windows\Control Panel\Desktop',
            'HKCU:\Software\Policies\Microsoft\Windows\Control Panel\Desktop'
        )) {
            foreach ($name in @('ScreenSaveActive', 'ScreenSaverIsSecure', 'ScreenSaveTimeOut')) {
                Remove-RegistryValueIfExists -Path $path -Name $name
            }
        }

        $desktop = 'HKCU:\Control Panel\Desktop'
        Set-ItemProperty -LiteralPath $desktop -Name 'ScreenSaveActive' -Value '0'
        Set-ItemProperty -LiteralPath $desktop -Name 'ScreenSaverIsSecure' -Value '0'
        Set-ItemProperty -LiteralPath $desktop -Name 'ScreenSaveTimeOut' -Value '900'
        Write-Log 'Protecao de tela desabilitada para o usuario atual.' -Level WARN
    }
}

function Invoke-TimeService {
    Invoke-ModuleSafe 'TimeService' {
        $computerSystem = Get-CimInstance -ClassName Win32_ComputerSystem
        Set-Service -Name W32Time -StartupType Automatic -ErrorAction SilentlyContinue
        Start-Service -Name W32Time -ErrorAction SilentlyContinue

        if ($computerSystem.PartOfDomain) {
            Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/config', '/manualpeerlist:', '/syncfromflags:DOMHIER', '/reliable:NO', '/update') -Description 'W32Time via dominio' | Out-Null
        }
        else {
            Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/config', '/manualpeerlist:time.windows.com,0x9', '/syncfromflags:MANUAL', '/reliable:NO', '/update') -Description 'W32Time padrao Microsoft' | Out-Null
        }
        Restart-Service -Name W32Time -Force -ErrorAction SilentlyContinue
        Invoke-Native -FilePath 'w32tm.exe' -ArgumentList @('/resync', '/force') -Description 'Sincronizacao W32Time' -AllowNonZeroExit | Out-Null
    }
}

function Invoke-LocalAccounts {
    if (-not $AllowAccountChanges) {
        $script:SkippedModules.Add('LocalAccounts')
        Write-Log 'LocalAccounts ignorado: exige -AllowAccountChanges.' -Level WARN
        return
    }

    Invoke-ModuleSafe 'LocalAccounts' {
        $adminGroup = Get-AdministratorsGroupName

        $usersToElevate = if ($ElevateUser.Count -gt 0) {
            foreach ($name in $ElevateUser) { Get-LocalUser -Name $name -ErrorAction Stop }
        }
        else {
            Get-LocalUser | Where-Object { $_.Enabled -and $_.Name -ne 'PC_Admin' }
        }

        foreach ($user in $usersToElevate) {
            try {
                $name = $user.Name
                if (-not $user.Enabled) {
                    Write-Log "Conta ignorada porque esta desabilitada: $name" -Level WARN
                    continue
                }
                $isMember = Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue |
                    Where-Object { $_.SID -eq $user.SID }
                if ($isMember) {
                    Write-Log "Conta ja administradora: $name" -Level INFO
                }
                else {
                    Add-LocalGroupMember -Group $adminGroup -Member $name -ErrorAction Stop
                    Write-Log "Conta adicionada ao grupo ${adminGroup}: $name" -Level WARN
                }
            }
            catch {
                Write-Log "Falha ao elevar conta '$($user.Name)': $($_.Exception.Message)" -Level ERROR
            }
        }

        if ($ElevateUser.Count -eq 0) { Write-Log 'Elevacao em massa aplicada para contas locais ativas, exceto PC_Admin.' -Level WARN }

        if ($NormalizeAgrUser) {
            foreach ($user in Get-LocalUser | Where-Object { $_.Name -like 'AGR-*' }) {
                $oldName = $user.Name
                $newName = $oldName -replace '^AGR-', ''
                $targetName = $oldName
                if ($oldName -eq $newName) { continue }
                if (Get-LocalUser -Name $newName -ErrorAction SilentlyContinue) {
                    Write-Log "Ja existe um usuario chamado '$newName'; renomeacao de '$oldName' ignorada." -Level WARN
                }
                else {
                    Rename-LocalUser -Name $oldName -NewName $newName -ErrorAction Stop
                    $targetName = $newName
                    Write-Log "Conta normalizada: $oldName -> $newName" -Level WARN
                }

                if ($RemoveAgrPassword) {
                    if (-not $AllowBlankPassword) { throw 'Remocao de senha exige -AllowBlankPassword.' }
                    Invoke-Native -FilePath 'net.exe' -ArgumentList @('user', $targetName, '""') -Description "Remocao de senha de $targetName" | Out-Null
                    Write-Log "ATENCAO: senha removida da conta $targetName." -Level WARN
                }
            }
        }

        if ($EnableBuiltInAdministrator) {
            $builtin = Get-LocalUser | Where-Object { $_.SID -like '*-500' } | Select-Object -First 1
            if (-not $builtin) { throw 'Conta interna RID 500 nao encontrada.' }
            if (-not $builtin.Enabled) {
                Enable-LocalUser -Name $builtin.Name -ErrorAction Stop
                Write-Log "Conta interna habilitada: $($builtin.Name). Defina uma senha forte." -Level WARN
            }
            else {
                Write-Log "Conta interna ja habilitada: $($builtin.Name)" -Level INFO
            }
        }
    }
}

function Invoke-DisablePCAdminFinal {
    Invoke-ModuleSafe 'DisablePCAdminFinal' {
        $pcAdmin = Get-LocalUser -Name 'PC_Admin' -ErrorAction SilentlyContinue
        if (-not $pcAdmin -or -not $pcAdmin.Enabled) {
            Write-Log 'PC_Admin ausente ou ja desabilitado.' -Level INFO
            return
        }

        $adminGroup = Get-AdministratorsGroupName
        $adminSids = @(Get-LocalGroupMember -Group $adminGroup -ErrorAction SilentlyContinue | ForEach-Object { $_.SID.Value })
        $otherEnabledAdmin = Get-LocalUser |
            Where-Object { $_.Enabled -and $_.Name -ne 'PC_Admin' -and ($adminSids -contains $_.SID.Value) } |
            Select-Object -First 1

        if (-not $otherEnabledAdmin) {
            Write-Log 'PC_Admin mantido ativo: nenhuma outra conta local habilitada foi confirmada como administradora.' -Level WARN
            return
        }

        Disable-LocalUser -Name 'PC_Admin' -ErrorAction Stop
        Write-Log "PC_Admin desabilitado. Administrador remanescente confirmado: $($otherEnabledAdmin.Name)." -Level WARN
    }
}

function Invoke-BitLocker {
    if (-not $AllowBitLockerDecryption) {
        $script:SkippedModules.Add('BitLocker')
        Write-Log 'BitLocker ignorado: exige -AllowBitLockerDecryption.' -Level WARN
        return
    }
    Invoke-ModuleSafe 'BitLocker' {
        $volumes = if ($BitLockerDrive.Count -gt 0) {
            foreach ($drive in $BitLockerDrive) { Get-BitLockerVolume -MountPoint $drive -ErrorAction Stop }
        }
        else {
            Get-BitLockerVolume -ErrorAction Stop
        }

        foreach ($volume in $volumes) {
            try {
                $drive = $volume.MountPoint
                if ($volume.VolumeStatus -eq 'FullyDecrypted') {
                    Write-Log "$drive ja esta descriptografado." -Level INFO
                    continue
                }
                Disable-BitLocker -MountPoint $drive -ErrorAction Stop | Out-Null
                Write-Log "Descriptografia iniciada em $drive. Progresso: manage-bde -status $drive" -Level WARN
            }
            catch {
                Write-Log "Falha ao tratar BitLocker em '$($volume.MountPoint)': $($_.Exception.Message)" -Level ERROR
            }
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
        $exe = @(
            "$env:ProgramFiles(x86)\AnyDesk\AnyDesk.exe",
            "$env:ProgramFiles\AnyDesk\AnyDesk.exe",
            "$env:ProgramData\AnyDesk\AnyDesk.exe"
        ) | Where-Object { $_ -and (Test-Path -LiteralPath $_ -PathType Leaf) } | Select-Object -First 1

        if (-not $exe) {
            Write-Log 'AnyDesk nao encontrado; nada a fazer.' -Level INFO
            return
        }
        Invoke-Native -FilePath $exe -ArgumentList @('--remove-password') -Description 'Remocao da senha do AnyDesk' | Out-Null
        Write-Log 'Comando do AnyDesk executado; valide acesso remoto manualmente.' -Level WARN
    }
}

try {
    New-Item -ItemType File -Path $script:LogFile -Force | Out-Null
    $edition = Test-WindowsProOnly
    Test-Administrator

    Write-Log 'Inicio do processo Reverse-Config' -Level SECTION
    Write-Log "Maquina: $env:COMPUTERNAME | Usuario: $env:USERDOMAIN\$env:USERNAME | Log: $script:LogFile" -Level INFO

    $validModules = @('All', 'SecurityPolicy', 'LocalGpo', 'ScreenSaver', 'TimeService', 'LocalAccounts', 'BitLocker', 'AnyDesk')
    $Modules = @($Modules | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    foreach ($module in $Modules) {
        if ($module -notin $validModules) {
            throw "Modulo invalido: $module. Valores aceitos: $($validModules -join ', ')."
        }
    }

    if (-not $Apply) {
        Write-Log 'Modo seguro: nenhuma alteracao sera feita. Use -Apply para prosseguir.' -Level WARN
        Write-Log "Modulos selecionados: $($Modules -join ', ')" -Level INFO
        return
    }

    Test-EssentialIntegrity -Stage 'pre-flight'
    New-RestorePointBestEffort

    $selected = if ($Modules -contains 'All') {
        @('SecurityPolicy', 'LocalGpo', 'ScreenSaver', 'TimeService', 'LocalAccounts', 'BitLocker', 'AnyDesk')
    }
    else {
        @($Modules | Select-Object -Unique)
    }

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

    if ($DisablePCAdmin) {
        Invoke-DisablePCAdminFinal
    }

    Test-EssentialIntegrity -Stage 'post-change'
    Write-Log "Modulos concluidos: $($script:ChangedModules -join ', ')" -Level OK
    Write-Log "Modulos ignorados: $($script:SkippedModules -join ', ')" -Level INFO

    if ($script:Failures -gt 0) {
        Write-Log "Execucao terminou com $($script:Failures) falha(s) nao criticas. Consulte $script:LogFile." -Level WARN
    }
}
catch {
    Write-Log "ERRO FATAL: $($_.Exception.Message)" -Level ERROR
    exit 1
}
finally {
    Write-Log 'Execucao encerrada.' -Level SECTION
}
