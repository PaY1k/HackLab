
module ps2_rx (
    input  logic       clk,
    input  logic       rst_n,

    input  logic       ps2_clk,
    input  logic       ps2_data,

    output logic [7:0] byte_data,
    output logic       byte_valid,
    output logic       frame_error
);

    logic [2:0] ps2_clk_sync;
    logic [1:0] ps2_data_sync;

    logic [3:0] bit_cnt;
    logic [7:0] shift_reg;
    logic       parity_ok;

    // синхронизация входных сигналов
    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ps2_clk_sync  <= 3'b111;
            ps2_data_sync <= 2'b11;
        end
        else begin
            ps2_clk_sync  <= {ps2_clk_sync[1:0], PS2_CLK};
            ps2_data_sync <= {ps2_data_sync[0], PS2_DATA};
        end
    end

    // обнаружение спадающего фронта PS2_CLK
    wire ps2_falling = ps2_clk_sync[2] &&
                       !ps2_clk_sync[1];

    always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            bit_cnt     <= 4'd0;
            shift_reg   <= 8'd0;
            parity_ok   <= 1'b0;
            byte_data   <= 8'd0;
            byte_valid  <= 1'b0;
            frame_error <= 1'b0;
        end
        else begin
            byte_valid  <= 1'b0;
            frame_error <= 1'b0;

            if (ps2_falling) begin
                case (bit_cnt)

                    // стартовый бит
                    4'd0: begin
                        if (!ps2_data_sync[1])
                            bit_cnt <= 4'd1;
                    end

                    // восемь информационных битов
                    4'd1, 4'd2, 4'd3, 4'd4,
                    4'd5, 4'd6, 4'd7, 4'd8: begin
                        shift_reg <= {
                            ps2_data_sync[1],
                            shift_reg[7:1]
                        };
                        bit_cnt <= bit_cnt + 1'b1;
                    end

                    // бит нечётности
                    4'd9: begin
                        parity_ok <= (^shift_reg) ^
                                     ps2_data_sync[1];
                        bit_cnt <= 4'd10;
                    end

                    // стоповый бит
                    4'd10: begin
                        if (ps2_data_sync[1] && parity_ok) begin
                            byte_data  <= shift_reg;
                            byte_valid <= 1'b1;
                        end
                        else begin
                            frame_error <= 1'b1;
                        end

                        bit_cnt <= 4'd0;
                    end

                    default: bit_cnt <= 4'd0;

                endcase
            end
        end
    end

endmodule
