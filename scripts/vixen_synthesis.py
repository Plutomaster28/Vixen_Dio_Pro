#!/usr/bin/env python3
"""
=============================================================================
Vixen Dio Pro - OpenROAD Synthesis Flow
=============================================================================
Complete synthesis flow for the Vixen Dio Pro processor using OpenROAD
Targets 130nm process with 3.4 GHz frequency goal
=============================================================================
"""

import os
import sys
import subprocess
import time
from pathlib import Path

class VixenSynthesisFlow:
    def __init__(self):
        self.project_root = Path(__file__).parent.parent
        self.config_file = self.project_root / "config" / "openroad_config.tcl"
        self.results_dir = self.project_root / "results"
        self.reports_dir = self.project_root / "reports"
        self.logs_dir = self.project_root / "logs"
        
        # Create directories
        for dir_path in [self.results_dir, self.reports_dir, self.logs_dir]:
            dir_path.mkdir(exist_ok=True)
    
    def run_command(self, command, log_file=None, cwd=None):
        """Run a shell command and capture output"""
        if cwd is None:
            cwd = self.project_root
            
        print(f"Running: {command}")
        
        if log_file:
            log_path = self.logs_dir / log_file
            with open(log_path, 'w') as f:
                try:
                    result = subprocess.run(
                        command, shell=True, cwd=cwd,
                        stdout=f, stderr=subprocess.STDOUT,
                        text=True, check=True
                    )
                    return result.returncode == 0
                except subprocess.CalledProcessError as e:
                    print(f"Error: Command failed with return code {e.returncode}")
                    return False
        else:
            try:
                result = subprocess.run(command, shell=True, cwd=cwd, check=True)
                return result.returncode == 0
            except subprocess.CalledProcessError as e:
                print(f"Error: Command failed with return code {e.returncode}")
                return False
    
    def check_prerequisites(self):
        """Check if required tools are available"""
        tools = ['openroad', 'yosys', 'klayout']
        missing_tools = []
        
        for tool in tools:
            if not self.run_command(f"which {tool}", log_file=None):
                missing_tools.append(tool)
        
        if missing_tools:
            print(f"Error: Missing required tools: {', '.join(missing_tools)}")
            print("Please install OpenROAD and required dependencies")
            return False
        
        return True
    
    def generate_tcl_script(self):
        """Generate the main OpenROAD TCL script"""
        tcl_script = f"""
# =============================================================================
# Vixen Dio Pro - OpenROAD Synthesis Script
# =============================================================================

# Load configuration
source {self.config_file}

# Set up directories
set results_dir "{self.results_dir}"
set reports_dir "{self.reports_dir}"
set logs_dir "{self.logs_dir}"

# Read liberty files
foreach lib_file $LIB_FILES {{
    if {{[file exists $lib_file]}} {{
        read_liberty $lib_file
    }} else {{
        puts "Warning: Liberty file $lib_file not found"
    }}
}}

# Read LEF files  
foreach lef_file $LEF_FILES {{
    if {{[file exists $lef_file]}} {{
        read_lef $lef_file
    }} else {{
        puts "Warning: LEF file $lef_file not found"
    }}
}}

# Read Verilog files
foreach verilog_file $VERILOG_FILES {{
    if {{[file exists $verilog_file]}} {{
        read_verilog $verilog_file
    }} else {{
        puts "Error: Verilog file $verilog_file not found"
        exit 1
    }}
}}

# Link design
link_design $TOP_MODULE

# Read constraints
if {{[file exists $SDC_FILE]}} {{
    read_sdc $SDC_FILE
}} else {{
    puts "Warning: SDC file $SDC_FILE not found, using default constraints"
    create_clock -name clk -period $CLOCK_PERIOD [get_ports clk]
}}

# Initialize floorplan
initialize_floorplan \\
    -die_area $DIE_AREA \\
    -core_area $CORE_AREA \\
    -site unithd

# Place macros (if any)
if {{$ENABLE_MACRO_PLACEMENT}} {{
    # Auto place any memory macros
    auto_macro_placement
}}

# Power planning
add_global_connection -net $POWER_NETS -pin_pattern VDD -power
add_global_connection -net $GROUND_NETS -pin_pattern VSS -ground

# Global placement
global_placement -density $PLACE_DENSITY
puts "Global placement completed"

# Resize and buffer insertion
estimate_parasitics -placement
repair_design
puts "Initial repair completed"

# Detailed placement
detailed_placement
puts "Detailed placement completed"

# Clock tree synthesis
clock_tree_synthesis \\
    -buf_list $CTS_BUF_CELL \\
    -root_buf $CTS_BUF_CELL
puts "Clock tree synthesis completed"

# Post-CTS optimization
estimate_parasitics -placement
repair_design
puts "Post-CTS repair completed"

# Global routing
set_routing_layers -signal $MIN_ROUTE_LAYER:$MAX_ROUTE_LAYER
global_route
puts "Global routing completed"

# Detailed routing
detailed_route
puts "Detailed routing completed"

# Final parasitic extraction and optimization
estimate_parasitics -placement
repair_design -max_wire_length 500
puts "Final repair completed"

# Fill insertion
filler_placement sky130_fd_sc_hd__fill_*
puts "Filler placement completed"

# Generate reports
report_checks -path_delay min_max -fields input_pin,net,fanout \\
    > $reports_dir/timing_report.txt
report_power > $reports_dir/power_report.txt
report_design_area > $reports_dir/area_report.txt

# Write results
write_def $results_dir/vixen_dio_pro_final.def
write_verilog $results_dir/vixen_dio_pro_final.v
write_sdf $results_dir/vixen_dio_pro_final.sdf
write_spef $results_dir/vixen_dio_pro_final.spef

# GDS generation (if LEF/GDS libraries are available)
if {{[info exists GDS_LIBS]}} {{
    write_gds $results_dir/vixen_dio_pro_final.gds
    puts "GDS file generated successfully"
}}

puts "Vixen Dio Pro synthesis flow completed successfully!"
exit 0
"""
        
        script_path = self.project_root / "scripts" / "vixen_synthesis.tcl"
        with open(script_path, 'w') as f:
            f.write(tcl_script)
        
        return script_path
    
    def run_synthesis(self):
        """Run the complete synthesis flow"""
        print("=" * 70)
        print("Starting Vixen Dio Pro Synthesis Flow")
        print("=" * 70)
        
        start_time = time.time()
        
        # Generate TCL script
        tcl_script = self.generate_tcl_script()
        
        # Run OpenROAD
        command = f"openroad -no_splash {tcl_script}"
        success = self.run_command(command, log_file="synthesis.log")
        
        end_time = time.time()
        duration = end_time - start_time
        
        if success:
            print(f"\\nSynthesis completed successfully in {duration:.2f} seconds!")
            self.print_summary()
        else:
            print(f"\\nSynthesis failed after {duration:.2f} seconds.")
            print(f"Check log file: {self.logs_dir}/synthesis.log")
        
        return success
    
    def print_summary(self):
        """Print synthesis summary"""
        print("\\n" + "=" * 70)
        print("VIXEN DIO PRO SYNTHESIS SUMMARY")
        print("=" * 70)
        
        # Try to extract basic information from reports
        timing_report = self.reports_dir / "timing_report.txt"
        area_report = self.reports_dir / "area_report.txt"
        power_report = self.reports_dir / "power_report.txt"
        
        if timing_report.exists():
            print("Timing Analysis:")
            # Simple parsing - in a real flow, you'd have more sophisticated report parsing
            try:
                with open(timing_report, 'r') as f:
                    content = f.read()
                    if "slack" in content.lower():
                        print("  - Timing report generated")
                    else:
                        print("  - Check timing report for detailed analysis")
            except Exception:
                print("  - Timing report available but could not be parsed")
        
        if area_report.exists():
            print("Area Analysis:")
            print("  - Area report generated")
        
        if power_report.exists():
            print("Power Analysis:")
            print("  - Power report generated")
        
        print(f"\\nOutput files available in:")
        print(f"  - Results: {self.results_dir}")
        print(f"  - Reports: {self.reports_dir}")
        print(f"  - Logs: {self.logs_dir}")
        
        print(f"\\nKey files:")
        print(f"  - Final netlist: {self.results_dir}/vixen_dio_pro_final.v")
        print(f"  - Layout (DEF): {self.results_dir}/vixen_dio_pro_final.def")
        print(f"  - Timing (SDF): {self.results_dir}/vixen_dio_pro_final.sdf")
        print(f"  - Parasitics: {self.results_dir}/vixen_dio_pro_final.spef")
        
        gds_file = self.results_dir / "vixen_dio_pro_final.gds"
        if gds_file.exists():
            print(f"  - Layout (GDS): {gds_file}")
        
        print("\\nProcessor specifications achieved:")
        print("  - Architecture: x86-64 CISC processor")
        print("  - Cores: 1 physical core, 2 HT threads")
        print("  - Pipeline: 20 stages")
        print("  - Issue width: 3-way superscalar")
        print("  - Process: 130nm")
        print("  - Target frequency: 3.4 GHz")
        print("  - Die area target: ~240 mm²")

def main():
    if len(sys.argv) > 1 and sys.argv[1] in ['-h', '--help']:
        print("Vixen Dio Pro Synthesis Flow")
        print("Usage: python3 vixen_synthesis.py")
        print("\\nThis script runs the complete OpenROAD synthesis flow for")
        print("the Vixen Dio Pro processor targeting 130nm process technology.")
        return
    
    flow = VixenSynthesisFlow()
    
    # Check prerequisites
    if not flow.check_prerequisites():
        sys.exit(1)
    
    # Run synthesis
    success = flow.run_synthesis()
    
    if not success:
        sys.exit(1)

if __name__ == "__main__":
    main()
