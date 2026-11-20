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

// Keep both flattened forms in the hierarchy while opening the comparison.
module twin_both;
  gold u_gold ();
  gate u_gate ();
endmodule

// Standalone elaboration sees these portless declarations. The proof copies
// the compiled modules into the design before elaborating twin_both.
module gold;
endmodule

module gate;
endmodule
