# make flash: write audio_nexys_a7.bit into the on-board QSPI flash (S25FL128S).
# With jumper JP1 on QSPI the board then loads the player by itself at every
# power-up, so the USB cable can go to another computer (e.g. the Windows PC
# that sends MIDI over UART) without losing the design.
set Bit [file normalize [lindex $argv 0]]
if {![file exists $Bit]} { puts "ERROR: $Bit not found, run make bit first"; exit 1 }
set Mcs [file rootname $Bit].mcs
write_cfgmem -force -format mcs -size 16 -interface SPIx4 -loadbit "up 0x00000000 $Bit" -file $Mcs

open_hw_manager
connect_hw_server
open_hw_target
set Dev [lindex [get_hw_devices xc7a100t*] 0]
current_hw_device $Dev
refresh_hw_device -update_hw_probes false $Dev

create_hw_cfgmem -hw_device $Dev -mem_dev [lindex [get_cfgmem_parts {s25fl128sxxxxxx0-spi-x1_x2_x4}] 0]
set Cfg [get_property PROGRAM.HW_CFGMEM $Dev]
set_property PROGRAM.ADDRESS_RANGE          {use_file} $Cfg
set_property PROGRAM.FILES                  [list $Mcs] $Cfg
set_property PROGRAM.PRM_FILE               {} $Cfg
set_property PROGRAM.UNUSED_PIN_TERMINATION {pull-none} $Cfg
set_property PROGRAM.BLANK_CHECK            0 $Cfg
set_property PROGRAM.ERASE                  1 $Cfg
set_property PROGRAM.CFG_PROGRAM            1 $Cfg
set_property PROGRAM.VERIFY                 1 $Cfg
set_property PROGRAM.CHECKSUM               0 $Cfg

# a helper design is loaded into the FPGA to reach the flash, then the flash is written
create_hw_bitstream -hw_device $Dev [get_property PROGRAM.HW_CFGMEM_BITFILE $Dev]
program_hw_devices $Dev
refresh_hw_device $Dev
program_hw_cfgmem -hw_cfgmem $Cfg

# start the player from flash right away
boot_hw_device $Dev
puts "flash written: $Mcs (JP1 must be on QSPI to boot from it)"
close_hw_target
disconnect_hw_server
close_hw_manager
