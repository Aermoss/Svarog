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

module io #(
    parameter bit SIMULATION = 1'b1,
    parameter int CLK_FREQ = 54000000,
    parameter int CORES = 2,
    parameter int SPINLOCKS = 8
) (
    input logic clk,
    input logic rst,

    input logic [CORES - 1:0][31:0] address,
    input logic [CORES - 1:0] access,
    input logic [CORES - 1:0][3:0] write_enable,
    input logic [CORES - 1:0][31:0] write_data,
    input logic [CORES - 1:0] stall,
    input logic [CORES - 1:0][31:0] instret,
    output logic [CORES - 1:0][31:0] read_word,
    output logic [CORES - 1:0] read_hit,
    output logic [CORES - 1:0] conflict,

    output logic [CORES - 1:0][2:0] interrupts,
    output logic [31:0] cycle_counter,
    output logic [31:0] ms_counter,
    output logic [CORES - 1:0] core_running,
    output logic [31:0] core_entry,

    input logic uart_rx,
    output logic uart_tx,

    output logic sd_clk,
    output logic sd_mosi,
    input logic sd_miso,
    output logic sd_cs_n,

    input logic button,
    output logic [5:0] leds,
    output logic ws2812,

    output logic video_write,
    output logic [11:0] video_address,
    output logic [15:0] video_data,
    output logic [15:0] video_cursor,
    output logic [4:0] video_scroll
);
    localparam logic [31:0] UART_DATA = 32'hFFFF;
    localparam logic [31:0] UART_STATUS = 32'hFFFC;
    localparam logic [31:0] UART_DIVISOR = 32'hFFF8;
    localparam logic [31:0] BUTTON = 32'hFFF4;
    localparam logic [31:0] LEDS = 32'hFFF0;
    localparam logic [31:0] MILLISECONDS = 32'hFFEC;
    localparam logic [31:0] CYCLES = 32'hFFE8;
    localparam logic [31:0] INSTRUCTIONS = 32'hFFE4;
    localparam logic [31:0] WS2812 = 32'hFFE0;
    localparam logic [31:0] TIMER_COMPARE = 32'hFFDC;
    localparam logic [31:0] VIDEO_CURSOR = 32'hFFD0;
    localparam logic [31:0] VIDEO_SCROLL = 32'hFFCC;
    localparam logic [31:0] SPI_DATA = 32'hFFB8;
    localparam logic [31:0] SPI_CONTROL = 32'hFFB4;
    localparam logic [31:0] SPI_DIVISOR = 32'hFFB0;
    localparam logic [31:0] IPI_SEND = 32'hFFA8;
    localparam logic [31:0] IPI_CLEAR = 32'hFFA4;
    localparam logic [31:0] CORE_START = 32'hFFA0;
    localparam logic [31:0] SPINLOCK_BASE = 32'hFF80;

    function automatic logic in_io_space(logic [31:0] value);
        return value[31:8] == 24'h0000FF || value[31:14] == 18'd2;
    endfunction

    function automatic logic is_spinlock(logic [31:0] value);
        return value[31:5] == SPINLOCK_BASE[31:5] && value[1:0] == 2'b00 && value[4:2] < SPINLOCKS;
    endfunction

    logic [CORES - 1:0] requesting;
    logic [CORES - 1:0] active;
    logic [$clog2(CORES > 1 ? CORES : 2) - 1:0] owner;

    always_comb begin
        for (int c = 0; c < CORES; c++)
            requesting[c] = access[c] && in_io_space(address[c]);

        conflict = '0;

        for (int c = 1; c < CORES; c++)
            for (int other = 0; other < c; other++)
                if (requesting[c] && requesting[other])
                    conflict[c] = 1'b1;

        owner = '0;

        for (int c = CORES - 1; c >= 0; c--)
            if (requesting[c])
                owner = c;

        for (int c = 0; c < CORES; c++)
            active[c] = requesting[c] && !stall[c];
    end

    wire selected = |active;
    wire [31:0] io_address = address[owner];
    wire [31:0] io_data = write_data[owner];
    wire [3:0] io_we = selected ? write_enable[owner] : 4'b0000;
    wire io_read = selected && write_enable[owner] == 4'b0000;
    wire io_write = io_we != 4'b0000;

    logic [7:0] uart_tx_data;
    logic [15:0] uart_clks_per_bit;
    logic [7:0] uart_rx_byte;
    logic uart_rx_ready;
    logic uart_tx_busy;

    always_comb begin
        if (io_we[3]) uart_tx_data = io_data[31:24];
        else if (io_we[2]) uart_tx_data = io_data[23:16];
        else if (io_we[1]) uart_tx_data = io_data[15:8];
        else uart_tx_data = io_data[7:0];
    end

    uart #(
        .CLK_FREQ(CLK_FREQ),
        .ECHO(SIMULATION)
    ) console_uart0 (
        .clk(clk),
        .rst(rst),
        .write(io_address == UART_DATA && io_write),
        .write_data(uart_tx_data),
        .read(io_address == UART_DATA && io_read),
        .read_data(uart_rx_byte),
        .rx_ready(uart_rx_ready),
        .tx_busy(uart_tx_busy),
        .divisor_write(io_address == UART_DIVISOR && io_write),
        .divisor_data(io_data[15:0]),
        .divisor(uart_clks_per_bit),
        .rx_pin(uart_rx),
        .tx_pin(uart_tx)
    );

    logic [21:0] tick_divider;

    localparam int TICK_MAX = (CLK_FREQ / 1000) - 1;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            ms_counter <= 0;
            tick_divider <= 0;
        end else if (tick_divider >= TICK_MAX) begin
            tick_divider <= 0;
            ms_counter <= ms_counter + 32'd1;
        end else begin
            tick_divider <= tick_divider + 22'd1;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            cycle_counter <= 0;
        else
            cycle_counter <= cycle_counter + 32'd1;
    end

    logic [CORES - 1:0][31:0] timer_compare;
    logic [CORES - 1:0] timer_pending;
    logic [CORES - 1:0] ipi_pending;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            timer_compare <= '0;
            timer_pending <= '0;
            ipi_pending <= '0;
        end else begin
            for (int c = 0; c < CORES; c++) begin
                if (active[c] && write_enable[c] != 4'b0000 && address[c] == TIMER_COMPARE)
                    timer_compare[c] <= write_data[c];

                timer_pending[c] <= $signed(cycle_counter - timer_compare[c]) >= 0;
            end

            if (io_write && io_address == IPI_CLEAR)
                ipi_pending[owner] <= 1'b0;

            if (io_write && io_address == IPI_SEND)
                ipi_pending <= ipi_pending | io_data[CORES - 1:0];
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            interrupts <= '0;
        end else begin
            for (int c = 0; c < CORES; c++)
                interrupts[c] <= {ipi_pending[c], c == 0 ? uart_rx_ready : 1'b0, timer_pending[c]};
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            core_running <= 1;
            core_entry <= '0;
        end else if (io_write && io_address == CORE_START && CORES > 1) begin
            core_entry <= io_data;
            core_running <= {CORES{1'b1}};
        end
    end

    logic [SPINLOCKS - 1:0] spinlocks;
    wire [2:0] spinlock_index = io_address[4:2];

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            spinlocks <= '0;
        else if (is_spinlock(io_address) && io_write)
            spinlocks[spinlock_index] <= 1'b0;
        else if (is_spinlock(io_address) && io_read)
            spinlocks[spinlock_index] <= 1'b1;
    end

    logic button_sync0, button_sync1;

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            button_sync0 <= 1'b0;
            button_sync1 <= 1'b0;
        end else begin
            button_sync0 <= button;
            button_sync1 <= button_sync0;
        end
    end

    always_ff @(posedge clk or posedge rst) begin
        if (rst)
            leds <= 6'h3F;
        else if (io_address == LEDS && io_write)
            leds <= io_data[5:0];
    end

    wire in_text_window = io_address[31:14] == 18'd2;

    assign video_write = in_text_window && io_write;
    assign video_address = io_address[13:2];
    assign video_data = io_data[15:0];

    always_ff @(posedge clk or posedge rst) begin
        if (rst) begin
            video_cursor <= 0;
            video_scroll <= 0;
        end else if (io_address == VIDEO_CURSOR && io_write) begin
            video_cursor <= io_data[15:0];
        end else if (io_address == VIDEO_SCROLL && io_write) begin
            video_scroll <= io_data[4:0];
        end
    end

    ws2812 #(
        .CLK_FREQ(CLK_FREQ)
    ) ws2812_0 (
        .clk(clk),
        .rst(rst),
        .strobe(io_address == WS2812 && io_write),
        .write(io_data[23:0]),
        .busy(),
        .out(ws2812)
    );

    logic [7:0] spi_read_data;
    logic [4:0] spi_status;
    logic [7:0] spi_divisor;

    spi sd_spi0 (
        .clk(clk),
        .rst(rst),
        .data_write(io_address == SPI_DATA && io_write),
        .write_data(io_data[7:0]),
        .read_data(spi_read_data),
        .control_write(io_address == SPI_CONTROL && io_write),
        .control_data(io_data[4:0]),
        .status(spi_status),
        .divisor_write(io_address == SPI_DIVISOR && io_write),
        .divisor_data(io_data[7:0]),
        .divisor(spi_divisor),
        .sclk(sd_clk),
        .mosi(sd_mosi),
        .miso(sd_miso),
        .cs_n(sd_cs_n)
    );

    logic [CORES - 1:0] spinlock_free;
    logic [CORES - 1:0] in_text;
    genvar lane;

    generate
        for (lane = 0; lane < CORES; lane++) begin : decode
            wire [31:0] lane_address = address[lane];

            assign spinlock_free[lane] = !spinlocks[lane_address[4:2]];
            assign in_text[lane] = lane_address[31:14] == 18'd2;
        end
    endgenerate

    always_comb begin
        for (int c = 0; c < CORES; c++) begin
            read_hit[c] = 1'b1;

            case (address[c])
                UART_DATA: read_word[c] = {4{uart_rx_byte}};
                UART_STATUS: read_word[c] = {30'b0, uart_tx_busy, uart_rx_ready};
                UART_DIVISOR: read_word[c] = {16'b0, uart_clks_per_bit};
                MILLISECONDS: read_word[c] = ms_counter;
                BUTTON: read_word[c] = {31'b0, button_sync1};
                CYCLES: read_word[c] = cycle_counter;
                INSTRUCTIONS: read_word[c] = instret[c];
                TIMER_COMPARE: read_word[c] = timer_compare[c];
                VIDEO_CURSOR: read_word[c] = {16'b0, video_cursor};
                VIDEO_SCROLL: read_word[c] = {27'b0, video_scroll};
                SPI_DATA: read_word[c] = {24'b0, spi_read_data};
                SPI_CONTROL: read_word[c] = {27'b0, spi_status};
                SPI_DIVISOR: read_word[c] = {24'b0, spi_divisor};
                IPI_SEND: read_word[c] = {31'b0, ipi_pending[c]};
                CORE_START: read_word[c] = CORES;
                default: begin
                    if (is_spinlock(address[c])) begin
                        read_word[c] = {31'b0, spinlock_free[c]};
                    end else begin
                        read_word[c] = 0;
                        read_hit[c] = in_text[c];
                    end
                end
            endcase
        end
    end
endmodule
