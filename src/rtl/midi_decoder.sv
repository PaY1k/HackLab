
module midi_decoder (
    input  logic       clk,
    input  logic       rst_n,

    // входной поток MIDI-байтов
    input  logic [7:0] midi_data,
    input  logic       midi_valid,

    // управление существующим tone_generator
    output logic [2:0] note_index,
    output logic       play
);

    typedef enum logic [1:0] {
        WAIT_STATUS,
        WAIT_NOTE,
        WAIT_VELOCITY
    } state_t;

    state_t state;

    logic [7:0] status_byte;
    logic [6:0] note_byte;

    logic [6:0] active_note;
    logic [3:0] active_channel;
    logic       sysex_mode;

    // преобразование MIDI-номера в индекс генератора
    function automatic logic [2:0] get_note_index(
        input logic [6:0] note
    );
        case (note)
            7'd60: get_note_index = 3'd0; // C4
            7'd62: get_note_index = 3'd1; // D4
            7'd64: get_note_index = 3'd2; // E4
            7'd65: get_note_index = 3'd3; // F4
            7'd67: get_note_index = 3'd4; // G4
            7'd69: get_note_index = 3'd5; // A4
            7'd71: get_note_index = 3'd6; // B4
            default: get_note_index = 3'd0;
        endcase
    endfunction

    function automatic logic is_supported_note(
        input logic [6:0] note
    );
        case (note)
            7'd60, 7'd62, 7'd64, 7'd65,
            7'd67, 7'd69, 7'd71:
                is_supported_note = 1'b1;
            default:
                is_supported_note = 1'b0;
        endcase
    endfunction

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state          <= WAIT_STATUS;
            status_byte    <= 8'd0;
            note_byte      <= 7'd0;
            active_note    <= 7'd0;
            active_channel <= 4'd0;
            sysex_mode     <= 1'b0;
            note_index     <= 3'd0;
            play           <= 1'b0;
        end
        else if (midi_valid) begin

            // системные сообщения реального времени
            // могут появляться между байтами MIDI
            if (midi_data >= 8'hF8) begin
                // пропускаем, не изменяя состояние
            end

            // начало SysEx
            else if (midi_data == 8'hF0) begin
                sysex_mode  <= 1'b1;
                status_byte <= 8'd0;
                state       <= WAIT_STATUS;
            end

            // конец SysEx
            else if (midi_data == 8'hF7) begin
                sysex_mode  <= 1'b0;
                status_byte <= 8'd0;
                state       <= WAIT_STATUS;
            end

            else if (sysex_mode) begin
                // игнорируем содержимое SysEx
            end

            // новый статусный байт
            else if (midi_data[7]) begin
                if (midi_data[7:4] == 4'h8 ||
                    midi_data[7:4] == 4'h9) begin

                    status_byte <= midi_data;
                    state       <= WAIT_NOTE;
                end
                else begin
                    // остальные команды пока не поддерживаем
                    status_byte <= 8'd0;
                    state       <= WAIT_STATUS;
                end
            end

            // байт данных
            else begin
                case (state)

                    WAIT_STATUS: begin
                        // running status
                        if (status_byte[7]) begin
                            note_byte <= midi_data[6:0];
                            state     <= WAIT_VELOCITY;
                        end
                    end

                    WAIT_NOTE: begin
                        note_byte <= midi_data[6:0];
                        state     <= WAIT_VELOCITY;
                    end

                    WAIT_VELOCITY: begin

                        // Note On с ненулевой velocity
                        if (status_byte[7:4] == 4'h9 &&
                            midi_data[6:0] != 7'd0) begin

                            if (is_supported_note(note_byte)) begin
                                note_index     <= get_note_index(note_byte);
                                active_note    <= note_byte;
                                active_channel <= status_byte[3:0];
                                play           <= 1'b1;
                            end
                        end

                        // Note Off или Note On с velocity = 0
                        else begin
                            if (play &&
                                note_byte == active_note &&
                                status_byte[3:0] == active_channel) begin
                                play <= 1'b0;
                            end
                        end

                        // следующий MIDI-message может
                        // использовать тот же status (running status)
                        state <= WAIT_NOTE;
                    end

                    default: begin
                        state <= WAIT_STATUS;
                    end

                endcase
            end
        end
    end

endmodule
