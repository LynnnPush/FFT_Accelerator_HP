################################################################################
#
# Innovus setup file
# Created by Genus(TM) Synthesis Solution 21.10-p002_1
#   on 03/27/2026 15:39:09
#
################################################################################
#
# Genus(TM) Synthesis Solution setup file
# This file can only be run in Innovus Legacy UI mode.
#
################################################################################


# Version Check
###########################################################

      namespace eval ::genus_innovus_version_check { 
        set minimum_version 21
        set maximum_version 22
        regexp {\d\d} [get_db program_version] this_version
        Puts "Checking Innovus major version against Genus expectations ..."
        if { $this_version < $minimum_version || $this_version > $maximum_version } {
          error "**ERROR: this operation requires Innovus major version to be between '$minimum_version' and '$maximum_version'."
        }
      }
    
set _t0 [clock seconds]
Puts [format  {%%%s Begin Genus to Innovus Setup (%s)} \# [clock format $_t0 -format {%m/%d %H:%M:%S}]]
set allowMultiplePortPinWithoutMustjoin 1
set mustjoinallports_is_one_pin true
setLibraryUnit -cap 1pf -time 1ns


# Design Import
################################################################################
source -quiet /eda/cadence/2021-22/RHELx86/GENUS_21.10.000/tools.lnx86/lib/cdn/rc/edi/innovus_procs.tcl
## Reading FlowKit settings file
source genus_invs_des/genus.flowkit_settings.tcl

source genus_invs_des/genus.globals
init_design

# Reading metrics file
################################################################################
read_metric -id current genus_invs_des/genus.metrics.json
## Reading Innovus Mode attributes file
pqos_eval {rcp::read_taf genus_invs_des/genus.mode_attributes.taf.gz}


# Mode Setup
################################################################################
source genus_invs_des/genus.mode
setMaxRouteLayer 8


# MSV Setup
################################################################################

# Source cell padding from Genus
################################################################################
source -quiet genus_invs_des/genus.cell_pad.tcl 


# Reading write_name_mapping file
################################################################################

      if { [is_attribute -obj_type port original_name] &&
           [is_attribute -obj_type pin original_name] &&
           [is_attribute -obj_type pin is_phase_inverted]} {
        source genus_invs_des/genus.wnm_attrs.tcl
      }
    

# Reading NDR file
source genus_invs_des/genus.ndr.tcl

# Reading minimum routing layer data file
################################################################################
gpsPrivate::readMinLayerCstr -file genus_invs_des/genus.min_layer 

eval {set edi_pe::pegConsiderMacroLayersUnblocked 1}
eval {set edi_pe::pegPreRouteWireWidthBasedDensityCalModel 1}

      set _t1 [clock seconds]
      Puts [format  {%%%s End Genus to Innovus Setup (%s, real=%s)} \# [clock format $_t1 -format {%m/%d %H:%M:%S}] [clock format [expr {28800 + $_t1 - $_t0}] -format {%H:%M:%S}]]
    


# The following is partial list of suggested prototyping commands.
# These commands are provided for reference only.
# Please consult the Innovus documentation for more information.
#   Placement...
#     ecoPlace                     ;# legalizes placement including placing any cells that may not be placed
#     - or -
#     placeDesign -incremental     ;# adjusts existing placement
#     - or -
#     placeDesign                  ;# performs detailed placement discarding any existing placement
#   Optimization & Timing...
#     optDesign -preCTS            ;# performs trial route and optimization
#     timeDesign -preCTS           ;# performs timing analysis

