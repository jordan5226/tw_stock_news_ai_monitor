$ErrorActionPreference = "Stop"

$projectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$cmakePath = Join-Path $projectRoot "windows\CMakeLists.txt"
$mainCppPath = Join-Path $projectRoot "windows\runner\main.cpp"
$runnerRcPath = Join-Path $projectRoot "windows\runner\Runner.rc"

if (-not (Test-Path $cmakePath)) {
    Write-Host "windows/ directory not found." -ForegroundColor Yellow
    Write-Host "Run this first:"
    Write-Host "  flutter create --platforms=windows ."
    exit 1
}

Write-Host "Updating Windows project name..."

# windows/CMakeLists.txt
$cmake = Get-Content -LiteralPath $cmakePath -Raw

$cmake = [regex]::Replace(
    $cmake,
    'project\([A-Za-z0-9_]+ LANGUAGES CXX\)',
    'project(tw_stock_news_ai_monitor LANGUAGES CXX)'
)

$cmake = [regex]::Replace(
    $cmake,
    'set\(BINARY_NAME "[^"]+"\)',
    'set(BINARY_NAME "tw_stock_news_ai_monitor")'
)

Set-Content -LiteralPath $cmakePath -Value $cmake -Encoding UTF8

# windows/runner/main.cpp
if (Test-Path $mainCppPath) {
    $cpp = Get-Content -LiteralPath $mainCppPath -Raw

    $cpp = [regex]::Replace(
        $cpp,
        'window\.Create\(L"[^"]*"',
        'window.Create(L"TW Stock News AI Monitor"'
    )

    Set-Content -LiteralPath $mainCppPath -Value $cpp -Encoding UTF8
}

# windows/runner/Runner.rc
if (Test-Path $runnerRcPath) {
    $rc = Get-Content -LiteralPath $runnerRcPath -Raw

    $rc = [regex]::Replace(
        $rc,
        'VALUE "FileDescription", "[^"]*"',
        'VALUE "FileDescription", "TW Stock News AI Monitor"'
    )

    $rc = [regex]::Replace(
        $rc,
        'VALUE "InternalName", "[^"]*"',
        'VALUE "InternalName", "tw_stock_news_ai_monitor"'
    )

    $rc = [regex]::Replace(
        $rc,
        'VALUE "OriginalFilename", "[^"]*"',
        'VALUE "OriginalFilename", "tw_stock_news_ai_monitor.exe"'
    )

    $rc = [regex]::Replace(
        $rc,
        'VALUE "ProductName", "[^"]*"',
        'VALUE "ProductName", "TW Stock News AI Monitor"'
    )

    Set-Content -LiteralPath $runnerRcPath -Value $rc -Encoding UTF8
}

Write-Host ""
Write-Host "Windows project naming updated successfully." -ForegroundColor Green
Write-Host "Project/Binary : tw_stock_news_ai_monitor"
Write-Host "EXE            : tw_stock_news_ai_monitor.exe"
Write-Host "Display name   : TW Stock News AI Monitor"
