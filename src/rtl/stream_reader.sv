// Takes samples of a stream (SD card, PC) out of its FIFO at the stream's own
// sample rate. Output runs at the PWM rate (48 kHz): a 16-bit phase counter
// adds `step` every tick and takes the next sample on overflow, so a 44.1 kHz
// file plays at the right pitch (nearest-sample resampling).
//   step = 65536 * f_file / 48006.5   (65527 for 48 kHz, 60204 for 44.1 kHz)
// If the FIFO runs dry the output goes to silence and `underrun` pulses.
module stream_reader (
    input  wire               clk        ,
    input  wire               rst_n      ,
    input  wire               tick       ,
    input  wire               run        ,
    input  wire               flush      ,   // forget the last sample (track change)
    input  wire        [15:0] step       ,
    input  wire               fifo_empty ,
    input  wire        [15:0] fifo_data  ,   // signed sample
    output logic              fifo_rd    ,
    output logic signed [15:0] sample    ,
    output logic              underrun
);

  logic [15:0] phase;
  wire  [16:0] phase_next = { 1'b0, phase } + { 1'b0, step };

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      phase    <= '0;
      sample   <= '0;
      fifo_rd  <= 1'b0;
      underrun <= 1'b0;
    end
    else begin
      fifo_rd  <= 1'b0;
      underrun <= 1'b0;
      if ( flush ) begin
        phase  <= '0;
        sample <= '0;
      end
      else if ( tick && run ) begin
        phase <= phase_next[15:0];
        if ( phase_next[16] ) begin
          if ( !fifo_empty ) begin
            sample  <= fifo_data;
            fifo_rd <= 1'b1;
          end
          else begin
            sample   <= '0;
            underrun <= 1'b1;
          end
        end
      end
    end
  end

endmodule
