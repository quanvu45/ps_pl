# =============================================================================
# msg_shared_mem_hw.tcl
#
# Platform Designer (Qsys) component description for Message Shared Memory.
# Compatible with Quartus 24.1 / Qsys 16.0+.
# =============================================================================

package require -exact qsys 16.0

# ------------------------------------------------------------------------------
# Module Properties
# ------------------------------------------------------------------------------
set_module_property DESCRIPTION "Shared Memory (1KB dual-port) for PS-PL message communication"
set_module_property NAME msg_shared_mem
set_module_property VERSION 1.0
set_module_property INTERNAL false
set_module_property OPAQUE_ADDRESS_MAP true
set_module_property AUTHOR ""
set_module_property DISPLAY_NAME "Message Shared Memory"
set_module_property INSTANTIATE_IN_SYSTEM_MODULE true
set_module_property EDITABLE true
set_module_property REPORT_TO_TALKBACK false
set_module_property ALLOW_GREYBOX_GENERATION false
set_module_property REPORT_HIERARCHY false

# ------------------------------------------------------------------------------
# File Sets
# ------------------------------------------------------------------------------
add_fileset QUARTUS_SYNTH QUARTUS_SYNTH "" ""
set_fileset_property QUARTUS_SYNTH TOP_LEVEL msg_shared_mem
add_fileset_file msg_shared_mem.v VERILOG PATH msg_shared_mem.v TOP_LEVEL_FILE

add_fileset SIM_VERILOG SIM_VERILOG "" ""
set_fileset_property SIM_VERILOG TOP_LEVEL msg_shared_mem
add_fileset_file msg_shared_mem.v VERILOG PATH msg_shared_mem.v TOP_LEVEL_FILE

# ------------------------------------------------------------------------------
# Clock Interface
# ------------------------------------------------------------------------------
add_interface clock clock end
set_interface_property clock clockRate 0
add_interface_port clock clk clk Input 1

# ------------------------------------------------------------------------------
# Reset Interface
# ------------------------------------------------------------------------------
add_interface reset reset end
set_interface_property reset associatedClock clock
set_interface_property reset synchronousEdges DEASSERT
add_interface_port reset reset reset Input 1

# ------------------------------------------------------------------------------
# Avalon-MM Slave Interface (HPS side)
#   256 words × 4 bytes = 1024 bytes address span
#   Read latency = 1 clock cycle
# ------------------------------------------------------------------------------
add_interface avalon_slave avalon end
set_interface_property avalon_slave addressUnits WORDS
set_interface_property avalon_slave associatedClock clock
set_interface_property avalon_slave associatedReset reset
set_interface_property avalon_slave bitsPerSymbol 8
set_interface_property avalon_slave burstOnBurstBoundariesOnly false
set_interface_property avalon_slave burstcountUnits WORDS
set_interface_property avalon_slave explicitAddressSpan 0
set_interface_property avalon_slave holdTime 0
set_interface_property avalon_slave linewrapBursts false
set_interface_property avalon_slave maximumPendingReadTransactions 0
set_interface_property avalon_slave readLatency 1
set_interface_property avalon_slave readWaitTime 0
set_interface_property avalon_slave setupTime 0
set_interface_property avalon_slave timingUnits Cycles
set_interface_property avalon_slave writeWaitTime 0

add_interface_port avalon_slave avl_address  address   Input  8
add_interface_port avalon_slave avl_read     read      Input  1
add_interface_port avalon_slave avl_write    write     Input  1
add_interface_port avalon_slave avl_writedata  writedata  Input  32
add_interface_port avalon_slave avl_readdata   readdata   Output 32

# ------------------------------------------------------------------------------
# FPGA-side Conduit Interface (dual-port access for custom FPGA logic)
#
# Exported port names in soc_system will follow the pattern:
#   {instance_name}_fpga_mem_{role}
# For example, if the instance is "msg_mem_0":
#   msg_mem_0_fpga_mem_address
#   msg_mem_0_fpga_mem_read
#   msg_mem_0_fpga_mem_write
#   msg_mem_0_fpga_mem_writedata
#   msg_mem_0_fpga_mem_readdata
# ------------------------------------------------------------------------------
add_interface fpga_mem conduit end
set_interface_property fpga_mem associatedClock clock
set_interface_property fpga_mem associatedReset reset

add_interface_port fpga_mem coe_address   address   Input  8
add_interface_port fpga_mem coe_read      read      Input  1
add_interface_port fpga_mem coe_write     write     Input  1
add_interface_port fpga_mem coe_writedata writedata Input  32
add_interface_port fpga_mem coe_readdata  readdata  Output 32
