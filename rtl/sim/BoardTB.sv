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

`define CORE dut.system0.core_0
`define MEMORY dut.system0.memory_0
`define CLOCK dut.sys_clk

module BoardTB;
    logic clk = 1'b0;
    logic rst = 1'b0;
    logic button = 1'b0;
    logic uart_rx = 1'b1;

    always #18.518519 clk = ~clk;

    GSR GSR (.GSRI(1'b1));

    wire uart_tx;
    wire sd_clk;
    wire sd_mosi;
    wire sd_miso;
    wire sd_cs_n;
    wire [5:0] leds;
    wire ws2812;
    wire tmds_clk_p;
    wire tmds_clk_n;
    wire [2:0] tmds_d_p;
    wire [2:0] tmds_d_n;
    wire spi_cs;
    wire spi_clk;
    wire spi_mosi;
    wire spi_miso;
    wire sdram_clk;
    wire sdram_cke;
    wire sdram_cs_n;
    wire sdram_cas_n;
    wire sdram_ras_n;
    wire sdram_we_n;
    wire [3:0] sdram_dqm;
    wire [10:0] sdram_addr;
    wire [1:0] sdram_ba;
    wire [31:0] sdram_dq;

    pullup (sd_miso);
    pullup (spi_miso);

    Top dut (
        .clk(clk),
        .rst(rst),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .sd_clk(sd_clk),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n),
        .button(button),
        .leds(leds),
        .ws2812(ws2812),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p),
        .tmds_d_n(tmds_d_n),
        .spi_cs_pin(spi_cs),
        .spi_clk_pin(spi_clk),
        .spi_mosi_pin(spi_mosi),
        .spi_miso_pin(spi_miso),
        .O_sdram_clk(sdram_clk),
        .O_sdram_cke(sdram_cke),
        .O_sdram_cs_n(sdram_cs_n),
        .O_sdram_cas_n(sdram_cas_n),
        .O_sdram_ras_n(sdram_ras_n),
        .O_sdram_wen_n(sdram_we_n),
        .O_sdram_dqm(sdram_dqm),
        .O_sdram_addr(sdram_addr),
        .O_sdram_ba(sdram_ba),
        .IO_sdram_dq(sdram_dq)
    );

    SDRAMChip sdram (
        .clk(sdram_clk),
        .cke(sdram_cke),
        .cs_n(sdram_cs_n),
        .ras_n(sdram_ras_n),
        .cas_n(sdram_cas_n),
        .we_n(sdram_we_n),
        .ba(sdram_ba),
        .addr(sdram_addr),
        .dqm(sdram_dqm),
        .dq(sdram_dq)
    );

    SPIFlash flash (.sck(spi_clk), .cs_n(spi_cs), .mosi(spi_mosi), .miso(spi_miso));
    SDCard card (.sck(sd_clk), .cs_n(sd_cs_n), .mosi(sd_mosi), .miso(sd_miso));

    real bit_time = 1.0e9 / 115200.0;
    real timeout = 400000000.0;
    string stop_text = "";
    string keys = "";
    string after_text = "";
    string recent = "";
    logic keys_sent = 1'b0;
    logic line_start = 1'b1;
    string pending = "";
    logic log_leds = 1'b0;
    int trace_file = 0;
    longint cycles = 0;
    int halted_cycles = 0;
    int framing_errors = 0;

    localparam int SCREEN_WIDTH = 640;
    localparam int SCREEN_HEIGHT = 480;

    string screen_path = "";
    logic [23:0] screen [0:SCREEN_WIDTH * SCREEN_HEIGHT - 1];
    int screen_x = 0;
    int screen_y = 0;
    int screen_frames = 0;
    int screen_errors = 0;
    logic screen_line = 1'b0;
    logic screen_vsync = 1'b1;
    logic screen_synced = 1'b0;
    string screen_problem = "";

    real light_rise = 0.0;
    real light_fall = -1.0e9;
    int light_bits = 0;
    int light_colors = 0;
    int light_errors = 0;
    logic [23:0] light_value = 24'd0;

    task automatic Finish(input string reason);
        $display("\n%s cycles=%0d instret=%0d time_us=%0.1f", reason, cycles, `CORE.instret_counter, $realtime / 1000.0);
        if (pending.len() > 0) $write("%s", pending);
        if (framing_errors != 0) $display("UART: %0d framing errors", framing_errors);
        if (screen_path.len() > 0) $display("SCREEN: %0d frames, %0d bad lines or frames%s, the last frame is in %s", screen_frames, screen_errors, screen_problem, screen_path);
        if (light_colors != 0 || light_errors != 0) $display("WS2812: %0d colors, %0d pulses out of spec", light_colors, light_errors);
        sdram.Report();
        flash.Report();
        card.Report();
        if (trace_file != 0) $fclose(trace_file);
        $finish;
    endtask

    function automatic string Unescape(input string text);
        string result;
        result = "";

        for (int i = 0; i < text.len(); i++) begin
            if (text.getc(i) == 8'd92 && i + 1 < text.len() && text.getc(i + 1) == "r") begin
                result = $sformatf("%s%c", result, 8'd13);
                i++;
            end else if (text.getc(i) == 8'd92 && i + 1 < text.len() && text.getc(i + 1) == "n") begin
                result = $sformatf("%s%c", result, 8'd10);
                i++;
            end else begin
                result = $sformatf("%s%c", result, text.getc(i));
            end
        end

        return result;
    endfunction

    function automatic logic EndsWith(input string text, input string suffix);
        if (suffix.len() == 0 || suffix.len() > text.len()) return 1'b0;
        return text.substr(text.len() - suffix.len(), text.len() - 1) == suffix;
    endfunction

    task automatic SendKeys();
        for (int i = 0; i < keys.len(); i++) begin
            logic [7:0] value;
            value = keys.getc(i);
            uart_rx = 1'b0;
            #(bit_time);

            for (int b = 0; b < 8; b++) begin
                uart_rx = value[b];
                #(bit_time);
            end

            uart_rx = 1'b1;
            #(2.0 * bit_time);
        end
    endtask

    task automatic Note(input string text);
        if (line_start) $display("%s", text);
        else pending = {pending, text, "\n"};
    endtask

    task automatic Console(input logic [7:0] value);
        $write("%c", value);
        line_start = value == 8'd10;

        if (line_start && pending.len() > 0) begin
            $write("%s", pending);
            pending = "";
        end

        $fflush();
        recent = $sformatf("%s%c", recent, value);
        if (recent.len() > 256) recent = recent.substr(recent.len() - 128, recent.len() - 1);

        if (!keys_sent && keys.len() > 0 && (after_text.len() == 0 || EndsWith(recent, after_text))) begin
            keys_sent = 1'b1;
            fork SendKeys(); join_none
        end

        if (EndsWith(recent, stop_text)) Finish("STOPPED");
    endtask

    always begin
        logic [7:0] value;
        @(negedge uart_tx);
        #(1.5 * bit_time);

        for (int b = 0; b < 8; b++) begin
            value[b] = uart_tx;
            #(bit_time);
        end

        if (uart_tx !== 1'b1) framing_errors++;
        Console(value);
    end

    always @(posedge `CLOCK) begin
        cycles <= cycles + 1;

        if (`CORE.trace_retire) begin
            if ($isunknown(`CORE.trace_pc) || (`CORE.trace_rd != 0 && $isunknown(`CORE.trace_value)) || $isunknown(`CORE.trace_store_mask) ||
                (`CORE.trace_store_mask != 0 && $isunknown(`CORE.trace_store_data))) begin
                $display("\nUNKNOWN VALUE COMMITTED pc=%h rd=%0d value=%h store=%h/%h", `CORE.trace_pc, `CORE.trace_rd, `CORE.trace_value,
                    `CORE.trace_store_data, `CORE.trace_store_mask);
                Finish("FAILED");
            end

            if (trace_file != 0)
                $fwrite(trace_file, "R %08x %02x %08x %08x %08x %x\n", `CORE.trace_pc, `CORE.trace_rd, `CORE.trace_value,
                    `CORE.trace_store_address & 32'hFFFFFFFC, `CORE.trace_store_data, `CORE.trace_store_mask);
        end

        if (`CORE.trace_trap && trace_file != 0)
            $fwrite(trace_file, "X %08x %08x %08x\n", `CORE.trace_cause, `CORE.trace_pc, `CORE.trace_address);

        if (`CORE.halted) halted_cycles <= halted_cycles + 1;
        if (halted_cycles == 8) Finish("HALTED");
    end

    always @(leds) if (log_leds) Note($sformatf("LEDS %06b at %0.1f us", ~leds, $realtime / 1000.0));

    always @(posedge ws2812) begin
        if ($realtime - light_fall > 50000.0) light_bits = 0;
        light_rise = $realtime;
    end

    always @(negedge ws2812) begin
        real high;
        high = $realtime - light_rise;
        light_fall = $realtime;
        if (!((high >= 250.0 && high <= 550.0) || (high >= 650.0 && high <= 950.0))) light_errors++;
        light_value = {light_value[22:0], high > 600.0};
        light_bits++;

        if (light_bits == 24) begin
            light_colors++;
            light_bits = 0;
            if (log_leds) Note($sformatf("WS2812 #%02x%02x%02x at %0.1f us", light_value[15:8], light_value[23:16], light_value[7:0], $realtime / 1000.0));
        end
    end

    function automatic logic [7:0] DecodeTMDS(input logic [9:0] symbol);
        logic [7:0] data;
        logic [7:0] value;
        data = symbol[9] ? ~symbol[7:0] : symbol[7:0];
        value[0] = data[0];
        for (int i = 1; i < 8; i++) value[i] = symbol[8] ? data[i] ^ data[i - 1] : !(data[i] ^ data[i - 1]);
        return value;
    endfunction

    function automatic int ControlCode(input logic [9:0] symbol);
        case (symbol)
            10'b1101010100: return 0;
            10'b0010101011: return 1;
            10'b0101010100: return 2;
            10'b1010101011: return 3;
            default: return -1;
        endcase
    endfunction

    task automatic SaveScreen();
        int file;
        screen_frames++;
        file = $fopen(screen_path, "wb");

        if (file == 0) begin
            $display("SCREEN: cannot write %s", screen_path);
            return;
        end

        $fwrite(file, "P6\n%0d %0d\n255\n", SCREEN_WIDTH, SCREEN_HEIGHT);
        for (int i = 0; i < SCREEN_WIDTH * SCREEN_HEIGHT; i++) $fwrite(file, "%c%c%c", screen[i][23:16], screen[i][15:8], screen[i][7:0]);
        $fclose(file);
    endtask

    task automatic ScreenProblem(input string text);
        if (screen_errors == 0) screen_problem = $sformatf(" (the first is %s at %0.1f us)", text, $realtime / 1000.0);
        screen_errors++;
    endtask

    task automatic ScreenSymbol(input logic [9:0] red, input logic [9:0] green, input logic [9:0] blue);
        int control;
        control = ControlCode(blue);

        if (control < 0) begin
            if (!screen_line) begin
                screen_line = 1'b1;
                screen_x = 0;
            end

            if (screen_x < SCREEN_WIDTH && screen_y < SCREEN_HEIGHT) screen[screen_y * SCREEN_WIDTH + screen_x] = {DecodeTMDS(red), DecodeTMDS(green), DecodeTMDS(blue)};
            screen_x++;
        end else begin
            if (screen_line) begin
                screen_line = 1'b0;
                if (screen_synced && screen_x != SCREEN_WIDTH) ScreenProblem($sformatf("a line of %0d pixels at line %0d", screen_x, screen_y));
                screen_y++;
            end

            if (screen_vsync && !control[1]) begin
                if (screen_synced && screen_y == SCREEN_HEIGHT) SaveScreen();
                else if (screen_synced) ScreenProblem($sformatf("a frame of %0d lines", screen_y));
                screen_synced = 1'b1;
                screen_y = 0;
            end

            screen_vsync = control[1];
        end
    endtask

    task automatic WatchScreen();
        logic [9:0] red;
        logic [9:0] green;
        logic [9:0] blue;
        logic [9:0] clock;
        red = 10'd0;
        green = 10'd0;
        blue = 10'd0;
        clock = 10'd0;
        wait (dut.video_pll_lock === 1'b1);

        forever begin
            @(dut.serial_clk);
            red = {tmds_d_p[2], red[9:1]};
            green = {tmds_d_p[1], green[9:1]};
            blue = {tmds_d_p[0], blue[9:1]};
            clock = {tmds_clk_p, clock[9:1]};
            if (clock == 10'b1111100000) ScreenSymbol(red, green, blue);
        end
    endtask

    initial begin
        real start;
        real sdram_edge;
        real next;
        wait (dut.pll0_lock === 1'b1);
        repeat (100) @(posedge `CLOCK);
        @(posedge `CLOCK);
        start = $realtime;
        @(posedge sdram_clk);
        sdram_edge = $realtime;
        @(posedge `CLOCK);
        next = $realtime;
        $display("CLOCKS: sys_clk period %0.3f ns, SDRAM clock rises %0.3f ns after sys_clk", next - start, sdram_edge - start);
    end

    initial begin
        string path;
        real timeout_us;
        int baud;

        if ($value$plusargs("timeout_us=%f", timeout_us)) timeout = timeout_us * 1000.0;
        if ($value$plusargs("baud=%d", baud)) bit_time = 1.0e9 / baud;
        if ($value$plusargs("stop=%s", stop_text)) stop_text = Unescape(stop_text);
        if ($value$plusargs("keys=%s", keys)) keys = Unescape(keys);
        if ($value$plusargs("after=%s", after_text)) after_text = Unescape(after_text);
        log_leds = $test$plusargs("leds");
        if ($value$plusargs("screen=%s", screen_path)) fork WatchScreen(); join_none

        if ($value$plusargs("trace=%s", path)) begin
            trace_file = $fopen(path, "w");
            if (trace_file == 0) $display("cannot write the trace file %s", path);
        end

        for (int i = 0; i < 16384; i++) `MEMORY.icache_ways[i] = 1'b0;

        for (int i = 0; i < 128; i++) begin
            `MEMORY.vtags0[i] = 6'd0;
            `MEMORY.vtags1[i] = 6'd0;
        end

        #(timeout);
        Finish("TIMEOUT");
    end
endmodule
