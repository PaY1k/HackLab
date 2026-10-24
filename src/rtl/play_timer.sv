// Playback time counter in BCD (mm:ss), ready for the screen.
// Counts sample ticks while run = 1; every TICKS_PER_SEC ticks adds a second.
// clear restarts from 00:00 (e.g. on track change). Wraps after 99:59.
module play_timer #(
    parameter  TICKS_PER_SEC = 17'd48006       // 49.15865 MHz / 1024
)(
    input  wire          clk         ,
    input  wire          rst_n       ,
    input  wire          sample_tick ,
    input  wire          run         ,
    input  wire          clear       ,
    output logic [15:0]  time_bcd          // {min_tens, min_ones, sec_tens, sec_ones}
);

  logic [16:0] tick_cnt;
  wire  [3:0]  m10 = time_bcd[15:12], m1 = time_bcd[11:8], s10 = time_bcd[7:4], s1 = time_bcd[3:0];

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      tick_cnt <= '0;
      time_bcd <= '0;
    end
    else if ( clear ) begin
      tick_cnt <= '0;
      time_bcd <= '0;
    end
    else if ( run && sample_tick ) begin
      if ( tick_cnt == TICKS_PER_SEC - 1 ) begin
        tick_cnt <= '0;
        if ( s1 != 4'd9 )
          time_bcd[3:0] <= s1 + 1'b1;
        else begin
          time_bcd[3:0] <= 4'd0;
          if ( s10 != 4'd5 )
            time_bcd[7:4] <= s10 + 1'b1;
          else begin
            time_bcd[7:4] <= 4'd0;
            if ( m1 != 4'd9 )
              time_bcd[11:8] <= m1 + 1'b1;
            else begin
              time_bcd[11:8]  <= 4'd0;
              time_bcd[15:12] <= ( m10 == 4'd9 ) ? 4'd0 : m10 + 1'b1;
            end
          end
        end
      end
      else
        tick_cnt <= tick_cnt + 1'b1;
    end
  end

endmodule
