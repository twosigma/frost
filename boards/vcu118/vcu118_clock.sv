/*
 *    Copyright 2026 John Goodacre
 *
 *    Licensed under the Apache License, Version 2.0 (the "License");
 *    you may not use this file except in compliance with the License.
 *    You may obtain a copy of the License at
 *
 *        http://www.apache.org/licenses/LICENSE-2.0
 *
 *    Unless required by applicable law or agreed to in writing, software
 *    distributed under the License is distributed on an "AS IS" BASIS,
 *    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 *    See the License for the specific language governing permissions and
 *    limitations under the License.
 */

// The board MMCM generates CPU and CPU/4 clocks from SYSCLK1_300.
module vcu118_clock #(
    parameter int unsigned CPU_CLK_HZ = 200_000_000
) (
    input logic i_sysclk_p,
    input logic i_sysclk_n,
    input logic i_rst,

    output logic o_clk_cpu,
    output logic o_clk_div4,
    output logic o_clk_freerun_150,
    output logic o_locked
);

  initial begin
    case (CPU_CLK_HZ)
      100_000_000, 200_000_000, 240_000_000, 250_000_000, 280_000_000: begin
      end
      default: $fatal(1, "vcu118_clock: unsupported CPU_CLK_HZ");
    endcase
  end

  logic sysclk_300_ibuf, sysclk_300_bufg;

  IBUFDS #(
      .DIFF_TERM   ("FALSE"),
      .IBUF_LOW_PWR("FALSE")
  ) u_ibuf_sysclk (
      .I (i_sysclk_p),
      .IB(i_sysclk_n),
      .O (sysclk_300_ibuf)
  );

  BUFG u_bufg_in (
      .I(sysclk_300_ibuf),
      .O(sysclk_300_bufg)
  );

  BUFGCE_DIV #(
      .BUFGCE_DIVIDE  (2),
      .IS_CE_INVERTED (1'b0),
      .IS_CLR_INVERTED(1'b0),
      .IS_I_INVERTED  (1'b0)
  ) u_bufg_freerun_150 (
      .O  (o_clk_freerun_150),
      .CE (1'b1),
      .CLR(1'b0),
      .I  (sysclk_300_ibuf)
  );

  logic clkfb_mmcm, clkfb_mmcm_buf;
  logic clk_cpu_unbuf, clk_div4_unbuf;

  localparam int unsigned DivclkDiv = (CPU_CLK_HZ == 280_000_000) ? 3 :
                                       (CPU_CLK_HZ == 250_000_000) ? 3 :
                                       (CPU_CLK_HZ == 240_000_000) ? 1 : 1;
  localparam real ClkfboutMult      = (CPU_CLK_HZ == 280_000_000) ? 14.000 :
                                       (CPU_CLK_HZ == 250_000_000) ? 10.000 :
                                       (CPU_CLK_HZ == 240_000_000) ? 4.000  :
                                       (CPU_CLK_HZ == 200_000_000) ? 4.000  : 4.000;
  localparam real Clkout0Div        = (CPU_CLK_HZ == 280_000_000) ? 5.000 :
                                       (CPU_CLK_HZ == 250_000_000) ? 4.000 :
                                       (CPU_CLK_HZ == 240_000_000) ? 5.000 :
                                       (CPU_CLK_HZ == 200_000_000) ? 6.000 : 12.000;
  localparam int unsigned Clkout1Div = (CPU_CLK_HZ == 280_000_000) ? 20 :
                                        (CPU_CLK_HZ == 250_000_000) ? 16 :
                                        (CPU_CLK_HZ == 240_000_000) ? 20 :
                                        (CPU_CLK_HZ == 200_000_000) ? 24 : 48;

  MMCME4_ADV #(
      .BANDWIDTH         ("OPTIMIZED"),
      .CLKIN1_PERIOD     (3.333),
      .DIVCLK_DIVIDE     (DivclkDiv),
      .CLKFBOUT_MULT_F   (ClkfboutMult),
      .CLKFBOUT_PHASE    (0.0),
      .CLKOUT0_DIVIDE_F  (Clkout0Div),    // clk_cpu
      .CLKOUT0_PHASE     (0.0),
      .CLKOUT0_DUTY_CYCLE(0.5),
      .CLKOUT1_DIVIDE    (Clkout1Div),    // clk_div4 (CPU/4)
      .CLKOUT1_PHASE     (0.0),
      .CLKOUT1_DUTY_CYCLE(0.5),
      .STARTUP_WAIT      ("FALSE")
  ) u_mmcm (
      .CLKIN1   (sysclk_300_bufg),
      .CLKIN2   (1'b0),
      .CLKINSEL (1'b1),
      .CLKFBIN  (clkfb_mmcm_buf),
      .CLKFBOUT (clkfb_mmcm),
      .CLKFBOUTB(),
      .CLKOUT0  (clk_cpu_unbuf),
      .CLKOUT0B (),
      .CLKOUT1  (clk_div4_unbuf),
      .CLKOUT1B (),
      .CLKOUT2  (),
      .CLKOUT2B (),
      .CLKOUT3  (),
      .CLKOUT3B (),
      .CLKOUT4  (),
      .CLKOUT5  (),
      .CLKOUT6  (),
      .LOCKED   (o_locked),
      .PWRDWN   (1'b0),
      .RST      (i_rst),
      .CDDCREQ  (1'b0),
      .CDDCDONE ()
  );

  BUFG u_bufg_fb (
      .I(clkfb_mmcm),
      .O(clkfb_mmcm_buf)
  );
  BUFG u_bufg_cpu (
      .I(clk_cpu_unbuf),
      .O(o_clk_cpu)
  );
  BUFG u_bufg_div4 (
      .I(clk_div4_unbuf),
      .O(o_clk_div4)
  );

endmodule
