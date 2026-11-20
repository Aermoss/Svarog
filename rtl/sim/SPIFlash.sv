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

module SPIFlash (
    input logic sck,
    input logic cs_n,
    input logic mosi,
    output wire miso
);
    localparam int BYTES = 8388608;
    localparam logic [23:0] JEDEC_ID = 24'hEF4017;

    real output_valid = 7.0;
    real read_limit = 50.0;

    logic [7:0] memory [0:BYTES - 1];
    logic [7:0] incoming = 8'd0;
    logic [7:0] outgoing = 8'hFF;
    logic [7:0] opcode = 8'd0;
    logic [23:0] address = 24'd0;
    int bit_count = 0;
    int byte_count = 0;
    int out_bits = 8;
    logic send_bit = 1'b1;
    logic miso_value = 1'b1;
    logic miso_enable = 1'b0;
    logic write_enable = 1'b0;
    logic data_phase = 1'b0;
    real last_rise = -1.0;
    real fastest = 1.0e9;
    int reads = 0;
    int warnings = 0;

    initial begin
        string path;
        int offset;
        int file;
        int count;

        for (int i = 0; i < BYTES; i++) memory[i] = 8'hFF;

        if ($value$plusargs("flash=%s", path)) begin
            if (!$value$plusargs("flash_offset=%d", offset)) offset = 32'h100000;
            file = $fopen(path, "rb");

            if (file == 0) begin
                $display("FLASH: cannot open %s", path);
            end else begin
                count = $fread(memory, file, offset);
                $fclose(file);
                $display("FLASH: loaded %0d bytes of %s at 0x%06x", count, path, offset);
            end
        end
    end

    task automatic Warning(input string text);
        warnings++;
        if (warnings <= 10) $display("FLASH: %0t ps: warning: %s", $time, text);
    endtask

    task automatic Report();
        $display("FLASH: %0d bytes read, fastest clock %0.1f MHz, %0d warnings", reads, fastest < 1.0e9 ? 1000.0 / fastest : 0.0, warnings);
    endtask

    function automatic logic [7:0] Next();
        logic [7:0] value;
        value = 8'hFF;

        case (opcode)
            8'h03, 8'h0B: begin
                if (data_phase) begin
                    value = memory[address];
                    address = address + 24'd1;
                    reads++;
                end
            end
            8'h9F: value = byte_count >= 1 && byte_count <= 3 ? JEDEC_ID[8 * (3 - byte_count) +: 8] : 8'hFF;
            8'h05: value = {6'd0, write_enable, 1'b0};
            8'hAB: value = byte_count >= 4 ? 8'h16 : 8'hFF;
            default: value = 8'hFF;
        endcase

        return value;
    endfunction

    task automatic Erase(input logic [23:0] start, input int length);
        if (!write_enable) begin
            Warning("erase without write enable");
            return;
        end

        for (int i = 0; i < length; i++) memory[(start & ~24'(length - 1)) + 24'(i)] = 8'hFF;
        write_enable = 1'b0;
    endtask

    assign miso = miso_enable ? miso_value : 1'bz;

    always @(negedge cs_n) begin
        bit_count = 0;
        byte_count = 0;
        data_phase = 1'b0;
        opcode = 8'd0;
        out_bits = 8;
        outgoing = 8'hFF;
    end

    always @(posedge cs_n) begin
        miso_enable <= #(output_valid) 1'b0;

        case (opcode)
            8'h06: write_enable = 1'b1;
            8'h04: write_enable = 1'b0;
            8'h20: if (byte_count == 4) Erase(address, 4096);
            8'h52: if (byte_count == 4) Erase(address, 32768);
            8'hD8: if (byte_count == 4) Erase(address, 65536);
            8'hC7, 8'h60: if (byte_count == 1) Erase(24'd0, BYTES);
            8'h02: write_enable = 1'b0;
            default: ;
        endcase
    end

    always @(posedge sck) begin
        if (!cs_n) begin
            if (last_rise >= 0.0 && $realtime - last_rise < fastest) fastest = $realtime - last_rise;
            if (opcode == 8'h03 && data_phase && last_rise >= 0.0 && 1000.0 / ($realtime - last_rise) > read_limit + 0.5)
                Warning($sformatf("READ (03h) clocked at %0.1f MHz, above the %0.1f MHz limit", 1000.0 / ($realtime - last_rise), read_limit));
            last_rise = $realtime;
            incoming = {incoming[6:0], mosi};
            bit_count++;

            if (bit_count == 8) begin
                bit_count = 0;

                if (byte_count == 0) begin
                    opcode = incoming;
                end else if ((opcode == 8'h03 || opcode == 8'h0B || opcode == 8'h02 || opcode == 8'h20 || opcode == 8'h52 || opcode == 8'hD8) && byte_count <= 3) begin
                    address = {address[15:0], incoming};
                    if (byte_count == 3 && opcode == 8'h03) data_phase = 1'b1;
                end else if (opcode == 8'h0B && byte_count == 4) begin
                    data_phase = 1'b1;
                end else if (opcode == 8'h02 && byte_count >= 4) begin
                    if (write_enable) memory[address] = memory[address] & incoming;
                    else Warning("page program without write enable");
                    address = {address[23:8], address[7:0] + 8'd1};
                end

                byte_count++;
            end
        end else begin
            last_rise = -1.0;
        end
    end

    always @(negedge sck) begin
        if (!cs_n) begin
            if (out_bits == 8) begin
                if (bit_count == 0) begin
                    outgoing = Next();
                    out_bits = 1;
                    send_bit = outgoing[7];
                    miso_value <= #(output_valid) send_bit;
                    miso_enable <= #(output_valid) 1'b1;
                end
            end else begin
                send_bit = outgoing[7 - out_bits];
                miso_value <= #(output_valid) send_bit;
                out_bits++;
            end
        end
    end
endmodule
