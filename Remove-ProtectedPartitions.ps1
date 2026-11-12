<#
.SYNOPSIS
    Borra particiones "protegidas" (EFI/ESP, MSR, Recovery, OEM, ocultas, y GPT
    con el atributo "required" / bit 63) y opcionalmente limpia el disco completo.

.DESCRIPTION
    Windows/diskpart se niega a borrar ciertas particiones por diseño:
      * Particiones GPT marcadas como "required" (EFI, MSR, Recovery, OEM).
      * Particiones MBR de tipo OEM (0x12), Recovery (0x27), etc.
      * Volumenes en uso (pagefile, BitLocker, punto de montaje activo).
      * Discos en solo lectura / offline / write-protected.

    Este script escala en una cascada de intentos, del menos al mas agresivo:
      1. Remove-Partition (cmdlet nativo de Storage)
      2. diskpart: gpt attributes=0x0 + attributes volume clear * + delete partition override
      3. diskpart: set id=<tipo datos basicos> override + delete partition override
      4. (-Aggressive) libera bloqueos: BitLocker off, mountvol /p, fsutil dismount,
         elimina pagefile, apaga hibernacion, offline/online del disco y reintenta
      5. (-Clean / -CleanAll) diskpart clean [all] y, si falla, Clear-Disk -RemoveOEM

.PARAMETER DiskNumber
    Numero(s) de disco a tratar. Se obtienen con -List o con Get-Disk.

.PARAMETER List
    Solo muestra discos y particiones. No modifica nada.

.PARAMETER Clean
    Borra TODAS las particiones del disco con "diskpart clean" (rapido).
    Si diskpart falla, usa Clear-Disk -RemoveData -RemoveOEM como respaldo.

.PARAMETER CleanAll
    Igual que -Clean pero con "clean all" (rellena el disco con ceros). Lento:
    puede tardar horas. Implica -Clean.

.PARAMETER Aggressive
    Libera bloqueos antes de reintentar: BitLocker off, pagefile, mountvol /p,
    fsutil dismount, powercfg /h off, y limpia el flag WriteProtect de USB.

.PARAMETER Force
    No pide confirmacion. NO permite operar sobre el disco del sistema: ese
    disco se detecta, se excluye del listado y se rechaza siempre (tambien con
    -Force). Para limpiarlo, arranque desde WinPE/USB.

.PARAMETER DryRun
    Muestra el plan y los comandos diskpart que se ejecutarian, sin tocar nada.

.PARAMETER InitializeDisk
    Se conserva por compatibilidad: equivale a -AutoManage.

.PARAMETER AutoManage
    Tras borrar, deja el disco usable automaticamente: lo inicializa en GPT (si
    esta RAW), crea una particion que ocupa todo el disco, la formatea y, al
    final, hace que Windows la "agarre" (letra, montaje y etiqueta). Sin esto,
    Windows muestra el disco como "no reconocido" (RAW) hasta que se le cree un
    volumen. Nunca recrea particiones que ya existan.

.PARAMETER Prepare
    No borra nada: solo deja el disco formateado y montado (letra + etiqueta).
    Si el disco esta vacio crea el volumen; si ya tiene una particion sin
    sistema de archivos la formatea EN SU SITIO; si ya esta formateada solo la
    finaliza. No se puede combinar con -Clean ni -CleanAll.

.PARAMETER VolumeLabel
    Etiqueta del volumen administrado. Por defecto: ALMACENAMIENTO.

.PARAMETER FileSystem
    Sistema de archivos para -AutoManage / -Prepare: NTFS (por defecto), exFAT
    o FAT32 (FAT32 no admite volumenes mayores de 32 GB).

.PARAMETER LogPath
    Ruta del log. Por defecto %TEMP%\wipe-protected-AAAAmmdd-HHmmss.log

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -List

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 2 -DryRun

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 2 -Aggressive

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 2,3 -Clean -Force

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Aggressive -AutoManage

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Clean -AutoManage -VolumeLabel "DATOS" -FileSystem exFAT

.EXAMPLE
    .\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Prepare -Force

.NOTES
    Destructivo e irreversible. Verifique SIEMPRE el numero de disco.
    Para el disco del sistema en uso: arranque desde WinPE/USB y ejecute alli.
#>

[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [int[]]$DiskNumber,

    [switch]$List,
    [switch]$Clean,
    [switch]$CleanAll,
    [switch]$Aggressive,
    [switch]$Force,
    [switch]$DryRun,
    [switch]$InitializeDisk,
    [switch]$AutoManage,
    [switch]$Prepare,
    [string]$VolumeLabel = 'ALMACENAMIENTO',
    [ValidateSet('NTFS', 'exFAT', 'FAT32')]
    [string]$FileSystem = 'NTFS',
    [string]$LogPath
)

# ---------------------------------------------------------------------------
#  Entorno
# ---------------------------------------------------------------------------
$ErrorActionPreference = 'Stop'
if (Test-Path variable:PSNativeCommandUseErrorActionPreference) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (-not $LogPath) {
    $LogPath = Join-Path $env:TEMP ('wipe-protected-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
}
$script:LogPath  = $LogPath
$script:Simulate = [bool]$DryRun
$script:Aggressive = [bool]$Aggressive

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1,-5}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level, $Message
    $color = switch ($Level) {
        'OK'    { 'Green' }
        'WARN'  { 'Yellow' }
        'ERROR' { 'Red' }
        default { 'Gray' }
    }
    Write-Host $line -ForegroundColor $color
    try { Add-Content -LiteralPath $script:LogPath -Value $line -Encoding UTF8 } catch { }
}

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    (New-Object Security.Principal.WindowsPrincipal($id)).IsInRole(
        [Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Auto-elevacion: reconstruye los parametros recibidos y relanza como admin.
if (-not (Test-Admin)) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath))
    foreach ($k in $PSBoundParameters.Keys) {
        if ($k -eq 'LogPath') { continue }
        $v = $PSBoundParameters[$k]
        if ($v -is [System.Management.Automation.SwitchParameter]) {
            if ($v.IsPresent) { $argList += "-$k" }
        }
        elseif ($v -is [array]) {
            $argList += "-$k"
            $argList += (($v | ForEach-Object { "$_" }) -join ',')
        }
        else {
            $argList += "-$k"
            $argList += ('"{0}"' -f $v)
        }
    }
    Write-Host 'Se requieren permisos de administrador. Solicitando elevacion (UAC)...' -ForegroundColor Yellow
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host 'No se pudo elevar. Abra PowerShell "como administrador" y vuelva a ejecutar.' -ForegroundColor Red
    }
    exit
}

Write-Log "Log: $script:LogPath"
Write-Log ("Equipo: {0} | Windows {1}" -f $env:COMPUTERNAME, [Environment]::OSVersion.Version)

# -Prepare no borra nada: combinarlo con -Clean/-CleanAll seria contradictorio.
if ($Prepare -and ($Clean -or $CleanAll)) {
    Write-Log '-Prepare no borra particiones: no se puede combinar con -Clean ni -CleanAll.' 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
#  Helpers
# ---------------------------------------------------------------------------
function Add-DiskPartNoErr {
    <#  DiskPart NO acepta 'noerr' como parametro del ejecutable: es un parametro
        POR COMANDO y solo en los documentados. Se anade aqui para que un
        comando que falle (p. ej. 'attributes volume' en una MSR/EFI) no aborte
        el resto del script. 'select', 'gpt', 'clean', 'rescan', 'san' y
        'set id' se dejan tal cual. #>
    param([string[]]$Commands)

    $supports = @('attributes', 'delete', 'format', 'assign', 'create', 'online', 'offline', 'remove')
    foreach ($c in $Commands) {
        $first = ($c.Trim() -split '\s+')[0].ToLowerInvariant()
        if (($supports -contains $first) -and ($c -notmatch '(?i)\bnoerr\b')) {
            "$c noerr"
        }
        else {
            $c
        }
    }
}

function Invoke-DiskPart {
    <#  Ejecuta un script diskpart desde archivo temporal.
        Devuelve un objeto con salida, codigo y si tuvo exito. #>
    param(
        [Parameter(Mandatory)][string[]]$Commands,
        [string]$Context = 'diskpart'
    )

    $lines  = @(Add-DiskPartNoErr -Commands $Commands)
    $pretty = $lines -join '  ;  '
    if ($script:Simulate) {
        Write-Log "[DRYRUN] $Context -> $pretty" 'WARN'
        return [pscustomobject]@{ Output = ''; ExitCode = 0; Success = $true }
    }

    $tmp = Join-Path $env:TEMP ('dp-{0}.txt' -f ([guid]::NewGuid().ToString('N')))
    try {
        # ASCII y CRLF: diskpart falla o ignora lineas si el archivo lleva BOM UTF-8.
        Set-Content -LiteralPath $tmp -Value $lines -Encoding ASCII
        Write-Log "diskpart [$Context] -> $pretty"
        try {
            # OJO: 'noerr' va dentro del script (por comando), NO en la linea
            # de comandos del ejecutable: 'diskpart /s archivo noerr' falla con
            # "DiskPart no puede procesar los parámetros".
            $out  = (& diskpart.exe /s $tmp 2>&1 | Out-String)
            $code = $LASTEXITCODE
        } catch {
            # diskpart no pudo arrancar (p. ej. sin elevacion): no abortar todo.
            $out  = $_.Exception.Message
            $code = 1
        }
        $bad  = $out -match '(?i)encountered an error|ha encontrado un error|not allowed|no se permite|denied|denegado|protected|protegid'
        if ($out.Trim()) {
            Write-Log ("diskpart [{0}] salida: {1}" -f $Context, ($out.Trim() -replace '\r?\n', ' / '))
        }
        [pscustomobject]@{
            Output   = $out
            ExitCode = $code
            Success  = (-not $bad -and $code -eq 0)
        }
    }
    finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

function Update-StorageCache {
    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch { }
}

function Get-ProtectedDisks {
    <#  Detecta el/los discos que no se pueden borrar porque contienen el sistema
        operativo en ejecucion. Combina varias fuentes para no depender de una:
          A) Flags de Windows (IsBoot / IsSystem)
          B) Unidad del SO ($env:SystemDrive)     -> particion -> disco
          C) Carpeta de Windows ($env:SystemRoot) -> particion -> disco
          D) Respaldo CIM (Win32_LogicalDisk -> Win32_DiskDrive)
        Devuelve Numbers (int[]) y Reasons (hashtable numero -> motivo). #>
    $reasons = @{}

    # A) Flags de Windows
    try {
        foreach ($d in @(Get-Disk -ErrorAction SilentlyContinue)) {
            $why = @()
            if ($d.IsBoot)   { $why += 'IsBoot' }
            if ($d.IsSystem) { $why += 'IsSystem' }
            if ($why.Count -gt 0) {
                $n = [int]$d.Number
                if ($reasons.ContainsKey($n)) { $reasons[$n] = "$($reasons[$n]), $($why -join ', ')" }
                else                          { $reasons[$n] = ($why -join ', ') }
            }
        }
    } catch { }

    # B y C) Unidad del SO y carpeta de Windows
    $letters = @()
    if ($env:SystemDrive) {
        $letters += $env:SystemDrive.TrimEnd('\').Substring(0, 1)
    }
    if ($env:SystemRoot) {
        try { $letters += (Split-Path -Qualifier $env:SystemRoot).TrimEnd('\').Substring(0, 1) } catch { }
    }
    foreach ($dl in ($letters | Select-Object -Unique)) {
        try {
            $p = Get-Partition -DriveLetter $dl -ErrorAction Stop
            $n = [int]$p.DiskNumber
            if ($reasons.ContainsKey($n)) { $reasons[$n] = "$($reasons[$n]), SO en ${dl}:" }
            else                          { $reasons[$n] = "SO en ${dl}:" }
        } catch { }
    }

    # D) Respaldo CIM si aun no hay nada
    if ($reasons.Count -eq 0 -and $env:SystemDrive) {
        try {
            $idx = Get-CimInstance Win32_LogicalDisk -Filter ("DeviceID='{0}'" -f $env:SystemDrive) -ErrorAction Stop |
                Get-CimAssociatedInstance -Association Win32_LogicalDiskToPartition -ErrorAction Stop |
                Get-CimAssociatedInstance -Association Win32_DiskDriveToDiskPartition -ErrorAction Stop |
                Select-Object -ExpandProperty Index -ErrorAction SilentlyContinue
            foreach ($i in @($idx)) { $reasons[[int]$i] = 'SO (deteccion CIM)' }
        } catch { }
    }

    [pscustomobject]@{
        Numbers = [int[]]@($reasons.Keys)
        Reasons = $reasons
    }
}

function Test-PartitionAtOffset {
    <#  Verifica si sigue existiendo una particion en un offset dado.
        Se usa el offset (no el numero) porque diskpart/Windows renumera. #>
    param(
        [int]$Disk,
        [UInt64]$Offset,
        [int]$WaitMs = 400
    )
    if ($WaitMs -gt 0) { Start-Sleep -Milliseconds $WaitMs }
    Update-StorageCache
    $found = Get-Partition -DiskNumber $Disk -ErrorAction SilentlyContinue |
             Where-Object { [UInt64]$_.Offset -eq $Offset }
    return [bool]$found
}

function Release-PartitionLocks {
    <#  -Aggressive: intenta soltar todo lo que impide borrar la particion. #>
    param(
        [int]$Disk,
        [int]$PartitionNumber
    )

    $p = Get-Partition -DiskNumber $Disk -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    if (-not $p) { return }

    foreach ($ap in @($p.AccessPaths)) {
        if ($ap -match '^[A-Za-z]:\\$') {
            $vol = $ap.Substring(0, 2)
            Write-Log "Liberando volumen $vol ..." 'INFO'

            # Quitar pagefile que viva en ese volumen
            try {
                Get-CimInstance Win32_PageFileSetting -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -like "$vol*" } |
                    ForEach-Object {
                        Write-Log "Eliminando pagefile $($_.Name)" 'WARN'
                        Remove-CimInstance -InputObject $_ -ErrorAction SilentlyContinue
                    }
            } catch { }

            # BitLocker: desactivar (no pide clave si el volumen esta desbloqueado)
            try { & manage-bde.exe -off $vol 2>&1 | Out-Null } catch { }

            # Quitar letra y desmontar
            try { & mountvol.exe $vol /p 2>&1 | Out-Null } catch { }
            try { & fsutil.exe volume dismount $vol 2>&1 | Out-Null } catch { }

            Start-Sleep -Milliseconds 500
        }
    }
}

function Get-AttributeCommands {
    param([int]$Disk, [int]$PartitionNumber, [bool]$IsGpt)
    $cmds = @("select disk $Disk", "select partition $PartitionNumber")
    # Primero los atributos del volumen (admiten 'noerr'), al final 'gpt': si
    # 'gpt' falla no impide haber limpiado antes los atributos del volumen.
    $cmds += @(
        'attributes volume clear readonly',
        'attributes volume clear hidden',
        'attributes volume clear nodefaultdriveletter',
        'attributes volume clear shadowcopy'
    )
    if ($IsGpt) { $cmds += 'gpt attributes=0x0000000000000000' }   # quita bit "required"
    return $cmds
}

function Remove-OnePartition {
    <#  Cascada de intentos para UNA particion. Devuelve $true si ya no existe. #>
    param(
        [int]$Disk,
        [int]$PartitionNumber,
        [UInt64]$Offset,
        [bool]$IsGpt
    )

    $label = "Disco $Disk / Particion $PartitionNumber (offset $Offset)"
    if (-not (Test-PartitionAtOffset -Disk $Disk -Offset $Offset -WaitMs 0)) {
        Write-Log "$label ya no existe." 'OK'
        return $true
    }

    if ($script:Simulate) {
        Write-Log "[DRYRUN] Se borraria $label" 'WARN'
        Invoke-DiskPart -Commands (Get-AttributeCommands -Disk $Disk -PartitionNumber $PartitionNumber -IsGpt $IsGpt) `
                        -Context "$label atributos" | Out-Null
        Invoke-DiskPart -Commands @("select disk $Disk", "select partition $PartitionNumber", 'delete partition override') `
                        -Context "$label delete override" | Out-Null
        return $true
    }

    # ---- Intento 1: cmdlet nativo -----------------------------------------
    try {
        Remove-Partition -DiskNumber $Disk -PartitionNumber $PartitionNumber -Confirm:$false -ErrorAction Stop
        if (-not (Test-PartitionAtOffset -Disk $Disk -Offset $Offset)) {
            Write-Log "$label borrada con Remove-Partition." 'OK'
            return $true
        }
    } catch {
        Write-Log "${label}: Remove-Partition fallo -> $($_.Exception.Message.Trim())" 'WARN'
    }

    # ---- Intento 2: limpiar atributos + delete override -------------------
    Invoke-DiskPart -Commands (Get-AttributeCommands -Disk $Disk -PartitionNumber $PartitionNumber -IsGpt $IsGpt) `
                    -Context "$label atributos" | Out-Null
    Invoke-DiskPart -Commands @(
        "select disk $Disk",
        "select partition $PartitionNumber",
        'delete partition override'
    ) -Context "$label delete override" | Out-Null

    if (-not (Test-PartitionAtOffset -Disk $Disk -Offset $Offset)) {
        Write-Log "$label borrada con 'delete partition override'." 'OK'
        return $true
    }

    # ---- Intento 3: cambiar tipo de particion y reintentar ----------------
    $newId = if ($IsGpt) { 'ebd0a0a2-b9e5-4433-87c0-68b6b72699c7' } else { '07' }
    Invoke-DiskPart -Commands @(
        "select disk $Disk",
        "select partition $PartitionNumber",
        "set id=$newId override"
    ) -Context "$label set id" | Out-Null
    # 'delete' va aparte: aunque 'set id' falle, el borrado se intenta igual.
    Invoke-DiskPart -Commands @(
        "select disk $Disk",
        "select partition $PartitionNumber",
        'delete partition override'
    ) -Context "$label delete tras set id" | Out-Null

    if (-not (Test-PartitionAtOffset -Disk $Disk -Offset $Offset)) {
        Write-Log "$label borrada cambiando el tipo de particion." 'OK'
        return $true
    }

    # ---- Intento 4: liberar bloqueos (-Aggressive) ------------------------
    if ($script:Aggressive) {
        Write-Log "$label sigue presente. Liberando bloqueos (modo agresivo)..." 'WARN'
        [void](Release-PartitionLocks -Disk $Disk -PartitionNumber $PartitionNumber)

        # Ciclo offline/online: reinicia el estado del disco y suelta handles de VDS
        Invoke-DiskPart -Commands @("select disk $Disk", 'offline disk') -Context "$label offline" | Out-Null
        Start-Sleep -Milliseconds 500
        Invoke-DiskPart -Commands @("select disk $Disk", 'online disk') -Context "$label online" | Out-Null
        Start-Sleep -Seconds 1

        Invoke-DiskPart -Commands (Get-AttributeCommands -Disk $Disk -PartitionNumber $PartitionNumber -IsGpt $IsGpt) `
                        -Context "$label retry agresivo (atributos)" | Out-Null
        Invoke-DiskPart -Commands @(
            "select disk $Disk",
            "select partition $PartitionNumber",
            'delete partition override'
        ) -Context "$label retry agresivo (delete)" | Out-Null

        if (-not (Test-PartitionAtOffset -Disk $Disk -Offset $Offset)) {
            Write-Log "$label borrada en modo agresivo." 'OK'
            return $true
        }
    }

    Write-Log "$label NO se pudo borrar (probablemente en uso o bloqueada por firmware/SAN)." 'ERROR'
    return $false
}

function Finalize-Volume {
    <#  Hace que Windows "agarre" un volumen ya formateado: refresca la
        enumeracion, pone el disco online, asigna letra si falta, limpia los
        atributos que ocultan el volumen y REAPLICA la etiqueta.
        NUNCA borra ni recrea particiones ni volumenes.
        Devuelve un objeto con Ok / Drive / Detail. #>
    param(
        [int]$Number,
        [int]$PartitionNumber,
        [string]$Label = 'ALMACENAMIENTO'
    )

    $out = [pscustomobject]@{ Ok = $false; Drive = ''; Detail = '' }

    # 1) Refrescar: que Windows reenumere disco, particion y volumen
    try { Update-Disk -Number $Number -ErrorAction SilentlyContinue } catch { }
    Update-StorageCache
    Invoke-DiskPart -Commands @('rescan') -Context 'rescan (finalizar)' | Out-Null
    Invoke-DiskPart -Commands @("select disk $Number", 'online disk', 'attributes disk clear readonly') `
                    -Context "finalizar disco $Number" | Out-Null
    Update-StorageCache

    # 2) Quitar atributos que impiden montar el volumen
    Invoke-DiskPart -Commands @(
        "select disk $Number",
        "select partition $PartitionNumber",
        'attributes volume clear readonly',
        'attributes volume clear hidden',
        'attributes volume clear nodefaultdriveletter'
    ) -Context 'finalizar atributos del volumen' | Out-Null

    Update-StorageCache

    # 3) Esperar a que el volumen exista y este sano (hasta ~9 s)
    $part = $null
    $vol  = $null
    for ($i = 0; $i -lt 15; $i++) {
        $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
        if (-not $part) { Start-Sleep -Milliseconds 600; continue }
        $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
        if ($vol -and $vol.HealthStatus -eq 'Healthy') { break }
        Start-Sleep -Milliseconds 600
    }

    if (-not $part) {
        $out.Detail = "no se encontro la particion $PartitionNumber del disco $Number"
        Write-Log "Finalizar: $($out.Detail)." 'ERROR'
        return $out
    }

    # 4) Asegurar letra de unidad (sin ella Explorer no lo muestra)
    if (-not $part.DriveLetter) {
        Write-Log "Finalizar: la particion $PartitionNumber no tiene letra; asignando..." 'WARN'
        try {
            Add-PartitionAccessPath -DiskNumber $Number -PartitionNumber $PartitionNumber -AssignDriveLetter -ErrorAction Stop
        } catch {
            Write-Log "Finalizar: Add-PartitionAccessPath fallo ($($_.Exception.Message.Trim())). Probando letra libre..." 'WARN'
            $used = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } |
                      Select-Object -ExpandProperty DriveLetter)
            $free = @([char[]](70..90) | Where-Object { $used -notcontains $_ })
            if ($free.Count -gt 0) {
                try {
                    Set-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber `
                                  -NewDriveLetter $free[0] -ErrorAction Stop
                } catch {
                    Write-Log "Finalizar: tampoco se pudo asignar letra: $($_.Exception.Message.Trim())" 'WARN'
                }
            }
        }
        Start-Sleep -Milliseconds 800
        Update-StorageCache
        $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    }

    # 5) Reaplicar la etiqueta de forma independiente al formateo
    if ($part) { $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue }
    if ($vol -and $vol.FileSystem -and $vol.FileSystem -ne 'RAW') {
        for ($i = 1; $i -le 2; $i++) {
            if ($vol.FileSystemLabel -eq $Label) { break }
            try {
                Set-Volume -DriveLetter $vol.DriveLetter -NewFileSystemLabel $Label -ErrorAction Stop
            } catch {
                Write-Log "Finalizar: Set-Volume fallo ($($_.Exception.Message.Trim()))." 'WARN'
            }
            Start-Sleep -Milliseconds 700
            Update-StorageCache
            $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
            if (-not $vol) { break }
        }
    }

    # 6) Que el sistema (y el USB) vuelva a ver el volumen
    try { & mountvol.exe /a 2>&1 | Out-Null } catch { }
    try { & pnputil.exe /scan-devices 2>&1 | Out-Null } catch { }
    Update-StorageCache
    Start-Sleep -Milliseconds 500

    $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    $vol  = if ($part) { Get-Volume -Partition $part -ErrorAction SilentlyContinue } else { $null }

    $drive = if ($part -and $part.DriveLetter) { "$($part.DriveLetter):" } else { '' }
    $out.Drive = $drive

    if (-not $vol -or -not $vol.FileSystem -or $vol.FileSystem -eq 'RAW') {
        $out.Detail = if ($drive) { "$drive sin sistema de archivos reconocido" }
                      else { 'volumen sin sistema de archivos reconocido' }
        Write-Log "Finalizar: $($out.Detail)." 'ERROR'
        return $out
    }

    $mounted = [bool]$drive
    $out.Detail = ('{0} {1} etiqueta ''{2}'' {3} GB {4}' -f `
        ($(if ($drive) { $drive } else { '(sin letra)' })), $vol.FileSystem, $vol.FileSystemLabel,
        [math]::Round($vol.Size / 1GB, 1), ($(if ($mounted) { 'montado' } else { 'SIN MONTAR' })))
    $out.Ok = $mounted -and ($vol.HealthStatus -eq 'Healthy')

    if ($out.Ok) {
        Write-Log "Finalizar: volumen listo -> $($out.Detail)." 'OK'
    } else {
        Write-Log "Finalizar: el volumen NO quedo montado/sano -> $($out.Detail)." 'ERROR'
    }
    return $out
}

function Mount-PartitionVolume {
    <#  Espera a que Windows cree el volumen de la particion y le asigna una
        letra de unidad (montaje). No formatea ni borra nada.
        Devuelve Ok / Drive / Detail. #>
    param(
        [int]$Number,
        [int]$PartitionNumber,
        [int]$TimeoutSec = 15
    )

    $out = [pscustomobject]@{ Ok = $false; Drive = ''; Detail = '' }

    # 1) Esperar a que exista el volumen de la particion
    $part = $null
    $vol  = $null
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
        if ($part) {
            $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
            if ($vol) { break }
        }
        Update-StorageCache
        Start-Sleep -Milliseconds 600
    }

    # 2) Si la particion existe pero no hay volumen, forzar el montaje
    if ($part -and -not $vol) {
        Write-Log "Montar: el volumen de la particion $PartitionNumber aun no aparece; forzando 'assign'..." 'WARN'
        Invoke-DiskPart -Commands @("select disk $Number", "select partition $PartitionNumber", 'assign') `
                        -Context 'montar volumen' | Out-Null
        Start-Sleep -Milliseconds 800
        Update-StorageCache
        $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
        if ($part) { $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue }
    }

    if (-not $part -or -not $vol) {
        $out.Detail = "el volumen de la particion $PartitionNumber no se creo"
        Write-Log "Montar: $($out.Detail)." 'ERROR'
        return $out
    }

    # 3) Letra de unidad (sin ella Explorer no muestra la unidad)
    if (-not $part.DriveLetter) {
        Write-Log "Montar: la particion $PartitionNumber no tiene letra; asignando..." 'WARN'
        try {
            Add-PartitionAccessPath -DiskNumber $Number -PartitionNumber $PartitionNumber -AssignDriveLetter -ErrorAction Stop
        } catch {
            Write-Log "Montar: Add-PartitionAccessPath fallo ($($_.Exception.Message.Trim())). Probando letra libre..." 'WARN'
            $used = @(Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter } |
                      Select-Object -ExpandProperty DriveLetter)
            $free = @([char[]](70..90) | Where-Object { $used -notcontains $_ })
            if ($free.Count -gt 0) {
                try {
                    Set-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber `
                                  -NewDriveLetter $free[0] -ErrorAction Stop
                } catch {
                    Write-Log "Montar: tampoco se pudo asignar letra: $($_.Exception.Message.Trim())" 'WARN'
                }
            }
        }
        Start-Sleep -Milliseconds 800
        Update-StorageCache
        $part = Get-Partition -DiskNumber $Number -PartitionNumber $PartitionNumber -ErrorAction SilentlyContinue
    }

    $out.Ok    = [bool]($part -and $part.DriveLetter)
    $out.Drive = if ($out.Ok) { "$($part.DriveLetter):" } else { '' }
    $out.Detail = if ($out.Ok) { "volumen montado en $($out.Drive)" } else { 'volumen sin letra de unidad' }

    if ($out.Ok) { Write-Log "Montar: $($out.Detail)." 'OK' }
    else         { Write-Log "Montar: $($out.Detail)." 'ERROR' }
    return $out
}

function Set-DiskAsStorage {
    <#  Deja el disco formateado y usable SIN recrear nada. La MSR (Type
        'Reserved') que crea Initialize-Disk NO cuenta como particion de datos.
          - 0 particiones de datos -> crea una con el espacio libre.
          - 1 particion de datos   -> si no tiene sistema de archivos la
                                      formatea EN SU SITIO; si ya esta
                                      formateada no la toca.
          En ambos casos, el orden es: crear -> esperar volumen -> montar ->
          formatear -> renombrar -> finalizar.
        Devuelve un objeto con Ok / Skipped / Drive / Detail. #>
    param(
        [int]$Number,
        [string]$Label = 'ALMACENAMIENTO',
        [string]$FileSystem = 'NTFS'
    )

    $out = [pscustomobject]@{ Ok = $false; Skipped = $false; Drive = ''; Detail = '' }

    try { $disk = Get-Disk -Number $Number -ErrorAction Stop }
    catch {
        $out.Detail = "disco $Number no accesible"
        Write-Log "Administrar: $($out.Detail)." 'ERROR'
        return $out
    }

    if ($disk.IsSystem -or $disk.IsBoot) {
        $out.Detail = "el disco $Number es de sistema; no se administra"
        Write-Log "Administrar: $($out.Detail)." 'ERROR'
        return $out
    }

    # Normalizar estado del disco
    if ($disk.IsReadOnly) {
        try { Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop } catch { }
    }
    if ($disk.IsOffline) {
        try { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop } catch { }
    }
    Update-StorageCache
    Invoke-DiskPart -Commands @('rescan') -Context 'rescan (administrar)' | Out-Null
    Update-StorageCache

    $disk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    if (-not $disk) {
        $out.Detail = "disco $Number desaparecio tras el rescan"
        Write-Log "Administrar: $($out.Detail)." 'ERROR'
        return $out
    }

    if ($disk.PartitionStyle -eq 'RAW') {
        try {
            Initialize-Disk -Number $Number -PartitionStyle GPT -ErrorAction Stop
            Update-StorageCache
            Write-Log "Disco $Number inicializado en GPT (crea la MSR de 16 MB)." 'OK'
        } catch {
            $out.Detail = "no se pudo inicializar el disco ${Number}: $($_.Exception.Message.Trim())"
            Write-Log "Administrar: $($out.Detail)." 'ERROR'
            return $out
        }
    }

    # La MSR (Reserved) y las particiones de sistema/recuperacion no son
    # particiones de datos: no se cuentan ni se formatean.
    $allParts  = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue | Sort-Object PartitionNumber)
    $dataParts = @($allParts | Where-Object { $_.Type -notin @('Reserved', 'System', 'Recovery') })

    if ($dataParts.Count -gt 1) {
        $out.Skipped = $true
        $out.Detail  = "el disco $Number tiene $($dataParts.Count) particiones de datos; no se toca (revise a mano)"
        Write-Log "Administrar: $($out.Detail)." 'WARN'
        return $out
    }

    $part = if ($dataParts.Count -eq 1) { $dataParts[0] } else { $null }

    # --- 1) Crear la particion de datos si no existe ----------------------
    if (-not $part) {
        Write-Log "Disco $Number sin particiones de datos: creando una con el espacio libre..." 'INFO'
        try {
            $part = New-Partition -DiskNumber $Number -UseMaximumSize -ErrorAction Stop
        } catch {
            $out.Detail = "no se pudo crear la particion: $($_.Exception.Message.Trim())"
            Write-Log "Administrar: $($out.Detail)." 'ERROR'
            return $out
        }
        Update-StorageCache
        Start-Sleep -Milliseconds 500
    }

    # --- 2) Montar: esperar a que Windows cree el volumen y darle letra ----
    $mount = Mount-PartitionVolume -Number $Number -PartitionNumber $part.PartitionNumber
    if (-not $mount.Ok) {
        $out.Detail = $mount.Detail
        Write-Log "Administrar: $($out.Detail)." 'ERROR'
        return $out
    }

    Update-StorageCache
    $part = Get-Partition -DiskNumber $Number -PartitionNumber $part.PartitionNumber -ErrorAction SilentlyContinue
    $vol  = if ($part) { Get-Volume -Partition $part -ErrorAction SilentlyContinue } else { $null }
    if (-not $part) {
        $out.Detail = "la particion desaparecio antes de formatear"
        Write-Log "Administrar: $($out.Detail)." 'ERROR'
        return $out
    }

    # --- 3) Formatear (solo si no tiene sistema de archivos) --------------
    $needsFormat = (-not $vol) -or (-not $vol.FileSystem) -or ($vol.FileSystem -eq 'RAW')

    if ($needsFormat) {
        Write-Log "Particion $($part.PartitionNumber) sin sistema de archivos: formateando como $FileSystem..." 'WARN'
        $formatted = $false
        for ($i = 1; $i -le 3 -and -not $formatted; $i++) {
            try {
                Format-Volume -Partition $part -FileSystem $FileSystem -NewFileSystemLabel $Label `
                              -Confirm:$false -ErrorAction Stop | Out-Null
                $formatted = $true
            } catch {
                Write-Log "Administrar: intento de formateo $i fallo: $($_.Exception.Message.Trim())" 'WARN'
                Start-Sleep -Seconds 1

                # Respaldo con diskpart para volumenes que el cmdlet no ve aun
                if ($i -ge 2) {
                    $fsDp = $FileSystem.ToLowerInvariant()
                    Invoke-DiskPart -Commands @(
                        "select disk $Number",
                        "select partition $($part.PartitionNumber)",
                        "format quick fs=$fsDp label=`"$Label`""
                    ) -Context 'formatear (diskpart)' | Out-Null
                }

                Update-StorageCache
                $part = Get-Partition -DiskNumber $Number -PartitionNumber $part.PartitionNumber -ErrorAction SilentlyContinue
                if (-not $part) { break }
                $vol = Get-Volume -Partition $part -ErrorAction SilentlyContinue
                if ($vol -and $vol.FileSystem -and $vol.FileSystem -ne 'RAW') { $formatted = $true }
            }
        }

        if (-not $formatted) {
            $out.Detail = "no se pudo formatear como $FileSystem (pruebe -FileSystem exFAT)"
            Write-Log "Administrar: $($out.Detail)." 'ERROR'
            return $out
        }
    }
    else {
        Write-Log "Particion $($part.PartitionNumber) ya formateada ($($vol.FileSystem)); no se reformatea ni se recrea." 'INFO'
    }

    # --- 4) Renombrar como $Label (despues de formatear) ------------------
    Update-StorageCache
    Start-Sleep -Milliseconds 500
    $part = Get-Partition -DiskNumber $Number -PartitionNumber $part.PartitionNumber -ErrorAction SilentlyContinue
    $vol  = if ($part) { Get-Volume -Partition $part -ErrorAction SilentlyContinue } else { $null }
    if ($vol -and $vol.FileSystem -and $vol.FileSystem -ne 'RAW' -and $vol.FileSystemLabel -ne $Label) {
        try {
            Set-Volume -DriveLetter $vol.DriveLetter -NewFileSystemLabel $Label -ErrorAction Stop
            Write-Log ("Renombrado: {0} -> '{1}'." -f $vol.DriveLetter, $Label) 'OK'
        } catch {
            Write-Log "Renombrar fallo ($($_.Exception.Message.Trim())); se reintenta en la finalizacion." 'WARN'
        }
    }

    # --- 5) Finalizar siempre: refresco, letra, montaje y etiqueta --------
    $fin = Finalize-Volume -Number $Number -PartitionNumber $part.PartitionNumber -Label $Label
    $out.Drive  = $fin.Drive
    $out.Detail = $fin.Detail
    $out.Ok     = $fin.Ok
    return $out
}

function Invoke-DiskOperation {
    param([int]$Number)

    $result = [ordered]@{
        Disco          = $Number
        Modelo         = ''
        Inicial        = 0
        Final          = 0
        Resultado      = 'ERROR'
        Detalle        = ''
    }

    try {
        $disk = Get-Disk -Number $Number -ErrorAction Stop
    } catch {
        Write-Log "El disco $Number no existe o no es accesible." 'ERROR'
        $result.Detalle = 'Disco no encontrado'
        return [pscustomobject]$result
    }

    # Defensa en profundidad: nunca operar sobre el disco del SO en ejecucion,
    # aunque la validacion previa se hubiera saltado.
    $protectedNumbers = @()
    if ($script:Protection) { $protectedNumbers = @($script:Protection.Numbers) }
    if ($disk.IsSystem -or $disk.IsBoot -or ($protectedNumbers -contains [int]$Number)) {
        $motivo = 'Disco del sistema operativo en ejecucion'
        if ($script:Protection -and $script:Protection.Reasons.ContainsKey([int]$Number)) {
            $motivo = $script:Protection.Reasons[[int]$Number]
        }
        Write-Log "Disco $Number PROTEGIDO: $motivo. Se omite." 'ERROR'
        $result.Resultado = 'PROTEGIDO'
        $result.Detalle   = $motivo
        return [pscustomobject]$result
    }

    $result.Modelo  = $disk.FriendlyName
    $result.Inicial = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue).Count

    Write-Log ('=== Disco {0}: {1} | {2} | {3:N1} GB | Style={4} | IsBoot={5} IsSystem={6} RO={7} Offline={8} ===' -f `
            $Number, $disk.FriendlyName, $disk.BusType, ($disk.Size / 1GB),
            $disk.PartitionStyle, $disk.IsBoot, $disk.IsSystem, $disk.IsReadOnly, $disk.IsOffline) 'INFO'

    # --- Normalizar estado del disco ---------------------------------------
    if ($disk.IsReadOnly) {
        Write-Log "Disco $Number en solo lectura. Quitando proteccion..." 'WARN'
        try { Set-Disk -Number $Number -IsReadOnly $false -ErrorAction Stop } catch {
            Write-Log "Set-Disk IsReadOnly fallo: $($_.Exception.Message)" 'WARN'
        }
        Invoke-DiskPart -Commands @("select disk $Number", 'attributes disk clear readonly') -Context 'clear readonly' | Out-Null
    }
    if ($disk.IsOffline) {
        Write-Log "Disco $Number offline. Poniendolo online..." 'WARN'
        try { Set-Disk -Number $Number -IsOffline $false -ErrorAction Stop } catch {
            Write-Log "Set-Disk IsOffline fallo: $($_.Exception.Message)" 'WARN'
        }
        Invoke-DiskPart -Commands @("select disk $Number", 'online disk') -Context 'online disk' | Out-Null
    }

    # Refrescar estado local
    $disk = Get-Disk -Number $Number -ErrorAction SilentlyContinue
    $isGpt = ($disk.PartitionStyle -eq 'GPT')

    # --- Modos de borrado (con -Prepare no se borra nada) -----------------
    $doPrepare    = [bool]$Prepare
    $doAutoManage = [bool]($AutoManage -or $InitializeDisk -or $doPrepare)

    if ($doPrepare) {
        Write-Log "Modo -Prepare: no se borra ninguna particion del disco $Number." 'INFO'
    }
    elseif ($Clean -or $CleanAll) {
        $cleanCmd = if ($CleanAll) { 'clean all' } else { 'clean' }
        Write-Log "Limpiando disco $Number completo ($cleanCmd)..." 'WARN'

        # san policy es global: se ejecuta aislado para no abortar el resto si falla
        Invoke-DiskPart -Commands @('san policy=onlineall') -Context 'san policy' | Out-Null
        Invoke-DiskPart -Commands @("select disk $Number", 'attributes disk clear readonly') -Context "prep clean $Number" | Out-Null
        Invoke-DiskPart -Commands @("select disk $Number", $cleanCmd) -Context "clean disco $Number" | Out-Null

        Start-Sleep -Seconds 1
        Update-StorageCache

        $left = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0 -and -not $script:Simulate) {
            Write-Log "diskpart $cleanCmd dejo $($left.Count) particion(es). Probando Clear-Disk -RemoveOEM..." 'WARN'
            try {
                Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                Update-StorageCache
            } catch {
                Write-Log "Clear-Disk fallo: $($_.Exception.Message.Trim())" 'ERROR'
            }
        }
    }
    else {
        # --- Modo particion por particion ---------------------------------
        $parts = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue |
                   Sort-Object PartitionNumber -Descending)

        if ($parts.Count -eq 0) {
            Write-Log "El disco $Number no tiene particiones." 'INFO'
        }

        foreach ($p in $parts) {
            [void](Remove-OnePartition -Disk $Number -PartitionNumber $p.PartitionNumber `
                                        -Offset ([UInt64]$p.Offset) -IsGpt $isGpt)
        }

        # Si quedaron particiones y el disco es 100% objetivo, ultimo recurso:
        $left = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
        if ($left.Count -gt 0 -and $script:Aggressive -and -not $script:Simulate) {
            Write-Log "Quedan $($left.Count) particion(es). Ultimo recurso: Clear-Disk -RemoveOEM..." 'WARN'
            try {
                Clear-Disk -Number $Number -RemoveData -RemoveOEM -Confirm:$false -ErrorAction Stop
                Update-StorageCache
            } catch {
                Write-Log "Clear-Disk fallo: $($_.Exception.Message.Trim())" 'ERROR'
            }
        }
    }

    # --- Dejar el disco formateado, montado y con etiqueta ----------------
    $managed = $null
    if ($doAutoManage) {
        if ($script:Simulate) {
            Write-Log "[DRYRUN] Se administraria el disco ${Number}: GPT si esta RAW, volumen $FileSystem formateado si hace falta y finalizacion (letra + montaje + etiqueta '$VolumeLabel'). No se recrean particiones." 'WARN'
        } else {
            $managed = Set-DiskAsStorage -Number $Number -Label $VolumeLabel -FileSystem $FileSystem
        }
    }

    Update-StorageCache
    $final = @(Get-Partition -DiskNumber $Number -ErrorAction SilentlyContinue)
    $result.Final = $final.Count

    if ($script:Simulate) {
        $result.Resultado = 'DRYRUN'
        $result.Detalle   = 'Sin cambios (simulacion)'
        return [pscustomobject]$result
    }

    if ($managed -and $managed.Ok) {
        $result.Resultado = 'LISTO'
        $result.Detalle   = $managed.Detail
        Write-Log "Disco ${Number}: volumen listo ($($managed.Detail))." 'OK'
    }
    elseif ($managed -and $managed.Skipped -and $doPrepare) {
        $result.Resultado = 'OMITIDO'
        $result.Detalle   = $managed.Detail
        Write-Log "Disco ${Number}: $($managed.Detail)." 'WARN'
    }
    elseif ($doAutoManage) {
        $result.Resultado = 'PARCIAL'
        $result.Detalle   = if ($managed -and $managed.Detail) { $managed.Detail } else { 'No se pudo administrar el volumen' }
        Write-Log "Disco ${Number}: $($result.Detalle)." 'ERROR'
    }
    elseif ($final.Count -eq 0) {
        $result.Resultado = 'LIMPIO'
        $result.Detalle   = 'Sin particiones'
        Write-Log "Disco ${Number}: sin particiones. OK" 'OK'
        Write-Log "Disco ${Number} quedo en RAW (Windows lo vera como 'no reconocido'). Use -AutoManage para crear el volumen '$VolumeLabel'." 'INFO'
    }
    else {
        $result.Resultado = 'PARCIAL'
        $result.Detalle   = ('Quedan: ' + (($final | ForEach-Object { $_.PartitionNumber }) -join ', '))
        Write-Log "Disco ${Number}: quedan $($final.Count) particion(es): $($result.Detalle)" 'ERROR'
    }

    return [pscustomobject]$result
}

# ---------------------------------------------------------------------------
#  Deteccion del disco del sistema (se excluye de la seleccion)
# ---------------------------------------------------------------------------
$script:Protection = Get-ProtectedDisks
$protectedNumbers  = @($script:Protection.Numbers)

if ($protectedNumbers.Count -gt 0) {
    $detalle = ($protectedNumbers | Sort-Object | ForEach-Object { "disco $_ ($($script:Protection.Reasons[[int]$_]))" }) -join '; '
    Write-Log "Disco(s) del sistema protegido(s): $detalle" 'INFO'
} else {
    Write-Log 'Aviso: no se pudo identificar el disco del sistema por flags; se usara la verificacion en ejecucion.' 'WARN'
}

# ---------------------------------------------------------------------------
#  -List
# ---------------------------------------------------------------------------
$hasDiskArgument = $PSBoundParameters.ContainsKey('DiskNumber') -and (@($DiskNumber).Count -gt 0)

if ($List -or -not $hasDiskArgument) {
    $allDisks  = @(Get-Disk | Sort-Object Number)
    $safeDisks = @($allDisks | Where-Object { $protectedNumbers -notcontains [int]$_.Number })

    Write-Host ''
    Write-Host '=== DISCOS SELECCIONABLES ===' -ForegroundColor Cyan
    if ($safeDisks.Count -gt 0) {
        $safeDisks | Format-Table -AutoSize `
            Number, FriendlyName, BusType, @{n = 'GB'; e = { [math]::Round($_.Size / 1GB, 1) } },
            PartitionStyle, OperationalStatus, IsReadOnly
    } else {
        Write-Host '  (ninguno)' -ForegroundColor Yellow
    }

    if ($protectedNumbers.Count -gt 0) {
        Write-Host ''
        Write-Host '=== DISCO DEL SISTEMA (PROTEGIDO, NO SELECCIONABLE) ===' -ForegroundColor Yellow
        foreach ($n in ($protectedNumbers | Sort-Object)) {
            $d = $allDisks | Where-Object { [int]$_.Number -eq [int]$n } | Select-Object -First 1
            $motivo = $script:Protection.Reasons[[int]$n]
            if ($d) {
                Write-Host ("  Disco {0}: {1} | {2} | {3:N1} GB | {4}" -f `
                        $n, $d.FriendlyName, $d.BusType, ($d.Size / 1GB), $motivo) -ForegroundColor Yellow
            } else {
                Write-Host ("  Disco {0}: {1}" -f $n, $motivo) -ForegroundColor Yellow
            }
        }
        Write-Host '  (no se puede elegir; para limpiarlo arranque desde WinPE/USB)' -ForegroundColor DarkYellow
    }

    Write-Host ''
    Write-Host '=== PARTICIONES (discos seleccionables) ===' -ForegroundColor Cyan
    $safeParts = @(Get-Partition -ErrorAction SilentlyContinue |
                   Where-Object { $protectedNumbers -notcontains [int]$_.DiskNumber } |
                   Sort-Object DiskNumber, PartitionNumber)
    if ($safeParts.Count -gt 0) {
        $safeParts | Format-Table -AutoSize `
            DiskNumber, PartitionNumber, DriveLetter, Type,
            @{n = 'GB'; e = { [math]::Round($_.Size / 1GB, 2) } }, Offset, IsHidden, IsActive
    } else {
        Write-Host '  (ninguna)' -ForegroundColor Yellow
    }

    if (-not $hasDiskArgument) {
        Write-Host 'Indique el disco a tratar:  .\Remove-ProtectedPartitions.ps1 -DiskNumber <n> [-Aggressive] [-Clean] [-AutoManage] [-Prepare]' -ForegroundColor Yellow
        Write-Host "Log: $script:LogPath" -ForegroundColor DarkGray
        exit 0
    }
}

# ---------------------------------------------------------------------------
#  Validacion de discos objetivo
# ---------------------------------------------------------------------------
$requested = @($DiskNumber | Select-Object -Unique)
$blocked   = @($requested | Where-Object { $protectedNumbers -contains [int]$_ })

if ($blocked.Count -gt 0) {
    foreach ($b in $blocked) {
        $motivo = $script:Protection.Reasons[[int]$b]
        Write-Log ("Disco {0} PROTEGIDO: {1}. No se puede seleccionar." -f $b, $motivo) 'ERROR'
    }
    Write-Host ''
    Write-Host '*** SELECCION RECHAZADA ***' -ForegroundColor Red
    Write-Host 'Uno de los discos indicados contiene el sistema operativo en ejecucion.' -ForegroundColor Red
    Write-Host 'Ese disco no se puede borrar desde Windows, ni con -Force.' -ForegroundColor Red
    Write-Host 'Para limpiarlo, arranque desde WinPE/USB y ejecute el script alli.' -ForegroundColor Red
    Write-Log 'Abortado: se selecciono el disco del sistema operativo.' 'ERROR'
    exit 2
}

$targets = @()
foreach ($n in $requested) {
    try {
        $d = Get-Disk -Number $n -ErrorAction Stop
        $targets += $d
    } catch {
        Write-Log "Disco $n no encontrado. Se omite." 'ERROR'
    }
}

if ($targets.Count -eq 0) {
    Write-Log 'No hay discos validos para procesar.' 'ERROR'
    exit 1
}

Write-Host ''
Write-Host '=== PLAN ===' -ForegroundColor Cyan
$targets | ForEach-Object {
    [pscustomobject]@{
        Disco   = $_.Number
        Modelo  = $_.FriendlyName
        Bus     = $_.BusType
        GB      = [math]::Round($_.Size / 1GB, 1)
        Estilo  = $_.PartitionStyle
        Sistema = ($_.IsSystem -or $_.IsBoot)
        Serie   = $_.SerialNumber
        Partics = @(Get-Partition -DiskNumber $_.Number -ErrorAction SilentlyContinue).Count
    }
} | Format-Table -AutoSize
Write-Host ("Modo: {0} | Agresivo: {1} | Administrar: {2} ({3}, etiqueta '{4}') | DryRun: {5}" -f `
        ($(if ($Prepare) { 'PREPARE (sin borrar)' } elseif ($CleanAll) { 'CLEAN ALL (ceros)' } elseif ($Clean) { 'CLEAN (todo el disco)' } else { 'particion por particion' })),
        $Aggressive, ($AutoManage -or $InitializeDisk -or $Prepare), $FileSystem, $VolumeLabel, $DryRun) -ForegroundColor DarkGray

Write-Host ''
Write-Host '=== OBJETIVO (verifique numero, modelo, bus y serie) ===' -ForegroundColor Yellow
foreach ($t in $targets) {
    Write-Host ("  Disco {0}: {1} | {2} | {3:N1} GB | serie: {4}" -f `
            $t.Number, $t.FriendlyName, $t.BusType, ($t.Size / 1GB), $t.SerialNumber) -ForegroundColor Yellow
}

if (-not $Force -and -not $DryRun) {
    Write-Host ''
    if ($Prepare) {
        Write-Host '*** MODO PREPARE: NO SE BORRAN PARTICIONES ***' -ForegroundColor Yellow
        Write-Host 'Se dejara el disco formateado, con letra y etiqueta.' -ForegroundColor Yellow
        Write-Host 'Solo se formatea una particion que no tenga sistema de archivos.' -ForegroundColor Yellow
    } else {
        Write-Host '*** OPERACION DESTRUCTIVA E IRREVERSIBLE ***' -ForegroundColor Red
        Write-Host 'Se perderan TODOS los datos de las particiones indicadas.' -ForegroundColor Red
    }
    $answer = Read-Host 'Escriba SI (mayusculas) para continuar'
    if ($answer -ne 'SI') {
        Write-Log 'Cancelado por el usuario.' 'WARN'
        exit 3
    }
}

# ---------------------------------------------------------------------------
#  Preparacion global en modo agresivo
# ---------------------------------------------------------------------------
if ($Aggressive -and -not $DryRun -and -not $Prepare) {
    Write-Log 'Modo agresivo: apagando hibernacion y limpiando WriteProtect de USB...' 'WARN'
    try { & powercfg.exe /h off 2>&1 | Out-Null } catch { }

    # Flag WriteProtect de medios extraibles (HKLM\SYSTEM\...\StorageDevicePolicies)
    try {
        foreach ($hive in @('HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies',
                            'HKLM:\SYSTEM\CurrentControlSet\Control\StorageDevicePolicies\CurrentControlSet')) {
            if (Test-Path $hive) {
                Set-ItemProperty -Path $hive -Name WriteProtect -Value 0 -Type DWord -ErrorAction SilentlyContinue
                Write-Log "WriteProtect=0 aplicado en $hive (requiere reinicio para algunos USB)." 'WARN'
            }
        }
    } catch { }
}

# ---------------------------------------------------------------------------
#  Ejecucion
# ---------------------------------------------------------------------------
$results = @()
foreach ($t in $targets) {
    $results += Invoke-DiskOperation -Number $t.Number
}

Write-Host ''
Write-Host '=== RESUMEN ===' -ForegroundColor Cyan
$results | Format-Table -AutoSize Disco, Modelo, Inicial, Final, Resultado, Detalle

$failed = @($results | Where-Object { $_.Resultado -notin @('LIMPIO', 'LISTO', 'DRYRUN', 'OMITIDO') })
Write-Log ("Terminado. Discos OK: {0} | Con restos: {1}" -f ($results.Count - $failed.Count), $failed.Count) `
    $(if ($failed.Count -eq 0) { 'OK' } else { 'WARN' })
Write-Host "Log completo: $script:LogPath" -ForegroundColor DarkGray

if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host 'Sugerencias si quedaron particiones:' -ForegroundColor Yellow
    Write-Host '  1) Repita con -Aggressive (libera BitLocker, pagefile y handles).' -ForegroundColor Yellow
    Write-Host '  2) Si es el disco del sistema en uso, arranque desde WinPE/USB.' -ForegroundColor Yellow
    Write-Host '  3) Discos SAN/RAID/virtuales: libere el LUN, quite solo-lectura o el Storage Space.' -ForegroundColor Yellow
    Write-Host '  4) Consulte README.md (seccion "Bloqueos que NO son de software").' -ForegroundColor Yellow
    exit 1
}

exit 0
