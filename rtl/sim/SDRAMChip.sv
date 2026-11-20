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

module SDRAMChip (
    input logic clk,
    input logic cke,
    input logic cs_n,
    input logic ras_n,
    input logic cas_n,
    input logic we_n,
    input logic [1:0] ba,
    input logic [10:0] addr,
    input logic [3:0] dqm,
    inout wire [31:0] dq
);
    localparam int WORDS = 2097152;
    localparam int REPORT_LIMIT = 20;

    real access_time = 5.4;
    real hold_time = 2.7;
    real path_delay = 3.0;
    real rcd = 18.0;
    real rp = 18.0;
    real rc = 60.0;
    real ras = 42.0;
    real rfc = 60.0;
    real wr = 12.0;
    real refresh_interval = 15625.0;
    real power_up = 100000.0;

    logic [31:0] cells [0:WORDS - 1];
    logic [31:0] drive = 32'd0;
    logic [3:0] lanes = 4'd0;

    for (genvar lane = 0; lane < 4; lane++) begin : output_lanes
        assign dq[lane * 8 +: 8] = lanes[lane] ? drive[lane * 8 +: 8] : 8'bz;
    end

    logic open [0:3];
    logic [10:0] open_row [0:3];
    real activated_at [0:3];
    real precharged_at [0:3];
    real written_at [0:3];
    real refreshed_at = -1.0e9;
    real previous_refresh = -1.0;
    real longest_refresh_gap = 0.0;

    logic mode_set = 1'b0;
    int cas_latency = 3;
    int burst_length = 1;
    logic interleaved = 1'b0;
    logic single_write = 1'b0;

    logic burst_active = 1'b0;
    logic burst_write = 1'b0;
    logic [1:0] burst_bank;
    logic [7:0] burst_start;
    int burst_index;
    logic burst_precharge;

    logic [7:0] pipe_valid = 8'd0;
    logic [7:0][31:0] pipe_data = '0;
    logic [3:0] mask_delay = 4'd0;
    logic [31:0] beat_word = 32'd0;
    logic [3:0] beat_lanes = 4'd0;
    logic driving = 1'b0;

    int violations = 0;
    int warnings = 0;
    int commands = 0;
    int reads = 0;
    int writes = 0;
    int refreshes = 0;

    real setup_time = 1.5;
    real input_hold = 0.8;
    real inputs_changed = -1.0e9;
    real clock_rose = -1.0e9;
    real smallest_setup = 1.0e9;
    real smallest_hold = 1.0e9;
    real log_from = -1.0;
    real log_to = 0.0;

    task automatic Violation(input string text);
        violations++;
        if (violations <= REPORT_LIMIT) $display("SDRAM: %0t ps: %s", $time, text);
    endtask

    task automatic Warning(input string text);
        warnings++;
        if (warnings <= REPORT_LIMIT) $display("SDRAM: %0t ps: warning: %s", $time, text);
    endtask

    task automatic Report();
        $display("SDRAM: tAC %0.1f ns, tOH %0.1f ns, IO delay on the read path %0.1f ns", access_time, hold_time, path_delay);
        $display("SDRAM: smallest input setup %0.3f ns, smallest input hold %0.3f ns", smallest_setup, smallest_hold);
        $display("SDRAM: %0d commands, %0d read beats, %0d write beats, %0d refreshes, longest refresh gap %0.1f us",
            commands, reads, writes, refreshes, longest_refresh_gap / 1000.0);
        $display("SDRAM: %0d timing violations, %0d warnings (limits are typical SDR SDRAM values; the GW2AR die is not documented)",
            violations, warnings);
    endtask

    function automatic logic [20:0] Index(input logic [1:0] bank, input logic [10:0] row, input logic [7:0] column);
        return {bank, row, column};
    endfunction

    function automatic logic [7:0] BurstColumn(input logic [7:0] start, input int index);
        logic [7:0] base;
        logic [7:0] offset;

        if (burst_length >= 256) return start + 8'(index);
        base = start & ~8'(burst_length - 1);
        offset = interleaved ? ((start & 8'(burst_length - 1)) ^ 8'(index)) : ((start + 8'(index)) & 8'(burst_length - 1));
        return base | offset;
    endfunction

    function automatic real Now();
        return $realtime;
    endfunction

    task automatic Precharge(input int bank);
        if (!open[bank]) return;
        if (Now() - activated_at[bank] < ras) Violation($sformatf("tRAS: precharge of bank %0d %0.1f ns after activate (needs %0.1f ns)", bank, Now() - activated_at[bank], ras));
        if (Now() - written_at[bank] < wr) Violation($sformatf("tWR: precharge of bank %0d %0.1f ns after the last write (needs %0.1f ns)", bank, Now() - written_at[bank], wr));
        open[bank] = 1'b0;
        precharged_at[bank] = Now();
    endtask

    task automatic FinishBurst();
        if (burst_active && burst_precharge) begin
            if (burst_write) written_at[burst_bank] = Now();
            Precharge(burst_bank);
        end

        burst_active = 1'b0;
    endtask

    task automatic StartBurst(input logic write, input logic [1:0] bank, input logic [7:0] column, input logic precharge);
        if (!mode_set) Violation("read or write before the mode register was loaded");
        if (!open[bank]) Violation($sformatf("%s to bank %0d, which has no open row", write ? "WRITE" : "READ", bank));
        else if (Now() - activated_at[bank] < rcd) Violation($sformatf("tRCD: %s %0.1f ns after activate (needs %0.1f ns)", write ? "WRITE" : "READ", Now() - activated_at[bank], rcd));
        burst_active = 1'b1;
        burst_write = write;
        burst_bank = bank;
        burst_start = column;
        burst_index = 0;
        burst_precharge = precharge;
    endtask

    initial begin
        void'($value$plusargs("sdram_tac=%f", access_time));
        void'($value$plusargs("sdram_toh=%f", hold_time));
        void'($value$plusargs("sdram_delay=%f", path_delay));
        if ($value$plusargs("sdram_log_from_us=%f", log_from)) log_from = log_from * 1000.0;
        if ($value$plusargs("sdram_log_to_us=%f", log_to)) log_to = log_to * 1000.0;

        for (int i = 0; i < WORDS; i++) cells[i] = 32'd0;

        for (int i = 0; i < 4; i++) begin
            open[i] = 1'b0;
            open_row[i] = 11'd0;
            activated_at[i] = -1.0e9;
            precharged_at[i] = -1.0e9;
            written_at[i] = -1.0e9;
        end
    end

    always @(cs_n or ras_n or cas_n or we_n or ba or addr or dqm) begin
        if ($realtime - clock_rose < smallest_hold) smallest_hold = $realtime - clock_rose;
        if ($realtime - clock_rose < input_hold) Violation($sformatf("tIH: command or address changed %0.3f ns after the clock edge", $realtime - clock_rose));
        inputs_changed = $realtime;
    end

    always @(posedge clk) begin
        if (mode_set && $realtime - inputs_changed < smallest_setup) smallest_setup = $realtime - inputs_changed;
        if (mode_set && $realtime - inputs_changed < setup_time) Violation($sformatf("tIS: command or address changed %0.3f ns before the clock edge", $realtime - inputs_changed));
        clock_rose = $realtime;
    end

    always @(posedge clk) begin
        logic beat_valid;
        logic [31:0] beat_data;
        logic [3:0] beat_mask;
        logic [20:0] index;
        logic [31:0] value;

        beat_valid = pipe_valid[cas_latency - 2];
        beat_data = pipe_data[cas_latency - 2];
        beat_mask = mask_delay;

        pipe_valid = {pipe_valid[6:0], 1'b0};
        pipe_data = {pipe_data[6:0], 32'd0};
        mask_delay = dqm;

        if (log_from >= 0.0 && Now() >= log_from && Now() <= log_to && cke && !cs_n && {ras_n, cas_n, we_n} != 3'b111)
            $display("SDRAM LOG %0.3f us cmd %b%b%b ba %0d addr %03h dqm %b dq %h", Now() / 1000.0, ras_n, cas_n, we_n, ba, addr, dqm, dq);
        if (log_from >= 0.0 && Now() >= log_from && Now() <= log_to && beat_valid)
            $display("SDRAM LOG %0.3f us beat %h mask %b", Now() / 1000.0, beat_data, beat_mask);

        if (cke && !cs_n) begin
            case ({ras_n, cas_n, we_n})
                3'b111: ;
                3'b011: begin
                    commands++;
                    if (Now() < power_up) Warning("command before the 100 us power-up wait");
                    if (!mode_set) Violation("ACTIVE before the mode register was loaded");
                    if (open[ba]) Violation($sformatf("ACTIVE to bank %0d, which already has row %0d open", ba, open_row[ba]));
                    if (Now() - precharged_at[ba] < rp) Violation($sformatf("tRP: activate of bank %0d %0.1f ns after precharge (needs %0.1f ns)", ba, Now() - precharged_at[ba], rp));
                    if (Now() - activated_at[ba] < rc) Violation($sformatf("tRC: activate of bank %0d %0.1f ns after the previous one (needs %0.1f ns)", ba, Now() - activated_at[ba], rc));
                    if (Now() - refreshed_at < rfc) Violation($sformatf("tRFC: activate %0.1f ns after refresh (needs %0.1f ns)", Now() - refreshed_at, rfc));
                    open[ba] = 1'b1;
                    open_row[ba] = addr;
                    activated_at[ba] = Now();
                end
                3'b101: begin
                    commands++;
                    FinishBurst();
                    StartBurst(1'b0, ba, addr[7:0], addr[10]);
                end
                3'b100: begin
                    commands++;
                    FinishBurst();
                    StartBurst(1'b1, ba, addr[7:0], addr[10]);
                end
                3'b110: begin
                    commands++;
                    burst_active = 1'b0;
                end
                3'b010: begin
                    commands++;
                    if (burst_active && (addr[10] || burst_bank == ba)) burst_active = 1'b0;

                    for (int i = 0; i < 4; i++)
                        if (addr[10] || ba == 2'(i)) Precharge(i);
                end
                3'b001: begin
                    commands++;
                    refreshes++;
                    for (int i = 0; i < 4; i++) if (open[i]) Violation($sformatf("AUTO REFRESH while bank %0d is open", i));
                    for (int i = 0; i < 4; i++) if (Now() - precharged_at[i] < rp) Violation($sformatf("tRP: refresh %0.1f ns after precharge of bank %0d (needs %0.1f ns)", Now() - precharged_at[i], i, rp));
                    if (Now() - refreshed_at < rfc) Violation($sformatf("tRFC: refresh %0.1f ns after the previous one (needs %0.1f ns)", Now() - refreshed_at, rfc));
                    if (previous_refresh >= 0.0 && Now() - previous_refresh > longest_refresh_gap) longest_refresh_gap = Now() - previous_refresh;
                    if (previous_refresh >= 0.0 && Now() - previous_refresh > 9.0 * refresh_interval) Violation($sformatf("refresh gap of %0.1f us", (Now() - previous_refresh) / 1000.0));
                    previous_refresh = Now();
                    refreshed_at = Now();
                end
                3'b000: begin
                    commands++;
                    for (int i = 0; i < 4; i++) if (open[i]) Violation("LOAD MODE REGISTER while a bank is open");
                    mode_set = 1'b1;
                    burst_length = addr[2:0] == 3'd7 ? 256 : (1 << addr[2:0]);
                    interleaved = addr[3];
                    cas_latency = int'(addr[6:4]);
                    single_write = addr[9];
                    if (cas_latency != 2 && cas_latency != 3) Violation($sformatf("unsupported CAS latency %0d", cas_latency));
                    if (addr[2:0] > 3'd3 && addr[2:0] != 3'd7) Violation("reserved burst length");
                    $display("SDRAM: %0t ps: mode CL=%0d BL=%0d, %0s order, %0s writes", $time, cas_latency, burst_length, interleaved ? "interleaved" : "sequential", single_write ? "single" : "burst");
                end
            endcase
        end

        if (burst_active) begin
            index = Index(burst_bank, open_row[burst_bank], BurstColumn(burst_start, burst_index));

            if (burst_write) begin
                value = cells[index];
                for (int lane = 0; lane < 4; lane++) if (!dqm[lane]) value[lane * 8 +: 8] = dq[lane * 8 +: 8];
                if ($isunknown(value)) Warning($sformatf("write of unknown data to word %h", index));
                cells[index] = value;
                written_at[burst_bank] = Now();
                writes++;
            end else begin
                pipe_valid[0] = 1'b1;
                pipe_data[0] = cells[index];
                reads++;
            end

            burst_index++;
            if ((burst_write && single_write) || (burst_length < 256 && burst_index == burst_length)) FinishBurst();
        end

        if (beat_valid) begin
            beat_word = beat_data;
            beat_lanes = ~beat_mask;
            lanes <= #(path_delay + hold_time) beat_lanes;
            drive <= #(path_delay + hold_time) 32'bx;
            drive <= #(path_delay + access_time) beat_word;
            driving = 1'b1;
        end else if (driving) begin
            lanes <= #(path_delay + hold_time) 4'd0;
            driving = 1'b0;
        end
    end
endmodule
