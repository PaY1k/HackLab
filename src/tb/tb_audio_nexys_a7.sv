`timescale 1ns / 1ps

module tb_audio_nexys_a7 ();
  bit               CLK100MHZ;
  bit     [15:0]    SW;
  //
  logic             DP, CG, CF, CE, CD, CC, CB, CA;
  logic   [ 7:0]    AN;
  logic   [ 3:0]    LED;
  //
  bit               BTNC, BTNU, BTNL, BTNR, BTND, CPU_RESETN;
  //
  logic             AUD_PWM;
  logic             AUD_SD;
  //
  logic   [ 3:0]    VGA_R, VGA_G, VGA_B;
  logic             VGA_HS, VGA_VS;
  //
  logic             UART_TXD_IN = 1'b1;   // PC idle
  logic             UART_RXD_OUT;
  logic             SD_RESET, SD_SCK, SD_CMD, SD_DAT3;
  logic             SD_DAT0 = 1'b1;       // no card

  //----------- CLK: 100 MHz (period 10 ns) -//
    always #5
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
