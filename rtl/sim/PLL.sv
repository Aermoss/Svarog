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

`timescale 1ns / 1ps

module rPLL (CLKOUT, CLKOUTP, CLKOUTD, CLKOUTD3, LOCK, CLKIN, CLKFB, FBDSEL, IDSEL, ODSEL, DUTYDA, PSDA, FDLY, RESET, RESET_P);
    input CLKIN;
    input CLKFB;
    input RESET;
    input RESET_P;
    input [5:0] FBDSEL;
    input [5:0] IDSEL;
    input [5:0] ODSEL;
    input [3:0] PSDA;
    input [3:0] FDLY;
    input [3:0] DUTYDA;
    output CLKOUT;
    output CLKOUTP;
    output CLKOUTD;
    output CLKOUTD3;
    output LOCK;

    parameter FCLKIN = "100.0";
    parameter DYN_IDIV_SEL = "false";
    parameter IDIV_SEL = 0;
    parameter DYN_FBDIV_SEL = "false";
    parameter FBDIV_SEL = 0;
    parameter DYN_ODIV_SEL = "false";
    parameter ODIV_SEL = 8;
    parameter PSDA_SEL = "0000";
    parameter DYN_DA_EN = "false";
    parameter DUTYDA_SEL = "1000";
    parameter CLKOUT_FT_DIR = 1'b1;
    parameter CLKOUTP_FT_DIR = 1'b1;
    parameter CLKOUT_DLY_STEP = 0;
    parameter CLKOUTP_DLY_STEP = 0;
    parameter CLKFB_SEL = "internal";
    parameter CLKOUT_BYPASS = "false";
    parameter CLKOUTP_BYPASS = "false";
    parameter CLKOUTD_BYPASS = "false";
    parameter DYN_SDIV_SEL = 2;
    parameter CLKOUTD_SRC = "CLKOUT";
    parameter CLKOUTD3_SRC = "CLKOUT";
    parameter DEVICE = "GW2A-18";

    function automatic int Sixteenths(input [31:0] code);
        case (code)
            "0001": return 1;
            "0010": return 2;
            "0011": return 3;
            "0100": return 4;
            "0101": return 5;
            "0110": return 6;
            "0111": return 7;
            "1000": return 8;
            "1001": return 9;
            "1010": return 10;
            "1011": return 11;
            "1100": return 12;
            "1101": return 13;
            "1110": return 14;
            "1111": return 15;
            default: return 0;
        endcase
    endfunction

    function automatic real FineDelay(input [3:0] code);
        case (code)
            4'b1110: return 0.125;
            4'b1101: return 0.25;
            4'b1011: return 0.5;
            4'b0111: return 1.0;
            default: return 0.0;
        endcase
    endfunction

    wire resetn = !(RESET || RESET_P);

    logic running = 1'b0;
    logic locked = 1'b0;
    logic clock = 1'b0;
    logic shifted = 1'b0;
    logic divided = 1'b0;
    logic third = 1'b0;
    logic third_started = 1'b0;
    int divided_count = 0;
    int third_count = 0;

    real cycles [0:4];
    real current_time = 0.0;
    real previous_time = 0.0;
    real average_period = 0.0;
    real input_period = 0.0;
    real lock_time = 0.0;
    real half = 0.0;
    real high = 0.0;
    real phase = 0.0;
    logic stable = 1'b0;
    int lock_count = 0;

    wire [5:0] input_divider = DYN_IDIV_SEL == "true" ? 6'(64 - int'(IDSEL)) : 6'(IDIV_SEL + 1);
    wire [5:0] feedback_divider = DYN_FBDIV_SEL == "true" ? 6'(64 - int'(FBDSEL)) : 6'(FBDIV_SEL + 1);
    logic [5:0] input_seen = 6'd0;
    logic [5:0] feedback_seen = 6'd0;
    logic [5:0] output_seen = 6'd0;
    wire divider_changed = input_seen != input_divider || feedback_seen != feedback_divider || output_seen != ODSEL;

    initial for (int i = 0; i < 5; i++) cycles[i] = 0.0;

    function automatic real Picoseconds(input real value);
        return real'($rtoi(value * 1000.0 + 0.5)) / 1000.0;
    endfunction

    task automatic Configure();
        real period;
        period = input_period * int'(input_divider) / int'(feedback_divider);
        half = period / 2.0;

        if (DYN_DA_EN == "true") begin
            phase = period * int'(PSDA) / 16.0 + FineDelay(FDLY);
            if (DUTYDA > PSDA) high = period * (int'(DUTYDA) - int'(PSDA)) / 16.0;
            else if (DUTYDA < PSDA) high = period * (16 + int'(DUTYDA) - int'(PSDA)) / 16.0;
            else high = period / 2.0;
            half = CLKOUT_FT_DIR == 1'b1 ? half - 0.05 * CLKOUT_DLY_STEP : half + 0.05 * CLKOUT_DLY_STEP;
            high = CLKOUTP_FT_DIR == 1'b1 ? high - 0.05 * CLKOUTP_DLY_STEP : high + 0.05 * CLKOUTP_DLY_STEP;
        end else begin
            phase = period * Sixteenths(PSDA_SEL) / 16.0;
            high = period * Sixteenths(DUTYDA_SEL) / 16.0;
        end

        half = Picoseconds(half);
        high = Picoseconds(high);
        phase = Picoseconds(phase);
    endtask

    always @(posedge CLKIN) begin
        input_seen <= input_divider;
        feedback_seen <= feedback_divider;
        output_seen <= ODSEL;
    end

    always @(posedge CLKIN or negedge resetn) begin
        if (!resetn) begin
            stable <= 1'b0;
            cycles[0] <= 0.0;
        end else begin
            previous_time <= current_time;
            current_time <= $realtime;
            if (previous_time > 0.0) cycles[0] <= current_time - previous_time;

            if (cycles[0] > 0.0) begin
                cycles[1] <= cycles[0];
                cycles[2] <= cycles[1];
                cycles[3] <= cycles[2];
                cycles[4] <= cycles[3];

                if (cycles[0] - average_period < 0.01 && cycles[0] - average_period > -0.01 && !divider_changed) begin
                    stable <= 1'b1;
                    input_period <= average_period;
                end else begin
                    stable <= 1'b0;
                end
            end
        end
    end

    always @(cycles[0] or cycles[1] or cycles[2] or cycles[3] or cycles[4] or average_period) begin
        if (cycles[0] != average_period) average_period <= (cycles[0] + cycles[1] + cycles[2] + cycles[3] + cycles[4]) / 5.0;
    end

    always @(posedge CLKIN or negedge resetn) begin
        if (!resetn) lock_time <= 0.0;
        else if (cycles[0] >= 2.0 && cycles[0] <= 40.0) lock_time <= 50000.0;
        else if (cycles[0] > 40.0 && cycles[0] <= 500.0) lock_time <= 200000.0;
    end

    always @(posedge CLKIN or negedge resetn) begin
        if (!resetn) begin
            running <= 1'b0;
            locked <= 1'b0;
        end else if (stable) begin
            lock_count <= lock_count + 1;
            running <= lock_count > lock_time / input_period - 10.0;
            locked <= lock_count > lock_time / input_period;
        end else begin
            running <= 1'b0;
            lock_count <= 0;
            locked <= 1'b0;
        end
    end

    always begin
        clock = 1'b0;
        wait (running);
        Configure();

        while (running) begin
            clock = 1'b1;
            #(half);
            clock = 1'b0;
            #(half);
        end
    end

    always @(posedge clock) begin
        shifted <= #(phase) 1'b1;
        shifted <= #(phase + high) 1'b0;
    end

    wire divider_source = CLKOUTD_SRC == "CLKOUTP" ? shifted : clock;
    wire third_source = CLKOUTD3_SRC == "CLKOUTP" ? shifted : clock;

    always @(posedge divider_source or negedge resetn) begin
        if (!resetn) begin
            divided_count = 0;
            divided <= 1'b0;
        end else begin
            divided_count++;

            if (divided_count == DYN_SDIV_SEL / 2) begin
                divided <= !divided;
                divided_count = 0;
            end
        end
    end

    always @(third_source or negedge resetn) begin
        if (!resetn) begin
            third <= 1'b0;
            third_count = 0;
        end else if (!third_started) begin
            if (!third_source) begin
                third <= 1'b1;
                third_started = 1'b1;
                third_count = 0;
            end
        end else begin
            third_count++;

            if (third_count == 3) begin
                third <= !third;
                third_count = 0;
            end
        end
    end

    assign CLKOUT = CLKOUT_BYPASS == "true" ? CLKIN : clock && resetn;
    assign CLKOUTP = CLKOUTP_BYPASS == "true" ? CLKIN : shifted && resetn;
    assign CLKOUTD = CLKOUTD_BYPASS == "true" ? CLKIN : divided;
    assign CLKOUTD3 = third;
    assign LOCK = locked;
endmodule
