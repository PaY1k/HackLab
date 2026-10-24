// Melody sequencer: reads {midi note, duration} words from block RAM
// (melodies.mem, made by tools/gen_tables.py) and drives a synth voice.
//
// Duration unit is 5 ms = UNIT_TICKS sample ticks. The gate goes low 15 ms
// before the end of each note, so repeated notes are heard separately.
// At the end word (0) the melody starts again.
module melody_player #(
    parameter  MEL_FILE   = "melodies.mem",
    parameter  INFO_FILE  = "melody_info.mem",
    parameter  UNIT_TICKS = 8'd240               // 5 ms at 48 kHz
)(
    input  wire          clk       ,
    input  wire          rst_n     ,
    input  wire          tick      ,
    input  wire          sel       ,   // melody number 0 / 1
    input  wire          restart   ,   // pulse: start from the beginning
    input  wire          run       ,   // advance (playing and selected)
    output logic [ 6:0]  note      ,   // 0 = rest
    output logic         gate      ,
    output logic [15:0]  len_bcd   ,   // melody length mm:ss
    output logic [ 9:0]  progress      // 0..1023
);

  logic [15:0] mel_mem  [0:1023];
  logic [15:0] info_mem [0:7];
  initial begin
    $readmemh( MEL_FILE,  mel_mem  );
    $readmemh( INFO_FILE, info_mem );
  end

  wire [15:0] start = info_mem[{ sel, 2'd0 }];
  wire [15:0] recip = info_mem[{ sel, 2'd3 }];
  assign      len_bcd = info_mem[{ sel, 2'd2 }];

  logic [ 9:0] addr;
  logic [15:0] word;
  always_ff @( posedge clk )
    word <= mel_mem[addr];

  typedef enum logic [1:0] { L_ADDR, L_WAIT, L_TAKE, PLAY } st_t;
  st_t        st;
  logic [ 8:0] units_left;
  logic [ 7:0] sub;
  logic [15:0] pos;              // units played since start

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      st         <= L_ADDR;
      addr       <= '0;
      note       <= '0;
      units_left <= '0;
      sub        <= '0;
      pos        <= '0;
    end
    else if ( restart ) begin
      addr <= start[9:0];
      pos  <= '0;
      sub  <= '0;
      note <= '0;
      st   <= L_WAIT;
    end
    else begin
      case ( st )
        L_ADDR: st <= L_WAIT;
        L_WAIT: st <= L_TAKE;                    // word for addr is ready next clock
        L_TAKE: begin
          if ( word == 16'd0 ) begin             // end -> loop
            addr <= start[9:0];
            pos  <= '0;
            st   <= L_WAIT;
          end
          else begin
            note       <= word[15:9];
            units_left <= word[8:0];
            sub        <= '0;
            st         <= PLAY;
          end
        end
        PLAY: if ( tick && run ) begin
          if ( sub == UNIT_TICKS - 1'b1 ) begin
            sub <= '0;
            pos <= pos + 1'b1;
            if ( units_left == 9'd1 ) begin
              addr <= addr + 1'b1;
              st   <= L_WAIT;
            end
            else
              units_left <= units_left - 1'b1;
          end
          else
            sub <= sub + 1'b1;
        end
        default: st <= L_ADDR;
      endcase
    end
  end

  assign gate = ( st == PLAY ) && ( note != 7'd0 ) && ( units_left > 9'd3 );

  // progress = pos * 1024 / total, with recip = 1024 * 65536 / total
  wire [31:0] prog_full = pos * recip;
  assign progress = ( prog_full[31:16] > 32'd1023 ) ? 10'd1023 : prog_full[25:16];

endmodule
