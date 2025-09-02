@echo off
REM =============================================================================
REM Vixen Dio Pro - Windows Build Script
REM =============================================================================
REM PowerShell-based build script for Windows environments
REM =============================================================================

setlocal enabledelayedexpansion

REM Colors for output (Windows console color codes)
set "RED=[91m"
set "GREEN=[92m"
set "YELLOW=[93m"
set "BLUE=[94m"
set "NC=[0m"

REM Project configuration
set "PROJECT_NAME=Vixen Dio Pro"
set "PROJECT_ROOT=%~dp0.."

echo %BLUE%===============================================%NC%
echo %BLUE%  %PROJECT_NAME% - Windows Build Script%NC%
echo %BLUE%===============================================%NC%
echo.

REM Function definitions using goto labels
goto :main

:print_status
echo %GREEN%[INFO]%NC% %~1
goto :eof

:print_warning
echo %YELLOW%[WARNING]%NC% %~1
goto :eof

:print_error
echo %RED%[ERROR]%NC% %~1
goto :eof

:check_file
if exist "%~1" (
    call :print_status "✓ %~1"
    exit /b 0
) else (
    call :print_error "✗ %~1 (missing)"
    exit /b 1
)

:main
REM Check if we're in the right directory
if not exist "%PROJECT_ROOT%\rtl\vixen_dio_pro.sv" (
    call :print_error "Cannot find vixen_dio_pro.sv. Are you in the right directory?"
    exit /b 1
)

call :print_status "Project root: %PROJECT_ROOT%"

REM Create necessary directories
call :print_status "Creating directory structure..."
if not exist "%PROJECT_ROOT%\results" mkdir "%PROJECT_ROOT%\results"
if not exist "%PROJECT_ROOT%\reports" mkdir "%PROJECT_ROOT%\reports"
if not exist "%PROJECT_ROOT%\logs" mkdir "%PROJECT_ROOT%\logs"
if not exist "%PROJECT_ROOT%\work" mkdir "%PROJECT_ROOT%\work"

REM Check for required tools
call :print_status "Checking for required tools..."

set "TOOLS_OK=true"

REM Check for Python
python --version >nul 2>&1
if errorlevel 1 (
    call :print_warning "Python not found"
    set "TOOLS_OK=false"
) else (
    call :print_status "Python found"
)

REM Check for OpenROAD (might be in PATH or specific location)
openroad -version >nul 2>&1
if errorlevel 1 (
    call :print_warning "OpenROAD not found in PATH"
    REM Check common installation locations
    if exist "C:\openroad\bin\openroad.exe" (
        call :print_status "OpenROAD found in C:\openroad\bin\"
        set "PATH=C:\openroad\bin;%PATH%"
    ) else if exist "C:\Program Files\openroad\bin\openroad.exe" (
        call :print_status "OpenROAD found in C:\Program Files\openroad\bin\"
        set "PATH=C:\Program Files\openroad\bin;%PATH%"
    ) else (
        call :print_warning "OpenROAD not found"
        set "TOOLS_OK=false"
    )
) else (
    call :print_status "OpenROAD found"
)

REM Check for Yosys
yosys -V >nul 2>&1
if errorlevel 1 (
    call :print_warning "Yosys not found"
) else (
    call :print_status "Yosys found"
)

if "%TOOLS_OK%"=="false" (
    call :print_error "Some required tools are missing. Please install:"
    echo   - OpenROAD (https://github.com/The-OpenROAD-Project/OpenROAD)
    echo   - Python 3
    echo   - Optional: Yosys (https://github.com/YosysHQ/yosys)
    pause
    exit /b 1
)

REM Validate Verilog files
call :print_status "Validating Verilog files..."

call :check_file "rtl\vixen_dio_pro.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_frontend.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_rename_rob.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_issue_queue.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_branch_predictor.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_trace_cache.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\core\vixen_smt_manager.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\execution\vixen_execution_cluster.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\execution\vixen_agu_mul_div.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\fpu\vixen_fpu.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\cache\vixen_l1_cache.sv"
if errorlevel 1 exit /b 1

call :check_file "rtl\cache\vixen_l2_l3_cache.sv"
if errorlevel 1 exit /b 1

REM Print design statistics
call :print_status "Design Statistics:"
echo   - Top module: vixen_dio_pro
echo   - Target process: 130nm
echo   - Target frequency: 3.4 GHz
echo   - Architecture: x86-64 CISC
echo   - Cores: 1 physical, 2 HT threads
echo   - Pipeline stages: 20
echo   - Issue width: 3-way superscalar
echo   - L1 cache: 32KB I + 32KB D
echo   - L2 cache: 1MB unified
echo   - L3 cache: 2MB unified
echo   - Trace cache: 2-8KB

REM Parse command line arguments
set "SYNTHESIS=true"
set "QUICK_CHECK=false"

:parse_args
if "%~1"=="" goto :args_done
if "%~1"=="--no-synthesis" (
    set "SYNTHESIS=false"
    shift
    goto :parse_args
)
if "%~1"=="--quick-check" (
    set "QUICK_CHECK=true"
    shift
    goto :parse_args
)
if "%~1"=="--help" goto :show_help
if "%~1"=="-h" goto :show_help
call :print_error "Unknown option: %~1"
goto :show_help

:show_help
echo Usage: %0 [options]
echo.
echo Options:
echo   --no-synthesis    Skip synthesis, only validate files
echo   --quick-check     Quick validation only
echo   --help, -h        Show this help message
echo.
exit /b 0

:args_done
if "%QUICK_CHECK%"=="true" (
    call :print_status "Quick check completed successfully!"
    pause
    exit /b 0
)

REM Run synthesis if requested
if "%SYNTHESIS%"=="true" (
    call :print_status "Starting synthesis flow..."
    
    REM Change to project directory
    cd /d "%PROJECT_ROOT%"
    
    REM Run the Python synthesis script
    python scripts\vixen_synthesis.py
    if errorlevel 1 (
        call :print_error "Synthesis failed!"
        echo Check the log files in logs\ directory for details
        pause
        exit /b 1
    )
    
    call :print_status "Synthesis completed successfully!"
    
    REM Check if key output files were generated
    if exist "results\vixen_dio_pro_final.v" (
        call :print_status "✓ Final netlist generated"
    )
    
    if exist "results\vixen_dio_pro_final.def" (
        call :print_status "✓ Layout (DEF) generated"
    )
    
    if exist "results\vixen_dio_pro_final.gds" (
        call :print_status "✓ GDSII layout generated"
    )
)

call :print_status "Build completed successfully!"
echo.
echo %BLUE%===============================================%NC%
echo %BLUE%  %PROJECT_NAME% Build Complete%NC%
echo %BLUE%===============================================%NC%
echo.
echo Next steps:
echo   1. Review timing reports in reports\
echo   2. Check layout in results\vixen_dio_pro_final.def
echo   3. Run verification (if tools available)
echo   4. Generate test vectors for validation
echo.

pause
exit /b 0
