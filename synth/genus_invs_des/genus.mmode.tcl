create_library_set -name default_library_set -timing {/data/Cadence/gpdk045_v60/gsclib045_svt_v4.7/gsclib045/timing/slow_vdd1v0_basicCells.lib /data/Cadence/gpdk045_v60/Synopsys_sram/saed32sram_ss0p95vn40c.lib}
create_rc_corner -name _default_rc_corner_ -T 125.0
create_delay_corner -name default_emulate_delay_corner -library_set default_library_set -opcond PVT_0P9V_125C  -opcond_library slow_vdd1v0 -rc_corner _default_rc_corner_

create_constraint_mode -name _default_constraint_mode_ -sdc_files {genus_invs_des/genus._default_constraint_mode_.sdc}
 
create_analysis_view -name _default_view_  -constraint_mode _default_constraint_mode_ -delay_corner default_emulate_delay_corner
 
 
set_analysis_view -setup _default_view_  -hold _default_view_
 
