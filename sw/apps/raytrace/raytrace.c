/*
 *    Copyright 2026 Two Sigma Open Source, LLC
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

/*
 * Ray tracer: renders the scene (scene_sunset.inc) in fixed-point arithmetic and
 * sends each pixel row to the UART as soon as it is finished. A coarse pass
 * comes first: one pixel in every RT_COARSE x RT_COARSE block, so that a
 * viewer sees the whole picture early; the full pass reuses those pixels.
 *
 * Output, one line per item:
 *   "FROST ray tracer <W>x<H>"            header
 *   "C<row> <4 characters per block>"     one coarse row, for pixel rows
 *                                         <row> to <row> + RT_COARSE - 1:
 *                                         the pixel at the top left of each
 *                                         block of RT_COARSE columns
 *   "P<row> <4 x W characters>"           one pixel row; each pixel is four
 *                                         base64 digits of its 24 bits:
 *                                         8-bit red, green and blue channels
 *   "Frame CRC-32 0x........ ..."         self-check against the reference
 *   "<<PASS>>" or "<<FAIL>>"
 *
 * The CRC covers the quantized frame (three bytes a pixel) only, so it depends on the program and
 * the arithmetic, never on timing. host_reference.c computes the
 * reference values below; RAYTRACE_SIZE in the Makefile selects the size.
 */

#include <stdint.h>

#include "mmio.h"
#include "render.h"
#include "uart.h"

#ifndef RT_WIDTH
#define RT_WIDTH 64
#endif
#ifndef RT_HEIGHT
#define RT_HEIGHT 36
#endif
#ifndef RT_SAMPLES
#define RT_SAMPLES 1
#endif
#define RT_COARSE 4
#define RT_COARSE_W ((RT_WIDTH + RT_COARSE - 1) / RT_COARSE)
#define RT_COARSE_H ((RT_HEIGHT + RT_COARSE - 1) / RT_COARSE)

typedef struct {
    int width;
    int height;
    int samples;
    uint32_t crc;
} rt_reference_t;

/* Frame CRCs from host_reference.c for each size the Makefile offers. */
static const rt_reference_t rt_references[] = {
    {76, 44, 1, 0x7d3f7e65u},
    {24, 12, 1, 0xfce9da14u},
};

/*
 * Empty functions that mark where the picture's rendering begins and ends.
 * They must stay real calls: the demonstration's simulator run reads their
 * addresses from the program's symbols (demo/make_regions.py) to count the
 * rendering apart from start-up and from sending the picture. uart_send and
 * uart_tx_ready are likewise kept as functions so that their address range
 * can be left out of that count.
 */
__attribute__((noinline)) void rt_mark_render_start(void)
{
    __asm__ volatile("");
}

__attribute__((noinline)) void rt_mark_render_end(void)
{
    __asm__ volatile("");
}

/*
 * Send len bytes. The transmit status stays ready while at least 64 more
 * bytes fit in the transmit FIFO, so one status check covers a burst of 48.
 */
__attribute__((noinline)) static void uart_send(const char *buf, int len)
{
    int i = 0;
    while (i < len) {
        while (!uart_tx_ready()) {
        }
        int end = i + 48 < len ? i + 48 : len;
        for (; i < end; i++) {
            UART_TX = (uint8_t) buf[i];
        }
    }
}

/* Append the four base64 digits of a 24-bit pixel to line at n; returns the new length. */
static int put_pixel(char *line, int n, uint32_t rgb)
{
    line[n++] = rt_digits[(rgb >> 18) & 63];
    line[n++] = rt_digits[(rgb >> 12) & 63];
    line[n++] = rt_digits[(rgb >> 6) & 63];
    line[n++] = rt_digits[rgb & 63];
    return n;
}

static int put_row_label(char *line, char kind, int y)
{
    line[0] = kind;
    line[1] = (char) ('0' + (y / 10) % 10);
    line[2] = (char) ('0' + y % 10);
    line[3] = ' ';
    return 4;
}

int main(void)
{
    static char line[4 + 4 * RT_WIDTH + 2];
    static uint32_t coarse[RT_COARSE_H][RT_COARSE_W];
    rt_camera_t cam;
    rt_init_tables();
    rt_setup(&cam, RT_WIDTH, RT_HEIGHT, RT_SAMPLES);

    uart_printf("FROST ray tracer %dx%d\n", RT_WIDTH, RT_HEIGHT);

    rt_mark_render_start();
    for (int cy = 0; cy < RT_COARSE_H; cy++) {
        int n = put_row_label(line, 'C', cy * RT_COARSE);
        for (int cx = 0; cx < RT_COARSE_W; cx++) {
            uint32_t rgb = rt_pixel(&cam, cx * RT_COARSE, cy * RT_COARSE);
            coarse[cy][cx] = rgb;
            n = put_pixel(line, n, rgb);
        }
        line[n++] = '\r';
        line[n++] = '\n';
        uart_send(line, n);
    }

    uint32_t crc = 0xFFFFFFFFu;
    for (int y = 0; y < RT_HEIGHT; y++) {
        int n = put_row_label(line, 'P', y);
        for (int x = 0; x < RT_WIDTH; x++) {
            uint32_t rgb = (x % RT_COARSE == 0 && y % RT_COARSE == 0)
                               ? coarse[y / RT_COARSE][x / RT_COARSE]
                               : rt_pixel(&cam, x, y);
            crc = rt_crc_pixel(crc, rgb);
            n = put_pixel(line, n, rgb);
        }
        line[n++] = '\r';
        line[n++] = '\n';
        uart_send(line, n);
    }
    rt_mark_render_end();
    crc = ~crc;

    uint32_t expected = 0;
    int known = 0;
    for (unsigned i = 0; i < sizeof(rt_references) / sizeof(rt_references[0]); i++) {
        if (rt_references[i].width == RT_WIDTH && rt_references[i].height == RT_HEIGHT &&
            rt_references[i].samples == RT_SAMPLES) {
            expected = rt_references[i].crc;
            known = 1;
        }
    }
    if (known && crc == expected) {
        uart_printf("Frame CRC-32 0x%08x matches the reference.\n<<PASS>>\n", (unsigned) crc);
    } else if (known) {
        uart_printf("Frame CRC-32 0x%08x does not match the reference 0x%08x.\n<<FAIL>>\n",
                    (unsigned) crc,
                    (unsigned) expected);
    } else {
        uart_printf("Frame CRC-32 0x%08x: no reference for this size.\n<<FAIL>>\n", (unsigned) crc);
    }

    for (;;) {
    }
}
