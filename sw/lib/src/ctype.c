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
 * ctype.c: character classification and case conversion for bare-metal use.
 *
 * Every function takes an int, as the standard interface does, so EOF (-1) is
 * a valid argument.
 */

#include "ctype.h"

/* Check if character is a decimal digit (0-9) */
int isdigit(int c)
{
    return c >= '0' && c <= '9';
}

/* Check if character is an alphabetic letter (a-z or A-Z) */
int isalpha(int c)
{
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z');
}

/* Check if character is an uppercase letter (A-Z) */
int isupper(int c)
{
    return c >= 'A' && c <= 'Z';
}

/* Check if character is a lowercase letter (a-z) */
int islower(int c)
{
    return c >= 'a' && c <= 'z';
}

/* Convert character to uppercase */
int toupper(int c)
{
    if (islower(c))
        return c - ('a' - 'A');
    return c;
}

/* Convert character to lowercase */
int tolower(int c)
{
    if (isupper(c))
        return c + ('a' - 'A');
    return c;
}

/* Check if character is whitespace */
int isspace(int c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f' || c == '\v';
}
