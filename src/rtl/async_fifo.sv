`timescale 1ns / 1ps

// Asynchronous FIFO for crossing between two clock domains
// (e.g. SD card / UART / CPU domain -> clk_audio).
//
// * Pointers cross domains in Gray code through 2-FF synchronizers
//   (classic Cummings design), so full/empty are always safe:
//   they may be reported late, never early.
// * Memory is written and read synchronously -> Vivado maps it to block RAM.
// * Read side is "first word fall through": rd_data is valid while !empty,
//   rd_en takes the word away. This is the same interface as fifo.sv,
//   so the module can replace it in front of pwm without changes.
// * wr_level / rd_level: how many words are inside, as seen from each side
//   (slightly stale because of synchronization). rd_level counts the word
//   held in rd_data too, so it can reach 2^ADDR_WIDTH + 1. Use them for
//   "almost empty -> read next SD block" logic.
module async_fifo #(
    parameter  DATA_WIDTH = 16,
    parameter  ADDR_WIDTH = 12                 // depth = 2^ADDR_WIDTH (4096)
)(
  //--------- Write side                         --------//
    input  wire                   wr_clk   ,
    input  wire                   wr_rst_n ,   // reset synchronized to wr_clk
    input  wire                   wr_en    ,
    input  wire  [DATA_WIDTH-1:0] wr_data  ,
    output logic                  full     ,
    output logic [ADDR_WIDTH  :0] wr_level ,
  //--------- Read side                          --------//
    input  wire                   rd_clk   ,
    input  wire                   rd_rst_n ,   // reset synchronized to rd_clk
    input  wire                   rd_en    ,
    output logic [DATA_WIDTH-1:0] rd_data  ,
    output wire                   empty    ,
    output logic [ADDR_WIDTH  :0] rd_level
);

  localparam DEPTH = 1 << ADDR_WIDTH;

  logic [DATA_WIDTH-1:0] mem [0:DEPTH-1];

  logic [ADDR_WIDTH:0]   wbin, wgray;   // write pointer (binary / Gray), wr_clk
  logic [ADDR_WIDTH:0]   rbin, rgray;   // read pointer  (binary / Gray), rd_clk

//------------- Helpers                                          -------------//
  function automatic [ADDR_WIDTH:0] bin2gray (input [ADDR_WIDTH:0] b);
    bin2gray = b ^ (b >> 1);
  endfunction

  function automatic [ADDR_WIDTH:0] gray2bin (input [ADDR_WIDTH:0] g);
    integer i;
    gray2bin[ADDR_WIDTH] = g[ADDR_WIDTH];
    for (i = ADDR_WIDTH-1; i >= 0; i = i - 1)
      gray2bin[i] = gray2bin[i+1] ^ g[i];
  endfunction
//____________________________________________________________________________//

//------------- Write domain                                     -------------//
  (* ASYNC_REG = "TRUE" *) logic [ADDR_WIDTH:0] rgray_w1, rgray_w2;  // read pointer in wr_clk

  wire                 do_write  = wr_en && !full;
  wire [ADDR_WIDTH:0]  wbin_next = wbin + do_write;
  wire [ADDR_WIDTH:0]  wgray_next = bin2gray(wbin_next);

  always_ff @( posedge wr_clk ) begin
    if ( do_write )
      mem[wbin[ADDR_WIDTH-1:0]] <= wr_data;
  end

  always_ff @( posedge wr_clk or negedge wr_rst_n ) begin
    if ( !wr_rst_n ) begin
      wbin     <= '0;
      wgray    <= '0;
      full     <= 1'b0;
      rgray_w1 <= '0;
      rgray_w2 <= '0;
      wr_level <= '0;
    end
    else begin
      wbin     <= wbin_next;
      wgray    <= wgray_next;
      rgray_w1 <= rgray;
      rgray_w2 <= rgray_w1;
      // full: next write pointer equals read pointer with the two MSBs inverted
      full     <= ( wgray_next == { ~rgray_w2[ADDR_WIDTH:ADDR_WIDTH-1], rgray_w2[ADDR_WIDTH-2:0] } );
      wr_level <= wbin_next - gray2bin(rgray_w2);
    end
  end
//____________________________________________________________________________//

//------------- Read domain                                      -------------//
  (* ASYNC_REG = "TRUE" *) logic [ADDR_WIDTH:0] wgray_r1, wgray_r2;  // write pointer in rd_clk
  logic                out_valid;   // rd_data holds a word

  wire mem_empty = ( rgray == wgray_r2 );                 // nothing left in memory
  wire mem_rd    = !mem_empty && ( !out_valid || rd_en ); // fetch next word into rd_data

  always_ff @( posedge rd_clk ) begin
    if ( mem_rd )
      rd_data <= mem[rbin[ADDR_WIDTH-1:0]];
  end

  always_ff @( posedge rd_clk or negedge rd_rst_n ) begin
    if ( !rd_rst_n ) begin
      rbin      <= '0;
      rgray     <= '0;
      out_valid <= 1'b0;
      wgray_r1  <= '0;
      wgray_r2  <= '0;
      rd_level  <= '0;
    end
    else begin
      wgray_r1 <= wgray;
      wgray_r2 <= wgray_r1;
      if ( mem_rd ) begin
        rbin  <= rbin + 1'b1;
        rgray <= bin2gray(rbin + 1'b1);
      end
      if ( mem_rd )
        out_valid <= 1'b1;
      else if ( rd_en )
        out_valid <= 1'b0;
      rd_level <= gray2bin(wgray_r2) - rbin + out_valid;
    end
  end

  assign empty = !out_valid;
//____________________________________________________________________________//

endmodule
