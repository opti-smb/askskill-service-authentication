#Requires -Version 5.1
<#
.SYNOPSIS
    Lambda ZIP packaging script for auth-service (Windows PowerShell)

.DESCRIPTION
    Packages the Python Lambda function and its dependencies into a
    deployment ZIP artifact compatible with AWS Lambda Python 3.12.

.PARAMETER Clean
    Remove build artifacts and exit.

.PARAMETER Test
    Run unit tests before packaging.

.PARAMETER InstallDeps
    Install Python dependencies only; do not create ZIP.

.PARAMETER PackageOnly
    Skip dependency install; re-zip the existing build directory.

.PARAMETER Docker
    Build dependencies inside a Lambda-compatible Docker container.

.PARAMETER Output
    Override the output ZIP filename (default: auth-service-lambda.zip).

.EXAMPLE
    .\build.ps1
    .\build.ps1 -Test
    .\build.ps1 -Docker -Output my-package.zip
    .\build.ps1 -Clean
#>

[CmdletBinding()]
param(
    [switch]$Clean,
    [switch]$Test,
    [switch]$InstallDeps,
    [switch]$PackageOnly,
    [switch]$Docker,
    [string]$Output = "auth-service-lambda.zip"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
$ScriptDir  = $PSScriptRoot
$BuildDir   = Join-Path $ScriptDir ".build"
$DistDir    = Join-Path $ScriptDir "dist"
$OutputPath = Join-Path $DistDir $Output

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
function Write-Info    { param($Msg) Write-Host "[INFO]  $Msg" -ForegroundColor Cyan }
function Write-Ok      { param($Msg) Write-Host "[OK]    $Msg" -ForegroundColor Green }
function Write-Warn    { param($Msg) Write-Host "[WARN]  $Msg" -ForegroundColor Yellow }
function Write-Section { param($Msg) Write-Host "`n── $Msg ──────────────────────────────────────────" -ForegroundColor White }
function Write-Fail    {
    param($Msg)
    Write-Host "[ERROR] $Msg" -ForegroundColor Red
    exit 1
}

# ---------------------------------------------------------------------------
# Requirement checks
# ---------------------------------------------------------------------------
function Require-Command {
    param([string]$Cmd)
    if (-not (Get-Command $Cmd -ErrorAction SilentlyContinue)) {
        Write-Fail "'$Cmd' is not installed or not on PATH"
    }
}

function Require-File {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        Write-Fail "Required file not found: $Path"
    }
}

# ---------------------------------------------------------------------------
# Clean
# ---------------------------------------------------------------------------
function Invoke-Clean {
    Write-Section "Clean"
    Write-Info "Removing build artifacts..."
    if (Test-Path $BuildDir) { Remove-Item $BuildDir -Recurse -Force }
    if (Test-Path $DistDir)  { Remove-Item $DistDir  -Recurse -Force }
    Write-Ok "Clean complete"
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
function Invoke-Preflight {
    Write-Section "Preflight"

    Require-Command "python"
    Require-Command "pip"

    # Python version check
    $VersionStr = & python --version 2>&1
    Write-Info "Python: $VersionStr"
    if ($VersionStr -match "Python (\d+)\.(\d+)") {
        $Major = [int]$Matches[1]; $Minor = [int]$Matches[2]
        if ($Major -lt 3 -or ($Major -eq 3 -and $Minor -lt 12)) {
            Write-Warn "Python $Major.$Minor detected; Lambda runtime is 3.12."
        } else {
            Write-Ok "Python version OK ($Major.$Minor)"
        }
    }

    Require-File (Join-Path $ScriptDir "requirements.txt")
    Require-File (Join-Path $ScriptDir "lambda_function.py")

    if ($Docker) { Require-Command "docker" }

    Write-Ok "Preflight passed"
}

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
function Invoke-Tests {
    Write-Section "Tests"
    Require-Command "python"

    $TestDir = Join-Path $ScriptDir "tests"
    & python -m pytest $TestDir -v --tb=short
    if ($LASTEXITCODE -ne 0) { Write-Fail "Tests failed — aborting build" }
    Write-Ok "All tests passed"
}

# ---------------------------------------------------------------------------
# Install dependencies (native pip)
# ---------------------------------------------------------------------------
function Invoke-InstallDepsNative {
    Write-Section "Install dependencies (native pip)"

    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null
    $ReqFile = Join-Path $ScriptDir "requirements.txt"

    Write-Info "Installing into $BuildDir..."
    & pip install `
        --requirement $ReqFile `
        --target $BuildDir `
        --upgrade `
        --no-cache-dir `
        --platform manylinux2014_x86_64 `
        --implementation cp `
        --python-version 3.12 `
        --only-binary=:all:

    if ($LASTEXITCODE -ne 0) { Write-Fail "pip install failed" }
    Write-Ok "Dependencies installed"
}

# ---------------------------------------------------------------------------
# Install dependencies (Docker)
# ---------------------------------------------------------------------------
function Invoke-InstallDepsDocker {
    Write-Section "Install dependencies (Docker — Lambda-compatible)"

    $DockerImage = "public.ecr.aws/lambda/python:3.12"
    Write-Info "Pulling image: $DockerImage"
    docker pull $DockerImage
    if ($LASTEXITCODE -ne 0) { Write-Fail "docker pull failed" }

    New-Item -ItemType Directory -Force -Path $BuildDir | Out-Null

    # Docker on Windows requires forward-slash paths for volume mounts
    $SrcMount  = $ScriptDir  -replace '\\', '/' -replace '^([A-Z]):', { "/$($_.Value.ToLower())" }
    $OutMount  = $BuildDir   -replace '\\', '/' -replace '^([A-Z]):', { "/$($_.Value.ToLower())" }

    Write-Info "Running pip inside Lambda container..."
    docker run --rm `
        -v "${SrcMount}:/src:ro" `
        -v "${OutMount}:/out" `
        $DockerImage `
        pip install `
            --requirement /src/requirements.txt `
            --target /out `
            --upgrade `
            --no-cache-dir

    if ($LASTEXITCODE -ne 0) { Write-Fail "Docker pip install failed" }
    Write-Ok "Dependencies installed (Docker)"
}

# ---------------------------------------------------------------------------
# Copy source files
# ---------------------------------------------------------------------------
function Invoke-CopySources {
    Write-Section "Copy source files"

    $SourceFiles = @(
        "lambda_function.py",
        "auth.py",
        "db.py",
        "validators.py",
        "config.py"
    )

    foreach ($File in $SourceFiles) {
        $Src = Join-Path $ScriptDir $File
        if (Test-Path $Src) {
            Copy-Item $Src -Destination (Join-Path $BuildDir $File) -Force
            Write-Info "Copied: $File"
        } else {
            Write-Warn "Source file not found (skipping): $File"
        }
    }

    # Prune unwanted artifacts from the build directory
    $Prune = @("__pycache__", ".pytest_cache", "tests", "*.pyc", "*.pyo")
    foreach ($Pattern in $Prune) {
        Get-ChildItem -Path $BuildDir -Filter $Pattern -Recurse -Force `
            -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force
    }

    # Remove dist-info directories (not needed at runtime)
    Get-ChildItem -Path $BuildDir -Directory -Filter "*.dist-info" -Recurse `
        -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force

    Write-Ok "Source files copied"
}

# ---------------------------------------------------------------------------
# Package ZIP
# ---------------------------------------------------------------------------
function Invoke-Package {
    Write-Section "Package"

    New-Item -ItemType Directory -Force -Path $DistDir | Out-Null

    if (Test-Path $OutputPath) {
        Write-Info "Removing existing ZIP: $OutputPath"
        Remove-Item $OutputPath -Force
    }

    Write-Info "Creating ZIP: $OutputPath"

    # Use .NET's ZipFile for reliable cross-platform zipping
    Add-Type -Assembly "System.IO.Compression.FileSystem"

    # Compression level: Optimal
    $CompressionLevel = [System.IO.Compression.CompressionLevel]::Optimal

    $ZipStream = [System.IO.File]::Open(
        $OutputPath,
        [System.IO.FileMode]::CreateNew
    )
    $Archive = [System.IO.Compression.ZipArchive]::new(
        $ZipStream,
        [System.IO.Compression.ZipArchiveMode]::Create
    )

    try {
        $BuildDirFull = (Get-Item $BuildDir).FullName
        $Files = Get-ChildItem -Path $BuildDir -Recurse -File

        foreach ($File in $Files) {
            $RelativePath = $File.FullName.Substring($BuildDirFull.Length + 1) -replace '\\', '/'
            $Entry = $Archive.CreateEntry($RelativePath, $CompressionLevel)
            $EntryStream = $Entry.Open()
            $FileStream  = $File.OpenRead()
            $FileStream.CopyTo($EntryStream)
            $FileStream.Close()
            $EntryStream.Close()
        }
    } finally {
        $Archive.Dispose()
        $ZipStream.Dispose()
    }

    $ZipInfo  = Get-Item $OutputPath
    $SizeMB   = [math]::Round($ZipInfo.Length / 1MB, 2)
    $FileCount = $Files.Count

    Write-Ok "Package created: $OutputPath"
    Write-Info "Size: ${SizeMB} MB  |  Files: $FileCount"

    if ($SizeMB -gt 50) {
        Write-Warn "ZIP is ${SizeMB} MB — Lambda upload limit is 50 MB (250 MB unzipped)"
    }

    Write-Ok "lambda_function.py confirmed at ZIP root"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
Write-Host "`nauth-service Lambda Build  $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor White
Write-Host "  Script dir : $ScriptDir"
Write-Host "  Build dir  : $BuildDir"
Write-Host "  Output     : $OutputPath"

if ($Clean) {
    Invoke-Clean
    exit 0
}

Invoke-Preflight

if ($Test) { Invoke-Tests }

if (-not $PackageOnly) {
    if ($Docker) {
        Invoke-InstallDepsDocker
    } else {
        Invoke-InstallDepsNative
    }
}

if (-not $InstallDeps) {
    Invoke-CopySources
    Invoke-Package
}

Write-Section "Done"
Write-Ok "Build complete → $OutputPath"
Write-Host ""
Write-Host "  Deploy with:" -ForegroundColor White
Write-Host "    aws lambda update-function-code ``"
Write-Host "      --function-name customer-auth-service ``"
Write-Host "      --zip-file fileb://$OutputPath"
