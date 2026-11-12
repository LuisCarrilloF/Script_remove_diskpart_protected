# MEMORY.md — Contexto vivo y bitácora

> **Qué es este archivo:** la memoria de trabajo del agente. Aquí se anota
> **todo** lo que el usuario indica como regla y todo avance/decidido, en el
> momento. Lo que sea estable se **consolida en `AGENTS.md`** (ese es el
> documento canónico). Si hay conflicto entre ambos, gana `AGENTS.md` y hay que
> corregir este archivo.
>
> **Última actualización:** 2026-11-12

---

## 1. Estado actual del proyecto

- Herramienta completa y funcional en modo seguro.
- Validada: parser de PowerShell sin errores + `-List` + `-DryRun` en discos
  MBR y GPT + guardia de disco de sistema (exit 2) + simulación de `-Clean`.
- **Ningún borrado real ejecutado.** Todo el desarrollo fue en seco.
- Documentación: `README.md` (uso), `AGENTS.md` (reglas/límites/ideas).
- Pendiente principal: probar en un disco desechable real y preparar variante
  WinPE.

---

## 2. Entorno verificado (2026-11-12)

| Dato | Valor |
|---|---|
| Sesión del agente | Windows 11, build 10.0.26300.0 |
| PowerShell | 5.1.26100.9818 |
| Privilegios de la sesión | **NO administrador** (por eso se prueba con copia sin elevación) |
| Terminal | PowerShell (win32) |

Inventario del equipo en ese momento (⚠️ los números de disco **cambian** entre
arranques; siempre `-List`):

| Disco | Modelo | GB | Estilo | Rol |
|---|---|---|---|---|
| 0 | TOSHIBA MQ01ABD100M (SATA) | 931.5 | MBR | Datos (D:) |
| 1 | WDC WD10EZEX-75M2NA0 (SATA) | 931.5 | GPT | Datos (E:) |
| 2 | ORICO (NVMe) | 238.5 | GPT | **Sistema/arranque** (EFI, MSR, C:, Recovery) |
| 3 | ST500DM002-1BD142 (USB/UGREEN) | 465.8 | GPT | **Disco de pruebas** (EFI, MSR, F:, Recovery) — conectado 2026-11-12 |

Consecuencia: el disco 2 **no** se puede limpiar desde Windows en vivo. Solo
WinPE/Linux live. El disco 3 es el objetivo de prueba seguro (USB, no es
sistema, serie reportada `0000...` → validar por modelo/tamaño/bus).

---

## 3. Reglas del usuario

| ID | Regla | Fecha |
|---|---|---|
| R-001 | Crear `AGENTS.md` con las **limitaciones** y las **ideas** del proyecto. | 2026-11-12 |
| R-002 | Crear `MEMORY.md` para que el agente tenga **contexto y limitaciones** entre sesiones. | 2026-11-12 |
| R-003 | **Cada vez** que el usuario dé una regla específica o se avance, actualizar `MEMORY.md` y reflejarlo en `AGENTS.md`. | 2026-11-12 |
| R-004 | El borrado debe funcionar **incluso en particiones protegidas** (DiskPart/`override`, "saltarse las restricciones"). | 2026-11-12 |
| R-005 | El resto de reglas estables (idioma, PS 5.1, seguridad, etc.) están consolidadas en `AGENTS.md` §1. | 2026-11-12 |
| R-006 | Probar el borrado real **solo** en un disco extra conectado por UGREEN/USB, sin dañar el equipo; documentar el procedimiento en `README.md`. | 2026-11-12 |
| R-007 | Detectar en qué disco corre el SO y **excluirlo de la lista** de borrado, para que un usuario no pueda seleccionarlo. | 2026-11-12 |

---

## 4. Decisiones tomadas (y por qué)

| ID | Decisión | Motivo |
|---|---|---|
| D-001 | Un solo `.ps1` sin módulos. | Portabilidad a WinPE y equipos sin repositorios. |
| D-002 | Cascada de 5 intentos (cmdlet → atributos+override → set id → agresivo → clean). | Cubre protecciones lógicas sin destruir datos cuando no hace falta. |
| D-003 | Verificar existencia por **offset**, no por número de partición. | Windows renumera al borrar. |
| D-004 | Invocar DiskPart con `/s archivo noerr` y archivo **ASCII**. | `noerr` evita abortar por un atributo sin soporte; ASCII evita fallos por BOM. |
| D-005 | No usar el flag `Success` de DiskPart para decidir. | El texto de DiskPart está localizado; la verdad es la verificación por offset. |
| D-006 | `Clear-Disk -RemoveOEM` solo en `-Clean` o como último recurso en `-Aggressive`. | Evita borrar particiones no seleccionadas en modo normal. |
| D-007 | Guardia de disco de sistema (exit 2) salvo `-Force`; en `-DryRun` se permite. | Seguridad sin estorbar la simulación. |
| D-008 | Confirmación interactiva escribiendo `SI` salvo `-Force`. | Evita doble clic accidental y automatización peligrosa. |
| D-009 | UI y docs en español; código en inglés. | Usuario hispanohablante, mantenibilidad estándar. |
| D-010 | No crear versión `.sh`; Linux solo documentado en README. | El objetivo es Windows; el usuario pidió "diskpart o algo así". |
| D-011 | `-Aggressive` toca estado del sistema (hibernación, pagefile, BitLocker, WriteProtect). | Necesario para soltar bloqueos; documentado como efecto secundario. |
| D-012 | El PLAN y la línea OBJETIVO muestran **BUS + modelo + tamaño + serie**. | Evitar borrar el disco equivocado cuando hay varios discos/USB y el número cambia. |
| D-013 | El modo partición-por-partición borra **todas** las particiones del disco elegido. | Es el propósito de la herramienta; para borrar una sola existe la plantilla manual. |
| D-014 | `-AutoManage` es **opt-in** y crea GPT + partición al máximo + letra + NTFS con etiqueta `ALMACENAMIENTO`. | Tras el borrado el disco queda RAW y Windows lo muestra como "no reconocido"; así queda usable en la misma pasada. |
| D-015 | `-InitializeDisk` pasa a ser alias de `-AutoManage`. | Inicializar dejando el disco RAW no resolvía el problema real del usuario. |
| D-016 | Bloqueo **duro** del disco del SO: no hay override, ni con `-Force`. `-Force` solo omite la confirmación. | Evitar que un usuario lo seleccione por error; ese disco se limpia desde WinPE. |
| D-017 | Detección por 4 fuentes (`IsBoot/IsSystem`, `$env:SystemDrive`, `$env:SystemRoot`, CIM) y rechazo de **toda** la ejecución si se mezcla un disco protegido. | No depender de una sola fuente y no dejar borrados parciales inesperados. |
| D-018 | **Nunca recrear** el volumen: la finalización solo asigna letra, monta y reaplica la etiqueta. Con 1 partición `RAW` se formatea en su sitio; con 1 ya formateada no se toca. | Orden explícita del usuario ("nunca recrear, debe estar formateado") y evitar pérdida de datos por recrear. |
| D-019 | Nueva función `Finalize-Volume` + modo `-Prepare` (sin borrar). | El volumen formateado no lo "agarraba" Windows hasta darle letra/nombre a mano; `-Prepare` arregla un disco ya formateado. |
| D-020 | `diskpart.exe /s <archivo>` **sin** `noerr` en la CLI; `noerr` se añade por comando (`Add-DiskPartNoErr`). | Causa raíz del fallo real: `diskpart /s f noerr` devuelve "DiskPart no puede procesar los parámetros" y **ningún** comando se ejecutó. |
| D-021 | Orden fijo al administrar: **montar** (`Mount-PartitionVolume`) → **formatear** → **renombrar** (`Set-Volume`) → `Finalize-Volume`. | El usuario lo pidió así; además `Format-Volume` falla si el volumen aún no está montado. |
| D-022 | Filtrar `Reserved` (MSR), `System` y `Recovery` del recuento de particiones de datos. | `Initialize-Disk` en GPT crea una MSR de 16 MB que no tiene volumen; el script intentaba formatearla y fallaba con "no encontró objetos MSFT_Volume". |

---

## 5. Bitácora de avance

### 2026-11-12 — Sesión 1
- [x] Analizado el requisito: borrar particiones protegidas usando DiskPart.
- [x] Creado `Remove-ProtectedPartitions.ps1` (~600 líneas) con cascada,
      auto-elevación, `-List`, `-DryRun`, `-Clean`, `-CleanAll`, `-Aggressive`,
      `-Force`, `-InitializeDisk`, logging y exit codes.
- [x] Creado `Ejecutar-como-Admin.bat`.
- [x] Creada plantilla `diskpart-comandos.txt` (con `rem`, soportado por DiskPart).
- [x] Creado `README.md` (uso, límites que no son de software, Linux, WinPE).
- [x] Corregidos 4 errores de parseo `$var:` → `${var}:`.
- [x] Corregido bug `-DiskNumber 0` interpretado como falso (`-not $DiskNumber`);
      ahora se usa `$PSBoundParameters.ContainsKey`.
- [x] Añadido `noerr`, comandos aislados (`san policy`, offline/online),
      `Get-AttributeCommands` y `DRYRUN` como resultado no fallido.
- [x] Probado: sintaxis OK; `-List` OK; `-DryRun` en MBR (disco 0), GPT
      (disco 1) y disco de sistema (disco 2) OK; guardia exit 2 OK;
      `-Clean -DryRun` OK.
- [x] Detectado: disco 2 de este equipo es el de arranque (no borrable en vivo).
- [x] Creados `AGENTS.md` y `MEMORY.md` a petición del usuario.
- [x] Confirmado por documentación Microsoft que DiskPart soporta `rem`,
      `gpt attributes`, `set id ... override` y `delete partition override`.

### 2026-11-12 — Sesión 2 (disco UGREEN)
- [x] El usuario conectó un disco extra por adaptador UGREEN → Detectado como
      **Disco 3**: `ST500DM002-1BD142`, USB, 465.8 GB, GPT, con EFI + MSR +
      F: (465.13 GB) + Recovery 0.52 GB. No es sistema/arranque.
- [x] Script reforzado: columna `Bus` y `Serie` en el PLAN, y bloque
      **OBJETIVO** (número/modelo/bus/tamaño/serie) antes de confirmar.
- [x] Validado con parser + `-DryRun` sobre el disco 3 (4 particiones, incluida
      Recovery y EFI). Sin cambios reales.
- [x] README: nueva sección "Probar con un disco extra (USB / UGREEN) sin dañar
      el equipo" con identificación por bus/serie, fases, verificación,
      qué no hacer, alternativa en VM y plan si el USB se desconecta.
- [x] Regla R-006 registrada y consolidada como R-010 en `AGENTS.md`.
- [x] README: guía "Cómo ejecutarlo (paso a paso)", ejemplo completo con el
      disco 3, tabla "Qué esperar", aviso de la ventana elevada del `.bat` y
      recordatorios (borra todas las particiones, el número puede cambiar,
      no afecta a los discos internos).
- [x] Incidencia real del usuario: `UnauthorizedAccess` por ExecutionPolicy
      `Restricted`. Documentadas 3 salidas en README (Bypass por proceso,
      `-File ... -ExecutionPolicy Bypass`, `.bat`, y scriptblock si hay GPO).
      Verificado que el equipo no tiene GPO (`Get-ExecutionPolicy -List`).
- [!] El usuario intentó `-DiskNumber 2` (disco de sistema): recordarle que el
      disco de pruebas es el **3** y que `2` está bloqueado por la guardia.
- [x] Petición del usuario: tras borrar, el disco "no lo reconocía" (RAW) →
      añadido `-AutoManage` (inicializa GPT, crea partición al máximo, letra y
      formatea con etiqueta **Almacenamiento**; `-VolumeLabel` y `-FileSystem`
      configurables). `-InitializeDisk` queda como alias.
- [x] `Set-DiskAsStorage` con `rescan`, reintento de letra y 2 intentos de
      formateo. Resultado nuevo `LISTO` (no cuenta como fallo).
- [x] README: parámetros nuevos, sección `-AutoManage`, ejemplos, tabla de
      "Qué esperar", "Después de limpiar" y fila de troubleshooting.
- [x] `diskpart-comandos.txt`: Opción D manual equivalente.
- [x] Validado con parser + `-DryRun -AutoManage` sobre disco 3. Nota: el disco 3
      ahora reporta **2 particiones** (offsets 17408 y 16777216), no las 4
      originales → el layout cambió desde la sesión anterior; reconfirmar antes
      de la prueba real.

### 2026-11-12 — Sesión 3 (protección del disco del SO)
- [x] Implementado `Get-ProtectedDisks`: une `IsBoot/IsSystem`, `$env:SystemDrive`,
      `$env:SystemRoot` y respaldo CIM. Registra el motivo por disco en el log.
- [x] `-List` ahora tiene dos bloques: **seleccionables** y **disco del sistema
      (protegido)**; las particiones mostradas excluyen el disco protegido.
- [x] Selección del disco protegido → mensaje `PROTEGIDO`, exit **2**, también
      con `-Force`. Si se mezcla (`-DiskNumber 2,0`) se **aborta todo**.
- [x] Defensa en profundidad en `Invoke-DiskOperation` (rechaza `PROTEGIDO`).
- [x] Probado (sin admin, copia sin elevación): `-List` excluye disco 2;
      `-DiskNumber 2 -DryRun` → exit 2; `-DiskNumber 2 -Force -DryRun` → exit 2;
      `-DiskNumber 2,0 -DryRun` → exit 2 (verificado el `exit` real con runner);
      `-DiskNumber 0 -DryRun` → exit 0.
- [x] Docs: README (sección nueva, parámetros, troubleshooting), `AGENTS.md`
      (R-011, límites, pruebas), `diskpart-comandos.txt` (aviso).
- [ ] El **disco 3 (UGREEN) no está conectado** en este momento (`Get-Disk` solo
      muestra 0, 1 y 2); repetir la prueba real cuando se reconecte.
- [ ] Pendiente del usuario: ejecutar la prueba real en el disco 3
      (`-Aggressive` y luego `-Clean -InitializeDisk`).

### 2026-11-12 — Sesión 4 (finalizar volumen, sin recrear)
- [x] Petición del usuario: al terminar de formatear, Windows no "agarra" el
      disco hasta darle letra/nombre a mano. Nombre por defecto: **ALMACENAMIENTO**.
- [!] El usuario eligió primero "recrear el volumen" y luego lo corrigió:
      **"nunca recrear, debe estar formateado"**. Implementado sin recrear.
- [x] `VolumeLabel` por defecto → `ALMACENAMIENTO` (mayúsculas).
- [x] Nueva `Finalize-Volume`: `Update-Disk` + `rescan`, online, limpia
      `hidden`/`nodefaultdriveletter`/`readonly`, asegura letra
      (`Add-PartitionAccessPath` y respaldo letra libre + `Set-Partition`),
      espera `Healthy` (~9 s), reaplica etiqueta (`Set-Volume`), `mountvol /a`
      y `pnputil /scan-devices`. Verifica con `Get-Volume`.
- [x] `Set-DiskAsStorage` idempotente y **sin recrear**:
      0 particiones → inicializa/crea/formatea/finaliza; 1 partición `RAW` →
      formatea en su sitio; 1 ya formateada → solo finaliza; 2+ → `OMITIDO`.
- [x] Nuevo `-Prepare` (sin borrar) para arreglar un disco ya formateado.
      `-Prepare` + `-Clean/-CleanAll` → exit 1. `-Aggressive` global no se
      ejecuta en `-Prepare`.
- [x] `Invoke-DiskPart` ya no aborta si `diskpart.exe` no arranca (p. ej. sin
      elevación): registra el error y sigue.
- [x] Resultado nuevo `OMITIDO` (no cuenta como fallo). `PARCIAL` si se pidió
      administrar y no se pudo (sin letra o sin `Healthy`).
- [x] Probado (sin admin, copia sin elevación, disco 3 conectado):
      `-Prepare -DryRun` → exit 0; `-Prepare -Clean` → exit 1;
      `-AutoManage -DryRun` → exit 0; `-Prepare` real sobre disco con 2
      particiones → `OMITIDO`, exit 0, sin cambios.
- [x] Docs: README (parámetros, sección `-AutoManage`/`-Prepare`, tabla de
      estados, "Después de limpiar", troubleshooting), `AGENTS.md` (R-012,
      flujo, límites, protocolo), `diskpart-comandos.txt` (etiqueta en
      mayúsculas).
- [ ] Falta la prueba real de formateo/finalización: requiere elevación y un
      disco vacío o `RAW` (el disco 3 tiene hoy 2 particiones). Cuando se haga,
      verificar `LISTO` + `Get-Volume` con letra y etiqueta `ALMACENAMIENTO`.

### 2026-11-12 — Sesión 5 (bugs de la primera ejecución real elevada)
- Log analizado: `%TEMP%\wipe-protected-20261112-111220.log`.
- [x] **Bug 1**: `Invoke-DiskPart` llamaba `diskpart.exe /s <archivo> noerr`.
      `noerr` no es parámetro del ejecutable → *"DiskPart no puede procesar los
      parámetros"* en **todos** los comandos (`san`, `select`, `clean`,
      `rescan`, …). Solo funcionó el respaldo `Clear-Disk`.
      Arreglado: `/s <archivo>` a secas + `Add-DiskPartNoErr` que añade `noerr`
      **por comando** solo a `attributes`, `delete`, `format`, `assign`,
      `create`, `online/offline`, `remove`.
- [x] **Bug 2**: `Initialize-Disk -PartitionStyle GPT` crea una **MSR** de
      16 MB (`Reserved`, offset 17408). El script la contaba como partición de
      datos e intentaba `Format-Volume` → *"no encontró objetos MSFT_Volume"*.
      Arreglado: se filtran `Reserved`/`System`/`Recovery`.
- [x] Orden corregido y explícito: **montar** (`Mount-PartitionVolume`: espera
      hasta 15 s el volumen, `assign` de respaldo, letra por
      `Add-PartitionAccessPath` o letra libre + `Set-Partition`) → **formatear**
      (solo si no hay FS; 3 intentos + respaldo `format quick fs=... label=...`)
      → **renombrar** (`Set-Volume -NewFileSystemLabel`) → `Finalize-Volume`.
- [x] `Remove-OnePartition`: `set id` y `delete partition override` en
      invocaciones separadas (un `set id` fallido ya no impide el borrado).
      `Get-AttributeCommands`: primero `attributes volume`, `gpt` al final.
- [x] Probado (sin admin, copia sin elevación, disco 3 = MSR + F: NTFS):
      `-Prepare -DryRun` → exit 0; `-Prepare` real → detecta **1 partición de
      datos** (MSR ignorada), `LISTO`, exit 0, sin cambios; `-Prepare -CleanAll`
      → exit 1; disco 2 → exit 2. Parser OK.
- [ ] Prueba real elevada pendiente: `-DiskNumber 3 -Prepare` (segura) y, con
      consentimiento, `-Clean -AutoManage` para verificar `LISTO` + `F:` +
      etiqueta `ALMACENAMIENTO` y que el log ya **no** diga "DiskPart no puede
      procesar los parámetros".

---

## 6. Problemas conocidos / trampas

- **No probar con `-Clean` real** en este equipo: disco 0 y 1 tienen datos del
  usuario (D: y E:).
- La sesión del agente no es admin: para probar hay que quitar el bloque
  `# Auto-elevacion` en una copia temporal en `%TEMP%` (nunca distribuirla).
- `delete partition override` no derrota al VDS en el volumen de arranque en uso.
- `attributes volume ...` no aplica a MSR/EFI (falla y se ignora con `noerr`).
- `clean all` puede tardar horas; en SSD es preferible `blkdiscard` desde Linux.
- El log por defecto va a `%TEMP%`, que puede limpiarse solo.
- Rutas con espacios ("Proyectos ayuntamiento"): siempre entre comillas en
  `.bat`/`Start-Process`.
- Muchos discos USB reportan serie `0000000000000000`: identificar por
  modelo + tamaño + `BusType = USB`, no solo por serie.
- El número de disco del USB puede cambiar al reconectar/encender: repetir
  `-List` siempre.
- `-CleanAll` por USB es mala idea: horas de escritura y riesgo de desconexión.
- **Multi-arranque**: solo se protege el disco del SO **en ejecución**; otro
  Windows instalado en otro disco no se detecta (backlog).
- El **disco 3 (UGREEN)** no estaba conectado durante la sesión 3 (`Get-Disk`
  solo mostraba 0, 1 y 2). Reconectar antes de probar. En la sesión 4 volvio a
  aparecer (2 particiones: offsets 17408 y 16777216).
- El volumen de un USB recien formateado puede tardar en recibir letra/montaje:
  `-AutoManage`/`-Prepare` lo finalizan, pero si `diskpart`/`mountvol` no
  responden el resultado queda `PARCIAL` (ver el log).
- `-Prepare` **no** es un borrado: no se puede combinar con `-Clean`/`-CleanAll`.
- El equipo tiene **ExecutionPolicy por defecto (`Restricted`)**: el `.ps1` no
  carga hasta aplicar `Set-ExecutionPolicy -Scope Process Bypass`, usar
  `-ExecutionPolicy Bypass -File` o el `.bat`. `Get-ExecutionPolicy -List` en
  este equipo muestra todo `Undefined` (sin GPO), así que el bypass por proceso
  funciona.

---

## 7. Siguiente sesión (por orden sugerido)

1. Reconectar el **disco 3 (UGREEN)** y probar en real: `-DryRun` →
   `-Aggressive -AutoManage` → verificar `LISTO`, letra y etiqueta
   `ALMACENAMIENTO` (`Get-Volume`). Probar también `-Prepare` tras un formateo
   que no haya montado. (El usuario lo hará por su cuenta; pedir salida del log.)
2. Añadir detección previa de pagefile/BitLocker/uso.
3. Preparar carpeta `winpe/` con instrucciones y copia del script.
4. Tests Pester con mocks.
5. (Si el usuario lo pide) `-Report` CSV/HTML e interactivo con `Out-GridView`.

---

## 8. Cómo actualizar este archivo (obligatorio)

Checklist en cada intervención:

1. ¿El usuario dio una **regla** nueva? → añadir fila en **§3** (ID `R-00N`) y
   consolidarla en `AGENTS.md` §1 (o donde corresponda).
2. ¿Se tomó una **decisión** técnica? → fila en **§4** (`D-00N`) + reflejarla en
   `AGENTS.md` §2/§4 si es estable.
3. ¿Hubo **avance**, prueba o hallazgo? → entrada con fecha en **§5**.
4. ¿Apareció un **límite** nuevo? → **§6** y `AGENTS.md` §3.
5. ¿Cambió el **entorno** (equipo, versión, privilegios)? → **§2**.
6. Actualizar la línea **"Última actualización"** del encabezado.
7. Revisar que `AGENTS.md` y `MEMORY.md` no se contradigan.

### Plantilla de entrada

```markdown
### AAAA-MM-DD — Sesión N
- [ ] Regla del usuario: ...
- [x] Avance: ...
- Decisión: ... (motivo: ...)
- Límite detectado: ...
```
