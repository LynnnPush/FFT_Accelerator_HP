#######################################################
#                                                     
#  Innovus Command Logging File                     
#  Created on Wed Mar  4 11:47:54 2026                
#                                                     
#######################################################

#@(#)CDS: Innovus v21.11-s130_1 (64bit) 08/19/2021 16:59 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: NanoRoute 21.11-s130_1 NR210811-1832/21_11-UB (database version 18.20.554) {superthreading v2.14}
#@(#)CDS: AAE 21.11-s059 (64bit) 08/19/2021 (Linux 3.10.0-693.el7.x86_64)
#@(#)CDS: CTE 21.11-s010_1 () Aug 12 2021 04:17:41 ( )
#@(#)CDS: SYNTECH 21.11-s003_1 () Aug  4 2021 01:23:26 ( )
#@(#)CDS: CPE v21.11-s010
#@(#)CDS: IQuantus/TQuantus 20.1.2-s578 (64bit) Fri Jul 9 11:48:16 PDT 2021 (Linux 2.6.32-431.11.2.el6.x86_64)

set_global _enable_mmmc_by_default_flow      $CTE::mmmc_default
suppressMessage ENCEXT-2799
setMessageLimit 1 ENCLF 45
setMessageLimit 1 ENCLF 119
setMessageLimit 1 ENCLF 200
setMessageLimit 1 ENCLF 201
setMessageLimit 10 IMPDB 2078
setMessageLimit 10 IMPDC 348
setMultiCpuUsage -localCpu 4 -cpuPerRemoteHost 4 -remoteHost 1 -keepLicense true
set init_pwr_net VDD
set init_gnd_net VSS
set init_design_settop 1
set init_verilog ../synth/outputs/et4351.struct.v
set init_top_cell et4351
set init_lef_file {  /data/Cadence/gpdk045_v60/gsclib045_svt_v4.7/gsclib045_tech/lef/gsclib045_tech.lef  /data/Cadence/gpdk045_v60/gsclib045_svt_v4.7/gsclib045/lef/gsclib045_macro.lef  /data/Cadence/gpdk045_v60/Synopsys_sram/saed32sram.lef }
set init_mmmc_file ./scripts/2.1.set_library_n_sdc.tcl
setDesignMode -process 45
setDelayCalMode -SIAware true
setAnalysisMode -analysisType onChipVariation -cppr both
init_design
report_design > initialReports/report_design.rpt
report_constraint > initialReports/report_constraint.rpt
report_clocks > initialReports/report_clocks.rpt
report_ports > initialReports/report_ports.rpt
report_path_exceptions > initialReports/report_path_exceptions.rpt
report_annotated_check > initialReports/report_annotated_check.rpt
setDrawView fplan
setFPlanRowSpacingAndType 0.0 1
floorPlan -site CoreSite -s 596.4 596.4 34.2 34.2 34.2 34.2 -noSnapToGrid
loadIoFile ./scripts/3.1.ET4351_chip.io
placeInstance soc/memory/sram_3 34.2 396.21 R0
placeInstance soc/memory/sram_2 73.035 396.21 R0
placeInstance soc/memory/sram_1 111.87 396.21 R0
placeInstance soc/memory/sram_0 150.705 396.21 R0
addHaloToBlock 0 2.000 2.000 0 -fromInstBox soc/memory/sram_3
addHaloToBlock 0 2.000 2.000 0 -fromInstBox soc/memory/sram_2
addHaloToBlock 0 2.000 2.000 0 -fromInstBox soc/memory/sram_1
addHaloToBlock 0 2.000 22.000 0 -fromInstBox soc/memory/sram_0
checkFPlan -outFile verifyReports/checkFPlan.rpt
saveDesign checkpoints/et4351_fplan.enc
saveFPlan checkpoints/et4351.fp
fit
addRing -around default_power_domain -nets {VSS VDD} -layer {bottom M1 top M1 right M2 left M2} -width 12 -spacing 5 -offset 2
addRing -around default_power_domain -nets {VSS VDD} -layer {bottom M3 top M3 right M4 left M4} -width 12 -spacing 5 -offset 2
addStripe -number_of_sets 1 -start_from left -start 190.54 -spacing 2.0 -direction vertical -layer 6 -width 8 -nets {VSS VDD}
globalNetConnect VDD -type pgpin -pin VDD -inst *
globalNetConnect VSS -type pgpin -pin VSS -inst *
globalNetConnect VDD -type tiehi
globalNetConnect VSS -type tielo
sroute -nets { VDD VSS } -connect { blockPin }
addStripe -number_of_sets 8 -start_from bottom -start 70 -stop 596 -spacing 2.5 -direction horizontal -layer 7 -width 8 -nets {VSS VDD}
addStripe -number_of_sets 2 -start_from left -start 70 -stop 155 -spacing 2.5 -direction vertical -layer 8 -width 8 -nets {VSS VDD}
addStripe -number_of_sets 5 -start_from left -start 240 -stop 596 -spacing 2.5 -direction vertical -layer 8 -width 8 -nets {VSS VDD}
sroute -nets { VDD VSS } -connect { corePin }
saveDesign checkpoints/et4351_pplan.enc
fit
set_power_analysis_mode -report_missing_nets true -corner delay_typ -analysis_view analysis_view_power
read_activity_file ../sim_struct/vcd/et4351.struct.vcd -reset -format VCD -scope testbench/dut
propagate_activity
report_power -outfile powerReports/prePlace_VCDImport.rpt
setPlaceMode -place_global_cong_effort high -place_global_solver_effort high -place_global_timing_effort medium -place_global_activity_power_driven true -place_global_activity_power_driven_effort standard -place_global_uniform_density true
setDesignMode -topRoutingLayer 10
set delaycal_use_default_delay_limit 1000
setExtractRCMode -engine preRoute -effortLevel high
getPlaceMode -place_hierarchical_flow -quiet
report_message -start_cmd
getRouteMode -maxRouteLayer -quiet
getRouteMode -user -maxRouteLayer
getPlaceMode -place_global_place_io_pins -quiet
getPlaceMode -user -maxRouteLayer
getPlaceMode -quiet -adaptiveFlowMode
getPlaceMode -timingDriven -quiet
getPlaceMode -adaptive -quiet
getPlaceMode -relaxSoftBlockageMode -quiet
getPlaceMode -user -relaxSoftBlockageMode
getPlaceMode -ignoreScan -quiet
getPlaceMode -user -ignoreScan
getPlaceMode -repairPlace -quiet
getPlaceMode -user -repairPlace
getPlaceMode -inPlaceOptMode -quiet
getPlaceMode -quiet -bypassFlowEffortHighChecking
getDesignMode -quiet -siPrevention
getPlaceMode -exp_slack_driven -quiet
um::push_snapshot_stack
getDesignMode -quiet -flowEffort
getDesignMode -highSpeedCore -quiet
getPlaceMode -quiet -adaptive
set spgFlowInInitialPlace 1
getPlaceMode -sdpAlignment -quiet
getPlaceMode -softGuide -quiet
getPlaceMode -useSdpGroup -quiet
getPlaceMode -sdpAlignment -quiet
getPlaceMode -enableDbSaveAreaPadding -quiet
getPlaceMode -quiet -wireLenOptEffort
getPlaceMode -sdpPlace -quiet
getPlaceMode -exp_slack_driven -quiet
getPlaceMode -sdpPlace -quiet
getPlaceMode -groupHighLevelClkGate -quiet
setvar spgRptErrorForScanConnection 0
getPlaceMode -place_global_exp_allow_missing_scan_chain -quiet
getPlaceMode -place_check_library -quiet
getPlaceMode -trimView -quiet
getPlaceMode -expTrimOptBeforeTDGP -quiet
getPlaceMode -quiet -useNonTimingDeleteBufferTree
getPlaceMode -congEffort -quiet
getPlaceMode -relaxSoftBlockageMode -quiet
getPlaceMode -user -relaxSoftBlockageMode
getPlaceMode -ignoreScan -quiet
getPlaceMode -user -ignoreScan
getPlaceMode -repairPlace -quiet
getPlaceMode -user -repairPlace
getPlaceMode -congEffort -quiet
getPlaceMode -fp -quiet
getPlaceMode -timingDriven -quiet
getPlaceMode -user -timingDriven
getPlaceMode -fastFp -quiet
getPlaceMode -clusterMode -quiet
get_proto_model -type_match {flex_module flex_instgroup} -committed -name -tcl
getPlaceMode -inPlaceOptMode -quiet
getPlaceMode -quiet -bypassFlowEffortHighChecking
getPlaceMode -ultraCongEffortFlow -quiet
getPlaceMode -forceTiming -quiet
getPlaceMode -fp -quiet
getPlaceMode -fastfp -quiet
getPlaceMode -timingDriven -quiet
getPlaceMode -fp -quiet
getPlaceMode -fastfp -quiet
getPlaceMode -powerDriven -quiet
getExtractRCMode -quiet -engine
getAnalysisMode -quiet -clkSrcPath
getAnalysisMode -quiet -clockPropagation
getAnalysisMode -quiet -cppr
setExtractRCMode -engine preRoute
setAnalysisMode -clkSrcPath false -clockPropagation forcedIdeal
getPlaceMode -exp_slack_driven -quiet
isAnalysisModeSetup
getPlaceMode -quiet -place_global_exp_solve_unbalance_path
getPlaceMode -quiet -NMPsuppressInfo
getPlaceMode -quiet -place_global_exp_wns_focus_v2
getPlaceMode -quiet -place_incr_exp_isolation_flow
getPlaceMode -enableDistPlace -quiet
getPlaceMode -quiet -clusterMode
getPlaceMode -wl_budget_mode -quiet
setPlaceMode -reset -place_global_exp_balance_buffer_chain
getPlaceMode -wl_budget_mode -quiet
setPlaceMode -reset -place_global_exp_balance_pipeline
getPlaceMode -place_global_exp_balance_buffer_chain -quiet
getPlaceMode -place_global_exp_balance_pipeline -quiet
getPlaceMode -tdgpMemFlow -quiet
getPlaceMode -user -resetCombineRFLevel
getPlaceMode -quiet -resetCombineRFLevel
setPlaceMode -resetCombineRFLevel 1000
setvar spgSpeedupBuildVSM 1
getPlaceMode -tdgpResetCteTG -quiet
getPlaceMode -macroPlaceMode -quiet
getPlaceMode -place_global_replace_QP -quiet
getPlaceMode -macroPlaceMode -quiet
getPlaceMode -enableDistPlace -quiet
getPlaceMode -exp_slack_driven -quiet
getPlaceMode -place_global_ignore_spare -quiet
getPlaceMode -enableDistPlace -quiet
getPlaceMode -quiet -expNewFastMode
setPlaceMode -expHiddenFastMode 1
setPlaceMode -reset -ignoreScan
getPlaceMode -quiet -place_global_exp_auto_finish_floorplan
colorizeGeometry
getPlaceMode -quiet -IOSlackAdjust
getPlaceMode -tdgpCteZeroDelayModeDelBuf -quiet
set_global timing_enable_zero_delay_analysis_mode true
getPlaceMode -quiet -useNonTimingDeleteBufferTree
getPlaceMode -quiet -prePlaceOptSimplifyNetlist
getPlaceMode -quiet -enablePrePlaceOptimizations
getPlaceMode -quiet -prePlaceOptDecloneInv
deleteBufferTree -decloneInv
getPlaceMode -tdgpCteZeroDelayModeDelBuf -quiet
set_global timing_enable_zero_delay_analysis_mode false
getAnalysisMode -quiet -honorClockDomains
getPlaceMode -honorUserPathGroup -quiet
getAnalysisMode -quiet -honorClockDomains
set delaycal_use_default_delay_limit 101
set delaycal_default_net_delay 0
set delaycal_default_net_load 0
set delaycal_default_net_load_ignore_for_ilm 0
getAnalysisMode -clkSrcPath -quiet
getAnalysisMode -clockPropagation -quiet
getAnalysisMode -checkType -quiet
buildTimingGraph
getDelayCalMode -ignoreNetLoad -quiet
getDelayCalMode -ignoreNetLoad -quiet
setDelayCalMode -ignoreNetLoad true -quiet
get_global timing_enable_path_group_priority
get_global timing_constraint_enable_group_path_resetting
set_global timing_enable_path_group_priority false
set_global timing_constraint_enable_group_path_resetting false
getOptMode -allowPreCTSClkSrcPaths -quiet
set_global _is_ipo_interactive_path_groups 1
group_path -name in2reg_tmp.2925634 -from {0xa0 0xa3} -to 0xa4 -ignore_source_of_trigger_arc
getOptMode -allowPreCTSClkSrcPaths -quiet
set_global _is_ipo_interactive_path_groups 1
group_path -name in2out_tmp.2925634 -from {0xab 0xae} -to 0xaf -ignore_source_of_trigger_arc
set_global _is_ipo_interactive_path_groups 1
group_path -name reg2reg_tmp.2925634 -from 0xb5 -to 0xba
set_global _is_ipo_interactive_path_groups 1
group_path -name reg2out_tmp.2925634 -from 0xc5 -to 0xca
setPathGroupOptions reg2reg_tmp.2925634 -effortLevel high
reset_path_group -name reg2out_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name in2reg_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name in2out_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name reg2reg_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
setDelayCalMode -ignoreNetLoad false
set delaycal_use_default_delay_limit 1000
set delaycal_default_net_delay 1000ps
set delaycal_default_net_load 0.5pf
set delaycal_default_net_load_ignore_for_ilm 0
all_setup_analysis_views
getPlaceMode -place_global_exp_ignore_low_effort_path_groups -quiet
getPlaceMode -exp_slack_driven -quiet
getAnalysisMode -quiet -honorClockDomains
getPlaceMode -ignoreUnproperPowerInit -quiet
getPlaceMode -quiet -expSkipGP
setDelayCalMode -SIAware false
setDelayCalMode -engine feDc
createBasicPathGroups -quiet
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
getOptMode -quiet -leakagePowerEffort
getOptMode -quiet -viewOptEffort
getOptMode -quiet -multiModeEffort
getOptMode -quiet -powerEffort
getOptMode -user -powerEffort
getDesignMode -quiet -powerEffort
all_analysis_views -type leakage -quiet
all_analysis_views -type dynamic -quiet
getNanoRouteMode -grouteExpWithPowerDriven -quiet
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
psp::embedded_egr_init_
psp::embedded_egr_term_
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
psp::embedded_egr_init_
psp::embedded_egr_term_
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
psp::embedded_egr_init_
psp::embedded_egr_term_
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
setOptMode -viewOptMinNumberOfSetupViews 1
setOptMode -viewOptMaxNumberOfSetupViews 2
setOptMode -reset -viewOptMinNumberOfSetupViews
setOptMode -reset -viewOptMaxNumberOfSetupViews
reset_path_group
set_global _is_ipo_interactive_path_groups 0
scanReorder
setDelayCalMode -engine aae
setDelayCalMode -SIAware true
all_setup_analysis_views
getPlaceMode -exp_slack_driven -quiet
set_global timing_enable_path_group_priority $gpsPrivate::optSave_ctePGPriority
set_global timing_constraint_enable_group_path_resetting $gpsPrivate::optSave_ctePGResetting
getPlaceMode -quiet -tdgpAdjustNetWeightBySlack
get_ccopt_clock_trees *
getPlaceMode -exp_insert_guidance_clock_tree -quiet
getPlaceMode -exp_cluster_based_high_fanout_buffering -quiet
getPlaceMode -place_global_exp_incr_skp_preserve_mode_v2 -quiet
getPlaceMode -quiet -place_global_exp_netlist_balance_flow
getPlaceMode -quiet -timingEffort
getAnalysisMode -quiet -honorClockDomains
getPlaceMode -honorUserPathGroup -quiet
getAnalysisMode -quiet -honorClockDomains
set delaycal_use_default_delay_limit 101
set delaycal_default_net_delay 0
set delaycal_default_net_load 0
set delaycal_default_net_load_ignore_for_ilm 0
getAnalysisMode -clkSrcPath -quiet
getAnalysisMode -clockPropagation -quiet
getAnalysisMode -checkType -quiet
buildTimingGraph
getDelayCalMode -ignoreNetLoad -quiet
getDelayCalMode -ignoreNetLoad -quiet
setDelayCalMode -ignoreNetLoad true -quiet
get_global timing_enable_path_group_priority
get_global timing_constraint_enable_group_path_resetting
set_global timing_enable_path_group_priority false
set_global timing_constraint_enable_group_path_resetting false
getOptMode -allowPreCTSClkSrcPaths -quiet
set_global _is_ipo_interactive_path_groups 1
group_path -name in2reg_tmp.2925634 -from {0x104 0x107} -to 0x108 -ignore_source_of_trigger_arc
getOptMode -allowPreCTSClkSrcPaths -quiet
set_global _is_ipo_interactive_path_groups 1
group_path -name in2out_tmp.2925634 -from {0x10f 0x112} -to 0x113 -ignore_source_of_trigger_arc
set_global _is_ipo_interactive_path_groups 1
group_path -name reg2reg_tmp.2925634 -from 0x119 -to 0x11e
set_global _is_ipo_interactive_path_groups 1
group_path -name reg2out_tmp.2925634 -from 0x129 -to 0x12e
setPathGroupOptions reg2reg_tmp.2925634 -effortLevel high
reset_path_group -name reg2out_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name in2reg_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name in2out_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
reset_path_group -name reg2reg_tmp.2925634
set_global _is_ipo_interactive_path_groups 0
setDelayCalMode -ignoreNetLoad false
set delaycal_use_default_delay_limit 1000
set delaycal_default_net_delay 1000ps
set delaycal_default_net_load 0.5pf
set delaycal_default_net_load_ignore_for_ilm 0
all_setup_analysis_views
getPlaceMode -place_global_exp_ignore_low_effort_path_groups -quiet
getPlaceMode -exp_slack_driven -quiet
getPlaceMode -quiet -cong_repair_commit_clock_net_route_attr
getPlaceMode -enableDbSaveAreaPadding -quiet
getPlaceMode -quiet -wireLenOptEffort
setPlaceMode -reset -improveWithPsp
getPlaceMode -quiet -debugGlobalPlace
getPlaceMode -congRepair -quiet
getPlaceMode -fp -quiet
getPlaceMode -user -rplaceIncrNPClkGateAwareMode
getPlaceMode -user -congRepairMaxIter
getPlaceMode -quiet -congRepairPDClkGateMode4
setPlaceMode -rplaceIncrNPClkGateAwareMode 4
getPlaceMode -quiet -expCongRepairPDOneLoop
setPlaceMode -congRepairMaxIter 1
getPlaceMode -quickCTS -quiet
get_proto_model -type_match {flex_module flex_instgroup} -committed -name -tcl
getPlaceMode -congRepairForceTrialRoute -quiet
getPlaceMode -user -congRepairForceTrialRoute
setPlaceMode -congRepairForceTrialRoute true
::goMC::is_advanced_metrics_collection_running
congRepair
::goMC::is_advanced_metrics_collection_running
::goMC::is_advanced_metrics_collection_running
::goMC::is_advanced_metrics_collection_running
setPlaceMode -reset -congRepairForceTrialRoute
getPlaceMode -quiet -congRepairPDClkGateMode4
setPlaceMode -reset -rplaceIncrNPClkGateAwareMode
setPlaceMode -reset -congRepairMaxIter
getPlaceMode -congRepairCleanupPadding -quiet
getPlaceMode -quiet -wireLenOptEffort
all_setup_analysis_views
getPlaceMode -exp_slack_driven -quiet
set_global timing_enable_path_group_priority $gpsPrivate::optSave_ctePGPriority
set_global timing_constraint_enable_group_path_resetting $gpsPrivate::optSave_ctePGResetting
getPlaceMode -place_global_exp_incr_skp_preserve_mode_v2 -quiet
getPlaceMode -quiet -place_global_exp_netlist_balance_flow
getPlaceMode -quiet -timingEffort
getPlaceMode -tdgpDumpStageTiming -quiet
getPlaceMode -quiet -tdgpAdjustNetWeightBySlack
getPlaceMode -trimView -quiet
getOptMode -quiet -viewOptPolishing
getOptMode -quiet -fastViewOpt
getOptMode -quiet -expTvp
spInternalUse deleteViewOptManager
spInternalUse tdgp clearSkpData
setAnalysisMode -clkSrcPath true -clockPropagation sdcControl
getPlaceMode -exp_slack_driven -quiet
setExtractRCMode -engine preRoute
setPlaceMode -reset -relaxSoftBlockageMode
setPlaceMode -reset -ignoreScan
setPlaceMode -reset -repairPlace
getPlaceMode -quiet -NMPsuppressInfo
setvar spgSpeedupBuildVSM 0
getPlaceMode -macroPlaceMode -quiet
getPlaceMode -place_global_replace_QP -quiet
getPlaceMode -macroPlaceMode -quiet
getPlaceMode -exp_slack_driven -quiet
getPlaceMode -enableDistPlace -quiet
getPlaceMode -place_global_ignore_spare -quiet
getPlaceMode -tdgpMemFlow -quiet
setPlaceMode -reset -resetCombineRFLevel
getPlaceMode -enableDistPlace -quiet
getPlaceMode -quiet -clusterMode
getPlaceMode -quiet -place_global_exp_solve_unbalance_path
getPlaceMode -enableDistPlace -quiet
setPlaceMode -reset -expHiddenFastMode
getPlaceMode -tcg2Pass -quiet
getPlaceMode -quiet -wireLenOptEffort
getPlaceMode -fp -quiet
getPlaceMode -fastfp -quiet
getPlaceMode -doRPlace -quiet
getPlaceMode -RTCPlaceDesignFlow -quiet
getPlaceMode -quickCTS -quiet
set spgFlowInInitialPlace 0
getPlaceMode -user -maxRouteLayer
spInternalUse TDGP resetIgnoreNetLoad
getPlaceMode -place_global_exp_balance_pipeline -quiet
getDesignMode -quiet -flowEffort
report_message -end_cmd
um::create_snapshot -name final -auto min
um::pop_snapshot_stack
um::create_snapshot -name place_design
getPlaceMode -exp_slack_driven -quiet
place_opt_design -incremental -out_dir timingReports/place_opt_design.rpt
setDrawView place
addTieHiLo -prefix TIEHILO_ -cell {TIEHI TIELO}
set_power_analysis_mode -method static -corner delay_typ -create_binary_db true -write_static_currents true -honor_negative_energy true -ignore_control_signals true -analysis_view analysis_view_power
timeDesign -preCTS -outDir timingReports/preCTS
timeDesign -preCTS -hold -outDir timingReports/preCTS_hold
report_power -outfile powerReports/preCTS.rpt
reportDensityMap
checkPlace verifyReports/checkPlace.rpt
saveDesign checkpoints/et4351_place.enc
fit
setOptMode -usefulSkew true
setOptMode -usefulSkewCCOpt extreme
set_ccopt_property buffer_cells {         CLKBUFX2 CLKBUFX3 CLKBUFX4 CLKBUFX6 CLKBUFX8 CLKBUFX12 CLKBUFX16 CLKBUFX20}
set_ccopt_property inverter_cells {CLKINVX1 CLKINVX2 CLKINVX3 CLKINVX4 CLKINVX6 CLKINVX8 CLKINVX12 CLKINVX16 CLKINVX20}
set_ccopt_property delay_cells {DLY1X1 DLY1X4 DLY2X1 DLY2X4 DLY3X1 DLY3X4 DLY4X1 DLY4X4}
ccopt_design
setOptMode -fixCap true -fixTran true -fixFanoutLoad true
setOptMode -holdTargetSlack 0.1
optDesign -postCTS -hold -outDir timingReports/postCTSHold_hold
timeDesign -postCTS -outDir timingReports/postCTSHold
set_power_analysis_mode -method static -corner delay_typ -create_binary_db true -write_static_currents true -honor_negative_energy true -ignore_control_signals true -analysis_view analysis_view_power
report_power -outfile powerReports/postCTSHold.rpt
check_timing -verbose > verifyReports/cts_check_timing.rpt
report_ccopt_clock_trees -file clockReports/CT.rpt
report_ccopt_clock_trees -file clockReports/CT.rpt
saveDesign checkpoints/et4351_cts.enc
fit
setFillerMode -core {FILL1 FILL2 FILL4 FILL8 FILL16 FILL32 FILL64} -corePrefix FILLER_ -doDRC true -ecoMode true
addFiller
checkFiller
setNanoRouteMode -quiet -routeWithTimingDriven 1
setNanoRouteMode -quiet -routeTdrEffort 5
setNanoRouteMode -quiet -routeBottomRoutingLayer default
setNanoRouteMode -quiet -drouteEndIteration 30
setNanoRouteMode -quiet -routeWithTimingDriven true
setNanoRouteMode -quiet -routeWithSiDriven true
setNanoRouteMode -quiet -routeSiEffort high
setNanoRouteMode -drouteFixAntenna true
setNanoRouteMode -routeFixTopLayerAntenna false
setNanoRouteMode -routeInsertAntennaDiode true
setNanoRouteMode -routeAntennaCellName ANTENNA
setOptMode -postRouteDrvRecovery true -fixSISlew true -fixGlitch true
setExtractRCMode -engine postRoute -effortLevel high
routeDesign -globalDetail
timeDesign -postRoute -pathReports -slackReports -numPaths 50 -outDir timingReports/route
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 -outDir timingReports/route_hold
set_power_analysis_mode -method static -corner delay_typ -create_binary_db true -write_static_currents true -honor_negative_energy true -ignore_control_signals true -analysis_view analysis_view_power
report_power -clock_network all -hierarchy all -cell_type all -power_domain all -pg_net all -sort { total } -outfile powerReports/route.rpt
setOptMode -fixCap true -fixTran true -fixFanoutLoad true -postRouteHoldRecovery auto
optDesign -postRoute
timeDesign -postRoute -pathReports -slackReports -numPaths 50 -outDir timingReports/postRoute
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 -outDir timingReports/postRoute_hold
set_power_analysis_mode -method static -corner delay_typ -create_binary_db true -write_static_currents true -honor_negative_energy true -ignore_control_signals true -analysis_view analysis_view_power
report_power -clock_network all -hierarchy all -cell_type all -power_domain all -pg_net all -sort { total } -outfile powerReports/postRoute.rpt
setOptMode -fixCap true -fixTran true -fixFanoutLoad true -postRouteHoldRecovery auto
optDesign -postRoute -hold
optDesign -postRoute -drv
timeDesign -postRoute -pathReports -slackReports -numPaths 50 -outDir timingReports/postRouteHold
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 -outDir timingReports/postRouteHold_hold
report_noise -bumpy_waveform -output_file timingReports/bumpyWaves_postRouteHold.rpt
set_power_analysis_mode -method static -corner delay_typ -create_binary_db true -write_static_currents true -honor_negative_energy true -ignore_control_signals true -analysis_view analysis_view_power
report_power -clock_network all -hierarchy all -cell_type all -power_domain all -pg_net all -sort { total } -outfile powerReports/postRouteHold.rpt
reportRoute
deleteRouteBlk -all
saveDesign checkpoints/et4351_route.enc
fit
clearDrc
verifyConnectivity -type all -error 1000 -warning 50 -report verifyReports/verifyConnectivity.rpt
verify_drc -limit 1000 -report verifyReports/verify_drc.rpt
verifyProcessAntenna -error 1000 -reportfile verifyReports/verifyProcessAntenna.rpt
setSIMode -enable_glitch_report true
setSIMode -enable_delay_report true
report_power -hierarchy all -outfile finalReports/report_power.rpt
report_area -out_file finalReports/report_area.rpt
setExtractRCMode -engine postRoute -effortLevel high
setDelayCalMode -reset -siMode
timeDesign -postRoute -pathReports -slackReports -numPaths 50 -outDir finalReports/report_timing
timeDesign -postRoute -hold -pathReports -slackReports -numPaths 50 -outDir finalReports/report_timing_hold
timeDesign -postRoute -drvReports -numPaths 500 -outDir finalReports/report_DRV
report_noise -bumpy_waveform -output_file finalReports/bumpyWaves.rpt
saveNetlist outputs/et4351.phys.v
write_sdf -min_view analysis_view_hold -max_view analysis_view_setup -typ_view analysis_view_power -delimiter "/" outputs/${DESIGN}.phys.sdf
saveDesign checkpoints/et4351_done.enc
streamOut outputs/et4351.phys.gds
