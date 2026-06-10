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
 * FROST simulation-only CoreMark-PRO cjpeg wrapper.
 *
 * The official cjpeg-rose7-preset workload uses the Rose256 image and seven
 * work items. That is appropriate for score/certification builds, but much too
 * large for routine cycle-accurate simulation. This wrapper keeps the upstream
 * cjpeg kernel and MITH reporting path, but feeds it a tiny generated BMP and
 * verifies the resulting JPEG by CRC.
 */

#include "al_smp.h"
#include "algo.h"
#include "mith_workload.h"
#include "th_lib.h"

#define FROST_CJPEG_WIDTH 8
#define FROST_CJPEG_HEIGHT 8
#define FROST_CJPEG_BMP_HEADER_SIZE 54
#define FROST_CJPEG_ROW_STRIDE (((FROST_CJPEG_WIDTH * 3) + 3) & ~3)
#define FROST_CJPEG_BMP_SIZE                                                                       \
    (FROST_CJPEG_BMP_HEADER_SIZE + FROST_CJPEG_ROW_STRIDE * FROST_CJPEG_HEIGHT)
#define FROST_CJPEG_OUT_ALLOC 1024

#define FROST_CJPEG_EXPECTED_SIZE 647
#define FROST_CJPEG_EXPECTED_CRC 0x8537u

typedef struct {
    cjpparam_t cjpeg;
    int owns_input;
} frost_cjpeg_params_t;

static const version_number frost_cjpeg_bm_ver = BM_VERSION;

static void put_le16(e_u8 *p, e_u16 v)
{
    p[0] = (e_u8) (v & 0xffu);
    p[1] = (e_u8) ((v >> 8) & 0xffu);
}

static void put_le32(e_u8 *p, e_u32 v)
{
    p[0] = (e_u8) (v & 0xffu);
    p[1] = (e_u8) ((v >> 8) & 0xffu);
    p[2] = (e_u8) ((v >> 16) & 0xffu);
    p[3] = (e_u8) ((v >> 24) & 0xffu);
}

static void fill_tiny_bmp(e_u8 *bmp)
{
    th_memset(bmp, 0, FROST_CJPEG_BMP_SIZE);

    bmp[0] = 'B';
    bmp[1] = 'M';
    put_le32(&bmp[2], FROST_CJPEG_BMP_SIZE);
    put_le32(&bmp[10], FROST_CJPEG_BMP_HEADER_SIZE);
    put_le32(&bmp[14], 40);
    put_le32(&bmp[18], FROST_CJPEG_WIDTH);
    put_le32(&bmp[22], FROST_CJPEG_HEIGHT);
    put_le16(&bmp[26], 1);
    put_le16(&bmp[28], 24);
    put_le32(&bmp[34], FROST_CJPEG_ROW_STRIDE * FROST_CJPEG_HEIGHT);
    put_le32(&bmp[38], 2835);
    put_le32(&bmp[42], 2835);

    for (int row = 0; row < FROST_CJPEG_HEIGHT; row++) {
        int y = FROST_CJPEG_HEIGHT - 1 - row;
        e_u8 *dst = &bmp[FROST_CJPEG_BMP_HEADER_SIZE + row * FROST_CJPEG_ROW_STRIDE];
        for (int x = 0; x < FROST_CJPEG_WIDTH; x++) {
            dst[x * 3 + 0] = (e_u8) (16 + x * 23 + y * 3);
            dst[x * 3 + 1] = (e_u8) (24 + y * 25);
            dst[x * 3 + 2] = (e_u8) (40 + x * 11 + y * 13);
        }
    }
}

size_t cjpeg_fread(void *buf, size_t sizeofbuf, cjpparam_t *params)
{
    size_t return_size;

    if (params->inFile_size < params->inFile_idx + (int) sizeofbuf) {
        return_size = (size_t) (params->inFile_size - params->inFile_idx);
    } else {
        return_size = sizeofbuf;
    }

    th_memcpy(buf, &params->inFile_p[params->inFile_idx], return_size);
    params->inFile_idx += (int) return_size;
    return return_size;
}

size_t cjpeg_fwrite(const void *buf, size_t sizeofbuf, cjpparam_t *params)
{
    size_t return_size;

    if (params->outFile_size < params->outFile_idx + (int) sizeofbuf) {
        return_size = (size_t) (params->outFile_size - params->outFile_idx);
        th_printf("ERROR: frost cjpeg output buffer overflow\n");
    } else {
        return_size = sizeofbuf;
    }

    th_memcpy(&params->outFile_p[params->outFile_idx], buf, return_size);
    params->outFile_idx += (int) return_size;
    return return_size;
}

static void fill_tcdef_cjpeg(TCDef *tcdef)
{
    th_strcpy(tcdef->eembc_bm_id, BM_ID);
    th_strcpy(tcdef->member, EEMBC_MEMBER_COMPANY);
    th_strcpy(tcdef->processor, EEMBC_PROCESSOR);
    th_strcpy(tcdef->platform, EEMBC_TARGET);
    th_strcpy(tcdef->desc, BM_DESCRIPTION);
    tcdef->revision = TCDEF_REVISION;
    tcdef->bm_vnum = frost_cjpeg_bm_ver;
    tcdef->rec_iterations = 1;
    tcdef->expected_CRC = FROST_CJPEG_EXPECTED_CRC;
}

static void *define_params_cjpeg_tiny(void)
{
    frost_cjpeg_params_t *params =
        (frost_cjpeg_params_t *) th_calloc(1, sizeof(frost_cjpeg_params_t));

    params->cjpeg.idx = 0;
    params->cjpeg.default_in_name = "frost_tiny_8x8.bmp";
    params->cjpeg.default_out_name = "frost_tiny_8x8.jpg";
    params->cjpeg.inFile_size = FROST_CJPEG_BMP_SIZE;
    params->cjpeg.outFile_crcsize = FROST_CJPEG_OUT_ALLOC;
    params->cjpeg.outFile_size = FROST_CJPEG_OUT_ALLOC;
    params->cjpeg.inFile_p = (e_u8 *) th_malloc(FROST_CJPEG_BMP_SIZE);
    params->owns_input = 1;
    fill_tiny_bmp(params->cjpeg.inFile_p);

    th_printf("frost_tiny_8x8.bmp data generated in memory\n");
    th_printf(">> Data Set                 : %s\n", params->cjpeg.default_in_name);
    th_printf(">> Output File              : %s\n", params->cjpeg.default_out_name);

    return params;
}

static void *bmark_init_cjpeg_tiny(void *in_params)
{
    frost_cjpeg_params_t *orig = (frost_cjpeg_params_t *) in_params;
    frost_cjpeg_params_t *params;

    if (orig == NULL) {
        return NULL;
    }

    params = (frost_cjpeg_params_t *) th_malloc(sizeof(frost_cjpeg_params_t));
    th_memcpy(params, orig, sizeof(frost_cjpeg_params_t));
    params->owns_input = 0;
    params->cjpeg.inFile_idx = 0;
    params->cjpeg.outFile_idx = 0;
    params->cjpeg.outFile_size = FROST_CJPEG_OUT_ALLOC;
    params->cjpeg.outFile_p = (e_u8 *) th_malloc(FROST_CJPEG_OUT_ALLOC);
    if (params->cjpeg.outFile_p == NULL) {
        th_printf("ERROR: Failed allocating output buffer for frost cjpeg\n");
    }
    return params;
}

static void *bmark_fini_cjpeg_tiny(void *in_params)
{
    frost_cjpeg_params_t *params = (frost_cjpeg_params_t *) in_params;

    if (params == NULL) {
        return NULL;
    }
    if (params->cjpeg.outFile_p != NULL) {
        th_free(params->cjpeg.outFile_p);
    }
    th_free(params);
    return NULL;
}

static void *t_run_test_cjpeg_tiny(struct TCDef *tcdef, void *in_params)
{
    frost_cjpeg_params_t *params = (frost_cjpeg_params_t *) in_params;
    LoopCount loop_cnt;
    int rv = 0;
    char *outname;
    e_u32 override;

    tcdef->expected_CRC = 0;
    override = tcdef->iterations;
    fill_tcdef_cjpeg(tcdef);
    if (override != 0) {
        tcdef->iterations = override;
    } else {
        tcdef->iterations = tcdef->rec_iterations;
    }

    for (loop_cnt = 0; loop_cnt < tcdef->iterations && rv == 0; loop_cnt++) {
        rv += cjpeg_main(&outname, &params->cjpeg);
    }

    if (verify_output == 0) {
        tcdef->CRC = tcdef->expected_CRC;
    }

    tcdef->actual_iterations = loop_cnt;
    tcdef->v1 = (size_t) rv;
    tcdef->v2 = (size_t) params->cjpeg.outFile_size;
    tcdef->v3 = 0;
    tcdef->v4 = 0;
    return NULL;
}

static int bmark_verify_cjpeg_tiny(void *in_params)
{
    frost_cjpeg_params_t *params = (frost_cjpeg_params_t *) in_params;
    e_u16 crc = 0;

    if (params == NULL) {
        return 0;
    }

    for (int i = 0; i < params->cjpeg.outFile_size; i++) {
        crc = Calc_crc8((e_u8) params->cjpeg.outFile_p[i], crc);
    }
    params->cjpeg.cjpeg_CRC = crc;

    if (params->cjpeg.outFile_size != FROST_CJPEG_EXPECTED_SIZE ||
        crc != FROST_CJPEG_EXPECTED_CRC) {
        th_printf("ERROR: frost cjpeg tiny size=%d crc=0x%04x exp_size=%d exp_crc=0x%04x\n",
                  params->cjpeg.outFile_size,
                  crc,
                  FROST_CJPEG_EXPECTED_SIZE,
                  FROST_CJPEG_EXPECTED_CRC);
        return 0;
    }

    return 1;
}

static int bmark_clean_cjpeg_tiny(void *in_params)
{
    frost_cjpeg_params_t *params = (frost_cjpeg_params_t *) in_params;

    if (params != NULL) {
        if (params->owns_input && params->cjpeg.inFile_p != NULL) {
            th_free(params->cjpeg.inFile_p);
        }
        if (params->cjpeg.outFile_p != NULL) {
            th_free(params->cjpeg.outFile_p);
        }
        th_free(params);
    }
    return 0;
}

static void add_cjpeg_item(ee_workload *workload, void *params, char *name)
{
    ee_work_item_t *item;

    if (params == NULL) {
        th_exit(1, "Error when trying to define benchmark params");
    }

    item = mith_item_init(1);
    item->params = params;
    th_strncpy(item->shortname, name, MITH_MAX_NAME - 1);
    item->shortname[MITH_MAX_NAME - 1] = '\0';
    item->init_func = bmark_init_cjpeg_tiny;
    item->fini_func = bmark_fini_cjpeg_tiny;
    item->veri_func = bmark_verify_cjpeg_tiny;
    item->bench_func = t_run_test_cjpeg_tiny;
    item->cleanup = bmark_clean_cjpeg_tiny;
    item->num_contexts = 1;
    item->kernel_id = 466733417u;
    item->instance_id = 128872101u;
    mith_wl_add(workload, item);
}

int main(int argc, char *argv[])
{
    char name[MITH_MAX_NAME];
    char *hardware_desc;
    e_u32 num_contexts = 1;
    e_u32 num_workers = 0;
    e_u32 oversubscribe_allowed = 1;
    ee_workload *workload;
    void *params;

    al_main(argc, argv);

    workload = mith_wl_init(1);
    th_strncpy(workload->shortname, "cjpeg-rose7-preset", MITH_MAX_NAME);
    workload->rev_M = 1;
    workload->rev_m = 1;
    workload->uid = 236760500u;
    workload->iterations = 1;

    {
        e_s32 stmp;
        th_parse_flag_unsigned(argc, argv, "-i", &workload->iterations);
        th_parse_flag_unsigned(argc, argv, "-c", &num_contexts);
        th_parse_flag_unsigned(argc, argv, "-w", &num_workers);
        th_parse_flag_unsigned(argc, argv, "-o", &oversubscribe_allowed);
        th_parse_flag_unsigned(argc, argv, "-v", &verify_output);
        th_parse_flag_unsigned(argc, argv, "-V", &reporting_threshold);
        if (th_parse_flag(argc, argv, "-pgo=", &stmp)) {
            pgo_training_run = stmp;
        }
    }

    if (th_get_flag(argc, argv, "-P=", &hardware_desc)) {
        al_set_hardware_info(hardware_desc);
    }

    th_strncpy(name, "cjpeg-tiny", MITH_MAX_NAME);
    params = define_params_cjpeg_tiny();
    add_cjpeg_item(workload, params, name);

    mith_main(workload, workload->iterations, num_contexts, oversubscribe_allowed, num_workers);
    return 0;
}
