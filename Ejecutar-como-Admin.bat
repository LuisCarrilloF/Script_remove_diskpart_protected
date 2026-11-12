@echo off
setlocal
cd /d "%~dp0"
title Borrar particiones protegidas (diskpart override)

if "%~1"=="" (
    echo Mostrando discos y particiones...
    echo.
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-ProtectedPartitions.ps1" -List
) else (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0Remove-ProtectedPartitions.ps1" %*
)

echo.
echo ---------------------------------------------------------------
echo Proceso terminado. Revise el resultado y el log indicado arriba.
pause
