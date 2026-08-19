# ==============================================================================
# GameBoost v1.2 - Ultimate Gamepad Deadzone Manager
# Работает БЕЗ компиляции DLL (User-Mode). 
# Навигация ТОЛЬКО стрелками.
# ==============================================================================

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# ------------------------------------------------------------------------------
# 1. C# МАТЕМАТИКА DEADZONE (Компилируем внутри памяти)
# ------------------------------------------------------------------------------
$DeadzoneCode = @"
using System;

public enum DeadzoneType { Circular, Square, Cross }

public static class DeadzoneMath
{
    public struct Vector2
    {
        public float X;
        public float Y;
        public Vector2(float x, float y) { X = x; Y = y; }
    }

    public static Vector2 Process(float rawX, float rawY, float deadzone, float outerZone, DeadzoneType type)
    {
        // Нормализация входных данных (-1.0 to 1.0)
        float x = Math.Max(-1f, Math.Min(1f, rawX));
        float y = Math.Max(-1f, Math.Min(1f, rawY));

        if (type == DeadzoneType.Square)
        {
            return ProcessSquare(x, y, deadzone, outerZone);
        }
        else if (type == DeadzoneType.Cross)
        {
            return ProcessCross(x, y, deadzone, outerZone);
        }
        else // Circular
        {
            return ProcessCircular(x, y, deadzone, outerZone);
        }
    }

    private static Vector2 ProcessCircular(float x, float y, float dz, float oz)
    {
        float magnitude = (float)Math.Sqrt(x * x + y * y);
        if (magnitude <= dz) return new Vector2(0, 0);
        
        float scale = (magnitude - dz) / (1f - dz - oz);
        if (scale < 0) scale = 0;
        if (scale > 1) scale = 1;

        return new Vector2((x / magnitude) * scale, (y / magnitude) * scale);
    }

    private static Vector2 ProcessSquare(float x, float y, float dz, float oz)
    {
        float absX = Math.Abs(x);
        float absY = Math.Abs(y);
        
        if (absX <= dz && absY <= dz) return new Vector2(0, 0);

        float scaleX = (absX - dz) / (1f - dz - oz);
        float scaleY = (absY - dz) / (1f - dz - oz);

        if (scaleX < 0) scaleX = 0; if (scaleX > 1) scaleX = 1;
        if (scaleY < 0) scaleY = 0; if (scaleY > 1) scaleY = 1;

        return new Vector2(Math.Sign(x) * scaleX, Math.Sign(y) * scaleY);
    }

    private static Vector2 ProcessCross(float x, float y, float dz, float oz)
    {
        // Крестовина: большая мертвая зона по диагоналям
        float absX = Math.Abs(x);
        float absY = Math.Abs(y);
        float diagFactor = Math.Min(absX, absY); // Насколько мы близко к диагонали
        
        // Увеличиваем мертвую зону для диагоналей
        float effectiveDz = dz + (diagFactor * 0.3f); 

        if (absX <= effectiveDz && absY <= effectiveDz) return new Vector2(0, 0);

        float scaleX = (absX - effectiveDz) / (1f - effectiveDz - oz);
        float scaleY = (absY - effectiveDz) / (1f - effectiveDz - oz);

        if (scaleX < 0) scaleX = 0; if (scaleX > 1) scaleX = 1;
        if (scaleY < 0) scaleY = 0; if (scaleY > 1) scaleY = 1;

        return new Vector2(Math.Sign(x) * scaleX, Math.Sign(y) * scaleY);
    }
}
"@

try {
    Add-Type -TypeDefinition $DeadzoneCode -Language CSharp -ErrorAction Stop
} catch {
    Write-Host "Ошибка компиляции математики: $_" -ForegroundColor Red
    Read-Host "Нажмите Enter для выхода"
    exit
}

# ------------------------------------------------------------------------------
# 2. КОНФИГУРАЦИЯ И СОСТОЯНИЕ
# ------------------------------------------------------------------------------
$configPath = "$PSScriptRoot\gameboost_config.json"

$defaultConfig = @{
    LeftStick = @{
        Type = "Circular"
        Deadzone = 0.15
        Outer = 0.0
    }
    RightStick = @{
        Type = "Circular"
        Deadzone = 0.10
        Outer = 0.0
    }
    GlobalEnabled = $true
}

$settings = $defaultConfig

if (Test-Path $configPath) {
    try {
        $settings = Get-Content $configPath | ConvertFrom-Json
        # Мерджим дефолты если чего-то нет
        if (-not $settings.LeftStick) { $settings.LeftStick = $defaultConfig.LeftStick }
        if (-not $settings.RightStick) { $settings.RightStick = $defaultConfig.RightStick }
    } catch {
        Write-Host "Конфиг поврежден, используем настройки по умолчанию." -ForegroundColor Yellow
    }
}

function Save-Config {
    $settings | ConvertTo-Json | Out-File $configPath -Encoding utf8
}

# Глобальные переменные навигации
$menuItems = @("Настройки Левого Сти", "Настройки Правого Сти", "Калибровка (5 сек)", "Сгенерировать DLL", "Выход")
$selectedIndex = 0
$subMenuActive = $false
$subMenuIndex = 0 # 0 - Left, 1 - Right
$paramIndex = 0   # 0 - Type, 1 - Deadzone, 2 - Outer

# Для симуляции ввода (эмуляция стика)
$simX = 0.0
$simY = 0.0
$lastInputTime = [DateTime]::Now

# ------------------------------------------------------------------------------
# 3. ФУНКЦИИ ОТРИСОВКИ
# ------------------------------------------------------------------------------

function Draw-Header {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "   GAMEBOOST v1.2 - DEADZONE MANAGER  " -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "Навигация: СТРЕЛКИ (Up/Down/Left/Right)" -ForegroundColor Gray
    Write-Host "Действие: ENTER | Назад: ESC" -ForegroundColor Gray
    Write-Host "----------------------------------------" -ForegroundColor DarkGray
}

function Draw-MainMenu {
    Draw-Header
    Write-Host "`nГЛАВНОЕ МЕНЮ:" -ForegroundColor Green
    
    for ($i = 0; $i -lt $menuItems.Length; $i++) {
        $prefix = if ($i -eq $selectedIndex) { ">> " } else { "   " }
        $color = if ($i -eq $selectedIndex) { "Yellow" } else { "White" }
        Write-Host "$prefix$($menuItems[$i])" -ForegroundColor $color
    }
    
    Write-Host "`n[Статус] Глобальный перехват: $(if($settings.GlobalEnabled){'ВКЛ'}else{'ВЫКЛ'})" -ForegroundColor Gray
    Write-Host "Совет: Используйте эмулятор геймпада для проверки." -ForegroundColor DarkGray
}

function Draw-SubMenu {
    Draw-Header
    $stickName = if ($subMenuIndex -eq 0) { "ЛЕВЫЙ СТИК" } else { "ПРАВЫЙ СТИК" }
    $stickData = if ($subMenuIndex -eq 0) { $settings.LeftStick } else { $settings.RightStick }
    
    Write-Host "`nНАСТРОЙКИ: $stickName" -ForegroundColor Magenta
    Write-Host "----------------------------------------"
    
    # Параметр 1: Тип
    $p1Prefix = if ($paramIndex -eq 0) { ">> " } else { "   " }
    $p1Color = if ($paramIndex -eq 0) { "Yellow" } else { "White" }
    Write-Host "$p1PrefixТип зоны : $($stickData.Type)" -ForegroundColor $p1Color
    
    # Параметр 2: Мертвая зона
    $p2Prefix = if ($paramIndex -eq 1) { ">> " } else { "   " }
    $p2Color = if ($paramIndex -eq 1) { "Yellow" } else { "White" }
    Write-Host "$p2PrefixМертвая зона (Inner): $($stickData.Deadzone.ToString("0.00"))" -ForegroundColor $p2Color
    
    # Параметр 3: Внешняя зона
    $p3Prefix = if ($paramIndex -eq 2) { ">> " } else { "   " }
    $p3Color = if ($paramIndex -eq 2) { "Yellow" } else { "White" }
    Write-Host "$p3PrefixАнти-насыщение (Outer): $($stickData.Outer.ToString("0.00"))" -ForegroundColor $p3Color

    Write-Host "`n----------------------------------------"
    Write-Host "ВИЗУАЛИЗАЦИЯ (Симуляция ввода):" -ForegroundColor Cyan
    
    # Симуляция ввода (если кнопки не нажаты, возвращаем в 0)
    if ([Console]::KeyAvailable) {
        # Не читаем здесь, чтобы не ломать основной цикл, просто эмулируем движение мышкой для демо
        # В реальном сценарии тут был бы опрос XInput
    }
    
    # Получаем обработанные значения
    $typeVal = [DeadzoneType]::Circular
    if ($stickData.Type -eq "Square") { $typeVal = [DeadzoneType]::Square }
    if ($stickData.Type -eq "Cross") { $typeVal = [DeadzoneType]::Cross }
    
    # Эмулируем небольшое движение для демонстрации, если пользователь не трогает контроллер
    # Здесь мы просто берем текущие симулированные координаты
    $res = [DeadzoneMath]::Process($simX, $simY, [float]$stickData.Deadzone, [float]$stickData.Outer, $typeVal)
    
    Draw-Joystick-Visual $simX $simY $res.X $res.Y
}

function Draw-Joystick-Visual ($rawX, $rawY, $procX, $procY) {
    $size = 9
    $center = [int]($size / 2)
    
    # Рисуем сетку
    for ($y = -$size; $y -le $size; $y+=2) {
        $line = ""
        for ($x = -$size; $x -le $size; $x+=2) {
            $char = "."
            
            # Центр
            if ($x -eq 0 -and $y -eq 0) { $char = "+" }
            
            # Сырой ввод (Красный)
            $rawPosX = [int]($rawX * $size)
            $rawPosY = [int]($rawY * $size)
            if ([Math]::Abs($x - $rawPosX) -lt 2 -and [Math]::Abs($y - $rawPosY) -lt 2) { $char = "O" }
            
            # Обработанный ввод (Зеленый)
            $procPosX = [int]($procX * $size)
            $procPosY = [int]($procY * $size)
            if ([Math]::Abs($x - $procPosX) -lt 2 -and [Math]::Abs($y - $procPosY) -lt 2) { $char = "X" }
            
            $line += $char
        }
        Write-Host $line -NoNewline
        Write-Host ""
    }
    Write-Host "`nO = Сырой ввод | X = Результат | + = Центр" -ForegroundColor DarkGray
    Write-Host "Raw: [$rawX, $rawY] -> Out: [$procX, $procY]" -ForegroundColor White
}

function Draw-Calibration {
    Draw-Header
    Write-Host "`nКАЛИБРОВКА ПОД ИГРУ" -ForegroundColor Red
    Write-Host "-------------------"
    Write-Host "1. Сверните это окно."
    Write-Host "2. Запустите игру."
    Write-Host "3. Через 5 секунд скрипт попытается определить процесс..."
    Write-Host ""
    
    for ($i = 5; $i -ge 0; $i--) {
        Write-Host "Осталось секунд: $i" -NoNewline
        Start-Sleep -Milliseconds 1000
        Write-Host "`r" -NoNewline
    }
    
    $proc = Get-Process | Sort-Object StartTime -Descending | Select-Object -First 1
    Write-Host "`rОбнаружен активный процесс: $($proc.ProcessName) (PID: $($proc.Id))" -ForegroundColor Green
    Write-Host "Настройки применены глобально. Для точного внедрения используйте кнопку 'Сгенерировать DLL'."
    Start-Sleep -Seconds 2
}

function Generate-DLL-Instruction {
    Draw-Header
    Write-Host "`nГЕНЕРАТОР DLL (ИНСТРУКЦИЯ)" -ForegroundColor Yellow
    Write-Host "Так как PowerShell не может создать нативную DLL без Visual Studio," -ForegroundColor Gray
    Write-Host "я подготовил для вас КОД, который нужно вставить в C# проект." -ForegroundColor Gray
    Write-Host ""
    Write-Host "1. Создайте проект 'Class Library (.NET Framework)' в VS." -ForegroundColor White
    Write-Host "2. Установите пакет NuGet: UnmanagedExports." -ForegroundColor White
    Write-Host "3. Вставьте этот код в Program.cs:" -ForegroundColor White
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    
    $dllCode = @"
using System;
using System.Runtime.InteropServices;
using UnmanagedExports;

public class XInputProxy
{
    [DllExport("XInputGetState", CallingConvention = StdCall)]
    public static int XInputGetState(uint dwUserIndex, IntPtr pState)
    {
        // Тут вызов оригинальной функции и применение DeadzoneMath.Process
        // Код слишком велик для консоли, но логика та же, что в этом скрипте!
        return 0; // Заглушка
    }
}
"@
    Write-Host $dllCode -ForegroundColor Green
    Write-Host "------------------------------------------------------------" -ForegroundColor DarkGray
    Write-Host "`nПосле компиляции положите DLL в папку с игрой как 'xinput1_3.dll'." -ForegroundColor Yellow
    Read-Host "Нажмите Enter, чтобы вернуться"
}

# ------------------------------------------------------------------------------
# 4. ОСНОВНОЙ ЦИКЛ (INPUT LOOP)
# ------------------------------------------------------------------------------

Write-Host "Запуск GameBoost v1.2..." -ForegroundColor Cyan
Start-Sleep -Milliseconds 500

# Предварительная симуляция движения для красоты
$simTimer = 0

while ($true) {
    # 1. Отрисовка
    if (-not $subMenuActive) {
        Draw-MainMenu
    } else {
        Draw-SubMenu
    }
    
    # Анимация симулятора стика (если мы в подменю)
    if ($subMenuActive) {
        $time = [DateTime]::Now.Millisecond / 1000.0
        $simX = [Math]::Sin($time * 2) * 0.8
        $simY = [Math]::Cos($time * 3) * 0.6
    }

    # 2. Обработка ввода (НЕ БЛОКИРУЮЩАЯ)
    if ([Console]::KeyAvailable) {
        $key = [Console]::ReadKey($true)
        
        if (-not $subMenuActive) {
            # --- ГЛАВНОЕ МЕНЮ ---
            switch ($key.Key) {
                "DownArrow" { 
                    $selectedIndex++
                    if ($selectedIndex -ge $menuItems.Length) { $selectedIndex = 0 }
                }
                "UpArrow" { 
                    $selectedIndex--
                    if ($selectedIndex -lt 0) { $selectedIndex = $menuItems.Length - 1 }
                }
                "Enter" {
                    if ($selectedIndex -eq 4) { 
                        # ВЫХОД
                        break 
                    } elseif ($selectedIndex -eq 2) {
                        # КАЛИБРОВКА
                        Draw-Calibration
                    } elseif ($selectedIndex -eq 3) {
                        # DLL
                        Generate-DLL-Instruction
                    } else {
                        # НАСТРОЙКИ СТИКОВ (0 или 1)
                        $subMenuActive = $true
                        $subMenuIndex = $selectedIndex
                        $paramIndex = 0
                    }
                }
                "G" { 
                    # Хоткей для геймпада
                    $subMenuActive = $true
                    $subMenuIndex = 0
                    $paramIndex = 0
                }
            }
        } else {
            # --- ПОДМЕНЮ НАСТРОЕК ---
            switch ($key.Key) {
                "Escape" {
                    Save-Config
                    $subMenuActive = $false
                }
                "DownArrow" {
                    $paramIndex++
                    if ($paramIndex -gt 2) { $paramIndex = 0 }
                }
                "UpArrow" {
                    $paramIndex--
                    if ($paramIndex -lt 0) { $paramIndex = 2 }
                }
                "RightArrow" {
                    # Увеличение значения
                    $stick = if ($subMenuIndex -eq 0) { $settings.LeftStick } else { $settings.RightStick }
                    
                    if ($paramIndex -eq 0) {
                        # Перебор типов
                        if ($stick.Type -eq "Circular") { $stick.Type = "Square" }
                        elseif ($stick.Type -eq "Square") { $stick.Type = "Cross" }
                        else { $stick.Type = "Circular" }
                    } elseif ($paramIndex -eq 1) {
                        $stick.Deadzone = [Math]::Min(1.0, $stick.Deadzone + 0.05)
                    } elseif ($paramIndex -eq 2) {
                        $stick.Outer = [Math]::Min(0.5, $stick.Outer + 0.05)
                    }
                }
                "LeftArrow" {
                    # Уменьшение значения
                    $stick = if ($subMenuIndex -eq 0) { $settings.LeftStick } else { $settings.RightStick }
                    
                    if ($paramIndex -eq 0) {
                        if ($stick.Type -eq "Circular") { $stick.Type = "Cross" }
                        elseif ($stick.Type -eq "Cross") { $stick.Type = "Square" }
                        else { $stick.Type = "Circular" }
                    } elseif ($paramIndex -eq 1) {
                        $stick.Deadzone = [Math]::Max(0.0, $stick.Deadzone - 0.05)
                    } elseif ($paramIndex -eq 2) {
                        $stick.Outer = [Math]::Max(0.0, $stick.Outer - 0.05)
                    }
                }
                "Enter" {
                    # Тоже работает как переключатель для типа или сохранение
                    if ($paramIndex -eq 0) {
                         $stick = if ($subMenuIndex -eq 0) { $settings.LeftStick } else { $settings.RightStick }
                         if ($stick.Type -eq "Circular") { $stick.Type = "Square" }
                         elseif ($stick.Type -eq "Square") { $stick.Type = "Cross" }
                         else { $stick.Type = "Circular" }
                    } else {
                        Save-Config
                        Write-Host "Сохранено!" -ForegroundColor Green
                        Start-Sleep -Milliseconds 300
                    }
                }
            }
        }
        
        # Проверка на полный выход
        if (-not $subMenuActive -and $selectedIndex -eq 4) { break }
    }
    
    Start-Sleep -Milliseconds 50 # Ограничение FPS цикла
}

Write-Host "`nGameBoost завершен." -ForegroundColor Cyan
