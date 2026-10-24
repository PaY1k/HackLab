# make bit: create the project, synthesize, implement, write the bitstream,
# then reports in ./reports and the bitstream as ./audio_nexys_a7.bit
set NO_GUI 1
set ScriptDir [file dirname [file normalize [info script]]]
set RepoDir   [file normalize [file join $ScriptDir .. ..]]
source [file join $ScriptDir deploy.tcl]

set Jobs 4
launch_runs synth_1 -jobs $Jobs
wait_on_run synth_1
if {[get_property PROGRESS [get_runs synth_1]] != "100%"} {
  puts "ERROR: synthesis failed, see [get_property DIRECTORY [get_runs synth_1]]/runme.log"
  exit 1
}

launch_runs impl_1 -to_step write_bitstream -jobs $Jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] != "100%"} {
  puts "ERROR: implementation failed, see [get_property DIRECTORY [get_runs impl_1]]/runme.log"
  exit 1
}

open_run impl_1
set Rep [file join $RepoDir reports]
file mkdir $Rep
report_timing_summary -max_paths 20 -file [file join $Rep timing.txt]
report_utilization                  -file [file join $Rep utilization.txt]
report_cdc -details                 -file [file join $Rep cdc.txt]
report_methodology                  -file [file join $Rep methodology.txt]

set Bit [file join [get_property DIRECTORY [get_runs impl_1]] audio_nexys_a7.bit]
file copy -force $Bit [file join $RepoDir audio_nexys_a7.bit]

set Wns [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -setup]]
set Whs [get_property SLACK [get_timing_paths -max_paths 1 -nworst 1 -hold]]
puts ""
puts "================================================================"
puts " bitstream : audio_nexys_a7.bit"
puts " reports   : reports/timing.txt utilization.txt cdc.txt"
puts " setup WNS : $Wns ns   hold WHS : $Whs ns"
if {$Wns < 0 || $Whs < 0} {
  puts " TIMING FAILED: see reports/timing.txt"
} else {
  puts " TIMING OK"
}
puts "================================================================"
