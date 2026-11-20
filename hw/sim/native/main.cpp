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

#include "Vtop.h"
#include "Vtop___024root.h"
#include "verilated.h"
#ifdef FROST_NATIVE_SAVABLE
#include "verilated_save.h"
#endif

#include <cerrno>
#include <chrono>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <iomanip>
#include <iostream>
#include <memory>
#include <optional>
#include <sstream>
#include <string>
#include <unistd.h>
#include <utility>
#include <vector>

namespace fs = std::filesystem;

extern "C" void frost_sim_assertions_enable();
extern "C" bool frost_sim_assertions_enabled();

namespace
{

#ifndef FROST_COMPILED_THREADS
#define FROST_COMPILED_THREADS 1
#endif

#ifdef FROST_NATIVE_ASSERTIONS
constexpr bool kAssertionsCompiled = true;
#else
constexpr bool kAssertionsCompiled = false;
#endif

constexpr uint64_t kCompiledThreads = FROST_COMPILED_THREADS;
constexpr uint64_t kMaxThreads = 256;
static_assert(kCompiledThreads >= 1 && kCompiledThreads <= kMaxThreads,
              "FROST_COMPILED_THREADS must be between 1 and 256");

volatile std::sig_atomic_t g_interrupted = 0;

void handle_signal(int sig)
{
    g_interrupted = sig;
}

using SteadyClock = std::chrono::steady_clock;

double elapsed_seconds(SteadyClock::time_point start)
{
    return std::chrono::duration<double>(SteadyClock::now() - start).count();
}

std::string format_with_commas(uint64_t value)
{
    std::string digits = std::to_string(value);
    std::string result;
    result.reserve(digits.size() + digits.size() / 3);
    for (size_t i = 0; i < digits.size(); ++i) {
        if (i > 0 && (digits.size() - i) % 3 == 0) {
            result.push_back(',');
        }
        result.push_back(digits[i]);
    }
    return result;
}

std::optional<uint64_t> parse_coremark_ticks(const std::string &uart_text)
{
    for (const char *prefix : {"Total 64-bit ticks :", "Total ticks"}) {
        size_t pos = uart_text.find(prefix);
        if (pos == std::string::npos) {
            continue;
        }
        size_t colon = uart_text.find(':', pos);
        if (colon == std::string::npos) {
            continue;
        }
        size_t idx = colon + 1;
        while (idx < uart_text.size() && (uart_text[idx] == ' ' || uart_text[idx] == '\t')) {
            ++idx;
        }
        if (idx >= uart_text.size() || uart_text[idx] < '0' || uart_text[idx] > '9') {
            continue;
        }
        char *end = nullptr;
        errno = 0;
        unsigned long long parsed = std::strtoull(uart_text.c_str() + idx, &end, 10);
        if (errno == 0 && end != uart_text.c_str() + idx) {
            return static_cast<uint64_t>(parsed);
        }
    }
    return std::nullopt;
}

bool parse_u64(const char *text, uint64_t *out)
{
    if (text == nullptr || *text == '\0' || *text == '-') {
        return false;
    }
    char *end = nullptr;
    errno = 0;
    unsigned long long val = std::strtoull(text, &end, 10);
    if (errno != 0 || end == text || *end != '\0') {
        return false;
    }
    *out = static_cast<uint64_t>(val);
    return true;
}

void print_usage(const char *prog)
{
    std::cerr
        << "Usage: " << prog << " [options] [+verilator+...]\n\n"
        << "Options:\n"
        << "  --mem-dir <dir>       Directory holding sw.mem, sw64.mem, sw_ddr.mem (default: .)\n"
        << "  --threads <N>         Simulation thread count (default: " << kCompiledThreads << ")\n"
        << "  --max-cycles <N>      Maximum simulated cycles, 0 for unlimited (default: 5000000)\n"
        << "  --stop <text>         Stop after UART emits <text> (default: <<PASS>>, empty "
           "disables)\n"
        << "  --drain <N>           Extra cycles to run after --stop matches (default: 0)\n"
        << "  --uart-out <path>     Write cumulative raw UART bytes to <path>\n"
        << "  --summary-json <path> Write structured run summary JSON to <path>\n"
        << "  --retire-trace <path> Keep retirement trace and write it to <path>\n"
        << "  --no-assert           Keep runtime assertions off after reset in checked builds\n"
        << "  --numa-assign         Enable Verilator fixed CPU affinity for worker threads\n"
        << "  --quiet-summary       Omit human-readable summary block on stderr\n"
        << "  --save <path>         Save simulator checkpoint to <path> (requires SAVABLE=1)\n"
        << "  --save-at <cycle>     Cycle at which --save writes checkpoint (0 saves at stop)\n"
        << "  --restore <path>      Restore simulator checkpoint from <path> (requires SAVABLE=1)\n"
        << "  --stats <path>        Write core activity counters to <path> (see README.md)\n"
        << "  --stats-interval <N>  Cycles between --stats lines (default: 10000)\n"
        << "  --regions <path>      With --stats: also count one region of the run (README.md)\n"
        << "  -h, --help            Show this help message\n";
}

struct StagingGuard {
    fs::path original_cwd;
    fs::path temp_dir;

    ~StagingGuard()
    {
        std::error_code ec;
        if (!original_cwd.empty()) {
            fs::current_path(original_cwd, ec);
        }
        if (!temp_dir.empty()) {
            fs::remove_all(temp_dir, ec);
        }
    }
};

bool setup_image_staging(const fs::path &mem_dir,
                         bool mem_dir_explicit,
                         bool restoring,
                         StagingGuard *guard,
                         std::string *error_message)
{
    std::error_code ec;
    guard->original_cwd = fs::current_path(ec);
    if (ec) {
        *error_message = "failed to determine working directory: " + ec.message();
        return false;
    }

    fs::path base_tmp = fs::temp_directory_path(ec);
    if (ec) {
        base_tmp = "/tmp";
    }
    std::string pattern = (base_tmp / "frost-native-XXXXXX").string();
    std::vector<char> mutable_pattern(pattern.begin(), pattern.end());
    mutable_pattern.push_back('\0');
    char *created = ::mkdtemp(mutable_pattern.data());
    if (created == nullptr) {
        *error_message = "mkdtemp failed while staging memory images";
        return false;
    }
    guard->temp_dir = fs::path(created);

    const char *image_names[] = {"sw.mem", "sw64.mem", "sw_ddr.mem"};
    const char *dummy_words[] = {"00000000\n", "0000000000000000\n", "00000000\n"};

    fs::path abs_mem_dir = mem_dir.is_absolute() ? mem_dir : (guard->original_cwd / mem_dir);
    for (size_t i = 0; i < 3; ++i) {
        fs::path src = abs_mem_dir / image_names[i];
        fs::path dst = guard->temp_dir / image_names[i];
        if (fs::exists(src, ec)) {
            fs::create_symlink(src, dst, ec);
            if (ec) {
                *error_message = "failed to symlink " + src.string() + ": " + ec.message();
                return false;
            }
        } else if (restoring && !mem_dir_explicit) {
            std::ofstream placeholder(dst, std::ios::binary);
            placeholder << dummy_words[i];
            if (!placeholder) {
                *error_message = "failed to create placeholder " + dst.string();
                return false;
            }
        } else {
            *error_message = "missing memory image: " + src.string();
            return false;
        }
    }

    fs::current_path(guard->temp_dir, ec);
    if (ec) {
        *error_message = "failed to enter staging directory: " + ec.message();
        return false;
    }
    return true;
}

bool write_run_outputs(const fs::path &uart_out_path,
                       const fs::path &summary_json_path,
                       const std::string &uart_output,
                       uint64_t cycles,
                       uint64_t start_cycle,
                       bool marker_seen,
                       uint64_t marker_cycle,
                       uint64_t drain_cycles,
                       double wall_seconds,
                       uint64_t threads_u64,
                       bool assertions_compiled,
                       bool assertions_armed,
                       bool passed,
                       bool failed)
{
    if (!uart_out_path.empty()) {
        std::ofstream uart_out(uart_out_path, std::ios::binary);
        if (!uart_out) {
            std::cerr << "Error: cannot write --uart-out path " << uart_out_path << "\n";
            return false;
        }
        uart_out.write(uart_output.data(), static_cast<std::streamsize>(uart_output.size()));
    }

    if (!summary_json_path.empty()) {
        std::ofstream json_out(summary_json_path);
        if (!json_out) {
            std::cerr << "Error: cannot write --summary-json path " << summary_json_path << "\n";
            return false;
        }
        const uint64_t advanced_cycles = cycles - start_cycle;
        const double cycles_per_second =
            wall_seconds > 0.0 ? static_cast<double>(advanced_cycles) / wall_seconds : 0.0;
        const std::optional<uint64_t> coremark_ticks = parse_coremark_ticks(uart_output);
        json_out << "{\n"
                 << "  \"cycles\": " << cycles << ",\n"
                 << "  \"advanced_cycles\": " << advanced_cycles << ",\n"
                 << "  \"marker_cycle\": ";
        if (marker_seen) {
            json_out << (marker_cycle + 1);
        } else {
            json_out << "null";
        }
        json_out << ",\n"
                 << "  \"drain_cycles\": " << drain_cycles << ",\n"
                 << "  \"uart_bytes\": " << uart_output.size() << ",\n"
                 << "  \"coremark_ticks\": ";
        if (coremark_ticks.has_value()) {
            json_out << *coremark_ticks;
        } else {
            json_out << "null";
        }
        json_out << ",\n"
                 << std::fixed << std::setprecision(6) << "  \"wall_seconds\": " << wall_seconds
                 << ",\n"
                 << "  \"cycles_per_second\": " << cycles_per_second << ",\n"
                 << "  \"threads\": " << threads_u64 << ",\n"
                 << "  \"assertions_compiled\": " << (assertions_compiled ? "true" : "false")
                 << ",\n"
                 << "  \"assertions_armed\": " << (assertions_armed ? "true" : "false") << ",\n"
                 << "  \"passed\": " << (passed ? "true" : "false") << ",\n"
                 << "  \"failed\": " << (failed ? "true" : "false") << "\n"
                 << "}\n";
    }
    return true;
}

#ifdef FROST_NATIVE_SAVABLE
bool write_checkpoint(const fs::path &save_path,
                      uint64_t cycles,
                      uint64_t simtime,
                      bool marker_seen,
                      uint64_t marker_cycle,
                      const std::string &uart_output,
                      Vtop *top)
{
    fs::path tmp_path = save_path;
    tmp_path += ".tmp";
    VerilatedSave out;
    out.open(tmp_path.c_str());
    uint8_t seen_flag = marker_seen ? 1U : 0U;
    out << cycles << simtime << seen_flag << marker_cycle << uart_output << *top;
    out.close();
    std::error_code ec;
    fs::rename(tmp_path, save_path, ec);
    if (ec) {
        std::cerr << "Error: failed to rename checkpoint to " << save_path << ": " << ec.message()
                  << "\n";
        return false;
    }
    return true;
}
#endif

// Core activity for --stats, accumulated once per i_clk cycle after reset
// releases. Every count starts at zero when the process starts, including
// after --restore.
struct ActivityCounters {
    uint64_t instructions = 0;
    uint64_t branches = 0;
    uint64_t mispredicts = 0;
    uint64_t rob_occupancy_sum = 0;
    uint64_t retire_cycles[3] = {0, 0, 0};
};

// --regions: counts over part of the run. The file holds lines
//   start <pc>        counting begins after the cycle in which this PC retires
//   end <pc>          counting ends with the cycle in which this PC retires
//   skip <lo> <hi>    cycles that end in the retirement of an instruction in
//                     [lo, hi) are left out (the stall before it is charged to it)
//   rob_depth <N>     the reorder buffer's size as built, echoed in --stats lines
// Every cycle belongs to the next instruction that retires: an idle cycle is
// held until then and counted or left out together with that cycle. The
// program is not touched and its timing does not change.
struct RegionSpec {
    bool enabled = false;
    bool has_start = false;
    uint64_t start_pc = 0;
    uint64_t end_pc = 0;
    std::vector<std::pair<uint64_t, uint64_t>> skips;
    uint64_t rob_depth = 0;
};

struct RegionTotals {
    uint64_t cycles = 0;
    uint64_t instructions = 0;
    uint64_t branches = 0;
    uint64_t mispredicts = 0;
    uint64_t rob_occupancy_sum = 0;
    uint64_t retire_cycles[3] = {0, 0, 0};
};

bool load_regions(const fs::path &path, RegionSpec *spec)
{
    std::ifstream in(path);
    if (!in) {
        return false;
    }
    std::string line;
    while (std::getline(in, line)) {
        std::istringstream words(line);
        std::string key, a, b;
        words >> key >> a >> b;
        if (key == "start") {
            spec->start_pc = std::strtoull(a.c_str(), nullptr, 0);
            spec->has_start = true;
        } else if (key == "end") {
            spec->end_pc = std::strtoull(a.c_str(), nullptr, 0);
        } else if (key == "skip") {
            spec->skips.emplace_back(std::strtoull(a.c_str(), nullptr, 0),
                                     std::strtoull(b.c_str(), nullptr, 0));
        } else if (key == "rob_depth") {
            spec->rob_depth = std::strtoull(a.c_str(), nullptr, 0);
        }
    }
    spec->enabled = spec->has_start && spec->end_pc != 0;
    return true;
}

bool region_skips(const RegionSpec &spec, uint64_t pc)
{
    for (const auto &range : spec.skips) {
        if (pc >= range.first && pc < range.second) {
            return true;
        }
    }
    return false;
}

void write_stats_line(std::FILE *out,
                      uint64_t cycles,
                      const ActivityCounters &c,
                      size_t uart_bytes,
                      bool final_line,
                      const RegionSpec &spec,
                      const RegionTotals &r)
{
    if (spec.enabled) {
        std::fprintf(out,
                     "region_cycles=%llu region_instructions=%llu region_branches=%llu "
                     "region_mispredicts=%llu region_rob_occupancy_sum=%llu "
                     "region_retired0=%llu region_retired1=%llu region_retired2=%llu ",
                     static_cast<unsigned long long>(r.cycles),
                     static_cast<unsigned long long>(r.instructions),
                     static_cast<unsigned long long>(r.branches),
                     static_cast<unsigned long long>(r.mispredicts),
                     static_cast<unsigned long long>(r.rob_occupancy_sum),
                     static_cast<unsigned long long>(r.retire_cycles[0]),
                     static_cast<unsigned long long>(r.retire_cycles[1]),
                     static_cast<unsigned long long>(r.retire_cycles[2]));
    }
    if (spec.rob_depth != 0) {
        std::fprintf(out, "rob_depth=%llu ", static_cast<unsigned long long>(spec.rob_depth));
    }
    std::fprintf(out,
                 "cycle=%llu instructions=%llu branches=%llu mispredicts=%llu "
                 "rob_occupancy_sum=%llu retired0=%llu retired1=%llu retired2=%llu "
                 "uart_bytes=%llu%s\n",
                 static_cast<unsigned long long>(cycles),
                 static_cast<unsigned long long>(c.instructions),
                 static_cast<unsigned long long>(c.branches),
                 static_cast<unsigned long long>(c.mispredicts),
                 static_cast<unsigned long long>(c.rob_occupancy_sum),
                 static_cast<unsigned long long>(c.retire_cycles[0]),
                 static_cast<unsigned long long>(c.retire_cycles[1]),
                 static_cast<unsigned long long>(c.retire_cycles[2]),
                 static_cast<unsigned long long>(uart_bytes),
                 final_line ? " final=1" : "");
    std::fflush(out);
}

} // namespace

int main(int argc, char **argv)
{
    std::signal(SIGINT, handle_signal);
    std::signal(SIGTERM, handle_signal);

    fs::path mem_dir = ".";
    bool mem_dir_explicit = false;
    uint64_t threads_u64 = kCompiledThreads;
    uint64_t max_cycles = 5000000;
    std::string stop_marker = "<<PASS>>";
    uint64_t drain_cycles = 0;
    fs::path uart_out_path;
    fs::path summary_json_path;
    fs::path retire_trace_path;
    fs::path save_path;
    uint64_t save_at_cycle = 0;
    fs::path restore_path;
    bool arm_assertions_after_reset = true;
    bool numa_assign = false;
    bool quiet_summary = false;
    fs::path stats_path;
    uint64_t stats_interval = 10000;
    fs::path regions_path;

    std::vector<const char *> verilator_args;
    verilator_args.push_back(argv[0]);

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto require_value = [&](const char *flag) -> const char * {
            if (i + 1 >= argc) {
                std::cerr << "Error: " << flag << " requires a value\n";
                std::exit(2);
            }
            return argv[++i];
        };

        if (arg == "-h" || arg == "--help") {
            print_usage(argv[0]);
            return 0;
        } else if (arg == "--mem-dir") {
            mem_dir = require_value("--mem-dir");
            mem_dir_explicit = true;
        } else if (arg == "--threads") {
            if (!parse_u64(require_value("--threads"), &threads_u64) || threads_u64 == 0 ||
                threads_u64 > kMaxThreads) {
                std::cerr << "Error: --threads must be between 1 and " << kMaxThreads << "\n";
                return 2;
            }
            if (threads_u64 < kCompiledThreads) {
                std::cerr << "Error: --threads (" << threads_u64
                          << ") cannot be less than compiled model partition count ("
                          << kCompiledThreads << ")\n";
                return 2;
            }
        } else if (arg == "--max-cycles") {
            if (!parse_u64(require_value("--max-cycles"), &max_cycles)) {
                std::cerr << "Error: --max-cycles must be a non-negative integer\n";
                return 2;
            }
        } else if (arg == "--stop") {
            stop_marker = require_value("--stop");
        } else if (arg == "--drain") {
            if (!parse_u64(require_value("--drain"), &drain_cycles)) {
                std::cerr << "Error: --drain must be a non-negative integer\n";
                return 2;
            }
        } else if (arg == "--uart-out") {
            uart_out_path = require_value("--uart-out");
        } else if (arg == "--summary-json") {
            summary_json_path = require_value("--summary-json");
        } else if (arg == "--retire-trace") {
            retire_trace_path = require_value("--retire-trace");
        } else if (arg == "--no-assert") {
            arm_assertions_after_reset = false;
        } else if (arg == "--numa-assign") {
            numa_assign = true;
        } else if (arg == "--quiet-summary") {
            quiet_summary = true;
        } else if (arg == "--save") {
            save_path = require_value("--save");
        } else if (arg == "--save-at") {
            if (!parse_u64(require_value("--save-at"), &save_at_cycle)) {
                std::cerr << "Error: --save-at must be a non-negative integer\n";
                return 2;
            }
        } else if (arg == "--restore") {
            restore_path = require_value("--restore");
        } else if (arg == "--stats") {
            stats_path = require_value("--stats");
        } else if (arg == "--regions") {
            regions_path = require_value("--regions");
        } else if (arg == "--stats-interval") {
            if (!parse_u64(require_value("--stats-interval"), &stats_interval) ||
                stats_interval == 0) {
                std::cerr << "Error: --stats-interval must be a positive integer\n";
                return 2;
            }
        } else if (!arg.empty() && arg[0] == '+') {
            if (arg == "+verilator+noassert") {
                arm_assertions_after_reset = false;
            }
            verilator_args.push_back(argv[i]);
        } else {
            std::cerr << "Error: unrecognized argument '" << arg << "'\n";
            print_usage(argv[0]);
            return 2;
        }
    }

#ifndef FROST_NATIVE_SAVABLE
    if (!save_path.empty() || save_at_cycle != 0 || !restore_path.empty()) {
        std::cerr << "Error: checkpoint save/restore requires a build with SAVABLE=1\n";
        return 2;
    }
#else
    if (save_at_cycle != 0 && save_path.empty()) {
        std::cerr << "Error: --save-at requires --save <path>\n";
        return 2;
    }
#endif

    StagingGuard staging;
    std::string staging_error;
    if (!setup_image_staging(
            mem_dir, mem_dir_explicit, !restore_path.empty(), &staging, &staging_error)) {
        std::cerr << "Error: " << staging_error << "\n";
        return 2;
    }

    auto ctx = std::make_unique<VerilatedContext>();
    ctx->fatalOnError(false);
    ctx->threads(static_cast<unsigned>(threads_u64));
    const char *numa_env = std::getenv("VERILATOR_NUMA_STRATEGY");
    if (!numa_assign && (numa_env == nullptr || std::strcmp(numa_env, "default") != 0)) {
        ctx->useNumaAssign(false);
    }
    ctx->commandArgs(static_cast<int>(verilator_args.size()), verilator_args.data());

    // Start every run with runtime assertions off before model construction and
    // time-zero evaluation, matching COCOTB_PLUSARGS += +verilator+noassert in
    // tests/Makefile. Checked builds arm them after cold reset through
    // frost_sim_assertions_enable() (hw/sim/sim_assertions.cpp).
    ctx->assertOn(false);
    if (frost_sim_assertions_enabled()) {
        std::cerr << "Error: simulation assertions remained enabled before reset\n";
        return 2;
    }

    uint64_t cycles = 0;
    bool marker_seen = false;
    uint64_t marker_cycle = 0;
    bool assertions_armed_after_reset = false;
    bool assertions_ever_enabled = false;
    std::string uart_output;

    auto top = std::make_unique<Vtop>(ctx.get());
    auto *root = top->rootp;

    // Match the idle port and reset-synchronizer setup of prepare_program_start
    // in verif/cocotb_tests/test_real_program.py.
    top->i_clk = 0;
    top->i_cpu_clk = 0;
    top->i_clk_div4 = 0;
    top->i_rst_n = 0;
    top->i_power_on_rst = 0;
    top->i_instr_mem_en = 0;
    top->i_instr_mem_we = 0;
    top->i_instr_mem_addr = 0;
    top->i_instr_mem_wrdata = 0;
    top->i_uart_rx = 1;
    top->i_external_interrupt = 0;
    top->i_jtag_tck = 0;
    top->i_jtag_tms = 0;
    top->i_jtag_tdi = 0;
    top->i_jtag_trst_n = 1;
    top->i_ddr_axi_rst_n = 1;
    top->i_nic_tx_clk = 0;
    top->i_nic_rx_clk = 0;
    top->i_nic_tx_clk_ok = 0;
    top->i_nic_rx_clk_ok = 0;
    top->i_nic_phy_status = 15;
    top->i_nic_rx_raw_valid = 0;
    top->i_nic_rx_raw_data = 0;
    top->i_nic_rx_signal_ok = 0;
    top->i_nic_1g_tx_clk = 0;
    top->i_nic_1g_rx_clk = 0;
    top->i_nic_1g_tx_clk_ok = 0;
    top->i_nic_1g_rx_clk_ok = 0;
    root->frost__DOT__reset_synchronizer_shift_register = 7;
    root->frost__DOT__reset_synchronized = 1;
    root->frost__DOT__reset_div4_synchronizer_shift_register = 7;

    top->eval();
    assertions_ever_enabled = assertions_ever_enabled || frost_sim_assertions_enabled();

    auto &retire_fd =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__u_tomasulo__DOT__u_rob__DOT__retire_trace_fd;
    if (retire_fd != 0) {
        VL_FCLOSE_I(retire_fd);
        retire_fd = 0;
    }

    // Restore caller working directory and clean temporary staging files before
    // opening output or checkpoint paths.
    {
        std::error_code ec;
        fs::current_path(staging.original_cwd, ec);
        staging.original_cwd.clear();
        fs::remove_all(staging.temp_dir, ec);
        staging.temp_dir.clear();
    }

#ifdef FROST_NATIVE_SAVABLE
    if (!restore_path.empty()) {
        std::error_code ec;
        if (!fs::exists(restore_path, ec)) {
            std::cerr << "Error: checkpoint file not found: " << restore_path << "\n";
            return 2;
        }
        VerilatedRestore in;
        in.open(restore_path.c_str());
        uint64_t simtime = 0;
        uint8_t seen_flag = 0;
        in >> cycles >> simtime >> seen_flag >> marker_cycle >> uart_output >> *top;
        in.close();
        marker_seen = (seen_flag != 0);
        if (stop_marker.empty()) {
            marker_seen = false;
            marker_cycle = 0;
        } else {
            const size_t pos = uart_output.find(stop_marker);
            if (pos == std::string::npos) {
                marker_seen = false;
                marker_cycle = 0;
            } else if (!marker_seen) {
                marker_seen = true;
                marker_cycle = cycles > 0 ? cycles - 1 : 0;
            }
        }
        ctx->time(simtime);
        // Never carry a serialized file descriptor integer across a restore.
        retire_fd = 0;
#ifdef FROST_NATIVE_ASSERTIONS
        if (cycles >= 18 && arm_assertions_after_reset) {
            frost_sim_assertions_enable();
            if (!frost_sim_assertions_enabled()) {
                std::cerr << "Error: simulation assertions failed to arm after restore\n";
                return 2;
            }
            assertions_armed_after_reset = true;
        }
#endif
        assertions_ever_enabled = assertions_ever_enabled || frost_sim_assertions_enabled();
    }
#endif

    // Open --retire-trace after any checkpoint restore so VerilatedRestore
    // cannot overwrite retire_fd or leak an earlier descriptor.
    if (!retire_trace_path.empty()) {
        retire_fd = VL_FOPEN_NN(retire_trace_path.string(), "w");
        if (retire_fd == 0) {
            std::cerr << "Error: cannot open --retire-trace path " << retire_trace_path << "\n";
            return 2;
        }
    }

    // --stats samples the signals that frost_native.vlt exposes for it: the
    // retirement, branch and misprediction counts that feed the HPM counters
    // and the reorder buffer's occupancy.
    std::FILE *stats_file = nullptr;
    if (!stats_path.empty()) {
        stats_file = std::fopen(stats_path.c_str(), "w");
        if (stats_file == nullptr) {
            std::cerr << "Error: cannot open --stats path " << stats_path << "\n";
            return 2;
        }
    }
    ActivityCounters activity;
    RegionSpec region;
    RegionTotals region_totals;
    RegionTotals region_pending;
    int region_state = 0; // 0 before the start PC retires, 1 counting, 2 done
    uint64_t region_prev_pc1 = 0;
    uint64_t region_prev_pc2 = 0;
    if (!regions_path.empty() && !load_regions(regions_path, &region)) {
        std::cerr << "Error: cannot read --regions path " << regions_path << "\n";
        return 2;
    }
    const auto &stat_head_pc =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__u_tomasulo__DOT__u_rob__DOT__head_pc;
    const auto &stat_head_next_pc =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__u_tomasulo__DOT__u_rob__DOT__head_next_pc;
    const auto &stat_retired =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__instruction_retired_count;
    const auto &stat_branches =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__commit_branch_retired_count;
    const auto &stat_mispredicts =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__commit_branch_mispredict_count;
    const auto &stat_rob_count =
        root->frost__DOT__cpu_and_memory_subsystem__DOT__cpu__DOT__hart__DOT__cpu_inst__DOT__u_tomasulo__DOT__u_rob__DOT__count;

    const uint64_t start_cycle = cycles;
    size_t fail_search_offset = uart_output.size() > 8 ? uart_output.size() - 8 : 0;
    bool failed = ctx->gotError() || (uart_output.find("<<FAIL>>") != std::string::npos);
    bool passed = !failed && marker_seen && cycles >= marker_cycle + drain_cycles + 1;
    bool saved_at_target = false;

    const auto sim_start = SteadyClock::now();

    while (!failed && !passed && (max_cycles == 0 || cycles < max_cycles) && !ctx->gotFinish() &&
           !g_interrupted) {
        const uint64_t n = cycles;

        ctx->time(1 + n * 3000);
        if (n >= 20 && root->frost__DOT__uart_write_enable_from_cpu) {
            char ch = static_cast<char>(root->frost__DOT__uart_write_data_from_cpu);
            uart_output.push_back(ch);
            std::fwrite(&ch, 1, 1, stdout);
            std::fflush(stdout);
            if (!stop_marker.empty() && !marker_seen && uart_output.size() >= stop_marker.size() &&
                uart_output.compare(uart_output.size() - stop_marker.size(),
                                    stop_marker.size(),
                                    stop_marker) == 0) {
                marker_seen = true;
                marker_cycle = n;
            }
        }

        top->i_clk = 1;
        top->eval();
        if (ctx->gotError()) {
            failed = true;
            break;
        }
        if (ctx->gotFinish()) {
            break;
        }

        bool edge_changed = false;
        if ((n & 1U) == 1U) {
            top->i_clk_div4 ^= 1;
            edge_changed = true;
        }
        if (n == 0) {
            top->i_power_on_rst = 1;
            edge_changed = true;
        }
        if (n == 7) {
            top->i_power_on_rst = 0;
            edge_changed = true;
        }
        if (n == 19) {
            top->i_rst_n = 1;
            edge_changed = true;
        }
        if (edge_changed) {
            top->eval();
            if (ctx->gotError()) {
                failed = true;
                break;
            }
            if (ctx->gotFinish()) {
                break;
            }
        }

#ifdef FROST_NATIVE_ASSERTIONS
        if (n == 17 && arm_assertions_after_reset) {
            frost_sim_assertions_enable();
            if (!frost_sim_assertions_enabled()) {
                std::cerr << "Error: simulation assertions failed to arm after reset\n";
                return 2;
            }
            assertions_armed_after_reset = true;
        }
#endif
        assertions_ever_enabled = assertions_ever_enabled || frost_sim_assertions_enabled();

        if (stats_file != nullptr && n >= 20) {
            const unsigned retired = static_cast<unsigned>(stat_retired) & 3U;
            activity.instructions += retired;
            activity.retire_cycles[retired > 2 ? 2 : retired] += 1;
            activity.branches += static_cast<unsigned>(stat_branches) & 3U;
            activity.mispredicts += static_cast<unsigned>(stat_mispredicts) & 3U;
            activity.rob_occupancy_sum += static_cast<unsigned>(stat_rob_count);
            if (region.enabled && region_state != 2) {
                // This cycle's counts wait in region_pending until an instruction retires.
                // The retirement count and the branch events are registered one clock after
                // the commit enables and the head PCs, so the instructions that account for
                // this clock's counts are the ones sampled in the previous clock.
                const unsigned slots = retired > 2 ? 2U : retired;
                region_pending.cycles += 1;
                region_pending.rob_occupancy_sum += static_cast<unsigned>(stat_rob_count);
                region_pending.retire_cycles[retired > 2 ? 2 : retired] += 1;
                if (slots > 0) {
                    const uint64_t pc1 = region_prev_pc1;
                    const uint64_t pc2 = region_prev_pc2;
                    const bool two = slots > 1;
                    const bool start_hit =
                        pc1 == region.start_pc || (two && pc2 == region.start_pc);
                    const bool end_hit = pc1 == region.end_pc || (two && pc2 == region.end_pc);
                    if (region_state == 0) {
                        if (start_hit) {
                            // The cycle of the start PC is not counted; a start and an end that
                            // retire together bound an empty region.
                            region_state = end_hit ? 2 : 1;
                        }
                    } else {
                        const bool skip1 = region_skips(region, pc1);
                        const bool skip2 = two && region_skips(region, pc2);
                        // Branch events are counts, not tied to a slot. When the two
                        // instructions of a pair are on different sides of a skipped range,
                        // two events mean one in each; one event goes with the first.
                        const unsigned b = static_cast<unsigned>(stat_branches) & 3U;
                        const unsigned m = static_cast<unsigned>(stat_mispredicts) & 3U;
                        const bool straddles = two && skip1 != skip2;
                        region_totals.branches += straddles && b >= 2 ? 1U : (skip1 ? 0U : b);
                        region_totals.mispredicts += straddles && m >= 2 ? 1U : (skip1 ? 0U : m);
                        if (!skip1) {
                            region_totals.cycles += region_pending.cycles;
                            region_totals.rob_occupancy_sum += region_pending.rob_occupancy_sum;
                            for (int k = 0; k < 3; ++k) {
                                region_totals.retire_cycles[k] += region_pending.retire_cycles[k];
                            }
                        }
                        region_totals.instructions += (skip1 ? 0U : 1U) + (two && !skip2 ? 1U : 0U);
                        if (end_hit) {
                            region_state = 2; // the cycle of the end PC is the last counted
                        }
                    }
                    region_pending = RegionTotals();
                }
            }
            // What retires in this clock is counted by the registered bus in the next one.
            region_prev_pc1 = stat_head_pc;
            region_prev_pc2 = stat_head_next_pc;
        }

        ctx->time(1501 + n * 3000);
        top->i_clk = 0;
        top->eval();
        if (ctx->gotError()) {
            failed = true;
            break;
        }
        if (ctx->gotFinish()) {
            break;
        }

        ++cycles;

        if (stats_file != nullptr && cycles % stats_interval == 0) {
            write_stats_line(
                stats_file, cycles, activity, uart_output.size(), false, region, region_totals);
        }

#ifdef FROST_NATIVE_SAVABLE
        if (!save_path.empty() && save_at_cycle != 0 && cycles == save_at_cycle) {
            if (!write_checkpoint(save_path,
                                  cycles,
                                  ctx->time(),
                                  marker_seen,
                                  marker_cycle,
                                  uart_output,
                                  top.get())) {
                return 2;
            }
            saved_at_target = true;
        }
#endif

        if (uart_output.find("<<FAIL>>", fail_search_offset) != std::string::npos) {
            failed = true;
            break;
        }
        if (uart_output.size() > 8) {
            fail_search_offset = uart_output.size() - 8;
        }

        if (marker_seen && cycles >= marker_cycle + drain_cycles + 1) {
            passed = true;
            break;
        }
    }

    if (!failed && !g_interrupted && ctx->gotFinish()) {
        failed = true;
        std::cerr << "Error: simulation terminated early via HDL $finish at cycle "
                  << format_with_commas(cycles) << "\n";
    }

    bool missed_save_target = false;
#ifdef FROST_NATIVE_SAVABLE
    if (!save_path.empty() && save_at_cycle == 0 && !saved_at_target && !failed && !g_interrupted) {
        if (!write_checkpoint(save_path,
                              cycles,
                              ctx->time(),
                              marker_seen,
                              marker_cycle,
                              uart_output,
                              top.get())) {
            return 2;
        }
    } else if (!save_path.empty() && save_at_cycle != 0 && !saved_at_target && !failed &&
               !g_interrupted) {
        missed_save_target = true;
    }
#else
    (void) saved_at_target;
#endif

    const double wall_seconds = elapsed_seconds(sim_start);
    const uint64_t advanced_cycles = cycles - start_cycle;
    const double cycles_per_second =
        wall_seconds > 0.0 ? static_cast<double>(advanced_cycles) / wall_seconds : 0.0;
    const std::optional<uint64_t> coremark_ticks = parse_coremark_ticks(uart_output);

    assertions_ever_enabled = assertions_ever_enabled || frost_sim_assertions_enabled();
    if ((!kAssertionsCompiled || !arm_assertions_after_reset) && assertions_ever_enabled) {
        std::cerr << "Error: simulation assertions were unexpectedly enabled\n";
        return 2;
    }
    const bool assertions_armed =
        kAssertionsCompiled && assertions_armed_after_reset && frost_sim_assertions_enabled();

    const bool summary_passed = passed && !missed_save_target;
    const bool summary_failed = failed || missed_save_target;

    if (!write_run_outputs(uart_out_path,
                           summary_json_path,
                           uart_output,
                           cycles,
                           start_cycle,
                           marker_seen,
                           marker_cycle,
                           drain_cycles,
                           wall_seconds,
                           threads_u64,
                           kAssertionsCompiled,
                           assertions_armed,
                           summary_passed,
                           summary_failed)) {
        return 2;
    }

    if (!quiet_summary) {
        if (!uart_output.empty() && uart_output.back() != '\n') {
            std::cerr << "\n";
        }
        const char *assertions_status = "disabled (not compiled)";
        if (kAssertionsCompiled) {
            if (assertions_armed) {
                assertions_status = "enabled after reset";
            } else if (!arm_assertions_after_reset) {
                assertions_status = "disabled";
            } else {
                assertions_status = "not yet armed (stopped in reset)";
            }
        }
        std::ostringstream rate_text;
        rate_text << format_with_commas(static_cast<uint64_t>(cycles_per_second + 0.5));
        std::cerr << "--- FROST RTL simulation summary ---\n";
        std::cerr << "Simulated cycles : " << format_with_commas(cycles);
        if (start_cycle != 0 && passed && drain_cycles > 0) {
            std::cerr << " (" << format_with_commas(advanced_cycles) << " advanced; "
                      << format_with_commas(marker_cycle + 1) << " to stop marker + "
                      << format_with_commas(drain_cycles) << " drain)";
        } else if (start_cycle != 0) {
            std::cerr << " (" << format_with_commas(advanced_cycles) << " advanced)";
        } else if (passed && drain_cycles > 0) {
            std::cerr << " (" << format_with_commas(marker_cycle + 1) << " to stop marker + "
                      << format_with_commas(drain_cycles) << " drain)";
        }
        std::cerr << "\n";
        if (coremark_ticks.has_value()) {
            std::cerr << "CoreMark ticks   : " << format_with_commas(*coremark_ticks) << "\n";
        }
        std::cerr << "RTL assertions   : " << assertions_status << "\n";
        std::cerr << std::fixed << std::setprecision(3) << "Wall time        : " << wall_seconds
                  << " s\n"
                  << "Simulation speed : " << rate_text.str()
                  << " cycles/s (threads: " << threads_u64 << ")\n";
    }

    if (retire_fd != 0) {
        VL_FCLOSE_I(retire_fd);
        retire_fd = 0;
    }

    if (stats_file != nullptr) {
        write_stats_line(
            stats_file, cycles, activity, uart_output.size(), true, region, region_totals);
        std::fclose(stats_file);
        stats_file = nullptr;
    }

    top->final();

    if (g_interrupted) {
        return 128 + static_cast<int>(g_interrupted);
    }
    if (failed) {
        return 1;
    }
    if (missed_save_target) {
        std::cerr << "Error: --save-at cycle " << format_with_commas(save_at_cycle)
                  << " was not reached before simulation stopped at cycle "
                  << format_with_commas(cycles) << "\n";
        return 1;
    }
    const bool stopped_for_checkpoint =
        saved_at_target && save_at_cycle != 0 && max_cycles == save_at_cycle;
    if (!stop_marker.empty() && !passed && !stopped_for_checkpoint) {
        std::cerr << "Error: stop marker '" << stop_marker << "' not reached within "
                  << format_with_commas(cycles) << " cycles\n";
        return 1;
    }
    return 0;
}
