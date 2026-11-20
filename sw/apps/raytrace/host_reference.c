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
 * Host reference for the ray tracer: renders the same frame with the host's
 * integer arithmetic and prints its CRC, the value that raytrace.c checks.
 * Optionally writes the frame as a PPM image.
 *
 *   cc -O2 -o host_reference host_reference.c
 *   ./host_reference 76 44 1 [frame.ppm]
 */

#include <stdio.h>
#include <stdlib.h>

#include "render.h"

int main(int argc, char **argv)
{
    if (argc < 4) {
        fprintf(stderr, "usage: %s <width> <height> <samples: 1, 2 or 4> [frame.ppm]\n", argv[0]);
        return 2;
    }
    int width = atoi(argv[1]);
    int height = atoi(argv[2]);
    int samples = atoi(argv[3]);
    if (width <= 0 || height <= 0 || (samples != 1 && samples != 2 && samples != 4)) {
        fprintf(stderr, "width and height must be positive and samples 1, 2 or 4\n");
        return 2;
    }
    FILE *ppm = NULL;
    if (argc > 4) {
        ppm = fopen(argv[4], "wb");
        if (ppm == NULL) {
            perror(argv[4]);
            return 1;
        }
        fprintf(ppm, "P6\n%d %d\n255\n", width, height);
    }
    rt_camera_t cam;
    rt_init_tables();
    rt_setup(&cam, width, height, samples);
    uint32_t crc = 0xFFFFFFFFu;
    for (int y = 0; y < height; y++) {
        for (int x = 0; x < width; x++) {
            uint32_t rgb = rt_pixel(&cam, x, y);
            crc = rt_crc_pixel(crc, rgb);
            if (ppm != NULL) {
                fputc((int) ((rgb >> 16) & 255), ppm);
                fputc((int) ((rgb >> 8) & 255), ppm);
                fputc((int) (rgb & 255), ppm);
            }
        }
    }
    if (ppm != NULL) {
        fclose(ppm);
    }
    printf("%dx%d, %d per pixel: 0x%08x\n", width, height, samples, (unsigned) ~crc);
    return 0;
}
