#-------------- PROC                                             --------------#
  #------------ findFiles                                        ------------#
    # basedir - the directory to start looking in
    # pattern - A pattern, as defined by the glob command, that the files must match
    proc findFiles { basedir pattern } {
      # Fix the directory name, this ensures the directory name is in the
      # native format for the platform and contains a final directory seperator
      set basedir [string trimright [file join [file normalize $basedir] { }]]
      set fileList {}

      # Look in the current directory for matching files, -type {f r}
      # means ony readable normal files are looked at, -nocomplain stops
      # an error being thrown if the returned list is empty
      foreach fileName [glob -nocomplain -type {f r} -path $basedir $pattern] {
          lappend fileList $fileName
      }

      # Now look for any sub direcories in the current directory
      foreach dirName [glob -nocomplain -type {d  r} -path $basedir *] {
          # Recusively call the routine on the sub directory and append any
          # new files to the results
          set subDirList [findFiles $dirName $pattern]
          if { [llength $subDirList] > 0 } {
              foreach subDirFile $subDirList {
                  lappend fileList $subDirFile
              }
          }
      }
      return $fileList
    }
#______________________________________________________________________________#

#habr.com/ru/articles/308962
#Stage 1: Specify project settings
set TclPath [file dirname [file normalize [info script]]]
set NewLoc [string range $TclPath 0 [string last / $TclPath]-5]

set PartDev "xc7a100tcsg324-1"
set PrjDir [string range $TclPath 0 [string last / $NewLoc]]
set TopName [string range $NewLoc [string last / $NewLoc]+1 end]

puts "TclPath: $TclPath"
puts "NewLoc: $NewLoc"
puts "PrjDir: $PrjDir"
puts "TopName: $TopName"

#Stage 2: Auto-complete part for path
set PrjName $TopName.xpr
set SrcDir $PrjDir/$TopName/src
set VivNm "vivado"
set VivDir $PrjDir/$TopName/$VivNm

puts "PrjName: $PrjName"
puts "SrcDir: $SrcDir"
puts "VivDir: $VivDir"

cd $PrjDir/$TopName
pwd
if {[file exists $VivNm]==1} { file delete -force $VivNm }
file mkdir $VivNm
cd $VivDir


#Stage 3: Find sources
#This stage used instead of: add_files -scan_for_includes $SrcDir
set SrcVHD [findFiles $SrcDir "*.vhd"]
#set SrcVer [findFiles $SrcDir "*.v"]
#set SrcSVR  [findFiles $SrcDir "*.sv"]
set SrcSVRtl  [findFiles $SrcDir/rtl "*.sv"]
set SrcVerRtl [findFiles $SrcDir/rtl "*.v"]
set SrcSVTop  [findFiles $SrcDir/top "*.sv"]
set SrcVerTop [findFiles $SrcDir/top "*.v"]
set SrcNGC [findFiles $SrcDir "*.ngc"]; #ISE format IP
set SrcXCI [findFiles $SrcDir "*.xci"]; #Vivado IP format
set SrcXDC [findFiles $SrcDir "*.xdc"]; #Vivado Design Constraint

puts "SrcVHD: $SrcVHD"
#puts "SrcVer: $SrcVer"
#puts "SrcSV: $SrcSV"
puts "SrcNGC: $SrcNGC"
puts "SrcXCI: $SrcXCI"
puts "SrcXDC: $SrcXDC"

set SrcSim [findFiles $SrcDir/tb "*.sv"]
puts "Src SIM : $SrcSim"

# # Stage 4: Find all subdirs for IP cores (VHD, XCO, NGC, EDN)
# set PrjAll {}
# lappend PrjAll $DirIps $DirAdm 
# 
# set SrcSim {}
# for {set i 0} {$i < [llength $PrjAll]} {incr i} {
# 	set SrcXXX [findFiles [lindex $PrjAll $i] "*.sv"]
# 	put $SrcXXX
# 	foreach SrcAdd $SrcXXX {
# 		lappend SrcSim $SrcAdd
# 	}
# }
# 
# puts "SrcSV : $SrcSV"

create_project -force $TopName $VivDir -part $PartDev
set_property target_language Verilog [current_project]

#add_files -norecurse $SrcNGC

add_files -norecurse $SrcXCI
export_ip_user_files -of_objects [get_files $SrcXCI] -force -quiet

if {$SrcSVRtl ne ""} {add_files $SrcSVRtl}
if {$SrcVerRtl ne ""} {add_files $SrcVerRtl}
if {$SrcSVTop ne ""} {add_files $SrcSVTop}
if {$SrcVerTop ne ""} {add_files $SrcVerTop}
# add_files $SrcSVRtl $SrcVerRtl $SrcSVTop $SrcVerTop
add_files -fileset constrs_1 -norecurse $SrcXDC
add_files -fileset sim_1 -norecurse $SrcSim

set_property top $TopName [current_fileset]

start_gui
# Stage 7: Upgrade IP Cores (if needed)
# report_ip_status -name ip_status 
# set IpCores [get_ips]
# for {set i 0} {$i < [llength $IpCores]} {incr i} {
# 	set IpSingle [lindex $IpCores $i]
# 	
# 	set locked [get_property IS_LOCKED $IpSingle]
# 	set upgrade [get_property UPGRADE_VERSIONS $IpSingle]
# 	if {$upgrade != "" && $locked} {
# 		upgrade_ip $IpSingle
# 	}
# }
# report_ip_status -name ip_status
