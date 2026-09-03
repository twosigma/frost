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

#ifndef CTYPE_H
#define CTYPE_H

/* Character classification and case conversion for bare-metal C programs */

/* Check if character is a decimal digit (0-9) */
int isdigit(int c);

/* Check if character is an alphabetic letter (a-z or A-Z) */
int isalpha(int c);

/* Check if character is an uppercase letter (A-Z) */
int isupper(int c);

/* Check if character is a lowercase letter (a-z) */
int islower(int c);

/* Convert character to uppercase */
int toupper(int c);

/* Convert character to lowercase */
int tolower(int c);

/* Check if character is whitespace (space, \t, \n, \v, \f, \r) */
int isspace(int c);

#endif /* CTYPE_H */
