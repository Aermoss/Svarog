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

module sdram #(
    parameter int CLK_FREQ = 54000000
) (
    input logic clk,
    input logic rst,

    input logic start,
    input logic write,
    input logic [1:0] length,
    input logic [20:0] address,
    input logic [31:0] data,
    input logic [3:0] dqm,
    output logic ready,
    output logic read_valid,
    output logic [31:0] read_data,

    output logic sdrc_cmd_en,
    output logic [2:0] sdrc_cmd,
    output logic [20:0] sdrc_addr,
    output logic [31:0] sdrc_data_w,
    output logic [3:0] sdrc_dqm,
    output logic [7:0] sdrc_data_len,
    input logic [31:0] sdrc_data_r,
    input logic sdrc_init_done,
    input logic sdrc_cmd_ack
);
    localparam int REFRESH_CYCLES = CLK_FREQ / 1000000 * 15;
    localparam logic [2:0] DEFAULT_LATENCY = 3'd5;
    localparam logic [20:0] CALIBRATION_ADDRESS = 21'h000000;
    localparam logic [1:0] CALIBRATION_ATTEMPTS = 2'd3;

    typedef enum logic [2:0] {
        S_IDLE,
        S_REFRESH,
        S_ACTIVATE_WAIT,
        S_COMMAND_WAIT,
        S_READ_WAIT,
        S_READ_DATA,
        S_READ_ACK
    } state_t;

    state_t state;
    logic reading;
    logic acknowledged;
    logic [2:0] delay;
    logic [1:0] remaining;
    logic [$clog2(REFRESH_CYCLES) - 1:0] refresh_counter;
    logic refresh_pending;
    logic [20:0] active_address;
    logic [31:0] active_data;
    logic [3:0] active_dqm;
    logic [1:0] active_length;
    logic internal;

    logic [2:0] latency;
    logic calibrated;
    logic [2:0] calibration_step;
    logic [1:0] attempts;
    logic watching;
    logic [3:0] watch_cycle;
    logic [1:0] matched;
    logic [31:0] expected;
    logic [31:0] pattern;

    always_comb begin
        case (calibration_step[1:0])
            2'd0: pattern = 32'h13579BDF;
            2'd1: pattern = 32'hECA86420;
            2'd2: pattern = 32'h0F1E2D3C;
            default: pattern = 32'hB4A59687;
        endcase

        case (matched)
            2'd0: expected = 32'h13579BDF;
            2'd1: expected = 32'hECA86420;
            2'd2: expected = 32'h0F1E2D3C;
            default: expected = 32'hB4A59687;
        endcase
    end

    wire [3:0] first_cycle = watch_cycle - 4'd3;
    wire idle = state == S_IDLE && !refresh_pending && sdrc_init_done;
    wire calibration_request = !calibrated && idle && calibration_step <= 3'd4;

    wire request = calibrated ? start : calibration_request;
    wire request_write = calibrated ? write : calibration_step != 3'd4;
    wire [1:0] request_length = calibrated ? length : 2'd3;
    wire [20:0] request_address = calibrated ? address : CALIBRATION_ADDRESS + {19'b0, calibration_step[1:0]};
    wire [31:0] request_data = calibrated ? data : pattern;
    wire [3:0] request_dqm = calibrated ? dqm : 4'b0000;

    assign ready = idle && calibrated;
    assign read_valid = state == S_READ_DATA && !internal;
    assign read_data = sdrc_data_r;

    assign sdrc_addr = active_address;
    assign sdrc_data_w = active_data;
    assign sdrc_dqm = active_dqm;
    assign sdrc_data_len = {6'b0, active_length};

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= S_IDLE;
            reading <= 1'b0;
            acknowledged <= 1'b0;
            delay <= 3'b0;
            remaining <= 2'b0;
            refresh_counter <= '0;
            refresh_pending <= 1'b0;
            sdrc_cmd_en <= 1'b0;
            sdrc_cmd <= 3'b000;
            active_address <= 21'b0;
            active_data <= 32'b0;
            active_dqm <= 4'b0000;
            active_length <= 2'b0;
            internal <= 1'b0;
            latency <= DEFAULT_LATENCY;
            calibrated <= 1'b0;
            calibration_step <= 3'd0;
            attempts <= 2'd0;
            watching <= 1'b0;
            watch_cycle <= 4'd0;
            matched <= 2'd0;
        end else begin
            if (calibration_request)
                calibration_step <= calibration_step + 3'd1;

            if (!calibrated && !watching && sdrc_cmd_en && sdrc_cmd == 3'b101) begin
                watching <= 1'b1;
                watch_cycle <= 4'd1;
                matched <= 2'd0;
            end

            if (watching) begin
                watch_cycle <= watch_cycle + 4'd1;

                if (sdrc_data_r == expected) begin
                    matched <= matched + 2'd1;

                    if (matched == 2'd3 && watch_cycle >= 4'd4 && watch_cycle <= 4'd10) begin
                        latency <= first_cycle[2:0];
                        calibrated <= 1'b1;
                        watching <= 1'b0;
                    end
                end else if (sdrc_data_r == 32'h13579BDF) begin
                    matched <= 2'd1;
                end else begin
                    matched <= 2'd0;
                end

                if (watch_cycle == 4'd15) begin
                    watching <= 1'b0;
                    attempts <= attempts + 2'd1;

                    if (attempts + 2'd1 == CALIBRATION_ATTEMPTS)
                        calibrated <= 1'b1;
                    else
                        calibration_step <= 3'd0;
                end
            end

            if (sdrc_init_done) begin
                if (refresh_counter == REFRESH_CYCLES - 1) begin
                    refresh_counter <= '0;
                    refresh_pending <= 1'b1;
                end else begin
                    refresh_counter <= refresh_counter + 1'b1;
                end
            end

            case (state)
                S_IDLE: begin
                    if (refresh_pending) begin
                        refresh_pending <= 1'b0;
                        sdrc_cmd_en <= 1'b1;
                        sdrc_cmd <= 3'b001;
                        state <= S_REFRESH;
                    end else if (request) begin
                        sdrc_cmd_en <= 1'b1;
                        sdrc_cmd <= 3'b011;
                        active_address <= request_address;
                        active_data <= request_data;
                        active_dqm <= request_dqm;
                        active_length <= request_write ? 2'd0 : request_length;
                        reading <= !request_write;
                        internal <= !calibrated;
                        state <= S_ACTIVATE_WAIT;
                    end
                end

                S_REFRESH: begin
                    sdrc_cmd_en <= 1'b0;

                    if (sdrc_cmd_ack)
                        state <= S_IDLE;
                end

                S_ACTIVATE_WAIT: begin
                    sdrc_cmd_en <= 1'b0;

                    if (sdrc_cmd_ack) begin
                        sdrc_cmd_en <= 1'b1;
                        sdrc_cmd <= reading ? 3'b101 : 3'b100;
                        acknowledged <= 1'b0;
                        delay <= latency;
                        remaining <= active_length;

                        if (reading)
                            state <= S_READ_WAIT;
                        else
                            state <= S_COMMAND_WAIT;
                    end
                end

                S_COMMAND_WAIT: begin
                    sdrc_cmd_en <= 1'b0;

                    if (sdrc_cmd_ack)
                        state <= S_IDLE;
                end

                S_READ_WAIT: begin
                    sdrc_cmd_en <= 1'b0;

                    if (sdrc_cmd_ack)
                        acknowledged <= 1'b1;

                    if (delay > 3'd1)
                        delay <= delay - 3'd1;
                    else
                        state <= S_READ_DATA;
                end

                S_READ_DATA: begin
                    if (sdrc_cmd_ack)
                        acknowledged <= 1'b1;

                    if (remaining != 2'd0)
                        remaining <= remaining - 2'd1;
                    else if (acknowledged || sdrc_cmd_ack)
                        state <= S_IDLE;
                    else
                        state <= S_READ_ACK;
                end

                S_READ_ACK: begin
                    if (sdrc_cmd_ack)
                        state <= S_IDLE;
                end

                default: state <= S_IDLE;
            endcase
        end
    end
endmodule
