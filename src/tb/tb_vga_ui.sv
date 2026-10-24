`timescale 1ns / 1ps

// Renders frames of vga_ui into a text file, tools/frame_to_png.py turns it into PNG.
// No Vivado needed:
//   iverilog -g2012 -I src/rtl -o /tmp/ui -s tb_vga_ui \
//     src/rtl/display_ctrl.sv src/rtl/sber_logo_rom.sv src/rtl/vga_ui.sv src/tb/tb_vga_ui.sv
//   vvp /tmp/ui +FRAMES=2 +OUT=/tmp/frame.txt   (run from src/rtl so $readmemh finds the .mem files)
//   python3 tools/frame_to_png.py /tmp/frame.txt frame.png
module tb_vga_ui #(
    parameter SPLASH_LOG2 = 8,              // 8 = no splash; 21 = splash in the first frame
    parameter PLAY        = 1,
    parameter MENU        = 0
);
  bit         clk;
  logic       rst_n;
  always #12.5 clk = ~clk;                  // 40 MHz

  wire [10:0] h;  wire [9:0] v;
  wire        hs, vs, de;

  display_ctrl display_ctrl (
    .pixel_clk ( clk ), .rst_n ( rst_n ),
    .h_sync ( hs ), .v_sync ( vs ), .disp_enbl ( de ), .h_coord ( h ), .v_coord ( v )
  );

  // fake oscilloscope: a sine + a bit of the 3rd harmonic
  wire  [8:0] scope_addr;
  logic [7:0] scope_data;
  always @( posedge clk )
    scope_data <= 8'( $rtoi( 128.0 + 90.0 * $sin( scope_addr * 6.2832 * 3.0 / 512.0 )
                                   + 20.0 * $sin( scope_addr * 6.2832 * 9.0 / 512.0 ) ) );

  wire [3:0]  r, g, b;
  wire        ohs, ovs, ode, fs;
  wire [10:0] oh; wire [9:0] ov;

  vga_ui #( .SPLASH_LOG2 ( SPLASH_LOG2 ) ) ui (
    .pixel_clk ( clk ), .rst_n ( rst_n ),
    .h_coord ( h ), .v_coord ( v ), .h_sync ( hs ), .v_sync ( vs ), .disp_enbl ( de ),
    .play ( PLAY[0] ), .volume ( 4'd11 ),
    .time_bcd ( 16'h0123 ), .len_bcd ( 16'h0345 ), .len_valid ( 1'b1 ), .progress ( 10'd400 ),
    .track_idx ( 3'd0 ), .key_mask ( 36'd1 << ( 12 + 9 ) ),
    .menu_mode ( MENU[0] ), .menu_sel ( 3'd1 ), .dancing ( PLAY[0] ),
    .scope_addr ( scope_addr ), .scope_data ( scope_data ), .frame_start ( fs ),
    .txt_we ( 1'b0 ), .txt_addr ( 13'd0 ), .txt_data ( 12'd0 ),
    .red ( r ), .green ( g ), .blue ( b ),
    .out_hs ( ohs ), .out_vs ( ovs ), .out_de ( ode ), .out_h ( oh ), .out_v ( ov )
  );

  int    fd, frames, frame;
  string out;

  initial begin
    if ( !$value$plusargs( "FRAMES=%d", frames ) ) frames = 2;
    if ( !$value$plusargs( "OUT=%s", out ) ) out = "frame.txt";
    rst_n = 0;
    repeat ( 4 ) @( posedge clk );
    rst_n = 1;
    // FRAMES-1 vertical blankings first: they fill the dynamic text cells
    for ( frame = 1; frame < frames; frame++ )
      @( posedge fs );
    @( posedge clk );
    while ( !( ode && oh == 0 && ov == 0 ) )
      @( posedge clk );
    fd = $fopen( out, "w" );
    while ( !( ov == 599 && oh == 799 ) ) begin
      if ( ode && oh < 800 && ov < 600 )
        $fwrite( fd, "%0d %0d %h%h%h\n", oh, ov, r, g, b );
      @( posedge clk );
    end
    $fwrite( fd, "%0d %0d %h%h%h\n", oh, ov, r, g, b );
    $fclose( fd );
    $display( "frame written to %s", out );
    $finish;
  end
endmodule
