$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmakePath = Join-Path $projectRoot "windows\CMakeLists.txt"
$mainCppPath = Join-Path $projectRoot "windows\runner\main.cpp"
$runnerRcPath = Join-Path $projectRoot "windows\runner\Runner.rc"

if (-not (Test-Path $cmakePath)) {
    Write-Host "windows/ 尚不存在，先執行：" -ForegroundColor Yellow
    Write-Host "  flutter create --platforms=windows ."
    exit 1
}

# CMake project / executable name
$cmake = Get-Content $cmakePath -Raw
$cmake = [regex]::Replace(
    $cmake,
    'project\([A-Za-z0-9_]+\s+LANGUAGES\s+CXX\)',
    'project(tw_stock_news_ai_monitor LANGUAGES CXX)'
)
$cmake = [regex]::Replace(
    $cmake,
    'set\(BINARY_NAME\s+"[^"]+"\)',
    'set(BINARY_NAME "tw_stock_news_ai_monitor")'
)
Set-Content $cmakePath $cmake -Encoding UTF8

# Windows visible title
if (Test-Path $mainCppPath) {
    $cpp = Get-Content $mainCppPath -Raw
    $cpp = [regex]::Replace(
        $cpp,
        'window\.Create\(L"[^"]*"',
        'window.Create(L"TW Stock News AI Monitor"'
    )
    Set-Content $mainCppPath $cpp -Encoding UTF8
}

# Windows VERSIONINFO
if (Test-Path $runnerRcPath) {
    $rc = Get-Content $runnerRcPath -Raw
    $rc = [regex]::Replace(
        $rc,
        'VALUE "FileDescription", "[^"]*',
        'VALUE "FileDescription", "TW Stock News AI Monitor'
    )
    $rc = [regex]::Replace(
        $rc,
        'VALUE "InternalName", "[^"]*',
        'VALUE "InternalName", "tw_stock_news_ai_monitor'
    )
    $rc = [regex]::Replace(
        $rc,
        'VALUE "OriginalFilename", "[^"]*',
        'VALUE "OriginalFilename", "tw_stock_news_ai_monitor.exe'
    )
    $rc = [regex]::Replace(
        $rc,
        'VALUE "ProductName", "[^"]*',
        'VALUE "ProductName", "TW Stock News AI Monitor'
    )
    Set-Content $runnerRcPath $rc -Encoding UTF8
}

Write-Host ""
Write-Host "Windows naming updated:" -ForegroundColor Green
Write-Host "  Project/Binary : tw_stock_news_ai_monitor"
Write-Host "  EXE            : tw_stock_news_ai_monitor.exe"
Write-Host "  Display name   : TW Stock News AI Monitor"
