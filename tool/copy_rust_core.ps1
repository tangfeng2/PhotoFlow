param(
  [string]$Configuration = "Release"
)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$RustRoot = Join-Path $RepoRoot "rust"
$DllSource = Join-Path $RustRoot "target\release\photos_core.dll"
$WindowsRunnerOutput = Join-Path $RepoRoot "build\windows\x64\runner\$Configuration"

Push-Location $RustRoot
try {
  cargo build --release
} finally {
  Pop-Location
}

if (!(Test-Path -LiteralPath $DllSource)) {
  throw "Rust DLL not found: $DllSource"
}

New-Item -ItemType Directory -Force -Path $WindowsRunnerOutput | Out-Null
Copy-Item -LiteralPath $DllSource -Destination (Join-Path $WindowsRunnerOutput "photos_core.dll") -Force
Write-Host "Copied photos_core.dll to $WindowsRunnerOutput"
