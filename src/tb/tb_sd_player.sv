`timescale 1ns / 1ps

// Self-checking test: sd_card + sd_player against a model card with a FAT32 image.
//   python3 tools/make_sd_image.py /tmp/sd
//   iverilog -g2012 -o /tmp/sdp -s tb_sd_player src/rtl/sd_card.sv src/rtl/sd_player.sv \
//     src/rtl/async_fifo.sv src/tb/sd_card_model.sv src/tb/tb_sd_player.sv
//   cd /tmp && vvp -n /tmp/sdp        (sd.mem, sd_f0.txt, sd_f1.txt in the current folder)
module tb_sd_player;
  bit   clk;
  logic rst_n = 0;
  always #10.171 clk = ~clk;

  wire sd_reset, cs, sck, mosi, miso;
  wire card_ready, card_sdhc, rd_req, hold, rd_busy, rd_valid, rd_done, rd_err;
  wire [31:0] rd_lba;
  wire [7:0]  rd_data;
  wire [8:0]  rd_idx;

  sd_card #( .SLOW_HALF ( 8'd4 ), .FAST_HALF ( 8'd2 ), .WAIT_BITS ( 8 ) ) card (
    .clk ( clk ), .rst_n ( rst_n ),
    .sd_reset ( sd_reset ), .sd_cs ( cs ), .sd_sck ( sck ), .sd_mosi ( mosi ), .sd_miso ( miso ),
    .card_ready ( card_ready ), .card_sdhc ( card_sdhc ),
    .rd_req ( rd_req ), .rd_lba ( rd_lba ), .hold ( hold ), .rd_busy ( rd_busy ),
    .rd_data ( rd_data ), .rd_idx ( rd_idx ), .rd_valid ( rd_valid ), .rd_done ( rd_done ), .rd_err ( rd_err )
  );

  sd_card_model #( .IMG_FILE ( "sd.mem" ) ) model ( .cs ( cs ), .sck ( sck ), .mosi ( mosi ), .miso ( miso ) );

  logic        play_start = 0, play_stop = 0, file_sel = 0;
  wire         fifo_wr, fifo_flush, fifo_full, fifo_empty;
  wire [15:0]  fifo_data, fifo_q, step, len_bcd;
  wire [12:0]  wr_level, rd_level;
  logic        fifo_rd = 0;
  wire [1:0]   nfiles;
  logic        name_file = 0;
  logic [3:0]  name_idx = 0;
  wire [7:0]   name_char;
  wire [2:0]   status;
  wire         len_valid;
  wire [9:0]   progress;

  sd_player player (
    .clk ( clk ), .rst_n ( rst_n ),
    .card_ready ( card_ready ), .rd_req ( rd_req ), .rd_lba ( rd_lba ), .hold ( hold ), .rd_busy ( rd_busy ),
    .rd_data ( rd_data ), .rd_idx ( rd_idx ), .rd_valid ( rd_valid ), .rd_done ( rd_done ), .rd_err ( rd_err ),
    .play_start ( play_start ), .file_sel ( file_sel ), .play_stop ( play_stop ),
    .fifo_wr ( fifo_wr ), .fifo_data ( fifo_data ), .fifo_level ( wr_level ), .fifo_flush ( fifo_flush ),
    .nfiles ( nfiles ), .name_file ( name_file ), .name_idx ( name_idx ), .name_char ( name_char ),
    .status ( status ), .step ( step ), .len_bcd ( len_bcd ), .len_valid ( len_valid ), .progress ( progress )
  );

  async_fifo #( .DATA_WIDTH ( 16 ), .ADDR_WIDTH ( 12 ) ) fifo (
    .wr_clk ( clk ), .wr_rst_n ( rst_n && !fifo_flush ), .wr_en ( fifo_wr ), .wr_data ( fifo_data ),
    .full ( fifo_full ), .wr_level ( wr_level ),
    .rd_clk ( clk ), .rd_rst_n ( rst_n && !fifo_flush ), .rd_en ( fifo_rd ), .rd_data ( fifo_q ),
    .empty ( fifo_empty ), .rd_level ( rd_level )
  );

  int    errors = 0;
  string name;

  // read n samples from the FIFO and compare them with a file
  task automatic check_file (input string fname, input int n);
    int fd, exp, got;
    fd  = $fopen( fname, "r" );
    got = 0;
    while ( got < n ) begin
      @( negedge clk );
      fifo_rd = 0;
      if ( !fifo_empty ) begin
        void'( $fscanf( fd, "%d", exp ) );
        if ( $signed( fifo_q ) !== 16'( exp ) ) begin
          errors++;
          if ( errors < 6 ) $display( "%s sample %0d: got %0d expected %0d", fname, got, $signed( fifo_q ), exp );
        end
        fifo_rd = 1;
        got++;
      end
    end
    @( negedge clk ) fifo_rd = 0;
    $fclose( fd );
  endtask

  task automatic read_name (input logic f);
    name = "";
    name_file = f;
    for ( int i = 0; i < 12; i++ ) begin
      name_idx = 4'( i ); #1;
      if ( name_char != 8'h20 ) name = { name, string'( name_char ) };
    end
  endtask

  initial begin
    repeat ( 10 ) @( posedge clk );
    rst_n = 1;
    wait ( status == 3'd2 );                                   // READY
    read_name( 0 ); $display( "files: %0d, sdhc=%b, file0 = %s", nfiles, card_sdhc, name );
    if ( nfiles != 2 || name != "TONE1.WAV" ) errors++;
    read_name( 1 ); $display( "file1 = %s", name );
    if ( name != "CHORD.WAV" ) errors++;

    @( negedge clk ) begin file_sel = 0; play_start = 1; end
    @( negedge clk ) play_start = 0;
    check_file( "sd_f0.txt", 57600 );
    $display( "TONE1: step=%0d len=%h valid=%b progress=%0d status=%0d reads=%0d",
              step, len_bcd, len_valid, progress, status, model.reads );
    if ( step < 16'd65520 || len_bcd != 16'h0001 || !len_valid || progress < 900 ) errors++;

    @( negedge clk ) begin file_sel = 1; play_start = 1; end
    @( negedge clk ) play_start = 0;
    // samples of the old file still in flight are flushed by the player
    wait ( fifo_flush ); wait ( !fifo_flush );
    check_file( "sd_f1.txt", 2205 );
    $display( "CHORD: step=%0d len=%h status=%0d", step, len_bcd, status );
    if ( step < 16'd30090 || step > 16'd30110 ) errors++;

    if ( errors == 0 ) $display( "PASS" );
    else               $display( "FAIL (errors=%0d)", errors );
    $finish;
  end

  initial begin
    #400_000_000;
    $display( "FAIL: timeout, status=%0d", status );
    $finish;
  end
endmodule
