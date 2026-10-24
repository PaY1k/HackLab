`timescale 1ns / 1ps

// Self-checking test for async_fifo: two unrelated clocks, random write/read
// enables, every word must come out exactly once and in order.
// Run:  iverilog -g2012 -o /tmp/f src/rtl/async_fifo.sv src/tb/tb_async_fifo.sv && vvp /tmp/f
module tb_async_fifo ();
  localparam DW = 16, AW = 4;            // small depth (16) to hit full/empty often
  localparam N  = 20000;

  bit            wr_clk, rd_clk, rst_n;
  logic          wr_en, rd_en, full, empty;
  logic [DW-1:0] wr_data, rd_data;
  logic [AW:0]   wr_level, rd_level;

  always #3.1 wr_clk = ~wr_clk;          // ~161 MHz
  always #10.2 rd_clk = ~rd_clk;         // ~49 MHz

  async_fifo #( .DATA_WIDTH(DW), .ADDR_WIDTH(AW) ) dut (
    .wr_clk(wr_clk), .wr_rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data), .full(full), .wr_level(wr_level),
    .rd_clk(rd_clk), .rd_rst_n(rst_n), .rd_en(rd_en), .rd_data(rd_data), .empty(empty), .rd_level(rd_level)
  );

  int written, read_cnt, errors, max_level, saw_full, saw_empty;
  int phase;                              // 0: writer faster, 1: reader faster

  // Writer
  always @( posedge wr_clk ) begin
    if ( !rst_n ) begin
      wr_en <= 0; wr_data <= 0; written <= 0;
    end else begin
      if ( wr_en && !full ) begin
        written <= written + 1;
        wr_data <= wr_data + 1;
      end
      wr_en <= ( written < N ) && ( phase == 0 ? ($urandom % 4 != 0) : ($urandom % 8 == 0) );
      if ( full ) saw_full <= saw_full + 1;
    end
  end

  // Reader
  always @( posedge rd_clk ) begin
    if ( !rst_n ) begin
      rd_en <= 0; read_cnt <= 0;
    end else begin
      if ( rd_en && !empty ) begin
        if ( rd_data !== read_cnt[DW-1:0] ) begin
          errors <= errors + 1;
          if ( errors < 10 ) $display("ERROR: got %0d, expected %0d", rd_data, read_cnt[DW-1:0]);
        end
        read_cnt <= read_cnt + 1;
      end
      rd_en <= ( phase == 0 ? ($urandom % 3 == 0) : 1'b1 );
      if ( empty ) saw_empty <= saw_empty + 1;
      if ( rd_level > max_level ) max_level <= rd_level;
    end
  end

  // Note: rd_en is a registered "intention"; the word is taken only when rd_en && !empty.
  initial begin
    phase = 0;
    rst_n = 0;
    #100 rst_n = 1;
    wait ( written >= N/2 );
    phase = 1;
    wait ( read_cnt >= N );
    #200;
    $display("written=%0d read=%0d errors=%0d max_level=%0d full_cycles=%0d empty_cycles=%0d",
             written, read_cnt, errors, max_level, saw_full, saw_empty);
    if ( errors == 0 && read_cnt == N && max_level <= (1 << AW) + 1 && saw_full > 0 && saw_empty > 0 )
      $display("PASS");
    else
      $display("FAIL");
    $finish;
  end

  initial begin
    #50_000_000 $display("FAIL: timeout (written=%0d read=%0d)", written, read_cnt);
    $finish;
  end
endmodule
