@echo off
title GameBoost
chcp 65001 >nul
setlocal

net session >nul 2>&1
if not %errorlevel%==0 (
    echo Requesting admin rights. Click Yes in the UAC window.
    timeout /t 2 >nul
    powershell -ExecutionPolicy Bypass -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs -WorkingDirectory '%~dp0'"
    exit /b
)

cd /d "%~dp0"

REM === 1) АВТО-ФИКС КОДИРОВКИ (UTF-8 BOM) НА ЛЮБОМ ПК ===
powershell -NoProfile -Command "$f='%~dp0GameBoost.ps1'; $t=[System.IO.File]::ReadAllText($f); $b=New-Object System.Text.UTF8Encoding($true); [System.IO.File]::WriteAllText($f,$t,$b)"
powershell -NoProfile -Command "$f='%~dp0GameBoost_config.ini'; $t=[System.IO.File]::ReadAllText($f); $b=New-Object System.Text.UTF8Encoding($true); [System.IO.File]::WriteAllText($f,$t,$b)"

REM === 2) АВТОТЕСТ: ЦЕЛОСТНОСТЬ ФАЙЛА ПЕРЕД ЗАПУСКОМ ===
powershell -NoProfile -Command "$e=$null;$t=$null;[System.Management.Automation.Language.Parser]::ParseFile('%~dp0GameBoost.ps1',[ref]$t,[ref]$e)|Out-Null; if($e.Count -gt 0){ Add-Type -AssemblyName System.Windows.Forms; [System.Windows.Forms.MessageBox]::Show('GameBoost.ps1 поврежден при копировании! Ошибок: '+$e.Count+'. Первая: '+$e[0].Message+' (строка '+$e[0].Extent.StartLineNumber+'). Скопируй файл заново ЦЕЛИКОМ.', 'GameBoost'); exit 1 } else { exit 0 }"
if not %errorlevel%==0 (
    echo Файл поврежден. Скопируй GameBoost.ps1 заново целиком.
    pause
    exit /b
)

REM === 3) ЗАПУСК ===
start "" powershell -ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command "try { Add-Type -AssemblyName System.Windows.Forms; & '%~dp0GameBoost.ps1' } catch { [System.Windows.Forms.MessageBox]::Show('Не удалось запустить GameBoost: ' + $_, 'GameBoost') }"

endlocal
exit /b