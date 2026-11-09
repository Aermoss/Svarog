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

module spi #(
    parameter logic [7:0] DEFAULT_DIVISOR = 8'd68
) (
    input logic clk,
    input logic rst,

    input logic data_write,
    input logic [7:0] write_data,
    output logic [7:0] read_data,
    input logic control_write,
    input logic [4:0] control_data,
    output logic [4:0] status,
    input logic divisor_write,
    input logic [7:0] divisor_data,
    output logic [7:0] divisor,

    output logic sclk,
    output logic mosi,
    input logic miso,
    output logic cs_n
);
    logic cpol;
    logic cpha;
    logic lsb_first;
    logic busy;
    logic [7:0] shift;
    logic [7:0] received;
    logic [4:0] edges;
    logic [7:0] timer;

    wire [4:0] edge_number = edges + 5'd1;
    wire leading = edge_number[0];
    wire next_bit = lsb_first ? shift[0] : shift[7];
    wire [7:0] shifted = lsb_first ? {1'b1, shift[7:1]} : {shift[6:0], 1'b1};

    assign read_data = received;
    assign status = {lsb_first, cpha, cpol, busy, !cs_n};

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            {cpol, cpha, lsb_first, busy} <= 4'b0000;
            shift <= 8'hFF;
            received <= 8'hFF;
            edges <= 5'd0;
            timer <= 8'd0;
            divisor <= DEFAULT_DIVISOR;
            sclk <= 1'b0;
            mosi <= 1'b1;
            cs_n <= 1'b1;
        end else begin
            if (control_write) begin
                cs_n <= !control_data[0];

                if (!busy) begin
                    {lsb_first, cpha, cpol} <= control_data[4:2];
                    sclk <= control_data[2];
                end
            end

            if (divisor_write)
                divisor <= divisor_data == 8'd0 ? 8'd1 : divisor_data;

            if (data_write && !busy) begin
                busy <= 1'b1;
                edges <= 5'd0;
                timer <= divisor - 8'd1;

                if (cpha) begin
                    shift <= write_data;
                end else begin
                    mosi <= lsb_first ? write_data[0] : write_data[7];
                    shift <= lsb_first ? {1'b1, write_data[7:1]} : {write_data[6:0], 1'b1};
                end
            end else if (busy) begin
                if (timer != 8'd0) begin
                    timer <= timer - 8'd1;
                end else begin
                    timer <= divisor - 8'd1;
                    edges <= edge_number;
                    sclk <= !sclk;

                    if (leading != cpha)
                        received <= lsb_first ? {miso, received[7:1]} : {received[6:0], miso};

                    if ((cpha && leading) || (!cpha && !leading && edge_number != 5'd16)) begin
                        mosi <= next_bit;
                        shift <= shifted;
                    end

                    if (edge_number == 5'd16) begin
                        busy <= 1'b0;

                        if (!cpha)
                            mosi <= 1'b1;
                    end
                end
            end
        end
    end
endmodule
