# Borrado de particiones protegidas (diskpart override)

Herramienta para eliminar particiones que Windows/DiskPart normalmente rechazan:
**EFI/ESP, MSR, Recovery, OEM, ocultas**, particiones GPT marcadas como
*required* (bit 63) y volúmenes bloqueados por atributos, BitLocker, pagefile
o por estar "en uso".

> ⚠️ **Destructivo e irreversible.** Borra tablas de particiones y datos sin
> posibilidad de recuperación sencilla. Verifique siempre el **número de disco**
> con `-List` antes de ejecutar. No lo use en equipos de producción sin respaldo.
>
> 💡 Si va a probarlo con un disco externo (USB/UGREEN), siga la sección
> **[Probar con un disco extra](#probar-con-un-disco-extra-usb--ugreen-sin-dañar-el-equipo)**.

---

## Archivos

| Archivo | Para qué sirve |
|---|---|
| `Remove-ProtectedPartitions.ps1` | Script principal (cascada de métodos, logging, resumen). |
| `Ejecutar-como-Admin.bat` | Doble clic: lista discos o lanza el script con los argumentos que le pase. |
| `diskpart-comandos.txt` | Plantilla manual de DiskPart equivalente, para ejecutar a mano. |
| `README.md` | Este documento. |

Requisitos: Windows 10/11 o Server 2016+, PowerShell 5.1+, consola **elevada**
(el script se auto-eleva pidiendo UAC).

### Cómo ejecutarlo (paso a paso)

1. Abra **PowerShell como administrador**: botón Inicio → escriba `PowerShell` →
   clic derecho → *Ejecutar como administrador*.
   *(No haga doble clic sobre el `.ps1`: Windows lo abre en el Bloc de notas.)*
2. Vaya a la carpeta del proyecto:
   ```powershell
   cd "C:\Users\SISTEMAS5\Desktop\Proyectos ayuntamiento\Script_delete_part_protected"
   ```
3. Si PowerShell bloquea el script por política de ejecución:
   ```powershell
   Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
   ```
4. Ejecute **en este orden**: `-List` → `-DryRun` → operación real. Escriba `SI`
   cuando lo pida.
5. El resultado queda en pantalla y en `%TEMP%\wipe-protected-*.log`.

#### Ejemplo completo con el disco de pruebas (USB/UGREEN)

```powershell
# a) Ver discos (no modifica nada)
.\Remove-ProtectedPartitions.ps1 -List

# b) Simulación sobre el disco 3 (no modifica nada)
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -DryRun

# c) Borrado real (pide escribir SI)
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Aggressive
```

Antes de confirmar, compruebe el bloque `=== OBJETIVO ===`:

```text
Disco 3: ST500DM002-1BD142 | USB | 465.8 GB | serie: 0000000000000000
```

Si el número, el bus (`USB`), el modelo y el tamaño coinciden con el disco que
quiere borrar, escriba `SI`. Si algo no cuadra, cancele (cualquier otra tecla).

#### Qué esperar

| Paso | Resultado |
|---|---|
| `-List` | Discos seleccionables + disco del sistema marcado como protegido; no toca nada. |
| `-DryRun` | `=== PLAN ===`, `=== OBJETIVO ===` y comandos `select disk 3`, `gpt attributes=0x0`, `delete partition override` simulados. Termina en segundos. |
| `-Aggressive` | Borra las 4 particiones (Recovery, datos, MSR, EFI); `=== RESUMEN ===` con `LIMPIO` y `Con restos: 0`. Tarda segundos. |
| `-AutoManage` | Además de lo anterior, crea el volumen (letra + etiqueta `ALMACENAMIENTO` + montaje); `RESUMEN` = `LISTO`. |
| `-Prepare` | No borra nada: deja un disco ya formateado montado y con nombre; `RESUMEN` = `LISTO` u `OMITIDO`. |
| `-CleanAll` | Rellena con ceros: **horas**. No usar por USB. |

Si el resumen sale `PARCIAL`, el log indica qué partición se resistió y por qué;
vea *Solución de problemas* y *Bloqueos que NO son de software*.

#### Si usa el `.bat`

Doble clic en `Ejecutar-como-Admin.bat` (sin argumentos solo lista) o
`Ejecutar-como-Admin.bat -DiskNumber 3 -DryRun`. Ojo: al auto-elevarse, la
ventana que hace el trabajo se cierra al terminar; el detalle queda en el log.
Para ver todo en vivo, use la consola elevada del paso 1.

#### Recordatorios

- En modo partición-por-partición se borran **todas** las particiones del disco
  indicado (en el disco 3, también la F: de ~465 GB).
- El número de disco del USB cambia al reconectar: repita `-List` y guíese por
  `Bus = USB` + modelo + tamaño.
- Lo que haga sobre el disco 3 no afecta a C: ni a los discos internos 0/1/2.

---

## Uso rápido

```powershell
# Sustituya <n> por el número de disco (siempre verifíquelo con -List)

# 1) Ver discos y particiones (no modifica nada)
.\Remove-ProtectedPartitions.ps1 -List

# 2) Simulación: muestra lo que haría, sin tocar el disco
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -DryRun

# 3) Borrar todas las particiones del disco (incluye EFI/MSR/Recovery/OEM)
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Aggressive

# 4) Limpiar el disco y dejarlo listo (GPT + volumen "ALMACENAMIENTO")
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Clean -AutoManage -Force

# 5) Borrado seguro con ceros (lento, horas según tamaño)
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -CleanAll -Force

# 6) Varios discos a la vez
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3,4 -Clean -Force

# 7) Borrar y dejar el volumen con otra etiqueta o sistema de archivos
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Aggressive -AutoManage -VolumeLabel "DATOS"

# 8) Arreglar un disco ya formateado que Windows no muestra (sin borrar nada)
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Prepare
```

Doble clic en `Ejecutar-como-Admin.bat` sin argumentos = listado de discos.
Con argumentos, los reenvía al script:

```bat
Ejecutar-como-Admin.bat -DiskNumber 2 -Aggressive
```

---

## Parámetros

| Parámetro | Efecto |
|---|---|
| `-DiskNumber <n[,n]>` | Disco(s) objetivo. Obligatorio salvo con `-List`. El disco del SO en ejecución se rechaza siempre. |
| `-List` | Muestra discos seleccionables, el disco del sistema (protegido) y sus particiones. |
| `-Clean` | `diskpart clean`: borra **todas** las particiones (rápido). Respaldo con `Clear-Disk -RemoveOEM`. |
| `-CleanAll` | `diskpart clean all`: igual pero rellena con ceros (lento). Implica `-Clean`. |
| `-Aggressive` | Libera bloqueos: BitLocker off, pagefile, `mountvol /p`, `fsutil dismount`, offline/online, hibernación off, limpia `WriteProtect` de USB. |
| `-Force` | Sin confirmación. **No** permite el disco del sistema: ese disco se rechaza siempre. **Cuidado igualmente.** |
| `-DryRun` | Muestra comandos sin ejecutarlos. |
| `-InitializeDisk` | Alias de `-AutoManage` (se conserva por compatibilidad). |
| `-AutoManage` | Tras limpiar: inicializa en GPT, crea partición al máximo, formatea y **finaliza** (letra, montaje, etiqueta `ALMACENAMIENTO`). Nunca recrea particiones existentes. |
| `-Prepare` | **No borra nada**: deja el disco formateado y montado con letra y etiqueta. Si ya está formateado, solo lo finaliza. |
| `-VolumeLabel <texto>` | Etiqueta del volumen administrado (por defecto `ALMACENAMIENTO`). |
| `-FileSystem <FS>` | `NTFS` (por defecto), `exFAT` o `FAT32` (FAT32 ≤ 32 GB). |
| `-LogPath <ruta>` | Log alternativo (por defecto `%TEMP%\wipe-protected-*.log`). |

### Dejar el disco listo automáticamente (`-AutoManage`)

Al borrar las particiones el disco queda en **`RAW`**: Windows no lo monta y en
Explorer aparece como *"no reconocido"* o pide formatearlo. `-AutoManage`
resuelve eso en la misma pasada:

1. Pone el disco online y sin solo-lectura.
2. Lo inicializa en **GPT** si está `RAW`.
3. Si no hay ninguna partición **de datos**, crea **una** que ocupa el disco.
   La partición **MSR** (`Type = Reserved`, 16 MB) que crea Windows al
   inicializar en GPT **no cuenta** como partición de datos: se ignora.
4. **Monta la unidad**: espera hasta 15 s a que exista el volumen y le asigna
   letra (`Add-PartitionAccessPath -AssignDriveLetter`, respaldo de letra libre
   + `Set-Partition -NewDriveLetter`, respaldo DiskPart `assign`).
5. **Formatea** (`-FileSystem`, por defecto **NTFS**) — solo si no tiene
   sistema de archivos. Si ya está formateada **no se reformatea**.
6. **Renombra al final** con `Set-Volume -NewFileSystemLabel`
   (**`ALMACENAMIENTO`**, cambiable con `-VolumeLabel`).
7. **Finaliza el volumen** (esto es lo que hace que Windows lo "agarre"):
   - `rescan` + `Update-HostStorageCache` para reenumerar.
   - limpia `hidden` / `nodefaultdriveletter` / `readonly`.
   - se asegura de que siga teniendo letra.
   - espera a que el volumen esté `Healthy`.
   - `mountvol /a` + `pnputil /scan-devices` para que aparezca al instante.

> Orden: **montar → crear el volumen (si falta) → formatear → renombrar**.
> Formatear antes de que el volumen esté montado es lo que producía el error
> `no encontró objetos MSFT_Volume que coincidan`.

Resumen final esperado:

```text
Disco 3: volumen listo (F: NTFS etiqueta 'ALMACENAMIENTO' 465.1 GB montado).
```

Comportamiento según el estado del disco (**nunca recrea**):

| Estado del disco | Acción |
|---|---|
| 0 particiones de datos (`RAW` o solo MSR) | inicializa GPT → crea partición → **monta** → formatea → renombra → finaliza |
| 1 partición **con** sistema de archivos | monta → **solo renombra/finaliza**. No borra ni reformatea |
| 1 partición **sin** sistema de archivos (`RAW`) | monta → la formatea **en su sitio** → renombra → finaliza |
| 2+ particiones de datos | no toca nada y avisa (`OMITIDO`) |

La partición **MSR** (`Reserved`) y las de tipo `System`/`Recovery` nunca se
formatean ni cuentan para decidir.

```powershell
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Aggressive -AutoManage
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Clean -AutoManage -VolumeLabel "DATOS" -FileSystem exFAT
```

### Arreglar un disco ya formateado (`-Prepare`)

Para el caso *"lo formateé pero Windows no lo muestra / no tiene nombre"*:

```powershell
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Prepare
```

- **No borra** particiones ni volúmenes.
- Disco vacío → crea y formatea; disco con volumen → solo asigna letra, monta
  y pone la etiqueta `ALMACENAMIENTO`.
- No se puede combinar con `-Clean` ni `-CleanAll` (error).
- `-Aggressive` no aporta nada aquí (no se ejecuta la preparación agresiva).

Notas:

- Nunca actúa sobre el disco de sistema/arranque.
- `FAT32` no admite volúmenes > 32 GB; para USB grande use `NTFS` o `exFAT`.
- Si no usa `-AutoManage` ni `-Prepare`, el script avisa al final de que el
  disco quedó en `RAW` y cómo crear el volumen.

---

## Protección del disco del sistema (no aparece para borrar)

El script identifica el disco donde está corriendo Windows y lo **excluye de la
lista de seleccionables**. Si alguien teclea su número, la operación se rechaza
aunque use `-Force`.

Detección combinada (no depende de una sola fuente):

1. `Get-Disk` → discos con `IsBoot` o `IsSystem`.
2. `$env:SystemDrive` (`C:`) → `Get-Partition -DriveLetter` → `DiskNumber`.
3. `$env:SystemRoot` (`C:\Windows`) → volumen → partición → disco.
4. Respaldo CIM (`Win32_LogicalDisk` → `Win32_DiskDrive`) si el módulo Storage
   no responde.

En `-List` se ve así:

```text
=== DISCOS SELECCIONABLES ===
Number Modelo Bus GB Estilo ...

=== DISCO DEL SISTEMA (PROTEGIDO, NO SELECCIONABLE) ===
  Disco 2: ORICO | NVMe | 238.5 GB | IsBoot, IsSystem, SO en C:
```

Si se intenta seleccionar:

```text
Disco 2 PROTEGIDO: IsBoot, IsSystem, SO en C:. No se puede seleccionar.
*** SELECCION RECHAZADA ***
```

Sale con código 2. Si se mezcla un disco válido con el protegido
(`-DiskNumber 2,3`), se aborta toda la ejecución: así no hay borrados parciales
inesperados.

Notas:

- **WinPE**: el disco de Windows *offline* no está marcado `IsBoot/IsSystem`, por
  eso **sí** se puede limpiar desde WinPE; el USB de arranque puede quedar
  protegido (correcto).
- **Multi-arranque**: solo se protege el disco del SO **en ejecución**. Otro
  Windows instalado en otro disco no se detecta (pendiente en el backlog).
- Este bloqueo **no** aplica a la plantilla manual `diskpart-comandos.txt`.

---

## Probar con un disco extra (USB / UGREEN) sin dañar el equipo

**Regla de oro:** el script solo actúa sobre el **número de disco** que se le
pasa; nunca barre todos los discos. Aun así, el número **cambia** al reconectar
el USB, así que valide siempre **modelo + bus + tamaño + serie** (el plan ahora
los muestra).

### 0. Identificar el disco correcto

```powershell
Get-Disk | Sort-Object Number | Format-Table -AutoSize `
    Number, FriendlyName, BusType, @{n='GB';e={[math]::Round($_.Size/1GB,1)}},
    PartitionStyle, IsBoot, IsSystem, SerialNumber

Get-Partition -DiskNumber 3 | Format-Table -AutoSize `
    PartitionNumber, DriveLetter, Type, Size, Offset, IsHidden
```

Criterios para el disco de pruebas:

- `BusType = USB` (el UGREEN).
- `IsBoot = False` y `IsSystem = False`.
- Modelo/tamaño esperados (ej.: `ST500DM002`, ~465.8 GB).
- El disco del sistema **no aparecerá** en `-List` (sale en la tabla de
  protegidos); si aparece como seleccionable, deténgase y revise.
- **Prueba de descarte:** desconecte el UGREEN y vuelva a listar; el disco que
  desaparece es el suyo.

### 1. Aislar el entorno

- Desconecte los discos internos que no quiera tocar, o simplemente no los
  seleccione.
- Use un puerto USB directo (sin hub) y evite que el equipo suspenda el USB.
- Cierre Explorador de Windows y antivirus que tengan abierta la letra del
  disco de pruebas.
- No use `-Force` aquí: la confirmación `SI` es la última red de seguridad.

### 2. Ensayo (no toca nada)

```powershell
.\Remove-ProtectedPartitions.ps1 -List
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -DryRun
```

Verifique en la salida:

- Tabla **PLAN** con `Disco = 3`, `Bus = USB` y la serie correcta.
- Línea **OBJETIVO** con el modelo y tamaño del UGREEN.
- Comandos simulados `select disk 3`, `gpt attributes=0x0` y
  `delete partition override` para las 4 particiones.

### 3. Prueba real escalonada

Un disco clonado como el del UGREEN (EFI + MSR + datos + Recovery) es el caso
ideal. **Ojo:** en modo partición-por-partición el script borra **todas** las
particiones del disco seleccionado, no solo una.

```powershell
# 3a) Borrado real de todas las particiones, incluida la Recovery y la EFI
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Aggressive
#    -> escriba SI cuando lo pida

# 3b) Comprobar que quedó limpio (ver paso 4)

# 3c) Probar el otro camino: limpieza total
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Clean

# 3d) Dejarlo formateado y usable (GPT + volumen "ALMACENAMIENTO")
.\Remove-ProtectedPartitions.ps1 -DiskNumber 3 -Clean -AutoManage -Force
```

Si solo quiere borrar **una** partición protegida y conservar el resto, use la
plantilla manual `diskpart-comandos.txt` (Opción A), no este script.

### 4. Verificar el resultado

```powershell
Get-Partition -DiskNumber 3          # debe quedar vacío
Get-Disk -Number 3 | Format-List Number, FriendlyName, PartitionStyle, Size, OperationalStatus
Get-Content (Get-ChildItem "$env:TEMP\wipe-protected-*.log" |
            Sort-Object LastWriteTime | Select-Object -Last 1)
```

Esperado: `PartitionStyle = RAW`, resumen `LIMPIO` y `Con restos: 0`.
El log conserva cada comando DiskPart y su salida real.

### 5. Dejar el disco listo para usar

```powershell
Initialize-Disk -Number 3 -PartitionStyle GPT
New-Partition -DiskNumber 3 -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "PRUEBAS"
```

### Qué NO hacer

- No ejecute `-Clean` sobre los discos **0, 1 o 2** de este equipo.
- No use `-CleanAll` en un USB: tarda horas y el adaptador puede desconectarse
  a mitad. Para SSD, `clean` es suficiente (o `blkdiscard` desde Linux live).
- No omita `-DryRun` la primera vez que use un disco nuevo.
- No pruebe con datos únicos sin respaldo: el borrado es irreversible.

### Alternativa sin hardware: máquina virtual

Hyper-V, VMware o VirtualBox con discos virtuales de 2–8 GB y una **instantánea
(snapshot)** previa. DiskPart y el script funcionan igual dentro de la VM, y
puede probar `-CleanAll` sin desgastar un SSD real. Es la forma más segura de
validar casos raros (discos de solo lectura, particiones MSR, etc.).

### Si el USB se desconecta a mitad de la operación

El script reportará la partición restante y saldrá con código 1. El disco
interno **no corre riesgo** (solo se opera sobre el número indicado): reconecte
el UGREEN, vuelva a `-List` (el número puede cambiar) y repita. Para evitarlo:
Administrador de dispositivos → concentrador USB → *Administración de energía* →
desmarcar *Permitir que el equipo apague este dispositivo*.

---

## Cómo “salta” las restricciones (cascada de intentos)

Por cada partición, en este orden:

1. **`Remove-Partition`** (cmdlet de Storage). Funciona en particiones normales.
2. **Atributos + override**:
   ```text
   select disk N
   select partition P
   gpt attributes=0x0000000000000000     <- quita el bit "required" (0x8000...)
   attributes volume clear readonly
   attributes volume clear hidden
   attributes volume clear nodefaultdriveletter
   attributes volume clear shadowcopy
   delete partition override             <- clave: "override" ignora OEM/EFI/MSR/Recovery
   ```
3. **Cambiar el tipo de partición** y reintentar:
   ```text
   set id=ebd0a0a2-b9e5-4433-87c0-68b6b72699c7 override   (GPT -> datos básicos)
   set id=07 override                                     (MBR -> NTFS)
   delete partition override
   ```
4. **`-Aggressive`**: desactiva BitLocker, quita pagefile del volumen, elimina
   la letra (`mountvol /p`), desmonta (`fsutil volume dismount`), hace
   `offline disk` / `online disk` para reiniciar el estado del disco y reintenta.
5. **`-Clean` / `-CleanAll`**: `diskpart clean` (con `san policy=onlineall` y
   `attributes disk clear readonly`) y, si aún quedan restos,
   `Clear-Disk -RemoveData -RemoveOEM`.

Además, al inicio de cada disco: quita solo-lectura (`Set-Disk -IsReadOnly $false`
+ `attributes disk clear readonly`) y lo pone online si está offline.

Por qué funciona: `delete partition override` es el modificador oficial de
DiskPart para forzar el borrado de particiones marcadas como protegidas, y el
atributo GPT `0x8000000000000000` es el que marca EFI/MSR/Recovery como
"required". Poniéndolo a `0` desaparece la protección lógica.

---

## Lo que **no** se puede saltar por software

Si tras `-Aggressive` sigue fallando, el bloqueo no es de Windows:

- **Disco del sistema en uso**: Windows no puede borrar el volumen donde se
  ejecuta. Solución: arrancar desde **WinPE/USB** y ejecutar allí el script
  (WinPE con componente *PowerShell* opcional) o DiskPart a mano.
- **Bloqueo físico/firmware**: interruptor de escritura en USB/SD, contraseña
  ATA/HDD password, LUN de SAN mapeado como read-only, discos de portátiles con
  bloqueo en BIOS/UEFI.
- **Discos virtuales/RAID**: Storage Spaces (`Remove-VirtualDisk`), discos
  dinámicos o volúmenes de arreglo; primero hay que disolver el conjunto.
- **Disco protegido por política de la controladora** (Intel RST, RAID de
  placa): se gestiona desde la utilidad/BIOS de la controladora.

Para esos casos la vía real es arrancar en **WinPE** o en un **Linux live**:

```bash
# Linux live (identificar el disco con lsblk ANTES)
sudo sgdisk --zap-all /dev/sdX     # borra GPT y MBR
sudo wipefs -a /dev/sdX            # borra firmas de sistemas de archivos
sudo blkdiscard -f /dev/sdX        # TRIM/erase instantáneo en SSD
sudo dd if=/dev/zero of=/dev/sdX bs=16M status=progress   # último recurso
```

---

## Después de limpiar

Tras el borrado el disco queda en `RAW`. Formas de dejarlo usable:

**Automática (recomendada):**

```powershell
# En la misma pasada del borrado:
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Aggressive -AutoManage

# O después, ya limpio:
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -AutoManage

# Si ya está formateado pero Windows no lo muestra o no tiene nombre:
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Prepare
```

Inicializa GPT si hace falta, crea la partición solo cuando el disco está vacío,
formatea NTFS con etiqueta `ALMACENAMIENTO` y **finaliza** el volumen (letra,
montaje y etiqueta) para que aparezca en Explorer sin tocar nada a mano.
Nunca borra ni recrea una partición existente.

**Manual:**

```powershell
Initialize-Disk -Number <n> -PartitionStyle GPT
New-Partition -DiskNumber <n> -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "ALMACENAMIENTO"
# Si no aparece en Explorer, asigne letra o revise atributos:
mountvol /a
```

---

## Solución de problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `... la ejecución de scripts está deshabilitada en este sistema` | Política `Restricted` de PowerShell | Ver **Error de ExecutionPolicy** abajo. |
| `Delete is not allowed on the selected partition` | Atributo GPT *required* activo | Ya lo cubre el intento 2 (`gpt attributes=0`). |
| `The disk is write-protected` | Solo-lectura lógico o hardware | `-Aggressive`; si persiste, interruptor físico/firmware. |
| `The partition is in use` / `acceso denegado` | Pagefile, BitLocker, handle abierto | `-Aggressive`; cerrar programas; reiniciar y reintentar. |
| `No se encontró el disco` | Número incorrecto o disco offline | `-List`, luego `Set-Disk -Number N -IsOffline $false`. |
| Windows no reconoce el disco / pide formatear tras borrar | Disco en `RAW` (sin volumen) | Normal: ejecute `-AutoManage` o cree el volumen a mano. |
| Formateado pero no aparece en Explorer o sale sin nombre | Falta letra/montaje o la etiqueta no se aplicó | `-Prepare` (asigna letra, monta y pone `ALMACENAMIENTO`). |
| `DiskPart no puede procesar los parámetros` en el log | Versión antigua del script pasaba `noerr` al ejecutable | Corregido: `noerr` va **dentro** del script, por comando. Actualice el `.ps1`. |
| `no encontró objetos MSFT_Volume que coincidan` | Se intentaba formatear la MSR/EFI (sin volumen) | Corregido: MSR (`Reserved`), `System` y `Recovery` se ignoran; se formatea la partición de datos. |
| Todo falla en el disco de arranque | Es el disco del SO en uso | Se rechaza por diseño: use WinPE/Linux live. |
| `Disco N PROTEGIDO ... No se puede seleccionar` | Elegiste el disco del SO | Elige otro número; para ese, WinPE. |
| USB “protegido” tras usarlo en otro equipo | Flag `WriteProtect` en registro | `-Aggressive` (aplica `WriteProtect=0`), reiniciar. |

### Error de ExecutionPolicy (`UnauthorizedAccess`)

Es el error por defecto de Windows y **no requiere ser administrador**. No cambia
la configuración del equipo: solo afecta a la ventana actual.

```powershell
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Unblock-File .\Remove-ProtectedPartitions.ps1
Get-ExecutionPolicy        # debe responder: Bypass
```

Si al cerrar la ventana vuelve a pasar, use una de estas alternativas:

```powershell
# Opción 2: ejecutar sin cargar el archivo como script
powershell -NoProfile -ExecutionPolicy Bypass -File ".\Remove-ProtectedPartitions.ps1" -List

# Opción 3: el .bat (ya lleva -ExecutionPolicy Bypass)
.\Ejecutar-como-Admin.bat -DiskNumber 3 -DryRun
```

Si una **GPO** impone la política (`Get-ExecutionPolicy -List` muestra algo en
`MachinePolicy`/`UserPolicy`), `-ExecutionPolicy Bypass` se ignora. En ese caso,
ejecute el contenido en memoria (no carga el `.ps1`, así que no lo bloquea):

```powershell
& ([scriptblock]::Create((Get-Content -Raw .\Remove-ProtectedPartitions.ps1))) -List
```

El log completo de cada ejecución queda en `%TEMP%\wipe-protected-*.log` con
cada comando DiskPart y su salida, útil para diagnosticar negativas del sistema.
