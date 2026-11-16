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

// Compare the decoded RTL legality with the installed reference implementation.
// Calling each reference instruction's entry point exercises its own checks;
// no reference overlap or EMUL formula is transcribed into this comparator.
#include <riscv/processor.h>
#include <riscv/simif.h>
#include <riscv/trap.h>

#include <array>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <map>
#include <set>
#include <string>
#include <vector>

#include "Vvec_legality_reference.h"
#include "forms.h"

class ReferenceHost : public simif_t
{
  public:
    cfg_t cfg;
    std::map<size_t, processor_t *> harts;
    char *addr_to_mem(reg_t) override { return nullptr; }
    bool mmio_load(reg_t, size_t, uint8_t *) override { return false; }
    bool mmio_store(reg_t, size_t, const uint8_t *) override { return false; }
    void proc_reset(unsigned) override {}
    const cfg_t &get_cfg() const override { return cfg; }
    const std::map<size_t, processor_t *> &get_harts() const override { return harts; }
    const char *get_symbol(uint64_t) override { return nullptr; }
};

int main(int argc, char **argv)
{
    if (argc < 2)
        return 2;
    unsigned vlen = std::stoul(argv[1]);
    bool negative = argc > 2;
    std::string isa = "rv64gcv_zvbb_zvl" + std::to_string(vlen) + "b";
    ReferenceHost host;
    host.cfg.isa = isa.c_str();
    host.cfg.hartids = {0};
    processor_t reference(isa.c_str(), "MSU", &host.cfg, &host, 0, false, nullptr, std::cerr);
    host.harts[0] = &reference;
    reference.put_csr(CSR_MSTATUS, MSTATUS_VS | MSTATUS_FS);
    for (unsigned reg = 1; reg < 32; ++reg)
        reference.get_state()->XPR.write(reg, 1);
    Vvec_legality_reference rtl;
    uint64_t compared = 0, mismatches = 0, accepted = 0, rejected = 0;
    for (const Form &form : forms) {
        uint64_t form_cases = 0, form_mismatches = 0;
        // Sweep each register field, all pairwise aliases, and adjacent groups.
        // The reference decoder mask keeps fixed unary selectors and vm bits.
        std::set<uint32_t> encodings;
        for (unsigned reg = 0; reg < 32; ++reg) {
            for (auto fields : std::array<std::array<unsigned, 3>, 9>{{{reg, 8, 24},
                                                                       {16, reg, 24},
                                                                       {16, 8, reg},
                                                                       {reg, reg, 24},
                                                                       {reg, 8, reg},
                                                                       {16, reg, reg},
                                                                       {reg, reg, reg},
                                                                       {reg, (reg + 1) % 32, 24},
                                                                       {reg, 8, (reg + 1) % 32}}}) {
                for (unsigned vm = 0; vm < 2; ++vm) {
                    uint32_t bits =
                        (fields[0] << 7) | (fields[1] << 20) | (fields[2] << 15) | (vm << 25);
                    encodings.insert(form.match | (bits & ~form.mask));
                }
            }
        }
        for (unsigned type = 0; type < 512; ++type) {
            // Include every policy, SEW, LMUL and vill encoding. Invalid vtypes
            // are normalized by the reference configuration unit, as hardware
            // vsetvl does before dispatch uses the architectural vtype.
            reg_t requested = (type & 255) | (reg_t(type >> 8) << 63);
            reference.VU.set_vl(1, 1, 1, requested);
            reg_t actual = reference.VU.vtype->read();
            rtl.i_vtype = (actual & 255) | ((actual >> 63) << 8);
            for (uint32_t bits : encodings) {
                reference.VU.vstart->write(0);
                std::memset(reference.VU.reg_file, 0, 32 * vlen / 8);
                bool illegal = false;
                try {
                    form.execute(&reference, insn_t(bits), 0x80000000);
                } catch (trap_t &trap) {
                    if (trap.cause() != CAUSE_ILLEGAL_INSTRUCTION) {
                        std::cerr << "Unexpected reference trap " << trap.cause() << '\n';
                        return 2;
                    }
                    illegal = true;
                }
                rtl.i_insn = bits;
                rtl.eval();
                bool got = rtl.o_illegal;
                if (negative && compared == 0)
                    got = !got;
                ++compared;
                ++form_cases;
                illegal ? ++rejected : ++accepted;
                if (got != illegal) {
                    ++mismatches;
                    ++form_mismatches;
                    if (mismatches <= 100)
                        std::cout << "MISMATCH " << form.name << " type=" << std::hex << type
                                  << " actual=" << actual << " insn=" << bits << std::dec
                                  << " rtl=" << got << " reference=" << illegal << '\n';
                    if (negative)
                        return 1;
                }
            }
        }
        std::cout << "FORM " << form.name << " compared=" << form_cases
                  << " mismatches=" << form_mismatches << std::endl;
    }
    std::cout << "TOTAL vlen=" << vlen << " forms=" << std::size(forms) << " compared=" << compared
              << " accepted=" << accepted << " rejected=" << rejected
              << " mismatches=" << mismatches << std::endl;
    return mismatches ? 1 : 0;
}
