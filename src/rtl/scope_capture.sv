// Oscilloscope buffer: captures 512 audio samples for the VGA screen.
//
// Audio domain: on request waits for a rising crossing of the middle level
// (trigger, so the picture does not run), then writes 512 samples, one per
// sample_tick, into one half of a dual-clock RAM.
// Pixel domain: shows the other half. When a capture is done, the halves are
// swapped at the next frame_start, so a frame never shows a half-written
// buffer (double buffering).
//
// Clock crossing: req/ack toggles through 2-FF synchronizers, data through
// the dual-port block RAM (written by aud_clk, read by pix_clk).
module scope_capture #(
    parameter  TRIG_LEVEL = 8'd128,
    parameter  TIMEOUT    = 11'd1024     // capture anyway if no trigger (silence, very low note)
)(
  //--------- Audio domain                       --------//
    input  wire          aud_clk     ,
    input  wire          aud_rst_n   ,
    input  wire          sample_tick ,   // one pulse per output sample (48 kHz)
    input  wire  [7:0]   sample      ,   // unsigned, 128 = silence
  //--------- Pixel domain                       --------//
    input  wire          pix_clk     ,
    input  wire          pix_rst_n   ,
    input  wire          frame_start ,   // one pulse per frame, outside the visible area
    input  wire  [8:0]   rd_addr     ,   // sample number 0..511
    output logic [7:0]   rd_data         // 1 clock latency
);

  logic [7:0] mem [0:1023];               // {bank, index}

//------------- Audio domain: trigger + capture                  -------------//
  typedef enum logic [1:0] { IDLE, ARM, CAPT } state_t;
  state_t      state;
  logic        req_seen, ack;             // ack toggles when a capture is done
  logic        wr_bank;
  logic [8:0]  wr_idx;
  logic [10:0] wait_cnt;
  logic [7:0]  prev_sample;
  (* ASYNC_REG = "TRUE" *) logic [1:0] req_sync;
  logic        req;                       // pixel domain

  wire trigger = ( prev_sample < TRIG_LEVEL ) && ( sample >= TRIG_LEVEL );

  always_ff @( posedge aud_clk ) begin
    if ( state == CAPT && sample_tick )
      mem[{wr_bank, wr_idx}] <= sample;
  end

  always_ff @( posedge aud_clk or negedge aud_rst_n ) begin
    if ( !aud_rst_n ) begin
      state       <= IDLE;
      req_sync    <= 2'b00;
      req_seen    <= 1'b0;
      ack         <= 1'b0;
      wr_bank     <= 1'b1;                // first capture goes to bank 1, bank 0 is shown
      wr_idx      <= '0;
      wait_cnt    <= '0;
      prev_sample <= 8'd128;
    end
    else begin
      req_sync <= { req_sync[0], req };
      if ( sample_tick )
        prev_sample <= sample;
      case ( state )
        IDLE: if ( req_sync[1] != req_seen ) begin
                req_seen <= req_sync[1];
                wait_cnt <= '0;
                state    <= ARM;
              end
        ARM:  if ( sample_tick ) begin
                wait_cnt <= wait_cnt + 1'b1;
                if ( trigger || wait_cnt == TIMEOUT ) begin
                  wr_idx <= '0;
                  state  <= CAPT;
                end
              end
        CAPT: if ( sample_tick ) begin
                wr_idx <= wr_idx + 1'b1;
                if ( &wr_idx ) begin
                  wr_bank <= ~wr_bank;
                  ack     <= ~ack;
                  state   <= IDLE;
                end
              end
        default: state <= IDLE;
      endcase
    end
  end

//------------- Pixel domain: bank swap + read                   -------------//
  (* ASYNC_REG = "TRUE" *) logic [1:0] ack_sync;
  logic show_bank;
  logic first;

  always_ff @( posedge pix_clk or negedge pix_rst_n ) begin
    if ( !pix_rst_n ) begin
      ack_sync  <= 2'b00;
      req       <= 1'b0;
      show_bank <= 1'b0;
      first     <= 1'b1;
    end
    else begin
      ack_sync <= { ack_sync[0], ack };
      if ( frame_start && ( ack_sync[1] == req ) ) begin   // previous capture finished
        if ( !first )
          show_bank <= ~show_bank;
        first <= 1'b0;
        req   <= ~req;                                      // ask for the next one
      end
    end
  end

  always_ff @( posedge pix_clk ) begin
    rd_data <= mem[{show_bank, rd_addr}];
  end

endmodule
