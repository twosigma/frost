//    Copyright 2026 Two Sigma Open Source, LLC
//
//    Licensed under the Apache License, Version 2.0 (the "License");
//    you may not use this file except in compliance with the License.
//    You may obtain a copy of the License at
//
//        http://www.apache.org/licenses/LICENSE-2.0
//
//    Unless required by applicable law or agreed to in writing, software
//    distributed under the License is distributed on an "AS IS" BASIS,
//    WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//    See the License for the specific language governing permissions and
//    limitations under the License.

#include "kernel/log.h"
#include "kernel/yosys.h"
#include <algorithm>
#include <cstdlib>
#include <fstream>
#include <sstream>

USING_YOSYS_NAMESPACE
PRIVATE_NAMESPACE_BEGIN

struct HeaderTraceSink : public LogSink {
    std::ofstream out;
    explicit HeaderTraceSink(const char *path) : out(path, std::ios::out | std::ios::trunc) {}
    void log(const LogMessage &msg) override
    {
        if (!out.is_open())
            return;
        auto emit = [&](char tag, const std::string &body) {
            out << tag << '\t';
            for (char c : body) {
                if (c != '\r' && c != '\n')
                    out << c;
            }
            out << '\n';
        };
        if (msg.severity == LogSeverity::Header) {
            emit('H', msg.prefix + msg.message);
        } else if (msg.format.find("-- Executing script file ") == 0) {
            emit('S', msg.message);
        } else if (msg.format.find("End of script.") == 0) {
            emit('E', msg.message);
        }
    }
    void flush() override
    {
        if (out.is_open())
            out.flush();
    }
};

struct HeaderTracePass : public Pass {
    HeaderTracePass() : Pass("frost_header_trace_sink", "internal header trace sink") {}
    void on_register() override
    {
        const char *path = std::getenv("FROST_YOSYS_HEADER_TRACE");
        if (path && *path) {
            logger().add_sink<HeaderTraceSink>(path);
        }
    }
    void execute(std::vector<std::string>, RTLIL::Design *) override {}
} HeaderTracePass;

// Inspect the elaborated reachability tree before proc, flatten or the point
// solver can simplify a high-impedance constant. Prep calls hierarchy too.
struct CheckedHierarchy : public Pass {
    Pass *hierarchy = nullptr;
    pool<std::string> pending_predicates, observed_predicates;
    void on_register() override
    {
        const char *allowed = std::getenv("FROST_YOSYS_PENDING_PREDICATES");
        std::istringstream input(allowed ? allowed : "");
        for (std::string site; std::getline(input, site);)
            pending_predicates.insert(site);
    }
    void on_shutdown() override
    {
        for (const auto &site : pending_predicates)
            if (!observed_predicates.count(site))
                log_error("Unused high-impedance predicate exemption at %s.\n", site);
        hierarchy->on_shutdown();
    }

    // The native frontend lowers $isunknown to tests against literal X and Z.
    // Only its one-bit Z comparison operand can use a registered source site.
    bool pending_predicate(RTLIL::Cell *cell, RTLIL::IdString port, const RTLIL::SigSpec &signal)
    {
        if (pending_predicates.empty() || cell->type != ID($eqx) || port != ID::B ||
            signal != RTLIL::SigSpec(RTLIL::Sz))
            return false;
        for (const auto &site : cell->get_strpool_attribute(ID::src)) {
            if (!pending_predicates.count(site))
                continue;
            if (observed_predicates.insert(site).second)
                log("Retained high-impedance predicate exemption at %s.\n", site);
            return true;
        }
        return false;
    }

    CheckedHierarchy() : Pass("hierarchy", "elaborate and check formal inputs") {}
    bool replace_existing_pass() const override { return true; }
    void run_register() override
    {
        // Keep the native implementation, including the calls made from prep.
        hierarchy = pass_register.at(pass_name);
        Pass::run_register();
    }

    static void check_value(const RTLIL::Const &value,
                            RTLIL::Module *module,
                            RTLIL::IdString object,
                            RTLIL::IdString field)
    {
        if (std::find(value.begin(), value.end(), RTLIL::Sz) != value.end())
            log_error("High-impedance constant in elaborated module %s, %s.%s.\n",
                      log_id(module),
                      log_id(object),
                      log_id(field));
    }

    void execute(std::vector<std::string> args, RTLIL::Design *design) override
    {
        hierarchy->execute(args, design);
        if (std::find(args.begin(), args.end(), "-top") == args.end() &&
            std::find(args.begin(), args.end(), "-auto-top") == args.end())
            return;
        auto *top = design->top_module();
        if (top == nullptr)
            log_error("Missing top after formal input elaboration.\n");
        pool<RTLIL::Module *> seen;
        std::vector<RTLIL::Module *> todo{top};
        while (!todo.empty()) {
            auto *module = todo.back();
            todo.pop_back();
            if (!seen.insert(module).second)
                continue;
            for (const auto &conn : module->connections())
                if (conn.first.has_const(RTLIL::Sz) || conn.second.has_const(RTLIL::Sz))
                    log_error("High-impedance constant in elaborated module %s, connection %s.\n",
                              log_id(module),
                              log_signal(conn.first));
            for (const auto &param : module->parameter_default_values)
                check_value(param.second, module, module->name, param.first);
            for (auto *cell : module->cells()) {
                // Slang can lower a conditional Z to a tri-state buffer during read_slang.
                if (cell->type.in(ID($tribuf), ID($_TBUF_)))
                    log_error("High-impedance driver in elaborated module %s, cell %s (%s).\n",
                              log_id(module),
                              log_id(cell),
                              log_id(cell->type));
                for (const auto &param : cell->parameters)
                    check_value(param.second, module, cell->name, param.first);
                for (const auto &port : cell->connections())
                    if (port.second.has_const(RTLIL::Sz) &&
                        !pending_predicate(cell, port.first, port.second))
                        log_error("High-impedance constant in elaborated module %s, port %s.%s.\n",
                                  log_id(module),
                                  log_id(cell),
                                  log_id(port.first));
                if (auto *child = design->module(cell->type))
                    todo.push_back(child);
            }
            for (auto *wire : module->wires())
                for (auto field : {ID::init, ID::defaultvalue})
                    if (wire->has_attribute(field))
                        check_value(wire->attributes.at(field), module, wire->name, field);
            for (const auto &proc : module->processes) {
                auto check_signal = [&](const RTLIL::SigSpec &sig) {
                    if (sig.has_const(RTLIL::Sz))
                        log_error("High-impedance constant in elaborated module %s, process %s.\n",
                                  log_id(module),
                                  log_id(proc.first));
                };
                proc.second->rewrite_sigspecs(check_signal);
            }
        }
        log("Checked elaborated formal inputs of %s for high-impedance constants.\n", log_id(top));
    }
} CheckedHierarchy;

PRIVATE_NAMESPACE_END
