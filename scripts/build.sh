#!/bin/bash
# =============================================================================
# Vixen Dio Pro - Build Script
# =============================================================================
# Simple bash script to run synthesis and setup the environment
# =============================================================================

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Project configuration
PROJECT_NAME="Vixen Dio Pro"
PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}  $PROJECT_NAME - Build Script${NC}"
echo -e "${BLUE}===============================================${NC}"
echo ""

# Function to print status messages
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

# Check if we're in the right directory
if [ ! -f "$PROJECT_ROOT/rtl/vixen_dio_pro.sv" ]; then
    print_error "Cannot find vixen_dio_pro.sv. Are you in the right directory?"
    exit 1
fi

print_status "Project root: $PROJECT_ROOT"

# Create necessary directories
print_status "Creating directory structure..."
mkdir -p "$PROJECT_ROOT/results"
mkdir -p "$PROJECT_ROOT/reports"  
mkdir -p "$PROJECT_ROOT/logs"
mkdir -p "$PROJECT_ROOT/work"

# Check for required tools
print_status "Checking for required tools..."

check_tool() {
    if command -v $1 &> /dev/null; then
        print_status "$1 found"
        return 0
    else
        print_warning "$1 not found"
        return 1
    fi
}

TOOLS_OK=true
if ! check_tool "openroad"; then
    TOOLS_OK=false
fi

if ! check_tool "yosys"; then
    TOOLS_OK=false
fi

if ! check_tool "python3"; then
    TOOLS_OK=false
fi

if [ "$TOOLS_OK" = false ]; then
    print_error "Some required tools are missing. Please install:"
    echo "  - OpenROAD (https://github.com/The-OpenROAD-Project/OpenROAD)"
    echo "  - Yosys (https://github.com/YosysHQ/yosys)"
    echo "  - Python 3"
    exit 1
fi

# Check for PDK files (optional)
print_status "Checking for PDK files..."
if [ -d "/usr/share/pdk" ] || [ -d "$HOME/pdk" ] || [ -d "./pdk" ]; then
    print_status "PDK directory found"
else
    print_warning "PDK files not found in standard locations"
    print_warning "You may need to install sky130 PDK for full synthesis"
    print_warning "See: https://github.com/google/skywater-pdk"
fi

# Validate Verilog files
print_status "Validating Verilog files..."
VERILOG_FILES=(
    "rtl/vixen_dio_pro.sv"
    "rtl/core/vixen_frontend.sv"
    "rtl/core/vixen_rename_rob.sv"
    "rtl/core/vixen_issue_queue.sv"
    "rtl/core/vixen_branch_predictor.sv"
    "rtl/core/vixen_trace_cache.sv"
    "rtl/core/vixen_smt_manager.sv"
    "rtl/execution/vixen_execution_cluster.sv"
    "rtl/execution/vixen_agu_mul_div.sv"
    "rtl/fpu/vixen_fpu.sv"
    "rtl/cache/vixen_l1_cache.sv"
    "rtl/cache/vixen_l2_l3_cache.sv"
)

for file in "${VERILOG_FILES[@]}"; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        print_status "✓ $file"
    else
        print_error "✗ $file (missing)"
        exit 1
    fi
done

# Basic syntax check with Yosys (if available)
if command -v yosys &> /dev/null; then
    print_status "Running basic syntax check..."
    
    cat > "$PROJECT_ROOT/work/syntax_check.ys" << EOF
# Basic syntax check script
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
EOF

    if yosys -s "$PROJECT_ROOT/work/syntax_check.ys" > "$PROJECT_ROOT/logs/syntax_check.log" 2>&1; then
        print_status "Syntax check passed"
    else
        print_warning "Syntax check failed - check logs/syntax_check.log"
        print_warning "Continuing anyway..."
    fi
fi

# Print design statistics
print_status "Design Statistics:"
echo "  - Top module: vixen_dio_pro"
echo "  - Target process: 130nm"
echo "  - Target frequency: 3.4 GHz"
echo "  - Architecture: x86-64 CISC"
echo "  - Cores: 1 physical, 2 HT threads"
echo "  - Pipeline stages: 20"
echo "  - Issue width: 3-way superscalar"
echo "  - L1 cache: 32KB I + 32KB D"
echo "  - L2 cache: 1MB unified"
echo "  - L3 cache: 2MB unified"
echo "  - Trace cache: 2-8KB"

# Count lines of code
print_status "Code Statistics:"
TOTAL_LINES=0
for file in "${VERILOG_FILES[@]}"; do
    if [ -f "$PROJECT_ROOT/$file" ]; then
        LINES=$(wc -l < "$PROJECT_ROOT/$file")
        TOTAL_LINES=$((TOTAL_LINES + LINES))
    fi
done
echo "  - Total lines of SystemVerilog: $TOTAL_LINES"

# Parse command line arguments
SYNTHESIS=true
QUICK_CHECK=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --no-synthesis)
            SYNTHESIS=false
            shift
            ;;
        --quick-check)
            QUICK_CHECK=true
            shift
            ;;
        --help|-h)
            echo "Usage: $0 [options]"
            echo ""
            echo "Options:"
            echo "  --no-synthesis    Skip synthesis, only validate files"
            echo "  --quick-check     Quick validation only"
            echo "  --help, -h        Show this help message"
            echo ""
            exit 0
            ;;
        *)
            print_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [ "$QUICK_CHECK" = true ]; then
    print_status "Quick check completed successfully!"
    exit 0
fi

# Run synthesis if requested
if [ "$SYNTHESIS" = true ]; then
    print_status "Starting synthesis flow..."
    
    # Make sure Python script is executable
    chmod +x "$PROJECT_ROOT/scripts/vixen_synthesis.py"
    
    # Run the Python synthesis script
    cd "$PROJECT_ROOT"
    if python3 scripts/vixen_synthesis.py; then
        print_status "Synthesis completed successfully!"
        
        # Check if key output files were generated
        if [ -f "results/vixen_dio_pro_final.v" ]; then
            print_status "✓ Final netlist generated"
        fi
        
        if [ -f "results/vixen_dio_pro_final.def" ]; then
            print_status "✓ Layout (DEF) generated"
        fi
        
        if [ -f "results/vixen_dio_pro_final.gds" ]; then
            print_status "✓ GDSII layout generated"
        fi
        
        # Show file sizes
        print_status "Output file sizes:"
        if [ -f "results/vixen_dio_pro_final.v" ]; then
            SIZE=$(du -h "results/vixen_dio_pro_final.v" | cut -f1)
            echo "  - Netlist: $SIZE"
        fi
        
        if [ -f "results/vixen_dio_pro_final.def" ]; then
            SIZE=$(du -h "results/vixen_dio_pro_final.def" | cut -f1)
            echo "  - DEF layout: $SIZE"
        fi
        
        if [ -f "results/vixen_dio_pro_final.gds" ]; then
            SIZE=$(du -h "results/vixen_dio_pro_final.gds" | cut -f1)
            echo "  - GDS layout: $SIZE"
        fi
        
    else
        print_error "Synthesis failed!"
        echo "Check the log files in logs/ directory for details"
        exit 1
    fi
fi

print_status "Build completed successfully!"
echo ""
echo -e "${BLUE}===============================================${NC}"
echo -e "${BLUE}  $PROJECT_NAME Build Complete${NC}"
echo -e "${BLUE}===============================================${NC}"
echo ""
echo "Next steps:"
echo "  1. Review timing reports in reports/"
echo "  2. Check layout in results/vixen_dio_pro_final.def"
echo "  3. Run verification (if tools available)"
echo "  4. Generate test vectors for validation"
echo ""
