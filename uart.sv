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
    parameter int FIFO_DEPTH = 16
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
    logic transmitting;
    logic started;

    wire start = write && !transmitting && !started;

    assign tx_busy = transmitting || started;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            divisor <= CLK_FREQ / BAUD_RATE;
            started <= 1'b0;
        end else begin
            started <= start;

            if (divisor_write)
                divisor <= divisor_data;
        end
    end

    uart_tx uart_tx0 (
        .clk(clk),
        .rst(rst),
        .clks_per_bit(divisor),
        .tx_data(write_data),
        .tx_write(start),
        .tx_busy(transmitting),
        .tx_pin(tx_pin)
    );

    uart_rx #(
        .FIFO_DEPTH(FIFO_DEPTH)
    ) uart_rx0 (
        .clk(clk),
        .rst(rst),
        .clks_per_bit(divisor),
        .rx_pin(rx_pin),
        .read_ack(read),
        .rx_byte(read_data),
        .rx_ready(rx_ready)
    );
endmodule
