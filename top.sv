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

module top (
    input logic clk,
    input logic rst,

    input logic uart_rx,
    output logic uart_tx,

    output logic sd_clk,
    output logic sd_mosi,
    input logic sd_miso,
    output logic sd_cs_n,

    input logic button,
    output logic [5:0] leds,
    output logic ws2812,

    output logic tmds_clk_p,
    output logic tmds_clk_n,
    output logic [2:0] tmds_d_p,
    output logic [2:0] tmds_d_n,

    output wire spi_cs_pin,
    output wire spi_clk_pin,
    output wire spi_mosi_pin,
    input wire spi_miso_pin,

    output logic O_sdram_clk,
    output logic O_sdram_cke,
    output logic O_sdram_cs_n,
    output logic O_sdram_cas_n,
    output logic O_sdram_ras_n,
    output logic O_sdram_wen_n,
    output logic [3:0] O_sdram_dqm,
    output logic [10:0] O_sdram_addr,
    output logic [1:0] O_sdram_ba,
    inout wire [31:0] IO_sdram_dq
);
    logic sys_clk;
    logic sdram_clk;
    logic pll_lock;

    Gowin_rPLL pll0 (
        .clkin(clk),
        .reset(rst),
        .clkout(sys_clk),
        .clkoutp(sdram_clk),
        .lock(pll_lock)
    );

    logic rst_reg;
    logic [7:0] counter = 8'd0;

    always_ff @(posedge sys_clk) begin
        if (!pll_lock) begin
            counter <= 8'd0;
            rst_reg <= 1'b1;
        end else if (counter < 8'hFF) begin
            counter <= counter + 8'd1;
            rst_reg <= 1'b1;
        end else begin
            rst_reg <= rst;
        end
    end

    localparam int CLK_FREQ = 54000000;

    logic video_write;
    logic [11:0] video_address;
    logic [15:0] video_data;
    logic [15:0] video_cursor;
    logic [4:0] video_scroll;

    logic flash_req;
    logic [23:0] flash_addr;
    logic [31:0] flash_rdata;
    logic flash_ready;

    logic sdram_start;
    logic sdram_write;
    logic [1:0] sdram_length;
    logic [20:0] sdram_address;
    logic [31:0] sdram_data;
    logic [3:0] sdram_dqm;
    logic sdram_ready;
    logic sdram_valid;
    logic [31:0] sdram_read_data;

    system #(
        .SIMULATION(1'b0),
        .CLK_FREQ(CLK_FREQ)
    ) system0 (
        .clk(sys_clk),
        .rst(rst_reg),

        .uart_rx(uart_rx),
        .uart_tx(uart_tx),

        .sd_clk(sd_clk),
        .sd_mosi(sd_mosi),
        .sd_miso(sd_miso),
        .sd_cs_n(sd_cs_n),

        .button(button),
        .leds(leds),
        .ws2812(ws2812),

        .video_write(video_write),
        .video_address(video_address),
        .video_data(video_data),
        .video_cursor(video_cursor),
        .video_scroll(video_scroll),

        .flash_req(flash_req),
        .flash_addr(flash_addr),
        .flash_rdata(flash_rdata),
        .flash_ready(flash_ready),

        .sdram_start(sdram_start),
        .sdram_write(sdram_write),
        .sdram_length(sdram_length),
        .sdram_address(sdram_address),
        .sdram_data(sdram_data),
        .sdram_dqm(sdram_dqm),
        .sdram_ready(sdram_ready),
        .sdram_valid(sdram_valid),
        .sdram_read_data(sdram_read_data)
    );

    logic sdrc_cmd_en;
    logic [2:0] sdrc_cmd;
    logic [20:0] sdrc_addr;
    logic [3:0] sdrc_dqm;
    logic [31:0] sdrc_data_w;
    logic [31:0] sdrc_data_r;
    logic sdrc_init_done;
    logic sdrc_cmd_ack;
    logic [7:0] sdrc_data_len;

    SDRAM_Controller_HS_Top sdrc0 (
        .O_sdram_clk(O_sdram_clk),
        .O_sdram_cke(O_sdram_cke),
        .O_sdram_cs_n(O_sdram_cs_n),
        .O_sdram_cas_n(O_sdram_cas_n),
        .O_sdram_ras_n(O_sdram_ras_n),
        .O_sdram_wen_n(O_sdram_wen_n),
        .O_sdram_dqm(O_sdram_dqm),
        .O_sdram_addr(O_sdram_addr),
        .O_sdram_ba(O_sdram_ba),
        .IO_sdram_dq(IO_sdram_dq),

        .I_sdrc_rst_n(~rst_reg),
        .I_sdrc_clk(sys_clk),
        .I_sdram_clk(sdram_clk),
        .I_sdrc_cmd_en(sdrc_cmd_en),
        .I_sdrc_cmd(sdrc_cmd),
        .I_sdrc_precharge_ctrl(1'b1),
        .I_sdram_power_down(1'b0),
        .I_sdram_selfrefresh(1'b0),
        .I_sdrc_addr(sdrc_addr),
        .I_sdrc_dqm(sdrc_dqm),
        .I_sdrc_data(sdrc_data_w),
        .I_sdrc_data_len(sdrc_data_len),
        .O_sdrc_data(sdrc_data_r), 
        .O_sdrc_init_done(sdrc_init_done),
        .O_sdrc_cmd_ack(sdrc_cmd_ack)
    );

    video video0 (
        .clk(clk),
        .cpu_clk(sys_clk),
        .rst(rst_reg),
        .text_write(video_write),
        .text_address(video_address),
        .text_data(video_data),
        .cursor(video_cursor),
        .scroll(video_scroll),
        .tmds_clk_p(tmds_clk_p),
        .tmds_clk_n(tmds_clk_n),
        .tmds_d_p(tmds_d_p),
        .tmds_d_n(tmds_d_n)
    );

    flash flash0 (
        .clk(sys_clk),
        .rst(rst_reg),
        .flash_req(flash_req),
        .flash_addr(flash_addr),
        .flash_rdata(flash_rdata),
        .flash_ready(flash_ready),
        .flash_cs(spi_cs_pin),
        .flash_sck(spi_clk_pin),
        .flash_mosi(spi_mosi_pin),
        .flash_miso(spi_miso_pin)
    );

    sdram #(
        .CLK_FREQ(CLK_FREQ)
    ) sdram0 (
        .clk(sys_clk),
        .rst(rst_reg),

        .start(sdram_start),
        .write(sdram_write),
        .length(sdram_length),
        .address(sdram_address),
        .data(sdram_data),
        .dqm(sdram_dqm),
        .ready(sdram_ready),
        .read_valid(sdram_valid),
        .read_data(sdram_read_data),

        .sdrc_cmd_en(sdrc_cmd_en),
        .sdrc_cmd(sdrc_cmd),
        .sdrc_addr(sdrc_addr),
        .sdrc_data_w(sdrc_data_w),
        .sdrc_dqm(sdrc_dqm),
        .sdrc_data_len(sdrc_data_len),
        .sdrc_data_r(sdrc_data_r),
        .sdrc_init_done(sdrc_init_done),
        .sdrc_cmd_ack(sdrc_cmd_ack)
    );
endmodule
