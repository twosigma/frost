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

#ifndef FIX_H
#define FIX_H

#include <stdint.h>

/* FIX (Financial Information eXchange) protocol parsing utilities */

/* FIX protocol tag numbers for common fields */
typedef enum {
    FIX_TAG_BEGIN_STRING = 8,    /* Protocol version */
    FIX_TAG_BODY_LENGTH = 9,     /* Message body length */
    FIX_TAG_CL_ORDER_ID = 11,    /* Client order ID */
    FIX_TAG_MSG_TYPE = 35,       /* Message type */
    FIX_TAG_ORDER_ID = 37,       /* Order ID */
    FIX_TAG_ORDER_QTY = 38,      /* Order quantity */
    FIX_TAG_PRICE = 44,          /* Price */
    FIX_TAG_SENDER_COMP_ID = 49, /* Sender company ID */
    FIX_TAG_SENDING_TIME = 52,   /* Time message sent */
    FIX_TAG_TRANSACT_TIME = 60   /* Transaction timestamp */
} fix_tags_t;

/* Fixed-point price representation structure
 * Stores price as integer with implied decimal scale
 * Example: $94.50 with scale=2 stored as amount=9450, scale=2
 */
typedef struct __attribute__((packed)) {
    int64_t amount; /* Price value scaled by 10^scale */
    uint8_t scale;  /* Number of decimal places */
} fix_price_t;

/* Target scale for price parsing (number of decimal places) */
#define TARGET_SCALE 8

/* Parse FIX protocol timestamp string to nanoseconds
 * Format: YYYYMMDD-HH:MM:SS.mmm
 * Uses 30-day months and 365-day years, so the result is not a real epoch time.
 * A string shorter than 21 characters returns 0.
 */
uint64_t parse_timestamp(const char *timestamp_string);

/* Parse decimal price string to fixed-point representation
 * Example: "94.5000" -> {amount=9450000000, scale=8}
 * A leading '-' makes the amount negative: "-1.5" -> {amount=-150000000, scale=8}
 * An amount outside the int64_t range is not detected and wraps modulo 2^64.
 */
fix_price_t parse_price(const char *price_string);

#endif /* FIX_H */
