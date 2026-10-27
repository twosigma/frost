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

// Clock generator for the AMD/Xilinx VCU118 Evaluation Board.
// Takes the 300 MHz differential SYSCLK1_300 input (G31/F31) and generates:
//   - Main CPU clock (100 MHz, 200 MHz, 240 MHz, 250 MHz, or 280 MHz; default 200 MHz)
//   - Divided clock by 4 for UART / JTAG loader (exact 1/4 of CPU clock)
module vcu118_clock #(
    parameter int unsigned CPU_CLK_HZ = 200_000_000
) (
    input  logic i_sysclk_p,
    input  logic i_sysclk_n,
    input  logic i_rst,

    output logic o_clk_cpu,
    output logic o_clk_div4,
    output logic o_clk_freerun_150,
    output logic o_locked
);

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

  // MMCM Parameter Calculation from 300 MHz input:
  // 100 MHz: Fin=300, D=1, M=4.000 -> FVCO=1200 MHz. Out0=12.000 (100 MHz), Out1=48 (25 MHz)
  // 200 MHz: Fin=300, D=1, M=4.000 -> FVCO=1200 MHz. Out0=6.000  (200 MHz), Out1=24 (50 MHz)
  // 240 MHz: Fin=300, D=1, M=4.000 -> FVCO=1200 MHz. Out0=5.000  (240 MHz), Out1=20 (60 MHz)
  // 250 MHz: Fin=300, D=3, M=10.000 -> FVCO=1000 MHz. Out0=4.000  (250 MHz), Out1=16 (62.5 MHz)
  // 280 MHz: Fin=300, D=3, M=14.000 -> FVCO=1400 MHz. Out0=5.000  (280 MHz), Out1=20 (70 MHz)
  localparam int unsigned DIVCLK_DIV = (CPU_CLK_HZ == 280_000_000) ? 3 :
                                       (CPU_CLK_HZ == 250_000_000) ? 3 :
                                       (CPU_CLK_HZ == 240_000_000) ? 1 : 1;
  localparam real CLKFBOUT_MULT      = (CPU_CLK_HZ == 280_000_000) ? 14.000 :
                                       (CPU_CLK_HZ == 250_000_000) ? 10.000 :
                                       (CPU_CLK_HZ == 240_000_000) ? 4.000  :
                                       (CPU_CLK_HZ == 200_000_000) ? 4.000  : 4.000;
  localparam real CLKOUT0_DIV        = (CPU_CLK_HZ == 280_000_000) ? 5.000 :
                                       (CPU_CLK_HZ == 250_000_000) ? 4.000 :
                                       (CPU_CLK_HZ == 240_000_000) ? 5.000 :
                                       (CPU_CLK_HZ == 200_000_000) ? 6.000 : 12.000;
  localparam int unsigned CLKOUT1_DIV = (CPU_CLK_HZ == 280_000_000) ? 20 :
                                        (CPU_CLK_HZ == 250_000_000) ? 16 :
                                        (CPU_CLK_HZ == 240_000_000) ? 20 :
                                        (CPU_CLK_HZ == 200_000_000) ? 24 : 48;

  MMCME4_ADV #(
      .BANDWIDTH         ("OPTIMIZED"),
      .CLKIN1_PERIOD     (3.333),           // 300 MHz input
      .DIVCLK_DIVIDE     (DIVCLK_DIV),
      .CLKFBOUT_MULT_F   (CLKFBOUT_MULT),
      .CLKFBOUT_PHASE    (0.0),
      .CLKOUT0_DIVIDE_F  (CLKOUT0_DIV),     // clk_cpu
      .CLKOUT0_PHASE     (0.0),
      .CLKOUT0_DUTY_CYCLE(0.5),
      .CLKOUT1_DIVIDE    (CLKOUT1_DIV),     // clk_div4 (CPU/4)
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

  BUFG u_bufg_fb   (.I(clkfb_mmcm),     .O(clkfb_mmcm_buf));
  BUFG u_bufg_cpu  (.I(clk_cpu_unbuf),  .O(o_clk_cpu));
  BUFG u_bufg_div4 (.I(clk_div4_unbuf), .O(o_clk_div4));

endmodule
