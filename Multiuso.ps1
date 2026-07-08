
# =============================================================================
# CONFIGURACAO DO REPOSITORIO (GitHub) — usado quando rodado via `irm`
# =============================================================================
# >>> AJUSTE AQUI: URL "raw" base do seu repositorio (sem barra no final).
#     Formato: https://raw.githubusercontent.com/<USUARIO>/<REPO>/<BRANCH>
$RepoBase = "https://raw.githubusercontent.com/raulzovisk/SistemaInfo/main"
$MultiusoUrl = "$RepoBase/Multiuso.ps1"
$ReverseUrl = "$RepoBase/Reverse-Config.ps1"

# Baixa um script para um arquivo LOCAL antes de executa-lo (nunca via
# Invoke-Expression em texto cru). Isso evita o mojibake de encoding que
# o `irm URL | iex` pode causar em caracteres acentuados/BOM no PowerShell
# 5.1, e mantem $PSScriptRoot/$PSCommandPath preenchidos no script baixado.
function Get-RemoteScript {
    param([Parameter(Mandatory)][string]$Url, [Parameter(Mandatory)][string]$FileName)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $destDir = Join-Path $env:TEMP "Multiuso"
    New-Item -ItemType Directory -Force -Path $destDir | Out-Null
    $destPath = Join-Path $destDir $FileName

    Invoke-WebRequest -Uri $Url -OutFile $destPath -UseBasicParsing
    return $destPath
}

# =============================================================================
# AUTO-ELEVACAO — reinicia o script como Administrador, se necessario
# =============================================================================
$principal = [Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Elevando privilegios (Administrador)..." -ForegroundColor Yellow

    # Se o script esta em disco ($PSCommandPath preenchido), reexecuta o arquivo.
    # Se foi carregado via `irm URL | iex` (sem arquivo), baixa para um arquivo
    # temporario e reexecuta a partir dele (evita re-piping via iex).
    if ($PSCommandPath) {
        $caminhoScript = $PSCommandPath
    }
    else {
        $caminhoScript = Get-RemoteScript -Url $MultiusoUrl -FileName "Multiuso.ps1"
    }
    $argElev = "-NoProfile -ExecutionPolicy Bypass -File `"$caminhoScript`""

    try {
        Start-Process powershell.exe -Verb RunAs -ArgumentList $argElev
    }
    catch {
        Write-Host "Elevacao cancelada. Encerrando." -ForegroundColor Red
    }
    exit
}


# =============================================================================
# OPCAO [1] — COLETAR EVIDENCIAS   (codigo integral do run.ps1)
# =============================================================================
function Coletar-Evidencias {

    # ErrorActionPreference local a esta funcao (nao afeta o menu principal)
    $ErrorActionPreference = "Stop"
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    # Carregar Assemblies Necessarios
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    # Carregar assinaturas Win32 P/Invoke
    try {
        [Win32Functions.Win32] | Out-Null
    }
    catch {
        $Signature = @"
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out RECT rect);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hWnd, uint msg, IntPtr w, IntPtr l);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int cmd);
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint lpdwProcessId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool fAttach);
    [DllImport("user32.dll")] public static extern bool BringWindowToTop(IntPtr hWnd);
    [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, int dwExtraInfo);


    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left, Top, Right, Bottom; }
"@
        Add-Type -MemberDefinition $Signature -Name "Win32" -Namespace "Win32Functions"
    }

    # Inicializar configuracoes do sistema
    [Win32Functions.Win32]::SetProcessDPIAware() | Out-Null

    # --- Funcoes Auxiliares de Captura e Janelas ---

    function Send-ToBack ($hwnd) {
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $HWND_BOTTOM = [IntPtr]1
        $SWP_NOMOVE = 0x0002; $SWP_NOSIZE = 0x0001; $SWP_NOACTIVATE = 0x0010
        [Win32Functions.Win32]::SetWindowPos($hwnd, $HWND_BOTTOM, 0, 0, 0, 0, $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_NOACTIVATE) | Out-Null
    }

    # >>> Garante que a janela seja aberta/movida para o monitor primario, evitando que em setups com
    # multiplos monitores uma janela abra em um monitor e o print (que sempre captura o monitor primario)
    # seja tirado de outro
    function Move-ToPrimaryMonitor ($hwnd, $maximize = $false) {
        if ($hwnd -eq [IntPtr]::Zero) { return }
        $primary = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        $SWP_NOSIZE = 0x0001; $SWP_NOZORDER = 0x0004; $SWP_NOACTIVATE = 0x0010

        if ($maximize) {
            [Win32Functions.Win32]::ShowWindow($hwnd, 9) | Out-Null # SW_RESTORE (necessario para poder mover antes de maximizar)
        }

        [Win32Functions.Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $primary.X, $primary.Y, 0, 0, $SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE) | Out-Null

        if ($maximize) {
            [Win32Functions.Win32]::ShowWindow($hwnd, 3) | Out-Null # SW_MAXIMIZE (agora no monitor primario)
        }
    }

    function Center-WindowOnPrimary ($hwnd) {
        if ($hwnd -eq [IntPtr]::Zero) { return }

        $r = New-Object Win32Functions.Win32+RECT
        if (-not [Win32Functions.Win32]::GetWindowRect($hwnd, [ref]$r)) { return }

        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $width = $r.Right - $r.Left
        $height = $r.Bottom - $r.Top

        if ($width -le 0 -or $height -le 0) { return }

        $x = $screen.X + [int](($screen.Width - $width) / 2)
        $y = $screen.Y + [int](($screen.Height - $height) / 2)

        $SWP_NOSIZE = 0x0001
        $SWP_NOZORDER = 0x0004
        $SWP_NOACTIVATE = 0x0010

        [Win32Functions.Win32]::ShowWindow($hwnd, 9) | Out-Null
        [Win32Functions.Win32]::SetWindowPos($hwnd, [IntPtr]::Zero, $x, $y, 0, 0, $SWP_NOSIZE -bor $SWP_NOZORDER -bor $SWP_NOACTIVATE) | Out-Null
    }
    function Force-Foreground ($hwnd) {
        if ($hwnd -eq [IntPtr]::Zero) { return }

        $HWND_TOP = [IntPtr]0
        $SWP_NOMOVE = 0x0002; $SWP_NOSIZE = 0x0001; $SWP_SHOWWINDOW = 0x0040
        $VK_MENU = 0x12
        $KEYEVENTF_KEYUP = 0x2

        $fgHwnd = [Win32Functions.Win32]::GetForegroundWindow()
        if ($fgHwnd -eq $hwnd) { return }

        $foreThread = [Win32Functions.Win32]::GetWindowThreadProcessId($fgHwnd, [ref]([uint32]0))
        $targetThread = [Win32Functions.Win32]::GetWindowThreadProcessId($hwnd, [ref]([uint32]0))
        $curThread = [Win32Functions.Win32]::GetCurrentThreadId()

        [Win32Functions.Win32]::AttachThreadInput($curThread, $foreThread, $true) | Out-Null
        [Win32Functions.Win32]::AttachThreadInput($curThread, $targetThread, $true) | Out-Null

        # >>> Truque do ALT: "engana" o Windows fazendo-o achar que houve interacao do usuario
        [Win32Functions.Win32]::keybd_event($VK_MENU, 0, 0, 0)
        [Win32Functions.Win32]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, 0)

        [Win32Functions.Win32]::ShowWindow($hwnd, 9) | Out-Null
        [Win32Functions.Win32]::BringWindowToTop($hwnd) | Out-Null
        [Win32Functions.Win32]::SetForegroundWindow($hwnd) | Out-Null
        [Win32Functions.Win32]::SetWindowPos($hwnd, $HWND_TOP, 0, 0, 0, 0, $SWP_NOMOVE -bor $SWP_NOSIZE -bor $SWP_SHOWWINDOW) | Out-Null

        Start-Sleep -Milliseconds 200

        # Fallback: se ainda nao colou, repete o truque do ALT mais uma vez
        if ([Win32Functions.Win32]::GetForegroundWindow() -ne $hwnd) {
            [Win32Functions.Win32]::keybd_event($VK_MENU, 0, 0, 0)
            [Win32Functions.Win32]::keybd_event($VK_MENU, 0, $KEYEVENTF_KEYUP, 0)
            [Win32Functions.Win32]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Milliseconds 200
        }

        [Win32Functions.Win32]::AttachThreadInput($curThread, $foreThread, $false) | Out-Null
        [Win32Functions.Win32]::AttachThreadInput($curThread, $targetThread, $false) | Out-Null
        Start-Sleep -Milliseconds 300
    }


    function Capture-Screen ($rect) {
        if ($rect) {
            $width = $rect.Right - $rect.Left
            $height = $rect.Bottom - $rect.Top
            $left = $rect.Left
            $top = $rect.Top
        }
        else {
            $screen = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
            $width = $screen.Width
            $height = $screen.Height
            $left = $screen.X
            $top = $screen.Y
        }

        $bmp = New-Object System.Drawing.Bitmap $width, $height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($left, $top, 0, 0, $bmp.Size)
        $g.Dispose()
        return $bmp
    }

    function Get-BmpHash ($bmp) {
        $ms = New-Object System.IO.MemoryStream
        $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        $bytes = $ms.ToArray()
        $ms.Dispose()

        $md5 = [System.Security.Cryptography.MD5]::Create()
        $hashBytes = $md5.ComputeHash($bytes)
        $md5.Dispose()

        $sb = New-Object System.Text.StringBuilder
        foreach ($b in $hashBytes) {
            $sb.Append($b.ToString("X2")) | Out-Null
        }
        return $sb.ToString()
    }

    function Wait-Stable ($hwnd = [IntPtr]::Zero, $interval = 0.8, $confirm = 3, $timeoutSec = 120) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aguardando tela estabilizar..." -ForegroundColor Gray
        $start = [DateTime]::UtcNow
        $prev = $null
        $equals = 0

        while (([DateTime]::UtcNow - $start).TotalSeconds -lt $timeoutSec) {
            $rect = $null
            if ($hwnd -ne [IntPtr]::Zero) {
                $r = New-Object Win32Functions.Win32+RECT
                if ([Win32Functions.Win32]::GetWindowRect($hwnd, [ref]$r)) {
                    $rect = $r
                }
            }

            $bmp = Capture-Screen $rect
            $h = Get-BmpHash $bmp
            $bmp.Dispose()

            if ($h -eq $prev) {
                $equals++
                if ($equals -ge $confirm) {
                    $diff = ([DateTime]::UtcNow - $start).TotalSeconds
                    Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Tela estabilizou apos $($diff.ToString('F1'))s." -ForegroundColor Gray
                    return
                }
            }
            else {
                $equals = 0
            }
            $prev = $h
            Start-Sleep -Milliseconds ($interval * 1000)
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Timeout ao aguardar estabilizacao, prosseguindo." -ForegroundColor Yellow
    }

    function Take-Screenshot ($name) {
        $path = Join-Path $SaveDir "$name.png"
        $bmp = Capture-Screen
        $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
        $bmp.Dispose()
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print salvo: $path" -ForegroundColor Gray
        return $path
    }

    function Wait-Window ($titles, $timeoutSec = 60) {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Aguardando janelas: $($titles -join ', ')..." -ForegroundColor Gray
        $start = [DateTime]::UtcNow

        while (([DateTime]::UtcNow - $start).TotalSeconds -lt $timeoutSec) {
            $procs = [System.Diagnostics.Process]::GetProcesses()
            foreach ($proc in $procs) {
                try {
                    if ($proc.MainWindowHandle -eq [IntPtr]::Zero) { continue }
                    if (-not [Win32Functions.Win32]::IsWindowVisible($proc.MainWindowHandle)) { continue }
                    foreach ($t in $titles) {
                        if ($proc.MainWindowTitle.IndexOf($t, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Janela '$($proc.MainWindowTitle)' encontrada." -ForegroundColor Gray
                            return $proc.MainWindowHandle
                        }
                    }
                }
                catch {}
            }
            Start-Sleep -Milliseconds 500
        }
        throw "Nenhuma janela [$($titles -join '/')] encontrada apos $timeoutSec s."
    }

    function Close-Window ($hwnd, $proc = $null) {
        if ($hwnd -ne [IntPtr]::Zero) {
            [Win32Functions.Win32]::PostMessage($hwnd, 0x0010, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
        }
        if ($proc -and -not $proc.HasExited) {
            try { $proc.Kill() } catch {}
        }
        Start-Sleep -Milliseconds 500
    }

    # --- Definicao das Tarefas ---

    function Task-MsInfo {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo MSINFO..." -ForegroundColor Gray
        $proc = [System.Diagnostics.Process]::Start("msinfo32.exe")
        $hwnd = Wait-Window @("Informações do Sistema", "System Information")
        Move-ToPrimaryMonitor $hwnd $true
        Wait-Stable $hwnd
        Take-Screenshot "INFO"
        Close-Window $hwnd $proc
    }

    function Open-SettingsAtivacao {
        [System.Diagnostics.Process]::Start("explorer.exe", "ms-settings:activation") | Out-Null
        $hwnd = Wait-Window @("Configurações", "Settings")
        Move-ToPrimaryMonitor $hwnd $true
        Wait-Stable $hwnd
        Send-ToBack $hwnd
        return $hwnd
    }

    # >>> Garante que a janela de Ativacao continua aberta (apps UWP podem ser suspensos/fechados
    # pelo Windows quando ficam muito tempo ocultos atras de outra janela em maquinas lentas)
    function Ensure-SettingsAtivacao ($hwndSettings) {
        if ($hwndSettings -ne [IntPtr]::Zero -and [Win32Functions.Win32]::IsWindowVisible($hwndSettings)) {
            return $hwndSettings
        }
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Janela de Ativacao fechou inesperadamente, reabrindo..." -ForegroundColor Yellow
        return Open-SettingsAtivacao
    }

    function Task-AtivacaoWindows {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: abrindo ms-settings:activation..." -ForegroundColor Gray

        # --- Abre o Settings de Ativacao (espelho do AguardarJanelaEstavel do C#) ---
        $hwndSettings = [IntPtr]::Zero

        try {
            [System.Diagnostics.Process]::Start("explorer.exe", "ms-settings:activation") | Out-Null
        }
        catch {}

        # Tenta os mesmos títulos e timeouts do C# (Configura 30s → Settings 20s → Ativa 15s)
        $tentativas = @(
            @{ Titulo = @("Configura", "Configurações"); Timeout = 30 },
            @{ Titulo = @("Settings"); Timeout = 20 },
            @{ Titulo = @("Ativa"); Timeout = 15 }
        )

        foreach ($t in $tentativas) {
            if ($hwndSettings -ne [IntPtr]::Zero) { break }
            try {
                $hwndSettings = Wait-Window $t.Titulo $t.Timeout
            }
            catch { $hwndSettings = [IntPtr]::Zero }
        }

        if ($hwndSettings -ne [IntPtr]::Zero) {
            # SW_MAXIMIZE = 3  (espelho do Native.ShowWindow(hSettings, SW_MAXIMIZE))
            [Win32Functions.Win32]::ShowWindow($hwndSettings, 3) | Out-Null
            Move-ToPrimaryMonitor $hwndSettings $false   # ja esta maximizado; só move de monitor
            Force-Foreground $hwndSettings

            # UWP render delay — worst case VM (igual ao Thread.Sleep(6000) do C#)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: Settings aberto (hwnd=$hwndSettings), aguardando render UWP..." -ForegroundColor Gray
            Start-Sleep -Seconds 6

            Wait-Stable $hwndSettings 0.8 3 30
        }
        else {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: Settings nao abriu em 65s — continuando sem fundo." -ForegroundColor Yellow
        }

        # --- CapturarSlmgrDuplo: /dli depois /xpr, com Settings de fundo ---

        # Helper local: garante que o Settings ainda está aberto (UWP pode ser suspenso)
        function Ensure-Settings {
            if ($hwndSettings -ne [IntPtr]::Zero -and [Win32Functions.Win32]::IsWindowVisible($hwndSettings)) {
                Send-ToBack $hwndSettings   # mantém como fundo durante o slmgr
                return $hwndSettings
            }
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Janela de Ativacao fechou, reabrindo..." -ForegroundColor Yellow
            $h = [IntPtr]::Zero
            foreach ($t in $tentativas) {
                if ($h -ne [IntPtr]::Zero) { break }
                try {
                    [System.Diagnostics.Process]::Start("explorer.exe", "ms-settings:activation") | Out-Null
                    $h = Wait-Window $t.Titulo $t.Timeout
                }
                catch { $h = [IntPtr]::Zero }
            }
            if ($h -ne [IntPtr]::Zero) {
                [Win32Functions.Win32]::ShowWindow($h, 3) | Out-Null
                Move-ToPrimaryMonitor $h $false
                Force-Foreground $h
                Start-Sleep -Seconds 4
                Wait-Stable $h 0.8 3 20
                Send-ToBack $h
            }
            return $h
        }

        try {
            # --- slmgr /dli ---
            $hwndSettings = Ensure-Settings
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: Rodando slmgr /dli..." -ForegroundColor Gray
            $psi = New-Object System.Diagnostics.ProcessStartInfo "wscript.exe", "C:\Windows\System32\slmgr.vbs /dli"
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $procDli = [System.Diagnostics.Process]::Start($psi)

            $hwndDli = Wait-Window @("Windows Script Host") 120
            Move-ToPrimaryMonitor $hwndDli
            Force-Foreground $hwndDli
            Start-Sleep -Milliseconds 200
            Center-WindowOnPrimary $hwndDli
            Force-Foreground $hwndDli
            Wait-Stable $hwndDli 0.5 2 30
            Take-Screenshot "WIN 1"
            Close-Window $hwndDli $procDli

            # --- slmgr /xpr ---
            $hwndSettings = Ensure-Settings
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: Rodando slmgr /xpr..." -ForegroundColor Gray
            $psi = New-Object System.Diagnostics.ProcessStartInfo "wscript.exe", "C:\Windows\System32\slmgr.vbs /xpr"
            $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
            $procXpr = [System.Diagnostics.Process]::Start($psi)

            $hwndXpr = Wait-Window @("Windows Script Host") 120
            Move-ToPrimaryMonitor $hwndXpr
            Force-Foreground $hwndXpr
            Start-Sleep -Milliseconds 200
            Center-WindowOnPrimary $hwndXpr
            Force-Foreground $hwndXpr
            Wait-Stable $hwndXpr 0.5 2 30
            Take-Screenshot "WIN 2"
            Close-Window $hwndXpr $procXpr

            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN]: concluido." -ForegroundColor Gray
        }
        catch {
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Print[WIN] EXCECAO: $_" -ForegroundColor Red
            # Espelho do catch do C#: tira um screenshot de fallback mesmo sem o Settings aberto
            Take-Screenshot "WIN"
        }
        finally {
            # Fecha o Settings ao final (independente de erro)
            if ($hwndSettings -ne [IntPtr]::Zero) {
                Close-Window $hwndSettings
            }
        }
    }

    function Task-GetMac {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo CMD para getmac /v..." -ForegroundColor Gray
        $psi = New-Object System.Diagnostics.ProcessStartInfo "cmd.exe", "/c title GETMAC_CARREGANDO && getmac /v && echo. && title GETMAC_PRONTO && pause"
        $psi.UseShellExecute = $true
        $psi.CreateNoWindow = $false
        $proc = [System.Diagnostics.Process]::Start($psi)

        $hwnd = Wait-Window @("GETMAC_PRONTO") 120
        Move-ToPrimaryMonitor $hwnd
        Start-Sleep -Seconds 1
        Take-Screenshot "MAC"
        Close-Window $hwnd $proc
    }

    function Task-SerialBios {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo PowerShell para Serial da BIOS..." -ForegroundColor Gray
        $psCmd = "[System.Console]::Title='PS_CARREGANDO'; Get-CimInstance Win32_Bios | Format-List SerialNumber; [System.Console]::Title='PS_PRONTO'; Start-Sleep -Seconds 300"
        $psi = New-Object System.Diagnostics.ProcessStartInfo "powershell.exe", "-NoProfile -Command `"$psCmd`""
        $psi.UseShellExecute = $true
        $psi.CreateNoWindow = $false
        $proc = [System.Diagnostics.Process]::Start($psi)

        $hwnd = Wait-Window @("PS_PRONTO") 120
        Move-ToPrimaryMonitor $hwnd
        Start-Sleep -Seconds 1
        Take-Screenshot "SERIAL"
        Close-Window $hwnd $proc
    }

    function Task-ProgramasRecursos {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Abrindo Programas e Recursos..." -ForegroundColor Gray
        [System.Diagnostics.Process]::Start("appwiz.cpl") | Out-Null
        $hwnd = Wait-Window @("Programas e Recursos", "Programs and Features")
        Move-ToPrimaryMonitor $hwnd $true
        Wait-Stable $hwnd

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Mudando visualizacao para Lista..." -ForegroundColor Gray
        try {
            [Win32Functions.Win32]::SetForegroundWindow($hwnd) | Out-Null
            Start-Sleep -Milliseconds 500
            [System.Windows.Forms.SendKeys]::SendWait("^+5")
            Start-Sleep -Milliseconds 1000
        }
        catch {}

        Take-Screenshot "PROGRAMAS"
        Close-Window $hwnd
    }

    function Task-Bitlocker {
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Verificando status do BitLocker..." -ForegroundColor Gray

        $volumes = Get-BitLockerVolume -ErrorAction SilentlyContinue

        $ativo = $false
        if ($null -ne $volumes) {
            foreach ($v in $volumes) {
                if ($v.ProtectionStatus -eq 'On' -or $v.VolumeStatus -eq 'FullyEncrypted') {
                    $ativo = $true
                    break
                }
            }
        }

        if (-not $ativo) {
            $outputStr = (manage-bde.exe -status) -join "`r`n"
            $txtPath = Join-Path $SaveDir "sem bitlocker.txt"
            $date = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
            $txtContent = "BitLocker não está ativado neste dispositivo.`r`nData/hora: $date`r`n`r`nSaída do manage-bde:`r`n$outputStr"
            [System.IO.File]::WriteAllText($txtPath, $txtContent, [System.Text.Encoding]::UTF8)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BitLocker inativo. Arquivo salvo: $txtPath" -ForegroundColor Gray
            return
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] BitLocker ativo. Coletando chaves de recuperacao..." -ForegroundColor Gray

        $entries = @()
        foreach ($vol in $volumes) {
            $keys = $vol.KeyProtector | Where-Object { $_.KeyProtectorType -eq 'RecoveryPassword' }
            foreach ($k in $keys) {
                $entries += [PSCustomObject]@{
                    Drive       = $vol.MountPoint
                    Status      = $vol.VolumeStatus
                    Protection  = $vol.ProtectionStatus
                    KeyId       = $k.KeyProtectorId
                    RecoveryKey = $k.RecoveryPassword
                }
            }
        }

        if ($entries.Count -eq 0) {
            $outputStr = (manage-bde.exe -status) -join "`r`n"
            $txtPath = Join-Path $SaveDir "sem bitlocker.txt"
            $date = Get-Date -Format "dd/MM/yyyy HH:mm:ss"
            $txtContent = "BitLocker ativo, mas nenhuma chave de recuperação encontrada.`r`nData/hora: $date`r`n`r`nSaída:`r`n$outputStr"
            [System.IO.File]::WriteAllText($txtPath, $txtContent, [System.Text.Encoding]::UTF8)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Nenhuma chave encontrada. Arquivo salvo: $txtPath" -ForegroundColor Gray
            return
        }

        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Chaves encontradas. Gerando PDF..." -ForegroundColor Gray
        $pdfPath = Join-Path $SaveDir  "$NomeAGR + BITLOCKER.pdf"
        Generate-BitlockerPdf $pdfPath $entries
    }


    function Generate-BitlockerPdf ($pdfPath, $entries) {
        $lines = @()

        foreach ($e in $entries) {
            $d = $e.RecoveryKey.Replace("-", "").Replace(" ", "")
            if ($d.Length -eq 48) {
                $formattedKey = @()
                for ($i = 0; $i -lt 8; $i++) {
                    $formattedKey += $d.Substring($i * 6, 6)
                }
                $recoveryKey = $formattedKey -join "-"
            }
            else {
                $recoveryKey = $e.RecoveryKey
            }

            # Texto reproduzido identico ao padrao nativo do Windows
            $lines += "Chave de recuperação de Criptografia de Unidade de Disco BitLocker"
            $lines += ""
            $lines += "Para verificar se esta é a chave de recuperação correta, compare o início do identificador a"
            $lines += "seguir com o valor do identificador exibido no computador."
            $lines += ""
            $lines += "Identificador:"
            $lines += "$($e.KeyId)"
            $lines += ""
            $lines += "Se o identificador acima corresponder ao que é exibido no computador, use a chave a seguir"
            $lines += "para desbloquear a unidade."
            $lines += ""
            $lines += "Chave de Recuperação:"
            $lines += "$recoveryKey"
            $lines += ""
            $lines += "Se o identificador acima não corresponder ao que é exibido no computador, significa que esta"
            $lines += "não é a chave correta para desbloquear a unidade."
            $lines += "Tente usar outra chave de recuperação ou consulte"
            $lines += "https://go.microsoft.com/fwlink/?LinkID=260589 para obter assistência."
            $lines += ""
            $lines += "============================================================"
            $lines += ""
        }

        $printers = [System.Drawing.Printing.PrinterSettings]::InstalledPrinters
        $pdfPrinter = $null
        foreach ($p in $printers) {
            if ($p.Contains("PDF") -and $p.Contains("Microsoft")) {
                $pdfPrinter = $p
                break
            }
        }

        if (-not $pdfPrinter) {
            $txtPath = $pdfPath.Replace(".pdf", ".txt")
            [System.IO.File]::WriteAllLines($txtPath, $lines, [System.Text.Encoding]::UTF8)
            Write-Host "[$(Get-Date -Format 'HH:mm:ss')] Impressora PDF não encontrada. Salvo como texto (.txt)." -ForegroundColor Gray
            return
        }

        $lineIndex = 0

        # Trocando Consolas por Arial para imitar a tipografia do PDF oficial
        $font = New-Object System.Drawing.Font("Arial", 10.0, [System.Drawing.FontStyle]::Regular)
        $titleFont = New-Object System.Drawing.Font("Arial", 14.0, [System.Drawing.FontStyle]::Regular)
        $lineH = 20

        $pd = New-Object System.Drawing.Printing.PrintDocument
        $pd.PrinterSettings.PrinterName = $pdfPrinter
        $pd.PrinterSettings.PrintToFile = $true
        $pd.PrinterSettings.PrintFileName = $pdfPath
        $pd.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(60, 60, 60, 60)

        $printPageHandler = {
            param($sender, $ev)
            $g = $ev.Graphics
            $y = $ev.MarginBounds.Top
            $x = $ev.MarginBounds.Left
            $bottom = $ev.MarginBounds.Bottom

            while ($script:lineIndex -lt $lines.Count) {
                $line = $lines[$script:lineIndex]

                # O titulo da Microsoft nao costuma ser negrito, mas e visivelmente maior
                $isTitle = $line.StartsWith("Chave de recuperação de Criptografia")

                $lh = if ($isTitle) { $lineH + 10 } else { $lineH }

                if ($y + $lh -gt $bottom) {
                    $ev.HasMorePages = $true
                    return
                }

                $f = if ($isTitle) { $titleFont } else { $font }
                $g.DrawString($line, $f, [System.Drawing.Brushes]::Black, $x, $y)
                $y += $lh
                $script:lineIndex++
            }
            $ev.HasMorePages = $false
        }

        $pd.add_PrintPage($printPageHandler)

        $script:lineIndex = 0
        $pd.Print()
        $pd.Dispose()
        $font.Dispose()
        $titleFont.Dispose()
        Write-Host "[$(Get-Date -Format 'HH:mm:ss')] PDF do BitLocker salvo no padrão nativo: $pdfPath" -ForegroundColor Gray
    }

    # --- Sub-menu de Coleta de Evidencias ---

    $Itens = @(
        @{ Label = "Informações do Sistema (MSINFO32)"; Acao = { Task-MsInfo } },
        @{ Label = "Ativação do Windows (slmgr /dli + /xpr)"; Acao = { Task-AtivacaoWindows } },
        @{ Label = "Endereço MAC (getmac /v)"; Acao = { Task-GetMac } },
        @{ Label = "Serial da BIOS (Win32_Bios)"; Acao = { Task-SerialBios } },
        @{ Label = "Programas e Recursos (appwiz.cpl)"; Acao = { Task-ProgramasRecursos } },
        @{ Label = "BitLocker - Chave de Recuperacao (PDF/TXT)"; Acao = { Task-Bitlocker } }
    )

    function Show-Cabecalho {
        Write-Host ""
        Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor DarkCyan
        Write-Host "  ║          SISTEMA INFO – Coleta de Dados          ║" -ForegroundColor DarkCyan
        Write-Host "  ║   Pasta: Downloads\Prints $NomeAGR" -ForegroundColor DarkCyan
        Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor DarkCyan
        Write-Host ""
    }

    function Show-MenuColeta {
        while ($true) {
            Clear-Host
            Show-Cabecalho

            Write-Host "  Selecione uma ou mais opções (ex: 1,3,5) ou escolha uma opção especial:`n" -ForegroundColor Cyan

            for ($i = 0; $i -lt $Itens.Count; $i++) {
                Write-Host "  [$($i + 1)] " -ForegroundColor White -NoNewline
                Write-Host "$($Itens[$i].Label)" -ForegroundColor Gray
            }

            Write-Host ""
            Write-Host "  [T] Executar TUDO (todas as opções acima)" -ForegroundColor Green
            Write-Host "  [S] Voltar ao menu principal" -ForegroundColor Red
            Write-Host ""
            Write-Host "  Opção: " -NoNewline

            $entrada = Read-Host
            if ($null -eq $entrada) { break }
            $entrada = $entrada.Trim().ToUpper()

            if ($entrada -eq "S") { break }

            $selecionados = @()
            if ($entrada -eq "T") {
                for ($i = 1; $i -le $Itens.Count; $i++) {
                    $selecionados += $i
                }
            }
            else {
                $partes = $entrada.Split(',', [System.StringSplitOptions]::RemoveEmptyEntries)
                foreach ($p in $partes) {
                    $p = $p.Trim()
                    if ($p -match '^\d+$') {
                        $val = [int]$p
                        if ($val -ge 1 -and $val -le $Itens.Count) {
                            $selecionados += $val
                        }
                    }
                }
                $selecionados = $selecionados | Select-Object -Unique | Sort-Object
            }

            if ($selecionados.Count -eq 0) {
                Write-Host "`n  Opção inválida. Pressione qualquer tecla para tentar novamente..." -ForegroundColor Red
                [System.Console]::ReadKey($true) | Out-Null
                continue
            }

            Clear-Host
            Show-Cabecalho

            $nomes = @()
            foreach ($idx in $selecionados) {
                $nomes += $Itens[$idx - 1].Label
            }
            Write-Host "  Executando: $($nomes -join ', ')`n" -ForegroundColor Yellow

            foreach ($idx in $selecionados) {
                try {
                    Write-Host "`n  ── [$idx] $($Itens[$idx - 1].Label) ──" -ForegroundColor Cyan
                    & $Itens[$idx - 1].Acao
                }
                catch {
                    Write-Host "ERRO na tarefa [$idx]: $_" -ForegroundColor Red
                }
            }
            Write-Host "`n  ✔ Concluído! Arquivos salvos em: $SaveDir" -ForegroundColor Green
            Write-Host "`n  Pressione qualquer tecla para voltar ao menu..."
            [System.Console]::ReadKey($true) | Out-Null
        }
    }

    # --- Execucao da Coleta ---
    Clear-Host
    $NomeAGR = (Read-Host "Nome do AGR").ToUpper()
    $SaveDir = Join-Path ([System.Environment]::GetFolderPath("UserProfile")) "Downloads\Prints $NomeAGR"
    [System.IO.Directory]::CreateDirectory($SaveDir) | Out-Null

    Show-MenuColeta
}


# =============================================================================
# OPCAO [2] — DESCONFIGURAR MAQUINA   (integracao do Reverse-Config.ps1)
# =============================================================================
function Desconfigurar-Maquina {
    Clear-Host
    Write-Host "  ── [2] Desconfigurar Maquina (Reverse-Config) ──`n" -ForegroundColor Cyan

    try {

        # ---------------------------------------------------------------------
        # OPCAO A (para uso via `irm | iex` a partir do GitHub):
        # baixa o Reverse-Config.ps1 do repositorio e executa em memoria.
        # Basta manter os dois arquivos no MESMO repo e ajustar $RepoBase no topo.
        # ---------------------------------------------------------------------
        $reversePathLocal = if ($PSScriptRoot) { Join-Path $PSScriptRoot "Reverse-Config.ps1" } else { $null }

        if ($reversePathLocal -and (Test-Path $reversePathLocal)) {
            # Rodando em disco: usa o arquivo ao lado (dot-source para expor as funcoes)
            Write-Host "  Executando arquivo local: $reversePathLocal`n" -ForegroundColor Gray
            & $reversePathLocal
        }
        elseif ($ReverseUrl -and $ReverseUrl -notmatch "SEU-USUARIO") {
            # Rodando via irm: baixa o segundo script do GitHub e executa
            Write-Host "  Baixando e executando: $ReverseUrl`n" -ForegroundColor Gray
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $reverseCode = Invoke-RestMethod -Uri $ReverseUrl -UseBasicParsing
            # Executa o conteudo baixado (o #Requires do topo e ignorado via iex;
            # a elevacao ja foi garantida no inicio do Multiuso.ps1).
            # O Trim([char]0xFEFF) previne o erro de BOM invisível que causa falha no Invoke-Expression
            Invoke-Expression $reverseCode.Trim([char]0xFEFF)
        }
        else {

            # =================================================================
            # >>> ALTERNATIVA: COLE AQUI O CODIGO DO Reverse-Config.ps1 <<<
            #
            # Se preferir NAO baixar do GitHub nem manter arquivo separado,
            # cole abaixo (ate o "FIM DA AREA DE COLAGEM") todo o conteudo do
            # Reverse-Config.ps1 — EXCETO a linha "#Requires -RunAsAdministrator"
            # do topo (a elevacao ja e feita no inicio deste Multiuso.ps1).
            # =================================================================

            Write-Host "  [AVISO] Nenhuma fonte do Reverse-Config disponivel." -ForegroundColor Yellow
            Write-Host "          Ajuste \$RepoBase no topo, coloque o arquivo ao lado" -ForegroundColor Yellow
            Write-Host "          deste script, ou cole o codigo na area reservada." -ForegroundColor Yellow

            # =================================================================
            # >>> FIM DA AREA DE COLAGEM DO SEGUNDO SCRIPT <<<
            # =================================================================
        }

        Write-Host "`n  ✔ Desconfiguracao finalizada." -ForegroundColor Green
    }
    catch {
        Write-Host "`n  ERRO ao desconfigurar a maquina: $_" -ForegroundColor Red
    }
}


# =============================================================================
# OPCAO [3] — CRIAR USUARIO LOCAL
# =============================================================================

# Helper: liga/desliga a politica "A senha deve satisfazer requisitos de
# complexidade" via secedit. Usado para poder criar um usuario com senha
# simples e, em seguida, DEIXAR A POLITICA HABILITADA conforme o print.
function Set-PasswordComplexity {
    param([Parameter(Mandatory)][bool]$Enabled)

    $valor = if ($Enabled) { 1 } else { 0 }
    $inf = @"
[Unicode]
Unicode=yes
[System Access]
PasswordComplexity = $valor
[Version]
signature="`$CHICAGO`$"
Revision = 1
"@
    $tmpInf = "$env:TEMP\complexity_$valor.inf"
    $tmpDb = "$env:TEMP\complexity_$valor.sdb"
    $inf | Out-File -FilePath $tmpInf -Encoding Unicode -Force
    secedit /configure /db $tmpDb /cfg $tmpInf /areas SECURITYPOLICY /quiet | Out-Null
    Remove-Item $tmpInf, $tmpDb -Force -ErrorAction SilentlyContinue
    gpupdate /target:computer /force /wait:0 | Out-Null

    $estado = if ($Enabled) { "HABILITADA" } else { "desabilitada (temporario)" }
    Write-Host "  [INFO] Politica de complexidade de senha: $estado" -ForegroundColor Gray
}

function Criar-UsuarioLocal {
    Clear-Host
    Write-Host "  ── [3] Criar Usuario Local ──`n" -ForegroundColor Cyan

    # 1. Coleta de dados
    $nome = (Read-Host "  Nome do novo usuario").Trim()
    if ([string]::IsNullOrWhiteSpace($nome)) {
        Write-Host "  Nome invalido. Operacao cancelada." -ForegroundColor Red
        return
    }

    if (Get-LocalUser -Name $nome -ErrorAction SilentlyContinue) {
        Write-Host "  O usuario '$nome' ja existe. Operacao cancelada." -ForegroundColor Red
        return
    }

    $senha = Read-Host "  Senha para '$nome'" -AsSecureString
    $ehAdmin = (Read-Host "  Tornar administrador? (S/N)").Trim().ToUpper() -eq "S"

    # 2. Criacao com tratamento de erros (Try/Catch)
    $complexidadeDesligada = $false
    try {
        try {
            # Primeira tentativa — respeitando a politica atual (complexidade Habilitada)
            New-LocalUser -Name $nome -Password $senha -FullName $nome `
                -Description "Criado via Multiuso.ps1" -ErrorAction Stop | Out-Null
        }
        catch {
            # A criacao provavelmente falhou porque a senha nao satisfaz a
            # politica de complexidade exigida no gpedit. Entao:
            #   1) desliga a complexidade temporariamente
            #   2) cria o usuario
            #   3) RELIGA a complexidade (fica "Habilitada" como no print)
            Write-Host "`n  [AVISO] Falha na criacao (possivel bloqueio por complexidade de senha)." -ForegroundColor Yellow
            Write-Host "          Desabilitando complexidade temporariamente para criar o usuario...`n" -ForegroundColor Yellow

            Set-PasswordComplexity -Enabled $false
            $complexidadeDesligada = $true

            New-LocalUser -Name $nome -Password $senha -FullName $nome `
                -Description "Criado via Multiuso.ps1" -ErrorAction Stop | Out-Null
        }

        # 3. Grupo do usuario (Administradores, se solicitado)
        if ($ehAdmin) {
            try {
                Add-LocalGroupMember -Group "Administradores" -Member $nome -ErrorAction Stop
            }
            catch {
                Add-LocalGroupMember -Group "Administrators" -Member $nome -ErrorAction Stop
            }
            Write-Host "  '$nome' adicionado ao grupo Administradores." -ForegroundColor Gray
        }

        Write-Host "`n  ✔ Usuario '$nome' criado com sucesso." -ForegroundColor Green
    }
    catch {
        Write-Host "`n  ERRO ao criar o usuario '$nome': $_" -ForegroundColor Red
    }
    finally {
        # Garante que a politica de complexidade volte a ficar HABILITADA
        # (conforme o print), mesmo que algo tenha dado errado no meio.
        if ($complexidadeDesligada) {
            Write-Host "`n  Restaurando politica de complexidade para HABILITADA (padrao do print)..." -ForegroundColor Gray
            Set-PasswordComplexity -Enabled $true
        }
    }
}


# =============================================================================
# MENU PRINCIPAL — LOOP
# =============================================================================
function Show-MenuPrincipal {
    Write-Host ""
    Write-Host "  ╔══════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "  ║              FERRAMENTA MULTIUSO                  ║" -ForegroundColor Cyan
    Write-Host "  ╚══════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] " -ForegroundColor White -NoNewline; Write-Host "Coletar Evidencias"   -ForegroundColor Gray
    Write-Host "  [2] " -ForegroundColor White -NoNewline; Write-Host "Desconfigurar Maquina" -ForegroundColor Gray
    Write-Host "  [3] " -ForegroundColor White -NoNewline; Write-Host "Criar Usuario"        -ForegroundColor Gray
    Write-Host "  [4] " -ForegroundColor White -NoNewline; Write-Host "Sair"                 -ForegroundColor Red
    Write-Host ""
    Write-Host "  Opção: " -NoNewline
}

while ($true) {
    Clear-Host
    Show-MenuPrincipal
    $opcao = (Read-Host).Trim()

    switch ($opcao) {
        "1" { Coletar-Evidencias }
        "2" { Desconfigurar-Maquina }
        "3" { Criar-UsuarioLocal }
        "4" {
            Write-Host "`n  Encerrando`n" -ForegroundColor Gray
            return
        }
        default {
            Write-Host "`n  Opção inválida." -ForegroundColor Red
        }
    }

    # Apos executar uma tarefa (exceto Sair), pausa e volta ao menu principal
    if ($opcao -ne "4") {
        Write-Host "`n  Pressione qualquer tecla para voltar ao menu principal..."
        [System.Console]::ReadKey($true) | Out-Null
    }
}
