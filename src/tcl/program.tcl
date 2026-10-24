# make program: load audio_nexys_a7.bit into the FPGA over JTAG (USB cable)
set Bit [file normalize [lindex $argv 0]]
if {![file exists $Bit]} { puts "ERROR: $Bit not found, run make bit first"; exit 1 }
open_hw_manager
connect_hw_server
open_hw_target
set Dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $Dev
refresh_hw_device -update_hw_probes false $Dev
set_property PROGRAM.FILE $Bit $Dev
program_hw_devices $Dev
puts "programmed: $Bit"
close_hw_target
disconnect_hw_server
close_hw_manager
