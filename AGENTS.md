# AGENTS.md — Reglas, límites e ideas del proyecto

Documento canónico para cualquier agente (humano o IA) que trabaje en este
repositorio. **Si algo de aquí contradice una instrucción puntual del usuario,
gana el usuario, pero hay que actualizar este archivo.**

- Ruta: `Script_delete_part_protected/`
- Objetivo: borrar particiones "protegidas" de Windows (EFI/ESP, MSR, Recovery,
  OEM, ocultas, GPT con bit *required*) y, opcionalmente, limpiar el disco
  completo.
- Estado: funcional, validado en seco (`-DryRun`). **No se ha ejecutado ningún
  borrado real durante el desarrollo.**

---

## 1. Reglas de trabajo (obligatorias)

| ID | Regla |
|---|---|
| R-001 | Mantener `MEMORY.md` como memoria de contexto: reglas nuevas, decisiones y avances se anotan ahí **en el momento**. |
| R-002 | Lo anotado en `MEMORY.md` que sea regla estable o límite se **consolida en este `AGENTS.md`**. `MEMORY.md` es el diario; `AGENTS.md` es la ley. |
| R-003 | No ejecutar operaciones destructivas reales (`clean`, `delete partition`, `Clear-Disk`) durante el desarrollo ni en pruebas. Validar con `-DryRun` y con el parser de PowerShell. |
| R-004 | Nunca asumir el número de disco. Siempre `-List` antes de operar; los números cambian entre arranques y equipos. |
| R-005 | Todo texto de interfaz, mensajes y documentación va en **español**. Identificadores de código, parámetros y comandos, en inglés. |
| R-006 | Compatibilidad objetivo: **Windows 10/11 y Server 2016+**, **PowerShell 5.1** (sin dependencias externas, sin módulos de terceros). |
| R-007 | Cualquier funcionalidad nueva debe conservar la escalera de intentos y el modo `-DryRun`. |
| R-008 | Los scripts DiskPart se generan a archivo temporal en **ASCII** (sin BOM) y se invocan con `diskpart.exe /s <archivo>`. **`noerr` va dentro del script, por comando** y solo en los que lo documentan (`attributes`, `delete`, `format`, `assign`, `create`, `online/offline`, `remove`); nunca en la línea de comandos del ejecutable. |
| R-009 | No borrar ni reescribir trabajo previo del usuario sin revisarlo antes. |
| R-010 | Las pruebas reales se hacen **solo en discos desechables/externos** (p. ej. USB/UGREEN), verificando `BusType`, `IsBoot/IsSystem = False`, modelo, tamaño y serie impresos en el bloque OBJETIVO. Nunca en discos internos con datos. |
| R-011 | El disco del **SO en ejecución** se detecta, se excluye del listado de seleccionables y se **rechaza siempre** (también con `-Force`). No hay override: para ese disco se usa WinPE/USB. |
| R-012 | Tras formatear **nunca se recrea** el volumen: `-AutoManage`/`-Prepare` crean solo si el disco está vacío, formatean en su sitio una partición `RAW` y **finalizan** (letra, montaje, etiqueta `ALMACENAMIENTO`). |

---

## 2. Arquitectura

```
Remove-ProtectedPartitions.ps1   Script principal (todo-en-uno, sin módulos)
Ejecutar-como-Admin.bat          Wrapper de doble clic / reenvío de argumentos
diskpart-comandos.txt            Plantilla manual equivalente
README.md                        Documentación de uso y límites
AGENTS.md                        Este archivo (reglas + límites + ideas)
MEMORY.md                        Contexto vivo, reglas nuevas y avance
```

Flujo interno del `.ps1`:

1. `param()` → auto-elevación UAC (reconstruye `$PSBoundParameters`).
2. `Write-Log` → consola + `%TEMP%\wipe-protected-*.log` (UTF-8).
3. `-List` / sin `-DiskNumber` → tabla de discos y particiones y salida.
4. Detección del **disco del SO** (`Get-ProtectedDisks`): se excluye del listado
   y se rechaza si se selecciona → validación de discos → plan (con **BUS y
   serie**) → bloque **OBJETIVO** → confirmación `SI`.
5. `Invoke-DiskOperation` por disco:
   - normaliza solo-lectura / offline;
   - modo `-Clean[-All]`, `-Prepare` (sin borrar) o partición-por-partición;
   - verificación final por **offset** (no por número, que se renumera);
   - `-AutoManage`/`-Prepare`: deja el disco **formateado y montado** sin
     recrear particiones:
       - 0 particiones → inicializa GPT y crea una (la MSR no cuenta).
       - 1 partición → si es `RAW`, `Format-Volume` en su sitio; si ya tiene
         sistema de archivos, no se toca.
       - 2+ particiones → no se toca (`OMITIDO`). La **MSR** (`Type = Reserved`) y las de tipo
          `System`/`Recovery` se excluyen del recuento y **nunca** se formatean.
        - Orden obligatorio: **montar** (`Mount-PartitionVolume`: espera el
          volumen y asigna letra), **formatear**, **renombrar** (`Set-Volume`)
          y por último `Finalize-Volume`.
       - `Finalize-Volume`: `rescan`, online, limpia `hidden`/
         `nodefaultdriveletter`, asegura letra, espera `Healthy`, reaplica la
         etiqueta (`Set-Volume -NewFileSystemLabel`), `mountvol /a` y
         `pnputil /scan-devices`.
6. Resumen en tabla + exit code.

Cascada de borrado por partición (`Remove-OnePartition`):

1. `Remove-Partition`.
2. `gpt attributes=0x0` + `attributes volume clear *` + `delete partition override`.
3. `set id=<datos básicos> override` + `delete partition override`.
4. `-Aggressive`: BitLocker off, pagefile, `mountvol /p`, `fsutil dismount`,
   `offline/online disk`, reintento.
5. `-Clean/-CleanAll`: `diskpart clean [all]` → `Clear-Disk -RemoveOEM`.

---

## 3. Límites técnicos (lo que el script NO puede hacer)

### 3.1 Bloqueos que no son software
- **Disco del sistema en uso**: Windows/VDS no permite borrar el volumen donde
  corre el SO. Requiere **WinPE** o Linux live. `-Force` solo evita la guardia,
  no la negativa del sistema.
- **Firmware/hardware**: interruptor de escritura (USB/SD), contraseña ATA/HDD,
  LUN de SAN read-only, bloqueo de BIOS/UEFI. No hay bypass por software.
- **Storage Spaces / discos dinámicos / RAID**: hay que disolver el conjunto
  (`Remove-VirtualDisk`, `diskpart break`, utilidad de la controladora) antes.
- **Controladora RAID (Intel RST, etc.)**: el disco no es visible como disco
  físico; se gestiona en BIOS/utilidad de la controladora.

### 3.2 Límites del propio script
- Solo **Windows + PowerShell 5.1+**. No hay versión `.sh`; Linux solo está
  documentado (`sgdisk`, `wipefs`, `blkdiscard`, `dd`).
- Requiere **administrador** (auto-elevación por UAC).
- La detección del disco del SO combina `IsBoot/IsSystem`, `$env:SystemDrive`,
  `$env:SystemRoot` y CIM. Si todas fallan se registra un `WARN` y queda la
  verificación en ejecución. En multi-arranque solo se protege el SO **en
  ejecución** (otro Windows en otro disco no se detecta).
- `gpt attributes` solo aplica a **GPT**; en MBR se omite (el borrado va por
  `set id` + `override`).
- Las particiones MSR/EFI no tienen volumen: los `attributes volume` fallan y se
  ignoran (por eso `noerr`). `Initialize-Disk -PartitionStyle GPT` crea además
  una **MSR de 16 MB** (`Type = Reserved`): el script debe filtrarla y nunca
  intentar `Format-Volume` sobre ella (`no encontró objetos MSFT_Volume`).
- El flag `Success` de `Invoke-DiskPart` depende de texto localizado
  (ES/EN). **No se usa para decidir**: la verdad es la verificación por offset.
- La identidad de partición se lleva por **offset**, no por número, porque
  Windows renumera tras borrar.
- `-CleanAll` rellena con ceros: puede tardar **horas** y desgasta SSD sin
  aportar ventaja sobre `blkdiscard`/TRIM.
- `-Aggressive` **cambia estado del sistema**: apaga hibernación
  (`powercfg /h off`), quita pagefile, apaga BitLocker y pone `WriteProtect=0` en
  el registro. Son efectos secundarios deliberados, documentados.
- `Clear-Disk -RemoveData -RemoveOEM` **borra todo el disco**: solo se usa como
  respaldo en `-Clean` o como último recurso en `-Aggressive`; nunca en modo
  partición-por-partición normal.
- No recupera datos, no redimensiona, no hace copias de seguridad.
- `-AutoManage`/`-Prepare` dejan el disco **formateado y montado**, pero
  **nunca recrean** una partición existente: si hay 2+ particiones no tocan
  nada (`OMITIDO`); si hay 1 ya formateada, solo la finalizan. Úsese con cuidado:
  una partición `RAW` se formatea en su sitio (no hay datos accesibles que
  conservar). Se niegan en el disco de sistema.
- `Finalize-Volume` depende del mount manager: si Windows no responde a
  `rescan`, el volumen puede tardar en aparecer; el script reintenta y, si no
  consigue letra o `Healthy`, lo marca `PARCIAL` con la causa en el log.
- El log depende de `%TEMP%` escribible; si falla, el log se pierde pero la
  operación continúa.
- No firma digitalmente el script; en equipos con ExecutionPolicy restrictiva
  hay que usar `-ExecutionPolicy Bypass` (lo hace el `.bat`). Si una GPO impone
  la política, el parámetro se ignora: ejecutar en memoria con
  `[scriptblock]::Create((Get-Content -Raw ...))`.

### 3.3 Riesgos operativos
- Destructivo e **irreversible**: sin respaldo, los datos no vuelven.
- Un número de disco equivocado destruye el disco equivocado.
- La guardia de disco de sistema **no** se puede saltar con `-Force`: el disco
  del SO en ejecución se rechaza siempre (exit 2).
- `diskpart clean` no verifica que el disco no sea de arranque de otro SO.

---

## 4. Convenciones de código

- Un solo archivo `.ps1`, sin módulos ni clases; funciones con verbo-sustantivo.
- Variables de script compartidas con prefijo `$script:` (`Simulate`,
  `Aggressive`, `LogPath`).
- Toda salida auxiliar se silencia (`| Out-Null`, `[void](...)`) para que
  `Invoke-DiskOperation` devuelva **un único** objeto.
- Comentarios y mensajes en español; sin tildes en rutas/comandos, con tildes
  solo en texto visible.
- No usar `Write-Output` para logs: `Write-Host` + `Add-Content`.
- Mantener exit codes: `0` OK, `1` con restos/error, `2` guardia de sistema,
  `3` cancelado por el usuario.

---

## 5. Protocolo de validación (sin tocar discos)

```powershell
# 1) Sintaxis
$t,$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile(
  "$PWD\Remove-ProtectedPartitions.ps1",[ref]$t,[ref]$e); $e

# 2) Prueba en seco (no muta nada)
.\Remove-ProtectedPartitions.ps1 -List
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -DryRun [-Aggressive] [-Clean] [-AutoManage]
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Prepare -DryRun

# 3) Rechazo del disco del sistema: debe salir con codigo 2, tambien con -Force
.\Remove-ProtectedPartitions.ps1 -DiskNumber <disco_del_so> -DryRun
.\Remove-ProtectedPartitions.ps1 -DiskNumber <disco_del_so> -Force -DryRun

# 4) -Prepare y -Clean juntos: debe fallar con codigo 1
.\Remove-ProtectedPartitions.ps1 -DiskNumber <n> -Prepare -Clean -DryRun
```

Si la sesión del agente no es administradora, para probar sin UAC se puede
copiar el script a `%TEMP%` quitando el bloque `# Auto-elevacion` (solo para
pruebas; nunca distribuir esa copia). Ver `MEMORY.md` §4.

Antes de dar por buena una entrega: parser sin errores + `-List` correcto +
`-DryRun` mostrando `select disk`, `gpt attributes`, `delete partition override`
y (si aplica) `clean`.

**Prueba real:** solo en disco externo/desechable (USB/UGREEN), comprobando en
el bloque OBJETIVO `BusType = USB`, `IsBoot/IsSystem = False` y modelo/tamaño
esperados. Procedimiento completo en `README.md` →
*"Probar con un disco extra (USB / UGREEN)"*.

---

## 6. Ideas / backlog

Prioridad alta:
- [ ] **Variante WinPE**: mismo script + instrucciones para montar USB de
      arranque (componente opcional *PowerShell*), que es donde de verdad se
      puede limpiar el disco del sistema.
- [ ] **Detección previa** de pagefile, BitLocker, volumen en uso y disco de
      sistema, con advertencia antes de intentar (hoy se descubre al fallar).
- [ ] Aviso de **otras instalaciones de Windows** en otros discos
      (multi-arranque): buscar `\Windows\System32\ntdll.dll` en los volúmenes
      seleccionables y marcarlos como "otro SO".
- [ ] **Pruebas Pester** con `Get-Disk`/`Get-Partition`/`diskpart` mockeados.

Prioridad media:
- [ ] `-Report <csv|html>` con el resultado por partición y offsets.
- [ ] Selector interactivo (`Out-GridView`) para elegir disco sin teclear
      números.
- [ ] Sustituir `mountvol`/`fsutil` por `diskpart remove letter=X dismount`
      (más alineado con la herramienta).
- [ ] Verificación posterior a la limpieza (leer primeros sectores / comprobar
      tabla vacía) y firma del resultado en el log.
- [ ] `-AnswerFile` para despliegue desatendido en lote (caso ayuntamiento:
      reacondicionar equipos).

Prioridad baja / explorar:
- [ ] Soporte explícito de Storage Spaces (`Remove-VirtualDisk`).
- [ ] Limpieza ATA Secure Erase (`hdparm`/`nvme format`) desde Linux live.
- [ ] Firma de código del `.ps1`.
- [ ] Empaquetar como tarea programada de una sola pasada.

---

## 7. Definición de terminado

1. `AGENTS.md` y `MEMORY.md` actualizados con la regla/avance nuevo.
2. Parser de PowerShell sin errores.
3. `-List` y `-DryRun` verificados.
4. `README.md` coherente con los parámetros reales.
5. Sin operaciones destructivas ejecutadas durante el desarrollo.
