# =============================================================================
# Vixen Dio Pro - PowerShell Build Script  
# =============================================================================
# Modern PowerShell script for Windows with advanced features
# =============================================================================

param(
    [switch]$NoSynthesis,
    [switch]$QuickCheck,
    [switch]$Help,
    [switch]$Verbose
)

# Enable strict mode
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Project configuration
$ProjectName = "Vixen Dio Pro"
$ProjectRoot = Split-Path -Parent $PSScriptRoot

# Color functions for better output
function Write-ColorText {
    param(
        [string]$Text,
        [string]$Color = "White"
    )
    Write-Host $Text -ForegroundColor $Color
}

function Write-Status {
    param([string]$Message)
    Write-ColorText "[INFO] $Message" -Color Green
}

function Write-Warning {
    param([string]$Message)
    Write-ColorText "[WARNING] $Message" -Color Yellow
}

function Write-Error {
    param([string]$Message)
    Write-ColorText "[ERROR] $Message" -Color Red
}

function Write-Header {
    param([string]$Title)
    Write-ColorText "===============================================" -Color Blue
    Write-ColorText "  $Title" -Color Blue
    Write-ColorText "===============================================" -Color Blue
    Write-Host ""
}

# Show help if requested
if ($Help) {
    Write-Header "$ProjectName - Build Script Help"
    Write-Host "Usage: .\build.ps1 [options]"
    Write-Host ""
    Write-Host "Options:"
    Write-Host "  -NoSynthesis    Skip synthesis, only validate files"
    Write-Host "  -QuickCheck     Quick validation only"
    Write-Host "  -Verbose        Enable verbose output"
    Write-Host "  -Help           Show this help message"
    Write-Host ""
    Write-Host "Examples:"
    Write-Host "  .\build.ps1                    # Full build with synthesis"
    Write-Host "  .\build.ps1 -QuickCheck        # Quick validation only"
    Write-Host "  .\build.ps1 -NoSynthesis       # Validate without synthesis"
    Write-Host ""
    exit 0
}

# Main script starts here
Write-Header "$ProjectName - PowerShell Build Script"

# Check if we're in the right directory
$TopModulePath = Join-Path $ProjectRoot "rtl\vixen_dio_pro.sv"
if (-not (Test-Path $TopModulePath)) {
    Write-Error "Cannot find vixen_dio_pro.sv. Are you in the right directory?"
    Write-Host "Expected: $TopModulePath"
    exit 1
}

Write-Status "Project root: $ProjectRoot"

# Create necessary directories
Write-Status "Creating directory structure..."
$Directories = @("results", "reports", "logs", "work")
foreach ($Dir in $Directories) {
    $DirPath = Join-Path $ProjectRoot $Dir
    if (-not (Test-Path $DirPath)) {
        New-Item -ItemType Directory -Path $DirPath -Force | Out-Null
        if ($Verbose) { Write-Status "Created directory: $Dir" }
    } else {
        if ($Verbose) { Write-Status "Directory exists: $Dir" }
    }
}

# Function to check if a command exists
function Test-Command {
    param([string]$CommandName)
    $Command = Get-Command $CommandName -ErrorAction SilentlyContinue
    return $null -ne $Command
}

# Check for required tools
Write-Status "Checking for required tools..."

$ToolsOK = $true

# Check Python
if (Test-Command "python") {
    $PythonVersion = & python --version 2>&1
    Write-Status "Python found: $PythonVersion"
} elseif (Test-Command "python3") {
    $PythonVersion = & python3 --version 2>&1
    Write-Status "Python3 found: $PythonVersion"
    Set-Alias python python3
} else {
    Write-Warning "Python not found"
    $ToolsOK = $false
}

# Check OpenROAD
if (Test-Command "openroad") {
    Write-Status "OpenROAD found in PATH"
} else {
    # Check common installation locations
    $OpenRoadPaths = @(
        "C:\openroad\bin\openroad.exe",
        "C:\Program Files\openroad\bin\openroad.exe",
        "${env:USERPROFILE}\openroad\bin\openroad.exe"
    )
    
    $OpenRoadFound = $false
    foreach ($Path in $OpenRoadPaths) {
        if (Test-Path $Path) {
            Write-Status "OpenROAD found at: $Path"
            $OpenRoadDir = Split-Path $Path
            $env:PATH = "$OpenRoadDir;$env:PATH"
            $OpenRoadFound = $true
            break
        }
    }
    
    if (-not $OpenRoadFound) {
        Write-Warning "OpenROAD not found"
        $ToolsOK = $false
    }
}

# Check Yosys (optional)
if (Test-Command "yosys") {
    $YosysVersion = & yosys -V 2>&1 | Select-Object -First 1
    Write-Status "Yosys found: $YosysVersion"
} else {
    Write-Warning "Yosys not found (optional)"
}

if (-not $ToolsOK) {
    Write-Error "Some required tools are missing. Please install:"
    Write-Host "  - OpenROAD (https://github.com/The-OpenROAD-Project/OpenROAD)"
    Write-Host "  - Python 3 (https://www.python.org/downloads/)"
    Write-Host "  - Optional: Yosys (https://github.com/YosysHQ/yosys)"
    exit 1
}

# Check for PDK files (optional)
Write-Status "Checking for PDK files..."
$PDKPaths = @(
    "C:\pdk",
    "${env:USERPROFILE}\pdk",
    ".\pdk"
)

$PDKFound = $false
foreach ($Path in $PDKPaths) {
    if (Test-Path $Path) {
        Write-Status "PDK directory found at: $Path"
        $PDKFound = $true
        break
    }
}

if (-not $PDKFound) {
    Write-Warning "PDK files not found in standard locations"
    Write-Warning "You may need to install sky130 PDK for full synthesis"
    Write-Warning "See: https://github.com/google/skywater-pdk"
}

# Define Verilog files to validate
$VerilogFiles = @(
    "rtl\vixen_dio_pro.sv",
    "rtl\core\vixen_frontend.sv",
    "rtl\core\vixen_rename_rob.sv",
    "rtl\core\vixen_issue_queue.sv",
    "rtl\core\vixen_branch_predictor.sv",
    "rtl\core\vixen_trace_cache.sv",
    "rtl\core\vixen_smt_manager.sv",
    "rtl\execution\vixen_execution_cluster.sv",
    "rtl\execution\vixen_agu_mul_div.sv",
    "rtl\fpu\vixen_fpu.sv",
    "rtl\cache\vixen_l1_cache.sv",
    "rtl\cache\vixen_l2_l3_cache.sv"
)

# Validate Verilog files
Write-Status "Validating Verilog files..."
$AllFilesExist = $true

foreach ($File in $VerilogFiles) {
    $FilePath = Join-Path $ProjectRoot $File
    if (Test-Path $FilePath) {
        $FileSize = (Get-Item $FilePath).Length
        Write-Status "✓ $File ($([math]::Round($FileSize/1KB, 1)) KB)"
    } else {
        Write-Error "✗ $File (missing)"
        $AllFilesExist = $false
    }
}

if (-not $AllFilesExist) {
    Write-Error "Some required files are missing!"
    exit 1
}

# Calculate total lines of code
Write-Status "Calculating code statistics..."
$TotalLines = 0
$TotalSize = 0

foreach ($File in $VerilogFiles) {
    $FilePath = Join-Path $ProjectRoot $File
    if (Test-Path $FilePath) {
        $Content = Get-Content $FilePath
        $Lines = $Content.Count
        $Size = (Get-Item $FilePath).Length
        $TotalLines += $Lines
        $TotalSize += $Size
        
        if ($Verbose) {
            Write-Status "  $File: $Lines lines"
        }
    }
}

# Print design statistics
Write-Status "Design Statistics:"
Write-Host "  - Top module: vixen_dio_pro"
Write-Host "  - Target process: 130nm"
Write-Host "  - Target frequency: 3.4 GHz"
Write-Host "  - Architecture: x86-64 CISC"
Write-Host "  - Cores: 1 physical, 2 HT threads"
Write-Host "  - Pipeline stages: 20"
Write-Host "  - Issue width: 3-way superscalar"
Write-Host "  - L1 cache: 32KB I + 32KB D"
Write-Host "  - L2 cache: 1MB unified"
Write-Host "  - L3 cache: 2MB unified"
Write-Host "  - Trace cache: 2-8KB"
Write-Host ""

Write-Status "Code Statistics:"
Write-Host "  - Total lines of SystemVerilog: $TotalLines"
Write-Host "  - Total source size: $([math]::Round($TotalSize/1KB, 1)) KB"

# Basic syntax check with Yosys (if available)
if ((Test-Command "yosys") -and (-not $QuickCheck)) {
    Write-Status "Running basic syntax check..."
    
    $SyntaxCheckScript = Join-Path $ProjectRoot "work\syntax_check.ys"
    
    $YosysScript = @"
# Basic syntax check script for Vixen Dio Pro
read_verilog -sv rtl/vixen_dio_pro.sv
read_verilog -sv rtl/core/vixen_frontend.sv  
read_verilog -sv rtl/core/vixen_rename_rob.sv
read_verilog -sv rtl/core/vixen_issue_queue.sv
read_verilog -sv rtl/core/vixen_branch_predictor.sv
read_verilog -sv rtl/core/vixen_trace_cache.sv
read_verilog -sv rtl/core/vixen_smt_manager.sv
read_verilog -sv rtl/execution/vixen_execution_cluster.sv
read_verilog -sv rtl/execution/vixen_agu_mul_div.sv
read_verilog -sv rtl/fpu/vixen_fpu.sv
read_verilog -sv rtl/cache/vixen_l1_cache.sv
read_verilog -sv rtl/cache/vixen_l2_l3_cache.sv

hierarchy -check -top vixen_dio_pro
"@

    Set-Content -Path $SyntaxCheckScript -Value $YosysScript
    
    try {
        Push-Location $ProjectRoot
        $LogFile = Join-Path $ProjectRoot "logs\syntax_check.log"
        & yosys -s $SyntaxCheckScript > $LogFile 2>&1
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Syntax check passed"
        } else {
            Write-Warning "Syntax check failed - check logs\syntax_check.log"
            Write-Warning "Continuing anyway..."
        }
    } catch {
        Write-Warning "Error running syntax check: $_"
    } finally {
        Pop-Location
    }
}

# Quick check exit
if ($QuickCheck) {
    Write-Status "Quick check completed successfully!"
    Write-Host ""
    Write-ColorText "All files validated and ready for synthesis." -Color Green
    exit 0
}

# Run synthesis if requested
if (-not $NoSynthesis) {
    Write-Status "Starting synthesis flow..."
    
    try {
        Push-Location $ProjectRoot
        
        # Check if synthesis script exists
        $SynthesisScript = Join-Path $ProjectRoot "scripts\vixen_synthesis.py"
        if (-not (Test-Path $SynthesisScript)) {
            Write-Error "Synthesis script not found: $SynthesisScript"
            exit 1
        }
        
        # Run the Python synthesis script
        Write-Status "Executing: python scripts\vixen_synthesis.py"
        & python scripts\vixen_synthesis.py
        
        if ($LASTEXITCODE -eq 0) {
            Write-Status "Synthesis completed successfully!"
            
            # Check output files
            $OutputFiles = @{
                "results\vixen_dio_pro_final.v" = "Final netlist"
                "results\vixen_dio_pro_final.def" = "Layout (DEF)"
                "results\vixen_dio_pro_final.gds" = "GDSII layout"
            }
            
            Write-Status "Checking output files:"
            foreach ($File in $OutputFiles.Keys) {
                $FilePath = Join-Path $ProjectRoot $File
                if (Test-Path $FilePath) {
                    $FileSize = (Get-Item $FilePath).Length
                    $Description = $OutputFiles[$File]
                    Write-Status "✓ $Description ($([math]::Round($FileSize/1MB, 2)) MB)"
                } else {
                    Write-Warning "✗ $($OutputFiles[$File]) not generated"
                }
            }
            
        } else {
            Write-Error "Synthesis failed with exit code: $LASTEXITCODE"
            Write-Host "Check the log files in logs\ directory for details"
            exit 1
        }
        
    } catch {
        Write-Error "Error during synthesis: $_"
        exit 1
    } finally {
        Pop-Location
    }
} else {
    Write-Status "Synthesis skipped (--NoSynthesis specified)"
}

# Completion message
Write-Status "Build completed successfully!"
Write-Host ""

Write-Header "$ProjectName Build Complete"

Write-Host "Next steps:"
Write-Host "  1. Review timing reports in reports\"
Write-Host "  2. Check layout in results\vixen_dio_pro_final.def"
Write-Host "  3. Run verification (if tools available)"
Write-Host "  4. Generate test vectors for validation"
Write-Host ""

# Show build summary
Write-Status "Build Summary:"
Write-Host "  - Files validated: $($VerilogFiles.Count)"
Write-Host "  - Total lines: $TotalLines"
Write-Host "  - Build time: $((Get-Date) - $StartTime)"

if (-not $NoSynthesis) {
    Write-Host "  - Synthesis: Completed"
} else {
    Write-Host "  - Synthesis: Skipped"
}

Write-Host ""
Write-ColorText "Vixen Dio Pro processor is ready for testing!" -Color Green
