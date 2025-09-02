
# =============================================================================
# Vixen Dio Pro - OpenROAD Synthesis Script
# =============================================================================

# Load configuration
source /workspace/config/openroad_config.tcl

# Set up directories
set results_dir "/workspace/results"
set reports_dir "/workspace/reports"
set logs_dir "/workspace/logs"

# Read liberty files
foreach lib_file $LIB_FILES {
    if {[file exists $lib_file]} {
        read_liberty $lib_file
    } else {
        puts "Warning: Liberty file $lib_file not found"
    }
}

# Read LEF files  
foreach lef_file $LEF_FILES {
    if {[file exists $lef_file]} {
        read_lef $lef_file
    } else {
        puts "Warning: LEF file $lef_file not found"
    }
}

# Read Verilog files
foreach verilog_file $VERILOG_FILES {
    if {[file exists $verilog_file]} {
        read_verilog $verilog_file
    } else {
        puts "Error: Verilog file $verilog_file not found"
        exit 1
    }
}

# Link design
link_design $TOP_MODULE

# Read constraints
if {[file exists $SDC_FILE]} {
    read_sdc $SDC_FILE
} else {
    puts "Warning: SDC file $SDC_FILE not found, using default constraints"
    create_clock -name clk -period $CLOCK_PERIOD [get_ports clk]
}

# Initialize floorplan
initialize_floorplan \
    -die_area $DIE_AREA \
    -core_area $CORE_AREA \
    -site unithd

# Place macros (if any)
if {$ENABLE_MACRO_PLACEMENT} {
    # Auto place any memory macros
    auto_macro_placement
}

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
clock_tree_synthesis \
    -buf_list $CTS_BUF_CELL \
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
report_checks -path_delay min_max -fields input_pin,net,fanout \
    > $reports_dir/timing_report.txt
report_power > $reports_dir/power_report.txt
report_design_area > $reports_dir/area_report.txt

# Write results
write_def $results_dir/vixen_dio_pro_final.def
write_verilog $results_dir/vixen_dio_pro_final.v
write_sdf $results_dir/vixen_dio_pro_final.sdf
write_spef $results_dir/vixen_dio_pro_final.spef

# GDS generation (if LEF/GDS libraries are available)
if {[info exists GDS_LIBS]} {
    write_gds $results_dir/vixen_dio_pro_final.gds
    puts "GDS file generated successfully"
}

puts "Vixen Dio Pro synthesis flow completed successfully!"
exit 0
