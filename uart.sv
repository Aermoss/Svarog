/*
 * Copyright 2026 Yusuf Rençber
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

module uart #(
    parameter int CLK_FREQ = 54000000,
    parameter int BAUD_RATE = 115200,
    parameter int FIFO_DEPTH = 16,
    parameter bit ECHO = 1'b0
) (
    input logic clk,
    input logic rst,

    input logic write,
    input logic [7:0] write_data,
    input logic read,
    output logic [7:0] read_data,
    output logic rx_ready,
    output logic tx_busy,

    input logic divisor_write,
    input logic [15:0] divisor_data,
    output logic [15:0] divisor,

    input logic rx_pin,
    output logic tx_pin
);
    typedef enum logic [1:0] {
        S_IDLE,
        S_START,
        S_DATA,
        S_STOP
    } state_t;

    localparam int POINTER_BITS = $clog2(FIFO_DEPTH);

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            divisor <= CLK_FREQ / BAUD_RATE;
        else if (divisor_write)
            divisor <= divisor_data;
    end

    generate
        if (ECHO) begin : echo_transmitter
            always_ff @(posedge clk) begin
                if (write)
                    $write("%c", write_data);
            end

            assign tx_busy = 1'b0;
            assign tx_pin = 1'b1;
        end else begin : transmitter
            state_t tx_state;
            logic [15:0] tx_count;
            logic [2:0] tx_index;
            logic [7:0] tx_byte;
            logic started;

            wire start = write && tx_state == S_IDLE && !started;

            assign tx_busy = tx_state != S_IDLE || started;

            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    tx_state <= S_IDLE;
                    tx_count <= 16'd0;
                    tx_index <= 3'd0;
                    tx_byte <= 8'd0;
                    tx_pin <= 1'b1;
                    started <= 1'b0;
                end else begin
                    started <= start;

                    case (tx_state)
                        S_IDLE: begin
                            tx_pin <= 1'b1;
                            tx_count <= 16'd0;
                            tx_index <= 3'd0;

                            if (start) begin
                                tx_byte <= write_data;
                                tx_state <= S_START;
                            end
                        end

                        S_START: begin
                            tx_pin <= 1'b0;

                            if (tx_count < divisor - 1) begin
                                tx_count <= tx_count + 16'd1;
                            end else begin
                                tx_count <= 16'd0;
                                tx_state <= S_DATA;
                            end
                        end

                        S_DATA: begin
                            tx_pin <= tx_byte[tx_index];

                            if (tx_count < divisor - 1) begin
                                tx_count <= tx_count + 16'd1;
                            end else begin
                                tx_count <= 16'd0;

                                if (tx_index < 3'd7) begin
                                    tx_index <= tx_index + 3'd1;
                                end else begin
                                    tx_index <= 3'd0;
                                    tx_state <= S_STOP;
                                end
                            end
                        end

                        S_STOP: begin
                            tx_pin <= 1'b1;

                            if (tx_count < divisor - 1) begin
                                tx_count <= tx_count + 16'd1;
                            end else begin
                                tx_count <= 16'd0;
                                tx_state <= S_IDLE;
                            end
                        end

                        default: tx_state <= S_IDLE;
                    endcase
                end
            end
        end
    endgenerate

    state_t rx_state;
    logic [15:0] rx_count;
    logic [2:0] rx_index;
    logic [7:0] rx_byte;
    logic rx_sync0, rx_sync1;

    wire byte_received = rx_state == S_STOP && !(rx_count < divisor - 1);

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_sync0 <= 1'b1;
            rx_sync1 <= 1'b1;
        end else begin
            rx_sync0 <= rx_pin;
            rx_sync1 <= rx_sync0;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            rx_state <= S_IDLE;
            rx_count <= 16'd0;
            rx_index <= 3'd0;
            rx_byte <= 8'd0;
        end else begin
            case (rx_state)
                S_IDLE: begin
                    rx_count <= 16'd0;
                    rx_index <= 3'd0;

                    if (rx_sync1 == 1'b0)
                        rx_state <= S_START;
                end

                S_START: begin
                    if (rx_count < (divisor >> 1) - 1) begin
                        rx_count <= rx_count + 16'd1;
                    end else begin
                        rx_count <= 16'd0;

                        if (rx_sync1 == 1'b0)
                            rx_state <= S_DATA;
                        else
                            rx_state <= S_IDLE;
                    end
                end

                S_DATA: begin
                    if (rx_count < divisor - 1) begin
                        rx_count <= rx_count + 16'd1;
                    end else begin
                        rx_count <= 16'd0;
                        rx_byte[rx_index] <= rx_sync1;

                        if (rx_index < 3'd7) begin
                            rx_index <= rx_index + 3'd1;
                        end else begin
                            rx_index <= 3'd0;
                            rx_state <= S_STOP;
                        end
                    end
                end

                S_STOP: begin
                    if (rx_count < divisor - 1) begin
                        rx_count <= rx_count + 16'd1;
                    end else begin
                        rx_count <= 16'd0;
                        rx_state <= S_IDLE;
                    end
                end

                default: rx_state <= S_IDLE;
            endcase
        end
    end

    generate
        if (FIFO_DEPTH <= 64) begin : register_fifo
            logic [7:0] fifo [0:FIFO_DEPTH - 1];
            logic [POINTER_BITS - 1:0] fifo_head;
            logic [POINTER_BITS - 1:0] fifo_tail;
            logic [POINTER_BITS:0] fifo_count;

            wire fifo_pop = read && fifo_count != 0;
            wire fifo_push = byte_received && (fifo_count != FIFO_DEPTH || fifo_pop);

            assign read_data = fifo[fifo_head];
            assign rx_ready = fifo_count != 0;

            always_ff @(posedge clk) begin
                if (fifo_push)
                    fifo[fifo_tail] <= rx_byte;
            end

            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    fifo_head <= 0;
                    fifo_tail <= 0;
                    fifo_count <= 0;
                end else begin
                    if (fifo_push)
                        fifo_tail <= fifo_tail + 1'b1;

                    if (fifo_pop)
                        fifo_head <= fifo_head + 1'b1;

                    case ({fifo_push, fifo_pop})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: ;
                    endcase
                end
            end
        end else begin : block_fifo
            logic [7:0] fifo [0:FIFO_DEPTH - 1];
            logic [7:0] fifo_read;
            logic [POINTER_BITS - 1:0] fifo_head;
            logic [POINTER_BITS - 1:0] fifo_tail;
            logic [POINTER_BITS:0] fifo_count;
            logic fetching;
            logic output_valid;
            logic [7:0] output_byte;

            wire fifo_pop = read && output_valid;
            wire fifo_push = byte_received && fifo_count != FIFO_DEPTH;
            wire fifo_issue = fifo_count != 0 && !fetching && (!output_valid || fifo_pop);

            assign read_data = output_byte;
            assign rx_ready = output_valid;

            always_ff @(posedge clk) begin
                if (fifo_push)
                    fifo[fifo_tail] <= rx_byte;

                fifo_read <= fifo[fifo_head];
            end

            always_ff @(posedge clk or posedge rst) begin
                if (rst) begin
                    fifo_head <= 0;
                    fifo_tail <= 0;
                    fifo_count <= 0;
                    fetching <= 1'b0;
                    output_valid <= 1'b0;
                    output_byte <= 8'b0;
                end else begin
                    if (fifo_push)
                        fifo_tail <= fifo_tail + 1'b1;

                    if (fifo_issue)
                        fifo_head <= fifo_head + 1'b1;

                    case ({fifo_push, fifo_issue})
                        2'b10: fifo_count <= fifo_count + 1'b1;
                        2'b01: fifo_count <= fifo_count - 1'b1;
                        default: ;
                    endcase

                    fetching <= fifo_issue;

                    if (fetching) begin
                        output_byte <= fifo_read;
                        output_valid <= 1'b1;
                    end else if (fifo_pop) begin
                        output_valid <= 1'b0;
                    end
                end
            end
        end
    endgenerate
endmodule
