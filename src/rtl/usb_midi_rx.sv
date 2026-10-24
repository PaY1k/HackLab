// USB-MIDI 1.0 receive-side payload adapter.
// IMPORTANT: input is already recovered, NRZI-decoded, de-stuffed USB PAYLOAD bits.
// It is NOT a USB PHY or a USB host controller.
module usb_payload_bit_to_byte (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       payload_start,
    input  logic       bit_in,
    input  logic       bit_valid,
    output logic [7:0] byte_data,
    output logic       byte_valid
);
    logic [7:0] shift_reg;
    logic [2:0] bit_count;

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            shift_reg  <= 8'd0;
            bit_count  <= 3'd0;
            byte_data  <= 8'd0;
            byte_valid <= 1'b0;
        end else begin
            byte_valid <= 1'b0;
            if (payload_start) begin
                bit_count <= 3'd0;
                shift_reg <= 8'd0;
            end else if (bit_valid) begin
                // USB transmits the least significant bit of a byte first.
                shift_reg <= {bit_in, shift_reg[7:1]};
                bit_count <= bit_count + 3'd1;
                if (bit_count == 3'd7) begin
                    byte_data  <= {bit_in, shift_reg[7:1]};
                    byte_valid <= 1'b1;
                end
            end
        end
    end
endmodule

// Strip the USB-MIDI 1.0 event header, forward Note On/Off as 3 MIDI bytes.
// Assumes the input is the payload of a USB-MIDI IN endpoint, with 4-byte
// event alignment at payload_start. Input must not provide bytes faster than
// one per 3 clock cycles (normal USB full-speed, with a faster system clock,
// naturally satisfies this). Overflow flag is sticky until reset.
module usb_midi_event_unpack (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       payload_start,
    input  logic [7:0] byte_data,
    input  logic       byte_valid,
    output logic [7:0] midi_data,
    output logic       midi_valid,
    output logic       overflow
);
    logic [1:0] byte_index;
    logic [3:0] cin;
    logic [7:0] status_byte, note_byte;
    logic [7:0] tx_status, tx_note, tx_velocity;
    logic [1:0] tx_state; // 0=idle, 1=status, 2=note, 3=velocity

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            byte_index  <= 2'd0;
            cin         <= 4'd0;
            status_byte <= 8'd0;
            note_byte   <= 8'd0;
            tx_status   <= 8'd0;
            tx_note     <= 8'd0;
            tx_velocity <= 8'd0;
            tx_state    <= 2'd0;
            midi_data   <= 8'd0;
            midi_valid  <= 1'b0;
            overflow    <= 1'b0;
        end else begin
            midi_valid <= 1'b0;
            case (tx_state)
                2'd1: begin
                    midi_data  <= tx_status;
                    midi_valid <= 1'b1;
                    tx_state   <= 2'd2;
                end
                2'd2: begin
                    midi_data  <= tx_note;
                    midi_valid <= 1'b1;
                    tx_state   <= 2'd3;
                end
                2'd3: begin
                    midi_data  <= tx_velocity;
                    midi_valid <= 1'b1;
                    tx_state   <= 2'd0;
                end
                default: ;
            endcase

            if (payload_start) begin
                byte_index <= 2'd0;
            end else if (byte_valid) begin
                case (byte_index)
                    2'd0: begin
                        cin        <= byte_data[3:0];
                        byte_index <= 2'd1;
                    end
                    2'd1: begin
                        status_byte <= byte_data;
                        byte_index  <= 2'd2;
                    end
                    2'd2: begin
                        note_byte  <= byte_data;
                        byte_index <= 2'd3;
                    end
                    2'd3: begin
                        byte_index <= 2'd0;
                        // MIDI 1.0 USB event CIN=8/9: Note Off/Note On.
                        if ((cin == 4'h8 && status_byte[7:4] == 4'h8) ||
                            (cin == 4'h9 && status_byte[7:4] == 4'h9)) begin
                            if (tx_state == 2'd0) begin
                                tx_status   <= status_byte;
                                tx_note     <= note_byte;
                                tx_velocity <= byte_data;
                                tx_state    <= 2'd1;
                            end else begin
                                overflow <= 1'b1;
                            end
                        end
                    end
                endcase
            end
        end
    end
endmodule

module usb_midi_rx (
    input  logic       clk,
    input  logic       rst_n,
    input  logic       payload_start,
    input  logic       bit_in,
    input  logic       bit_valid,
    output logic [7:0] midi_data,
    output logic       midi_valid,
    output logic       overflow
);
    logic [7:0] byte_data;
    logic       byte_valid;

    usb_payload_bit_to_byte bytes_rx (
        .clk(clk), .rst_n(rst_n),
        .payload_start(payload_start),
        .bit_in(bit_in), .bit_valid(bit_valid),
        .byte_data(byte_data), .byte_valid(byte_valid)
    );

    usb_midi_event_unpack events_rx (
        .clk(clk), .rst_n(rst_n),
        .payload_start(payload_start),
        .byte_data(byte_data), .byte_valid(byte_valid),
        .midi_data(midi_data), .midi_valid(midi_valid),
        .overflow(overflow)
    );
endmodule
