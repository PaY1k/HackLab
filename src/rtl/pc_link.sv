// Link with the PC over the board's USB-UART (tools/pc_player.py on the PC).
//
// PC -> board, packets:  0xA5, type, len, payload[len]
//   type 1  audio: len unsigned 8-bit samples, mono, 48 kHz
//   type 2  MIDI message: 3 bytes (note on 0x9n, note off 0x8n / velocity 0,
//           controller 123 = all notes off)
//   type 3  title: up to 18 CP866 characters, shown in the playlist
//   type 4  all MIDI notes off
//   type 5  hello: the PC (re)started, forget credits given earlier
// board -> PC:
//   0xC1    credit: the PC may send 255 more audio bytes
//
// Credits keep the audio FIFO from overflowing: one is sent whenever the FIFO
// has 255 free places that were not promised yet.
module pc_link #(
    parameter  CLKS_PER_BIT = 53,
    parameter  FIFO_AW      = 12           // audio FIFO depth 2^FIFO_AW
)(
    input  wire               clk           ,
    input  wire               rst_n         ,
    input  wire               uart_rx_pin   ,
    output wire               uart_tx_pin   ,
  //--------- Audio FIFO, write side           --------//
    output logic              fifo_wr       ,
    output logic       [15:0] fifo_data     ,   // signed 16-bit sample
    input  wire  [FIFO_AW:0]  fifo_level    ,   // words inside (write side view)
  //--------- MIDI                             --------//
    output logic              midi_on       ,
    output logic              midi_off      ,
    output logic       [ 6:0] midi_note     ,
    output logic              midi_all_off  ,
  //--------- Title                            --------//
    input  wire        [ 4:0] title_idx     ,
    output wire        [ 7:0] title_char    ,
    output logic              title_valid   ,   // a title was received
    output logic              title_changed     // pulse
);

//------------- UART                                             -------------//
  wire  [7:0] rx_data;
  wire        rx_valid;
  logic       tx_start;
  wire        tx_busy;

  uart_rx #( .CLKS_PER_BIT ( CLKS_PER_BIT ) ) uart_rx (
    .clk ( clk ), .rst_n ( rst_n ), .rx ( uart_rx_pin ), .data ( rx_data ), .valid ( rx_valid )
  );

  uart_tx #( .CLKS_PER_BIT ( CLKS_PER_BIT ) ) uart_tx (
    .clk ( clk ), .rst_n ( rst_n ), .data ( 8'hC1 ), .start ( tx_start ), .busy ( tx_busy ), .tx ( uart_tx_pin )
  );
//____________________________________________________________________________//

//------------- Packet parser                                    -------------//
  typedef enum logic [1:0] { P_SYNC, P_TYPE, P_LEN, P_DATA } pst_t;
  pst_t       pst;
  logic [7:0] ptype, plen, pidx;
  logic [7:0] midi_b [0:2];
  logic [7:0] title [0:17];
  logic       hello;
  logic       audio_byte;

  assign title_char = ( title_idx < 5'd18 ) ? title[title_idx] : 8'h20;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      pst           <= P_SYNC;
      ptype         <= '0;
      plen          <= '0;
      pidx          <= '0;
      fifo_wr       <= 1'b0;
      fifo_data     <= '0;
      midi_on       <= 1'b0;
      midi_off      <= 1'b0;
      midi_note     <= '0;
      midi_all_off  <= 1'b0;
      title_valid   <= 1'b0;
      title_changed <= 1'b0;
      hello         <= 1'b0;
      audio_byte    <= 1'b0;
      for ( int i = 0; i < 3; i++ )  midi_b[i] <= '0;
      for ( int i = 0; i < 18; i++ ) title[i]  <= 8'h20;
    end
    else begin
      fifo_wr       <= 1'b0;
      midi_on       <= 1'b0;
      midi_off      <= 1'b0;
      midi_all_off  <= 1'b0;
      title_changed <= 1'b0;
      hello         <= 1'b0;
      audio_byte    <= 1'b0;

      if ( rx_valid ) begin
        case ( pst )
          P_SYNC: if ( rx_data == 8'hA5 ) pst <= P_TYPE;
          P_TYPE: begin
            ptype <= rx_data;
            pst   <= P_LEN;
          end
          P_LEN: begin
            plen <= rx_data;
            pidx <= '0;
            if ( ptype == 8'd3 )                          // new title: clear the old one
              for ( int i = 0; i < 18; i++ ) title[i] <= 8'h20;
            if ( rx_data == 8'd0 ) begin                  // packet without payload
              pst <= P_SYNC;
              if ( ptype == 8'd4 ) midi_all_off <= 1'b1;
              if ( ptype == 8'd5 ) hello        <= 1'b1;
              if ( ptype == 8'd3 ) begin title_valid <= 1'b0; title_changed <= 1'b1; end
            end
            else
              pst <= P_DATA;
          end
          P_DATA: begin
            pidx <= pidx + 1'b1;
            case ( ptype )
              8'd1: begin                                 // u8 -> signed 16
                fifo_data  <= { ~rx_data[7], rx_data[6:0], 8'h00 };
                fifo_wr    <= 1'b1;
                audio_byte <= 1'b1;
              end
              8'd2: if ( pidx < 8'd3 ) midi_b[pidx[1:0]] <= rx_data;
              8'd3: if ( pidx < 8'd18 ) title[pidx[4:0]] <= rx_data;
              default: ;
            endcase
            if ( pidx == plen - 1'b1 ) begin              // last byte of the packet
              pst <= P_SYNC;
              if ( ptype == 8'd2 ) begin
                // midi_b[2] is this byte, not stored yet
                midi_note <= midi_b[1][6:0];
                case ( midi_b[0][7:4] )
                  4'h9:    if ( rx_data != 8'd0 ) midi_on <= 1'b1; else midi_off <= 1'b1;
                  4'h8:    midi_off <= 1'b1;
                  4'hB:    if ( midi_b[1] == 8'd123 ) midi_all_off <= 1'b1;
                  default: ;
                endcase
              end
              if ( ptype == 8'd3 ) begin
                title_valid   <= 1'b1;
                title_changed <= 1'b1;
              end
            end
          end
          default: pst <= P_SYNC;
        endcase
      end
    end
  end
//____________________________________________________________________________//

//------------- Credits                                          -------------//
  localparam [FIFO_AW+1:0] DEPTH  = 1 << FIFO_AW;
  localparam [FIFO_AW+1:0] CREDIT = 255;

  logic [FIFO_AW+1:0] promised;           // audio bytes allowed but not received yet
  wire  [FIFO_AW+1:0] used = { 1'b0, fifo_level } + promised;

  always_ff @( posedge clk or negedge rst_n ) begin
    if ( !rst_n ) begin
      promised <= '0;
      tx_start <= 1'b0;
    end
    else begin
      tx_start <= 1'b0;
      if ( hello )
        promised <= '0;
      else if ( !tx_busy && !tx_start && used + CREDIT <= DEPTH ) begin
        tx_start <= 1'b1;
        promised <= promised + CREDIT - ( audio_byte && promised != 0 );
      end
      else if ( audio_byte && promised != 0 )
        promised <= promised - 1'b1;
    end
  end
//____________________________________________________________________________//

endmodule
