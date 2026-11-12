# Borrado de particiones protegidas (diskpart override)

<div align="center">
  <img src="https://img.shields.io/badge/PowerShell-5391FE?logo=powershell&logoColor=white" alt="PowerShell">
  <img src="https://img.shields.io/badge/Windows-0078D4?logo=windows&logoColor=white" alt="Windows">
  <img src="https://img.shields.io/badge/DiskPart-0078D4?logo=windows&logoColor=white" alt="DiskPart">
</div>

Herramienta para eliminar particiones que Windows/DiskPart normalmente rechazan:
**EFI/ESP, MSR, Recovery, OEM, ocultas**, particiones GPT marcadas como
*required* (bit 63) y volúmenes bloqueados por atributos, BitLocker, pagefile
o por estar "en uso".

> [!WARNING]  
  **Destructivo e irreversible.** Borra tablas de particiones y datos sin
> posibilidad de recuperación sencilla. Verifique siempre el **número de disco**
> con `-List` antes de ejecutar. No lo use en equipos de producción sin respaldo.

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
| `-DiskNumber <n[,n]>` | Disco(s) objetivo. Obligatorio salvo con `-List`. |
| `-List` | Solo muestra discos/particiones. |
| `-Clean` | `diskpart clean`: borra **todas** las particiones (rápido). Respaldo con `Clear-Disk -RemoveOEM`. |
| `-CleanAll` | `diskpart clean all`: igual pero rellena con ceros (lento). Implica `-Clean`. |
| `-Aggressive` | Libera bloqueos: BitLocker off, pagefile, `mountvol /p`, `fsutil dismount`, offline/online, hibernación off, limpia `WriteProtect` de USB. |
| `-Force` | Sin confirmación y permite disco de sistema. **Cuidado.** |
| `-DryRun` | Muestra comandos sin ejecutarlos. |
| `-InitializeDisk` | Tras limpiar, inicializa el disco en GPT. |
| `-LogPath <ruta>` | Log alternativo (por defecto `%TEMP%\wipe-protected-*.log`). |

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

En caso de no seleccionar la opcion 4 del [uso rapido](#uso-rápido), el disco queda en estado `RAW`. Para dejarlo usable:

```powershell
Initialize-Disk -Number 2 -PartitionStyle GPT
New-Partition -DiskNumber 2 -UseMaximumSize -AssignDriveLetter |
    Format-Volume -FileSystem NTFS -NewFileSystemLabel "DATOS"
```

O simplemente use `-InitializeDisk` al ejecutar el script y luego cree la
partición desde Administración de discos.

---

## Solución de problemas

| Síntoma | Causa probable | Acción |
|---|---|---|
| `File cannot be loaded because running scripts is disabled` | Tienesactivada la opcion para usar scrpts| Activa manualmente esta opcion. Teclea `Inicio` y usca `Permitir la ejecucion de scrpts`, activa la opcion de PowerShell. **_RECOMENDADO_**|
| `Delete is not allowed on the selected partition` | Atributo GPT *required* activo | Ya lo cubre el intento 2 (`gpt attributes=0`). |
| `The disk is write-protected` | Solo-lectura lógico o hardware | `-Aggressive`; si persiste, interruptor físico/firmware. |
| `The partition is in use` / `acceso denegado` | Pagefile, BitLocker, handle abierto | `-Aggressive`; cerrar programas; reiniciar y reintentar. |
| `No se encontró el disco` | Número incorrecto o disco offline | `-List`, luego `Set-Disk -Number N -IsOffline $false`. |
| Todo falla en el disco 0 | Es el disco de arranque en uso | WinPE/Linux live. |
| USB “protegido” tras usarlo en otro equipo | Flag `WriteProtect` en registro | `-Aggressive` (aplica `WriteProtect=0`), reiniciar. |

El log completo de cada ejecución queda en `%TEMP%\wipe-protected-*.log` con
cada comando DiskPart y su salida, útil para diagnosticar negativas del sistema.
