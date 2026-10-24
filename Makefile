.PHONY: deploy bit program flash test test-sd test-midi tables clear clean

# Vivado project with GUI
deploy:
	vivado -mode tcl -source ./src/tcl/deploy.tcl

# bitstream without GUI: ./audio_nexys_a7.bit + ./reports (timing, utilization, CDC)
bit:
	vivado -mode batch -nojournal -log reports_vivado.log -source ./src/tcl/build.tcl

# load the bitstream into the board over USB (JTAG)
program:
	vivado -mode batch -nojournal -nolog -source ./src/tcl/program.tcl -tclargs audio_nexys_a7.bit

# write the bitstream into the board's flash: the player starts by itself at power-up
# (jumper JP1 on QSPI), so the USB cable can be moved to another PC
flash:
	vivado -mode batch -nojournal -nolog -source ./src/tcl/flash.tcl -tclargs audio_nexys_a7.bit

# regenerate tables, font and screen text (src/rtl/mem)
tables:
	python3 tools/gen_tables.py
	python3 tools/gen_screen.py

# self-checking tests in Icarus Verilog (no Vivado needed), ~2 minutes
B = build
test:
	@mkdir -p $(B)
	iverilog -g2012 -o $(B)/fifo src/rtl/async_fifo.sv src/tb/tb_async_fifo.sv && vvp -n $(B)/fifo | grep -E "PASS|FAIL"
	iverilog -g2012 -o $(B)/mt -s tb_midi_text src/rtl/uart.sv src/rtl/midi_text_rx.sv src/tb/tb_midi_text.sv && vvp -n $(B)/mt | grep -E "PASS|FAIL"
	iverilog -g2012 -o $(B)/pl -s tb_pc_link src/rtl/uart.sv src/rtl/pc_link.sv src/rtl/async_fifo.sv src/tb/tb_pc_link.sv && vvp -n $(B)/pl | grep -E "PASS|FAIL"
	iverilog -g2012 -o $(B)/ac -s tb_audio_core src/rtl/poly_synth.sv src/rtl/melody_player.sv src/rtl/stream_reader.sv src/rtl/audio_core.sv src/rtl/player_ctrl.sv src/tb/tb_audio_core.sv
	cd src/rtl/mem && vvp -n ../../../$(B)/ac +OUT=../../../$(B)/ac.txt
	python3 tools/samples_to_wav.py $(B)/ac.txt $(B)/audio_core.wav 200

# text MIDI commands over UART
test-midi:
	@mkdir -p $(B)
	iverilog -g2012 -o $(B)/mt -s tb_midi_text src/rtl/uart.sv src/rtl/midi_text_rx.sv src/tb/tb_midi_text.sv && vvp -n $(B)/mt

# SD card player against a model card (~4 minutes)
test-sd:
	@mkdir -p $(B)
	python3 tools/make_sd_image.py $(B)/sd
	iverilog -g2012 -o $(B)/sdp -s tb_sd_player src/rtl/sd_card.sv src/rtl/sd_player.sv src/rtl/async_fifo.sv src/tb/sd_card_model.sv src/tb/tb_sd_player.sv
	cd $(B) && vvp -n sdp | grep -E "files|file1|TONE1|CHORD|PASS|FAIL"

clear:
	@rm -rf ./vivado ./build ./reports *.jou *.log
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_clk_wiz.v
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0.v
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0.veo
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0.xml
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_board.xdc
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_ooc.xdc
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_sim_netlist.v
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_sim_netlist.vhdl
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_stub.v
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0_stub.vhdl
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0.dcp
	@rm -rf src/ipcores/clk_wiz_0/clk_wiz_0.xdc
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_7s_mmcm.vh
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_7s_pll.vh
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_us_mmcm.vh
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_us_pll.vh
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_us_plus_mmcm.vh
	@rm -rf src/ipcores/clk_wiz_0/mmcm_pll_drp_func_us_plus_pll.vh
	@rm -rf src/ipcores/dist_mem_gen_0/doc/
	@rm -rf src/ipcores/dist_mem_gen_0/hdl/
	@rm -rf src/ipcores/dist_mem_gen_0/sim/
	@rm -rf src/ipcores/dist_mem_gen_0/simulation/
	@rm -rf src/ipcores/dist_mem_gen_0/synth/
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0_ooc.xdc
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0_sim_netlist.v
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0_sim_netlist.vhdl
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0_stub.v
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0_stub.vhdl
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0.dcp
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0.mif
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0.veo
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0.vho
	@rm -rf src/ipcores/dist_mem_gen_0/dist_mem_gen_0.xml

clean:
	rm -rf *.jou *.log