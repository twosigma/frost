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
 * fix.c: parsers for two FIX (Financial Information eXchange) field formats.
 *
 *   - Timestamps: "YYYYMMDD-HH:MM:SS.mmm" -> nanoseconds
 *   - Prices: decimal strings -> fixed point with TARGET_SCALE decimal places
 *
 * The timestamp conversion uses 30-day months and 365-day years, so the result
 * is not a real epoch time. It serves latency-sensitive code that does not
 * need exact calendar math.
 */

#include "fix.h"
#include <stddef.h>

/* Parse a FIX timestamp string to nanoseconds. */
uint64_t parse_timestamp(const char *timestamp_string)
{
    /* Approximate: 30-day months, 365-day years, no leap years (see the file header). */

    /* Expected format: "YYYYMMDD-HH:MM:SS.mmm", so at least 21 characters. A
     * shorter string would be over-read below. */
    int length = 0;
    const char *ptr = timestamp_string;
    while (*ptr && length < 21) {
        length++;
        ptr++;
    }
    if (length < 21) {
        return 0; /* too short */
    }

    /* Extract date components (YYYYMMDD format) */
    int year = (timestamp_string[0] - '0') * 1000 + (timestamp_string[1] - '0') * 100 +
               (timestamp_string[2] - '0') * 10 + (timestamp_string[3] - '0');
    int month = (timestamp_string[4] - '0') * 10 + (timestamp_string[5] - '0');
    int day = (timestamp_string[6] - '0') * 10 + (timestamp_string[7] - '0');

    /* Advance past the date and the dash */
    timestamp_string += 9;

    /* Extract time components (HH:MM:SS.mmm format) */
    int hour = (timestamp_string[0] - '0') * 10 + (timestamp_string[1] - '0');
    int minute = (timestamp_string[3] - '0') * 10 + (timestamp_string[4] - '0');
    int second = (timestamp_string[6] - '0') * 10 + (timestamp_string[7] - '0');
    int milliseconds = (timestamp_string[9] - '0') * 100 + (timestamp_string[10] - '0') * 10 +
                       (timestamp_string[11] - '0');

    /* Convert to nanoseconds (30-day months, 365-day years) */
    uint64_t timestamp_in_nanoseconds =
        ((uint64_t) year * 365 * 24 * 3600 + (uint64_t) month * 30 * 24 * 3600 +
         (uint64_t) day * 24 * 3600 + (uint64_t) hour * 3600 + (uint64_t) minute * 60 +
         (uint64_t) second) *
            1000000000ULL +
        (uint64_t) milliseconds * 1000000ULL;

    return timestamp_in_nanoseconds;
}

/* Parse decimal price string to fixed-point representation */
fix_price_t parse_price(const char *price_string)
{
    fix_price_t parsed_price;
    int64_t whole_number_part = 0;
    int64_t fractional_part = 0;
    int fractional_digits_count = 0;
    const char *decimal_point_position = NULL;
    const char *parse_pointer = price_string;

    while (*parse_pointer) {
        if (*parse_pointer == '.') {
            decimal_point_position = parse_pointer;
            break;
        }
        parse_pointer++;
    }

    /* If no decimal point found, treat entire string as whole number */
    if (!decimal_point_position) {
        decimal_point_position = parse_pointer; /* Point to null terminator */
    }

    /* Parse whole number part (digits before decimal point) */
    parse_pointer = price_string;
    while (parse_pointer < decimal_point_position && *parse_pointer >= '0' &&
           *parse_pointer <= '9') {
        whole_number_part = whole_number_part * 10 + (*parse_pointer - '0');
        parse_pointer++;
    }

    /* Parse fractional part if decimal point exists */
    if (*decimal_point_position == '.') {
        parse_pointer = decimal_point_position + 1;
        while (*parse_pointer >= '0' && *parse_pointer <= '9' &&
               fractional_digits_count < TARGET_SCALE) {
            fractional_part = fractional_part * 10 + (*parse_pointer - '0');
            fractional_digits_count++;
            parse_pointer++;
        }
    }

    /* Example: "94.0000" gives whole=94, fractional=0, fractional_digits=4 */
    /* Target: 94.00000000 in fixed point with scale 8 */
    /* Result: 9400000000 (stored as integer with implied 8 decimal places) */

    int64_t result = whole_number_part;

    /* Shift whole part by number of fractional digits parsed */
    for (int i = 0; i < fractional_digits_count; i++) {
        result *= 10;
    }

    result += fractional_part;

    /* Scale up to TARGET_SCALE when fewer fractional digits were present */
    for (int i = fractional_digits_count; i < TARGET_SCALE; i++) {
        result *= 10;
    }

    parsed_price.amount = result;
    parsed_price.scale = TARGET_SCALE;

    return parsed_price;
}
