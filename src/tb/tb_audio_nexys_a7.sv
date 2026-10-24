module tb_audio_nexys_a7 ();
  bit               CLK100MHZ;
  bit     [15:0]    SW;
  //
  logic             DP, CG, CF, CE, CD, CC, CB, CA;
  logic   [ 7:0]    AN;
  //
  bit               BTNC, BTNU, BTNL, BTNR, BTND, CPU_RESETN;
  //
  logic             AUD_PWM;
  logic             AUD_SD;
  
  //----------- CLK -//
    always #2
      CLK100MHZ = ~CLK100MHZ;

  //----------- Main Initial -//
    initial begin
      CPU_RESETN = 1'b1;
      #10
      CPU_RESETN = 1'b0;
      //To pass reset trough button deboucer we need 2^16 * (1/100MHz) > 65536 * 10ns = 656us
      #656000
      CPU_RESETN = 1'b1;
    end

  //-----------
    audio_nexys_a7 dut (
      .*
    );

endmodule