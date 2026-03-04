if {![namespace exists ::IMEX]} { namespace eval ::IMEX {} }
set ::IMEX::dataVar [file dirname [file normalize [info script]]]
set ::IMEX::libVar ${::IMEX::dataVar}/libs

create_library_set -name library_max\
   -timing\
    [list ${::IMEX::libVar}/mmmc/slow_vdd1v0_basicCells.lib\
    ${::IMEX::libVar}/mmmc/saed32sram_ss0p95vn40c.lib]
create_library_set -name library_typ\
   -timing\
    [list ${::IMEX::libVar}/mmmc/fast_vdd1v2_basicCells.lib\
    ${::IMEX::libVar}/mmmc/saed32sram_tt1p05v125c.lib]
create_library_set -name library_min\
   -timing\
    [list ${::IMEX::libVar}/mmmc/fast_vdd1v2_basicCells.lib\
    ${::IMEX::libVar}/mmmc/saed32sram_ff1p16vn40c.lib]
create_rc_corner -name rc\
   -preRoute_res 1\
   -postRoute_res 1\
   -preRoute_cap 1\
   -postRoute_cap 1\
   -postRoute_xcap 1\
   -preRoute_clkres 0\
   -preRoute_clkcap 0\
   -qx_tech_file ${::IMEX::libVar}/mmmc/rc/gpdk045.tch
create_delay_corner -name delay_typ\
   -library_set library_typ\
   -rc_corner rc
create_delay_corner -name delay_min\
   -library_set library_min\
   -rc_corner rc
create_delay_corner -name delay_max\
   -library_set library_max\
   -rc_corner rc
create_constraint_mode -name constraint_mode\
   -sdc_files\
    [list /dev/null]
create_analysis_view -name analysis_view_setup -constraint_mode constraint_mode -delay_corner delay_max
create_analysis_view -name analysis_view_power -constraint_mode constraint_mode -delay_corner delay_typ
create_analysis_view -name analysis_view_hold -constraint_mode constraint_mode -delay_corner delay_min
set_analysis_view -setup [list analysis_view_setup analysis_view_power] -hold [list analysis_view_hold analysis_view_power]
