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

/**
 * Packet Parser - FIX Protocol Message Parser Demo
 *
 * Demonstrates parsing of FIX (Financial Information eXchange) protocol
 * messages received via MMIO FIFOs. Reads tag/value pairs, constructs
 * structured message objects, and measures parsing latency in clock cycles.
 *
 * This is a simplified version intended to demonstrate:
 *   - MMIO FIFO communication
 *   - FIX timestamp and price parsing
 *   - Low-latency message processing on FROST
 */
#include "fifo.h"
#include "fix.h"
#include "stdlib.h"
#include "string.h"
#include "timer.h"
#include "uart.h"
#include <stdbool.h>
#include <stddef.h> /* For size_t */
#include <stdint.h>

#define CLOCK_PERIOD_PS 3103


/* Versioned packet types produced by the parser */
typedef uint8_t packet_v1_msg_type_t;
typedef uint8_t packet_v1_venue_t;
typedef uint8_t packet_v1_display_t;
typedef uint8_t packet_v1_currency_t;
typedef uint8_t packet_v1_line_setter_status_t;

typedef struct __attribute__((packed)) {
    uint16_t len;
    packet_v1_msg_type_t msg_type;
} packet_v1_msg_header_t;

typedef struct __attribute__((packed)) {
    int64_t amount;
    uint8_t scale;
} packet_v1_quantity_t;

typedef fix_price_t packet_v1_price_t;

typedef struct __attribute__((packed)) {
    uint16_t offset;
    uint16_t length;
} dma_vardata_t;

typedef struct __attribute__((packed)) {
    packet_v1_msg_header_t msg_header;
    packet_v1_venue_t venue_id;
    uint32_t order_id;
    uint16_t line_id;
    uint64_t mapped_order_id;
    uint64_t venue_transx_timestamp;
    uint64_t venue_sent_timestamp;
    uint64_t ts_receive;
    packet_v1_quantity_t accepted_quantity;
    packet_v1_price_t accepted_price;
    packet_v1_price_t display_price;
    packet_v1_display_t accepted_display;
    dma_vardata_t accepted_order_id;
    packet_v1_currency_t currency;
    packet_v1_line_setter_status_t line_setter_status;
} packet_v1_venue_accepted_t;

typedef struct __attribute__((packed)) {
    uint8_t sac_id;
    uint32_t order_id;
    uint8_t bump_id;
    uint8_t reserved[2];
} bump_bfcp_v1_venue_global_mapped_order_id_t;


/* Simple string buffer for parsing */
#define MAX_STRING_LEN 64
typedef struct {
    char data[MAX_STRING_LEN];
    uint8_t len;
} string_buffer_t;

/* Extract client order ID from mapped order ID structure */
static uint32_t extract_client_order_id(uint64_t mapped_order_id)
{
    /* The order_id field is at bytes 1-4 of the 8-byte mapped_order_id */
    /* Memory layout: sac_id(1 byte) | order_id(4 bytes) | bump_id(1 byte) | reserved(2 bytes) */
    return (uint32_t) ((mapped_order_id >> 8) & 0xFFFFFFFF);
}

/* Read a string from FIFO (simplified version for embedded system) */
static inline uint32_t fifo_read_word(int fifo_id)
{
    uint32_t chunk = (fifo_id == 0) ? fifo0_read() : fifo1_read();
    /* Give MMIO read data a cycle to settle before consumption. */
    asm volatile("nop");
    return chunk;
}

static bool read_string_from_fifo(int fifo_id, string_buffer_t *str)
{
    uint32_t chunk;

    /* Read first chunk to get length */
    chunk = fifo_read_word(fifo_id);

    uint8_t wire_len = chunk & 0xFF;
    if (wire_len == 0) {
        return false;
    }

    uint8_t stored_len = wire_len < MAX_STRING_LEN ? wire_len : MAX_STRING_LEN - 1;
    str->len = stored_len;
    int consumed = 0;
    int stored = 0;
    int chunk_idx = 1;

    /* Copy the first three payload bytes from the length word. Even when the
     * local buffer truncates an oversized value, consume its full wire length
     * so the next FIFO read starts at the next string boundary. */
    while (chunk_idx < 4 && consumed < wire_len) {
        if (stored < stored_len)
            str->data[stored++] = (chunk >> (chunk_idx * 8)) & 0xFF;
        consumed++;
        chunk_idx++;
    }

    /* Read additional chunks as needed */
    while (consumed < wire_len) {
        chunk = fifo_read_word(fifo_id);

        for (int i = 0; i < 4 && consumed < wire_len; i++) {
            if (stored < stored_len)
                str->data[stored++] = (chunk >> (i * 8)) & 0xFF;
            consumed++;
        }
    }

    str->data[stored_len] = '\0';
    return true;
}


/* Parse venue accepted message */
static void drain_fifo_pairs(void)
{
    string_buffer_t key_buf, val_buf;

    for (int i = 0; i < 128; i++) {
        bool has_key = read_string_from_fifo(0, &key_buf);
        bool has_val = read_string_from_fifo(1, &val_buf);

        if (!has_key && !has_val) {
            return;
        }
    }
}

static packet_v1_venue_accepted_t parse_venue_accepted(bool *ok, bool *fix_version_ok)
{
    packet_v1_venue_accepted_t msg;
    string_buffer_t key_buf, val_buf;
    bool success = true;
    bool fix_ok = true;

    /* Initialize message */
    memset(&msg, 0, sizeof(msg));
    msg.currency = 1; /* USD */

    /* Process FIX tags from FIFOs */
    while (true) {
        bool has_key = read_string_from_fifo(0, &key_buf);
        bool has_val = read_string_from_fifo(1, &val_buf);

        /* Should be in sync */
        if (has_key != has_val) {
            success = false;
            break;
        }

        if (!has_key) {
            break;
        }

        int tag = atoi(key_buf.data);

        switch (tag) {
            case FIX_TAG_BEGIN_STRING:
                /* Verify FIX version */
                if (strcmp(val_buf.data, "FIX.4.2") != 0) {
                    fix_ok = false;
                }
                break;

            case FIX_TAG_BODY_LENGTH:
                /* Not used */
                break;

            case FIX_TAG_CL_ORDER_ID:
                /* Map "400" to predefined mapped order ID */
                if (strcmp(val_buf.data, "400") == 0) {
                    /* The mapped order ID for "400" is 0x10000000400 = 1099511628800 */
                    /* On 32-bit system, build it carefully */
                    uint64_t high = 0x100;     /* Upper 32 bits */
                    uint64_t low = 0x00000400; /* Lower 32 bits */
                    msg.mapped_order_id = (high << 32) | low;
                    msg.order_id = extract_client_order_id(msg.mapped_order_id);
                }
                break;

            case FIX_TAG_MSG_TYPE:
                if (strcmp(val_buf.data, "8") == 0) {
                    msg.msg_header.msg_type = 38; /* venue accepted */
                    msg.msg_header.len = sizeof(packet_v1_venue_accepted_t);
                }
                break;

            case FIX_TAG_ORDER_ID:
                msg.accepted_order_id.offset = 0;
                msg.accepted_order_id.length = val_buf.len;
                break;

            case FIX_TAG_ORDER_QTY:
                msg.accepted_quantity.amount = atoi(val_buf.data);
                msg.accepted_quantity.scale = 0;
                break;

            case FIX_TAG_PRICE:
                msg.accepted_price = parse_price(val_buf.data);
                msg.display_price = msg.accepted_price;
                break;

            case FIX_TAG_SENDER_COMP_ID:
                if (strcmp(val_buf.data, "ICE") == 0) {
                    msg.venue_id = 76; /* ICE_LIFFE_FUTURES_FIX4_2 */
                }
                break;

            case FIX_TAG_SENDING_TIME:
                msg.venue_sent_timestamp = parse_timestamp(val_buf.data);
                break;

            case FIX_TAG_TRANSACT_TIME:
                msg.venue_transx_timestamp = parse_timestamp(val_buf.data);
                break;
        }
    }

    if (ok) {
        *ok = success;
    }
    if (fix_version_ok) {
        *fix_version_ok = fix_ok;
    }
    return msg;
}

/* Write string to FIFO with length prefix */
static void write_string_to_fifo(int fifo_id, const char *str)
{
    uint32_t chunk = 0;
    int len = strlen(str);

    /* First byte is length */
    chunk = len & 0xFF;
    int chunk_idx = 1;
    int str_idx = 0;

    /* Pack string into 4-byte chunks */
    while (str_idx < len) {
        if (chunk_idx == 4) {
            /* Write current chunk */
            if (fifo_id == 0) {
                fifo0_write(chunk);
            } else {
                fifo1_write(chunk);
            }
            chunk = 0;
            chunk_idx = 0;
        }

        chunk |= ((uint32_t) (str[str_idx] & 0xFF)) << (chunk_idx * 8);
        chunk_idx++;
        str_idx++;
    }

    /* Write final chunk if needed */
    if (chunk_idx > 0) {
        if (fifo_id == 0) {
            fifo0_write(chunk);
        } else {
            fifo1_write(chunk);
        }
    }
}

/* Verify that truncating an oversized local string does not leave unread wire
 * bytes behind to corrupt the following length-prefixed string. */
static bool test_oversized_fifo_string(void)
{
    static const char oversized[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-overflow";
    static const char expected_prefix[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-";
    string_buffer_t truncated;
    string_buffer_t following;

    write_string_to_fifo(0, oversized);
    write_string_to_fifo(0, "next");

    bool has_truncated = read_string_from_fifo(0, &truncated);
    bool has_following = read_string_from_fifo(0, &following);
    return has_truncated && has_following && truncated.len == MAX_STRING_LEN - 1 &&
           strcmp(truncated.data, expected_prefix) == 0 && following.len == 4 &&
           strcmp(following.data, "next") == 0;
}

/* Test FIX message: ICE venue accepted execution report */
static const char *test_fix_message[][2] = {
    {"8", "FIX.4.2"},                /* BeginString */
    {"9", "292"},                    /* BodyLength */
    {"35", "8"},                     /* MsgType (ExecutionReport) */
    {"49", "ICE"},                   /* SenderCompID */
    {"56", "26583"},                 /* TargetCompID */
    {"34", "10"},                    /* MsgSeqNum */
    {"52", "20250807-19:36:55.528"}, /* SendingTime */
    {"37", "1754595415526892558"},   /* OrderID */
    {"11", "400"},                   /* ClOrdID */
    {"109", "26583"},                /* ClientID */
    {"9139", "example-system"},      /* Custom: TradingSystem */
    {"17", "1754595415527892509"},   /* ExecID */
    {"20", "0"},                     /* ExecTransType */
    {"19", "TEST_ExecRefId"},        /* ExecRefID */
    {"150", "0"},                    /* ExecType */
    {"39", "0"},                     /* OrdStatus */
    {"54", "2"},                     /* Side */
    {"55", "6001174"},               /* Symbol */
    {"38", "150"},                   /* OrderQty */
    {"40", "2"},                     /* OrdType */
    {"44", "94.0000"},               /* Price */
    {"151", "150"},                  /* LeavesQty */
    {"14", "0"},                     /* CumQty */
    {"59", "0"},                     /* TimeInForce */
    {"6", "0"},                      /* AvgPx */
    {"31", "0"},                     /* LastPx */
    {"32", "0"},                     /* LastShares */
    {"60", "20250807-19:36:55.527"}, /* TransactTime */
    {"9821", "2661779"},             /* Custom: VenueOrderID */
    {"9175", "4"},                   /* Custom: VenueStatus */
    {"9120", "R"},                   /* Custom: DisplayIndicator */
    {"10", "238"},                   /* CheckSum */
};

#define TEST_FIX_MESSAGE_COUNT (sizeof(test_fix_message) / sizeof(test_fix_message[0]))

/* Fill FIFOs with FIX message tags and values */
static void fill_fifos_with_fix_message(void)
{
    for (size_t i = 0; i < TEST_FIX_MESSAGE_COUNT; i++) {
        write_string_to_fifo(0, test_fix_message[i][0]);
        write_string_to_fifo(1, test_fix_message[i][1]);
    }

    /* Write terminators */
    fifo0_write(0);
    fifo1_write(0);
}

int main(void)
{
    uint32_t start_time, end_time;

    /* Drain any leftover data so we start at a message boundary. */
    drain_fifo_pairs();

    bool fifo_framing_ok = test_oversized_fifo_string();

    /* Fill FIFOs with FIX message */
    fill_fifos_with_fix_message();
    delay_ticks(1000);

    /* Start timing */
    start_time = read_timer();

    /* Parse the message */
    bool parse_ok = true;
    bool fix_version_ok = true;
    packet_v1_venue_accepted_t msg = parse_venue_accepted(&parse_ok, &fix_version_ok);
    bool message_ok =
        fifo_framing_ok && parse_ok && fix_version_ok && msg.msg_header.msg_type == 38 &&
        msg.venue_id == 76 && msg.accepted_quantity.amount == 150 &&
        msg.accepted_price.amount == 9400000000LL && msg.accepted_price.scale == TARGET_SCALE &&
        msg.venue_sent_timestamp - msg.venue_transx_timestamp == 1000000ULL;

    /* End timing */
    end_time = read_timer();

    /* Print results */
    uart_printf("\n=== FROST Packet Parser - Full Parsed Message ===\n");
    uart_printf("Writing FIX message to FIFOs...\n");
    if (!fix_version_ok) {
        uart_printf("Warning: Expected FIX.4.2\n");
    }
    if (!parse_ok) {
        uart_printf("ERROR: FIFO mismatch\n");
    }
    if (!fifo_framing_ok) {
        uart_printf("ERROR: oversized FIFO string corrupted framing\n");
    }
    if (!message_ok) {
        uart_printf("ERROR: parsed fields did not match the expected message\n");
    }

    uart_printf("\n=== Parsed Venue Accepted Message ===\n");
    uart_printf("header.len: %u\n", msg.msg_header.len);
    uart_printf("header.msg_type: %u\n", msg.msg_header.msg_type);
    uart_printf("venue_id: %u\n", msg.venue_id);
    uart_printf("order_id: %u\n", msg.order_id);
    uart_printf("line_id: %u\n", msg.line_id);
    uart_printf("mapped_order_id: %llu\n", msg.mapped_order_id);
    uart_printf("venue_transx_timestamp: %llu\n", msg.venue_transx_timestamp);
    uart_printf("venue_sent_timestamp: %llu\n", msg.venue_sent_timestamp);
    uart_printf("ts_receive: %llu\n", msg.ts_receive);
    uart_printf("accepted_quantity.amount: %lld\n", msg.accepted_quantity.amount);
    uart_printf("accepted_quantity.scale: %u\n", msg.accepted_quantity.scale);
    uart_printf("accepted_price.amount: %lld\n", msg.accepted_price.amount);
    uart_printf("accepted_price.scale: %u\n", msg.accepted_price.scale);
    uart_printf("display_price.amount: %lld\n", msg.display_price.amount);
    uart_printf("display_price.scale: %u\n", msg.display_price.scale);
    uart_printf("accepted_display: %u\n", msg.accepted_display);
    uart_printf("accepted_order_id.length: %u\n", msg.accepted_order_id.length);
    uart_printf("currency: %u\n", msg.currency);
    uart_printf("line_setter_status: %u\n", msg.line_setter_status);

    uart_printf("\nParsing time: clock cycles = %u  Time duration = %u ns\n",
                end_time - start_time,
                (end_time - start_time) * CLOCK_PERIOD_PS / 1000);

    uart_printf("\n=== Test Complete ===\n");
    if (message_ok) {
        uart_printf("<<PASS>>\n");
    } else {
        uart_printf("<<FAIL>>\n");
    }

    /* Halt */
    for (;;) {
    }

    return 0;
}
