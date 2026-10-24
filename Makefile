.PHONY: deploy clear clean

deploy:
	vivado -mode tcl -source ./src/tcl/deploy.tcl

clear:
	@rm -rf ./vivado *.jou *.log
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