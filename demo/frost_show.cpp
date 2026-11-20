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
 * frost-show: the demonstration container's default program.
 *
 * Runs two programs on the FROST RTL through frost-native and presents them:
 *   1. raytrace: draws a coarse version of its picture, then each row in
 *      full detail, as the simulated CPU sends it.
 *   2. CoreMark: one iteration, reported as passed and in how many cycles by
 *      the benchmark's own count.
 * Each act is one program and its presentation; another program can take an
 * act's place by following the same pattern (act_raytrace, act_coremark).
 * A status line follows the simulated core while it runs (on a terminal),
 * and a closing table shows what the core did in each program. Every figure
 * comes from the simulation: the UART output, or frost-native --stats, which
 * samples the core's retirement, branch and reorder-buffer signals.
 *
 * Output adapts to the terminal. Plain text, with no color and no cursor or
 * erase commands, when NO_COLOR is set, TERM is not a known cursor-addressable
 * type (see term_supports_controls), or the output is not a terminal (no status
 * line then). Otherwise color, chosen only from this, in order: --truecolor or
 * --256; the COLORTERM variable (truecolor, 24bit); a TERM that names direct
 * color; else the nearest color of the 256-color palette (no dithering), with
 * a line under the picture saying how to get full color. The terminal is never
 * queried and its modes are never changed.
 */

#include <algorithm>
#include <cerrno>
#include <chrono>
#include <cmath>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <ctime>
#include <deque>
#include <fcntl.h>
#include <functional>
#include <map>
#include <poll.h>
#include <string>
#include <sys/ioctl.h>
#include <sys/wait.h>
#include <unistd.h>
#include <vector>

namespace
{

using Clock = std::chrono::steady_clock;

volatile std::sig_atomic_t g_signal = 0;
pid_t g_child = -1;
bool g_cursor_hidden = false;

void on_signal(int sig)
{
    g_signal = sig;
    if (g_child > 0) {
        kill(g_child, sig);
    }
}

void restore_terminal()
{
    if (g_cursor_hidden) {
        std::fputs("\r\x1b[K\x1b[0m\x1b[?25h", stdout);
        g_cursor_hidden = false;
    }
    std::fflush(stdout);
}

enum class ColorMode { None, Ansi256, TrueColor };

struct Options {
    std::string bin_dir = "/opt/frost-demo/bin";
    std::string apps_dir = "/opt/frost-demo/apps";
    int threads = 4;
    bool quick = false;
    bool full = false; /* keep the full picture on a slow host */
    std::string color = "auto";
};

struct Terminal {
    bool tty = false;
    bool live = false; /* status line updated in place */
    ColorMode color = ColorMode::None;
    int width = 80;
    bool fallback_256 = false; /* 256 colors for lack of any sign of 24-bit support */
};

std::string with_commas(uint64_t value)
{
    std::string digits = std::to_string(value);
    std::string out;
    for (size_t i = 0; i < digits.size(); ++i) {
        if (i > 0 && (digits.size() - i) % 3 == 0) {
            out.push_back(',');
        }
        out.push_back(digits[i]);
    }
    return out;
}

std::string fixed(double value, int decimals)
{
    char buf[64];
    std::snprintf(buf, sizeof(buf), "%.*f", decimals, value);
    return buf;
}

std::string percent(uint64_t part, uint64_t whole, int decimals)
{
    if (whole == 0) {
        return "-";
    }
    return fixed(100.0 * static_cast<double>(part) / static_cast<double>(whole), decimals) + "%";
}

/* ------------------------------------------------------------------------ */
/* Activity counters from frost-native --stats                               */
/* ------------------------------------------------------------------------ */

struct Sample {
    uint64_t cycle = 0;
    uint64_t instructions = 0;
    uint64_t branches = 0;
    uint64_t mispredicts = 0;
    uint64_t rob_occupancy_sum = 0;
    uint64_t retired[3] = {0, 0, 0};
    uint64_t rob_depth = 0; /* the reorder buffer's size as built, 0 if not reported */
    /* The same counts over the region frost-native was asked to count (see
       demo/make_regions.py); has_region is false when it was not. */
    bool has_region = false;
    uint64_t region_cycles = 0;
    uint64_t region_instructions = 0;
    uint64_t region_branches = 0;
    uint64_t region_mispredicts = 0;
    uint64_t region_rob_occupancy_sum = 0;
    uint64_t region_retired[3] = {0, 0, 0};
    bool valid = false;
};

/* The sample as the closing table counts it: over the region only. The caller has
   checked has_region; whole-run counters are never shown as the region's. */
Sample counted(const Sample &s)
{
    Sample c = s;
    c.cycle = s.region_cycles;
    c.instructions = s.region_instructions;
    c.branches = s.region_branches;
    c.mispredicts = s.region_mispredicts;
    c.rob_occupancy_sum = s.region_rob_occupancy_sum;
    for (int k = 0; k < 3; ++k) {
        c.retired[k] = s.region_retired[k];
    }
    return c;
}

bool parse_sample(const std::string &line, Sample *s)
{
    std::map<std::string, uint64_t> kv;
    size_t pos = 0;
    while (pos < line.size()) {
        size_t end = line.find(' ', pos);
        if (end == std::string::npos) {
            end = line.size();
        }
        std::string item = line.substr(pos, end - pos);
        size_t eq = item.find('=');
        if (eq != std::string::npos) {
            kv[item.substr(0, eq)] = std::strtoull(item.c_str() + eq + 1, nullptr, 10);
        }
        pos = end + 1;
    }
    if (kv.count("cycle") == 0 || kv.count("instructions") == 0) {
        return false;
    }
    s->cycle = kv["cycle"];
    s->instructions = kv["instructions"];
    s->branches = kv["branches"];
    s->mispredicts = kv["mispredicts"];
    s->rob_occupancy_sum = kv["rob_occupancy_sum"];
    s->retired[0] = kv["retired0"];
    s->retired[1] = kv["retired1"];
    s->retired[2] = kv["retired2"];
    s->rob_depth = kv["rob_depth"];
    s->has_region = kv.count("region_cycles") != 0;
    s->region_cycles = kv["region_cycles"];
    s->region_instructions = kv["region_instructions"];
    s->region_branches = kv["region_branches"];
    s->region_mispredicts = kv["region_mispredicts"];
    s->region_rob_occupancy_sum = kv["region_rob_occupancy_sum"];
    s->region_retired[0] = kv["region_retired0"];
    s->region_retired[1] = kv["region_retired1"];
    s->region_retired[2] = kv["region_retired2"];
    s->valid = true;
    return true;
}

/* ------------------------------------------------------------------------ */
/* Running frost-native                                                      */
/* ------------------------------------------------------------------------ */

struct RunResult {
    int exit_status = -1; /* exit code, or 128 + signal */
    std::string uart;
    std::string errors;
    Sample last;
    double seconds = 0.0;
};

void set_nonblocking(int fd)
{
    int flags = fcntl(fd, F_GETFL, 0);
    fcntl(fd, F_SETFL, flags | O_NONBLOCK);
}

/*
 * Run frost-native with UART bytes on a pipe and --stats on another.
 * on_uart receives each chunk of UART bytes; on_sample each counter line;
 * on_tick is called about five times a second.
 */
RunResult run_program(const std::string &binary,
                      const std::vector<std::string> &args,
                      const std::function<void(const std::string &)> &on_uart,
                      const std::function<void(const Sample &)> &on_sample,
                      const std::function<void()> &on_tick)
{
    RunResult result;
    int out_pipe[2], err_pipe[2], stats_pipe[2];
    if (pipe(out_pipe) != 0 || pipe(err_pipe) != 0 || pipe(stats_pipe) != 0) {
        result.errors = std::string("pipe: ") + std::strerror(errno);
        return result;
    }
    const auto start = Clock::now();
    pid_t pid = fork();
    if (pid < 0) {
        result.errors = std::string("fork: ") + std::strerror(errno);
        return result;
    }
    if (pid == 0) {
        dup2(out_pipe[1], 1);
        dup2(err_pipe[1], 2);
        dup2(stats_pipe[1], 3);
        for (int fd :
             {out_pipe[0], out_pipe[1], err_pipe[0], err_pipe[1], stats_pipe[0], stats_pipe[1]}) {
            if (fd > 3) {
                close(fd);
            }
        }
        std::vector<char *> argv;
        argv.push_back(const_cast<char *>(binary.c_str()));
        for (const std::string &a : args) {
            argv.push_back(const_cast<char *>(a.c_str()));
        }
        argv.push_back(nullptr);
        signal(SIGINT, SIG_DFL);
        signal(SIGTERM, SIG_DFL);
        execv(binary.c_str(), argv.data());
        std::fprintf(stderr, "cannot run %s: %s\n", binary.c_str(), std::strerror(errno));
        _exit(127);
    }
    g_child = pid;
    close(out_pipe[1]);
    close(err_pipe[1]);
    close(stats_pipe[1]);
    set_nonblocking(out_pipe[0]);
    set_nonblocking(err_pipe[0]);
    set_nonblocking(stats_pipe[0]);

    struct pollfd fds[3] = {
        {out_pipe[0], POLLIN, 0}, {err_pipe[0], POLLIN, 0}, {stats_pipe[0], POLLIN, 0}};
    bool open_fd[3] = {true, true, true};
    std::string stats_buf;
    auto last_tick = Clock::now();
    auto interrupted_at = Clock::time_point();
    bool killed = false;
    char buf[8192];
    while (open_fd[0] || open_fd[1] || open_fd[2]) {
        /* After Ctrl-C (forwarded by on_signal), give the simulator two seconds. */
        if (g_signal != 0 && !killed) {
            if (interrupted_at == Clock::time_point()) {
                interrupted_at = Clock::now();
            } else if (Clock::now() - interrupted_at > std::chrono::seconds(2)) {
                kill(pid, SIGKILL);
                killed = true;
            }
        }
        for (int i = 0; i < 3; ++i) {
            fds[i].fd = open_fd[i] ? fds[i].fd : -1;
            fds[i].revents = 0;
        }
        int rc = poll(fds, 3, 200);
        if (rc < 0 && errno != EINTR) {
            break;
        }
        for (int i = 0; i < 3; ++i) {
            if (!open_fd[i] || (fds[i].revents & (POLLIN | POLLHUP | POLLERR)) == 0) {
                continue;
            }
            for (;;) {
                ssize_t n = read(fds[i].fd, buf, sizeof(buf));
                if (n > 0) {
                    std::string chunk(buf, static_cast<size_t>(n));
                    if (i == 0) {
                        result.uart += chunk;
                        on_uart(chunk);
                    } else if (i == 1) {
                        result.errors += chunk;
                    } else {
                        stats_buf += chunk;
                        size_t nl;
                        while ((nl = stats_buf.find('\n')) != std::string::npos) {
                            Sample s;
                            if (parse_sample(stats_buf.substr(0, nl), &s)) {
                                result.last = s;
                                on_sample(s);
                            }
                            stats_buf.erase(0, nl + 1);
                        }
                    }
                    continue;
                }
                if (n == 0) {
                    open_fd[i] = false;
                    close(fds[i].fd);
                }
                break; /* EAGAIN or EOF */
            }
        }
        if (Clock::now() - last_tick >= std::chrono::milliseconds(200)) {
            last_tick = Clock::now();
            on_tick();
        }
    }
    int status = 0;
    while (waitpid(pid, &status, 0) < 0 && errno == EINTR) {
    }
    g_child = -1;
    if (WIFEXITED(status)) {
        result.exit_status = WEXITSTATUS(status);
    } else if (WIFSIGNALED(status)) {
        result.exit_status = 128 + WTERMSIG(status);
    }
    result.seconds = std::chrono::duration<double>(Clock::now() - start).count();
    return result;
}

/* Display columns of a UTF-8 string without escape sequences. */
size_t utf8_columns(const std::string &s)
{
    size_t n = 0;
    for (unsigned char c : s) {
        if ((c & 0xC0) != 0x80) {
            ++n;
        }
    }
    return n;
}

/* ------------------------------------------------------------------------ */
/* Presentation                                                              */
/* ------------------------------------------------------------------------ */

class Show
{
  public:
    Show(const Options &opt, const Terminal &term) : opt_(opt), term_(term) {}

    int run();

  private:
    const Options &opt_;
    Terminal term_;
    std::string status_;                         /* status line currently on screen */
    std::deque<Sample> window_;                  /* recent counter samples */
    std::deque<Clock::time_point> window_times_; /* when each sample arrived */
    Sample act_totals_[2];
    uint64_t total_cycles_ = 0;
    bool small_ = false;           /* small picture and one CoreMark iteration */
    bool switching_ = false;       /* the full picture was stopped for the small one */
    uint64_t estimate_cycles_ = 0; /* expected cycles of the running program */
    const char *act_name_ = "";

    /* Picture state. The program's pixels are kept at full size; they are
       drawn scaled down by a whole factor when the terminal is too narrow. */
    int pic_width_ = 0;
    int pic_height_ = 0;
    int scale_ = 1;            /* pixels per drawn pixel, each way */
    int disp_w_ = 0;           /* drawn pixels per row */
    int disp_h_ = 0;           /* drawn pixel rows */
    bool show_picture_ = true; /* false: too narrow to draw at all */
    std::string line_buf_;
    std::vector<std::vector<int>> pic_rows_; /* 0xRRGGBB pixels per row */
    int rows_drawn_ = 0;                     /* text rows printed */

    void out(const std::string &s) { std::fwrite(s.data(), 1, s.size(), stdout); }
    void flush() { std::fflush(stdout); }

    std::string bold(const std::string &s) const
    {
        return term_.color == ColorMode::None ? s : "\x1b[1m" + s + "\x1b[22m";
    }
    std::string accent(const std::string &s) const
    {
        if (term_.color == ColorMode::TrueColor) {
            return "\x1b[38;2;120;180;255m" + s + "\x1b[39m";
        }
        if (term_.color == ColorMode::Ansi256) {
            return "\x1b[38;5;111m" + s + "\x1b[39m";
        }
        return s;
    }
    std::string muted(const std::string &s) const
    {
        if (term_.color == ColorMode::TrueColor) {
            return "\x1b[38;2;150;165;185m" + s + "\x1b[39m";
        }
        if (term_.color == ColorMode::Ansi256) {
            return "\x1b[38;5;103m" + s + "\x1b[39m";
        }
        return s;
    }

    /* Print text above the status line. */
    void print(const std::string &s)
    {
        clear_status();
        out(s);
        draw_status();
        flush();
    }
    void clear_status()
    {
        if (term_.live && !status_.empty()) {
            out("\r\x1b[K");
        }
    }
    void draw_status()
    {
        if (term_.live && !status_.empty()) {
            out(status_);
        }
    }
    void set_status(const std::string &s)
    {
        if (!term_.live || s == status_) {
            return;
        }
        status_ = s;
        out("\r\x1b[K");
        out(status_);
        flush();
    }
    /* Current terminal width; the status line must stay shorter than it, or a
       wrapped line would leave copies behind on every redraw. */
    int width() const
    {
        struct winsize ws;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
            return ws.ws_col;
        }
        return term_.width;
    }
    int height() const
    {
        struct winsize ws;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_row > 0) {
            return ws.ws_row;
        }
        return 0;
    }
    void end_status()
    {
        if (term_.live && !status_.empty()) {
            out("\r\x1b[K");
            status_.clear();
            flush();
        }
    }

    void on_sample(const Sample &s)
    {
        window_.push_back(s);
        window_times_.push_back(Clock::now());
        /* Keep about the last 40,000 cycles for the rates on the status line. */
        while (window_.size() > 2 && window_[1].cycle + 40000 <= s.cycle) {
            window_.pop_front();
            window_times_.pop_front();
        }
    }
    void refresh_status();
    /* The first status line, cut to fit a narrow terminal. */
    std::string starting_status() const
    {
        const std::string text = "starting the simulation";
        const size_t room = static_cast<size_t>(std::max(1, width() - 1 - 2));
        return "  " + muted(text.substr(0, room));
    }
    void reset_window()
    {
        window_.clear();
        window_times_.clear();
        rate_samples_.clear();
    }
    /* Simulated cycles a second over the last ten seconds of samples, or 0. */
    std::deque<std::pair<Clock::time_point, uint64_t>> rate_samples_;
    double sim_rate() const
    {
        if (rate_samples_.size() < 2) {
            return 0.0;
        }
        const double secs =
            std::chrono::duration<double>(rate_samples_.back().first - rate_samples_.front().first)
                .count();
        if (secs < 1.0) {
            return 0.0;
        }
        return static_cast<double>(rate_samples_.back().second - rate_samples_.front().second) /
               secs;
    }
    void note_rate(const Sample &s)
    {
        rate_samples_.emplace_back(Clock::now(), s.cycle);
        while (rate_samples_.size() > 2 &&
               rate_samples_.back().first - rate_samples_[1].first > std::chrono::seconds(10)) {
            rate_samples_.pop_front();
        }
    }
    void check_slow_host();
    void reset_picture()
    {
        pic_width_ = pic_height_ = 0;
        scale_ = 1;
        disp_w_ = disp_h_ = 0;
        show_picture_ = true;
        line_buf_.clear();
        pic_rows_.clear();
        rows_drawn_ = 0;
        rows_received_ = 0;
        canvas_ = false;
        canvas_rows_ = 0;
        final_rows_.clear();
    }
    int rows_received_ = 0; /* pixel rows of the picture received */
    /* On a live terminal tall enough for it, the picture's text rows are
       reserved when its size arrives and redrawn in place: first from the
       coarse pass, then row by row in full detail. */
    bool canvas_ = false;
    int indent_ = 0;
    int canvas_rows_ = 0;
    std::vector<bool> final_rows_;
    std::string row_string(int text_row) const;
    std::vector<int> drawn_row(int y) const;
    void redraw_canvas_rows(int first_pixel_row, int last_pixel_row);
    void redraw_canvas_row(int text_row);
    void para(const std::string &text, int indent, int style);
    Clock::time_point act_start_;

    /* Act 1. */
    void picture_uart(const std::string &chunk);
    void picture_line(const std::string &line);
    void draw_text_row(int row);
    std::string cell(int top, int bottom, int *fg, int *bg) const;

    bool act_raytrace(std::string *failure);
    bool act_coremark(std::string *failure);
    void closing_table();
};

/* Print prose word-wrapped to the terminal (at most 80 columns, and never the
   last column, so nothing wraps by itself). style: 0 plain, 1 muted, 2 bold accent. */
void Show::para(const std::string &text, int indent, int style)
{
    const int cols = std::max(24, std::min(80, term_.tty ? width() : 80));
    const size_t limit = static_cast<size_t>(std::max(8, cols - 1 - indent));
    std::string line;
    auto flush_line = [&]() {
        if (line.empty()) {
            return;
        }
        std::string shown = line;
        if (style == 1) {
            shown = muted(line);
        } else if (style == 2) {
            shown = bold(accent(line));
        }
        out(std::string(static_cast<size_t>(indent), ' ') + shown + "\n");
        line.clear();
    };
    size_t pos = 0;
    while (pos < text.size()) {
        size_t end = text.find(' ', pos);
        if (end == std::string::npos) {
            end = text.size();
        }
        const std::string word = text.substr(pos, end - pos);
        pos = end + 1;
        if (word.empty()) {
            continue;
        }
        if (!line.empty() && utf8_columns(line) + 1 + utf8_columns(word) > limit) {
            flush_line();
        }
        line += (line.empty() ? "" : " ") + word;
    }
    flush_line();
}

std::string time_text(double seconds)
{
    if (seconds < 60.0) {
        return std::to_string(std::max(5, static_cast<int>(seconds / 5.0 + 0.5) * 5)) + " s";
    }
    return std::to_string(static_cast<int>(seconds / 60.0 + 0.5)) + " min";
}

/*
 * The status line: progress first, then the core's figures over the last
 * samples, each part dropped from the end when the terminal is too narrow.
 * It is redrawn in place and only when its text changes.
 */
void Show::refresh_status()
{
    if (!term_.live) {
        return;
    }
    struct Part {
        std::string plain, shown;
    };
    std::vector<Part> parts;
    const double elapsed = std::chrono::duration<double>(Clock::now() - act_start_).count();
    if (window_.empty()) {
        parts.push_back({"starting the simulation", muted("starting the simulation")});
    } else {
        const Sample &now = window_.back();
        const Sample &then = window_.front();
        if (pic_height_ > 0) {
            std::string t =
                "row " + std::to_string(rows_received_) + " of " + std::to_string(pic_height_);
            parts.push_back({t, t});
        } else {
            std::string t = "cycle " + with_commas(now.cycle);
            parts.push_back({t, muted("cycle ") + with_commas(now.cycle)});
        }
        const double rate = sim_rate();
        if (rate > 0.0 && estimate_cycles_ > 0) {
            double left_cycles =
                static_cast<double>(estimate_cycles_) - static_cast<double>(now.cycle);
            if (left_cycles <= 0.0 && pic_height_ > 0 && rows_received_ > 0) {
                /* Past the estimate: go by the rows still to come. */
                left_cycles = static_cast<double>(now.cycle) * (pic_height_ - rows_received_) /
                              rows_received_;
            }
            left_cycles = std::max(0.0, left_cycles);
            std::string t = "about " + time_text(left_cycles / rate) + " left";
            parts.push_back({t, t});
        } else if (elapsed >= 3.0) {
            parts.push_back({"measuring speed", muted("measuring speed")});
        }
        if (window_.size() >= 2 && now.cycle > then.cycle) {
            const uint64_t cycles = now.cycle - then.cycle;
            const std::string ipc =
                fixed(static_cast<double>(now.instructions - then.instructions) /
                          static_cast<double>(cycles),
                      2);
            parts.push_back({ipc + " IPC", ipc + muted(" IPC")});
            const uint64_t branches = now.branches - then.branches;
            if (branches > 0) {
                const std::string hit =
                    percent(branches - (now.mispredicts - then.mispredicts), branches, 0);
                parts.push_back({hit + " branch hits", hit + muted(" branch hits")});
            }
            const std::string rob = std::to_string(static_cast<int>(
                static_cast<double>(now.rob_occupancy_sum - then.rob_occupancy_sum) /
                    static_cast<double>(cycles) +
                0.5));
            const std::string of = now.rob_depth > 0 ? "/" + std::to_string(now.rob_depth) : "";
            parts.push_back({"ROB " + rob + of, muted("ROB ") + rob + muted(of)});
            const std::string dual = percent(now.retired[2] - then.retired[2], cycles, 0);
            parts.push_back({dual + " dual-retire", dual + muted(" dual-retire")});
        }
    }
    const size_t limit = static_cast<size_t>(std::max(10, width() - 1));
    std::string plain = "  ", shown = "  ";
    for (size_t k = 0; k < parts.size(); ++k) {
        const std::string sep_plain = k == 0 ? "" : " | ";
        const std::string sep_shown = k == 0 ? "" : muted(" \u2502 ");
        /* Count each separator as three columns, as it is drawn. */
        if (utf8_columns(plain) + utf8_columns(sep_plain) + utf8_columns(parts[k].plain) > limit) {
            break;
        }
        plain += sep_plain + parts[k].plain;
        shown += sep_shown + parts[k].shown;
    }
    set_status(shown);
}

/* --- picture --------------------------------------------------------------- */

int b64_value(char c)
{
    if (c >= 'A' && c <= 'Z') {
        return c - 'A';
    }
    if (c >= 'a' && c <= 'z') {
        return c - 'a' + 26;
    }
    if (c >= '0' && c <= '9') {
        return c - '0' + 52;
    }
    if (c == '+') {
        return 62;
    }
    if (c == '/') {
        return 63;
    }
    return -1;
}

void Show::picture_uart(const std::string &chunk)
{
    for (char c : chunk) {
        if (c == '\n') {
            picture_line(line_buf_);
            line_buf_.clear();
        } else if (c != '\r') {
            line_buf_.push_back(c);
        }
    }
}

/* Decode n pixels of four base64 digits each (24 bits: 8 a channel), starting at
   line[4], into 0xRRGGBB. */
bool decode_pixels(const std::string &line, int n, std::vector<int> *px)
{
    if (line.size() < static_cast<size_t>(4 + 4 * n)) {
        return false;
    }
    px->assign(static_cast<size_t>(n), 0);
    for (int x = 0; x < n; ++x) {
        int v = 0;
        for (int k = 0; k < 4; ++k) {
            int d = b64_value(line[static_cast<size_t>(4 + 4 * x + k)]);
            v = (v << 6) | (d < 0 ? 0 : d);
        }
        (*px)[static_cast<size_t>(x)] = v;
    }
    return true;
}

const int kCoarse = 4; /* RT_COARSE in sw/apps/raytrace/raytrace.c */

/* A picture is never drawn narrower than this many pixels across. */
const int kMinDrawnWidth = 32;

/* The whole-number factor to scale a picture w pixels wide down by so that a row
   is narrower than the terminal (cols columns), or 0 when no factor keeps the
   picture at least kMinDrawnWidth pixels across. */
int pick_scale(int w, int cols)
{
    for (int s = 1;; ++s) {
        const int dw = (w + s - 1) / s;
        if (s > 1 && dw < kMinDrawnWidth) {
            return 0;
        }
        if (dw < cols) {
            return s;
        }
    }
}

/* The least terminal width pick_scale accepts for a picture w pixels wide. */
int least_columns(int w)
{
    int best = w + 1;
    for (int s = 2; (w + s - 1) / s >= kMinDrawnWidth; ++s) {
        best = (w + s - 1) / s + 1;
    }
    return best;
}

void Show::picture_line(const std::string &line)
{
    int w = 0, h = 0;
    if (std::sscanf(line.c_str(), "FROST ray tracer %dx%d", &w, &h) == 2 && w > 0 && h > 0) {
        pic_width_ = w;
        pic_height_ = h;
        pic_rows_.assign(static_cast<size_t>(h), {});
        final_rows_.assign(static_cast<size_t>(h), false);
        const int cols = term_.tty ? width() : 80;
        scale_ = pick_scale(w, cols);
        show_picture_ = scale_ > 0;
        if (!show_picture_) {
            scale_ = 1;
            clear_status();
            para("The picture needs a terminal at least " + std::to_string(least_columns(w)) +
                     " columns wide, and this one is " + std::to_string(cols) +
                     ". Widen the window to see it; the program runs and checks itself either "
                     "way.",
                 6,
                 1);
            draw_status();
            flush();
            return;
        }
        disp_w_ = (w + scale_ - 1) / scale_;
        disp_h_ = (h + scale_ - 1) / scale_;
        canvas_rows_ = (disp_h_ + 1) / 2;
        indent_ = std::max(0, (std::min(cols, 80) - disp_w_) / 2);
        /* Rows are redrawn in place only when the whole picture and the status
           line fit on the screen. */
        canvas_ = term_.live && term_.color != ColorMode::None && height() >= canvas_rows_ + 4;
        if (canvas_) {
            clear_status();
            out(std::string(static_cast<size_t>(canvas_rows_), '\n'));
            draw_status();
            flush();
        }
        return;
    }
    if (line.size() < 4 || (line[0] != 'P' && line[0] != 'C') || pic_width_ == 0) {
        return;
    }
    const int row = std::atoi(line.substr(1, 2).c_str());
    if (row < 0 || row >= pic_height_) {
        return;
    }
    if (!show_picture_) {
        if (line[0] == 'P') {
            rows_received_ = std::max(rows_received_, row + 1);
        }
        return;
    }
    std::vector<int> px;
    if (line[0] == 'C') {
        /* Coarse pass: each pixel stands for a block of kCoarse x kCoarse. */
        const int blocks = (pic_width_ + kCoarse - 1) / kCoarse;
        if (!canvas_ || !decode_pixels(line, blocks, &px)) {
            return;
        }
        std::vector<int> wide(static_cast<size_t>(pic_width_));
        for (int x = 0; x < pic_width_; ++x) {
            wide[static_cast<size_t>(x)] = px[static_cast<size_t>(x / kCoarse)];
        }
        const int last = std::min(pic_height_, row + kCoarse);
        for (int y = row; y < last; ++y) {
            if (!final_rows_[static_cast<size_t>(y)]) {
                pic_rows_[static_cast<size_t>(y)] = wide;
            }
        }
        redraw_canvas_rows(row, last - 1);
        return;
    }
    if (!decode_pixels(line, pic_width_, &px)) {
        return;
    }
    pic_rows_[static_cast<size_t>(row)] = px;
    final_rows_[static_cast<size_t>(row)] = true;
    rows_received_ = std::max(rows_received_, row + 1);
    if (canvas_) {
        redraw_canvas_rows(row, row);
        return;
    }
    /* Print each text row once all the pixel rows it covers have arrived. */
    while (rows_drawn_ < canvas_rows_ &&
           rows_received_ >= std::min(pic_height_, 2 * (rows_drawn_ + 1) * scale_)) {
        draw_text_row(rows_drawn_);
        rows_drawn_++;
    }
}

/* xterm's 6x6x6 color cube has these levels in each channel; its 24 grays
   (palette entries 232 to 255) run from 8 to 238 in steps of 10. */
const int kCube[6] = {0, 95, 135, 175, 215, 255};

struct Lab {
    double l, a, b;
};

double srgb_to_linear(int v)
{
    const double c = v / 255.0;
    return c <= 0.04045 ? c / 12.92 : std::pow((c + 0.055) / 1.055, 2.4);
}

/* CIELAB, in which equal distances look about equally different. */
Lab to_lab(int r, int g, int b)
{
    const double lr = srgb_to_linear(r), lg = srgb_to_linear(g), lb = srgb_to_linear(b);
    const double x = (0.4124 * lr + 0.3576 * lg + 0.1805 * lb) / 0.9505;
    const double y = 0.2126 * lr + 0.7152 * lg + 0.0722 * lb;
    const double z = (0.0193 * lr + 0.1192 * lg + 0.9505 * lb) / 1.089;
    auto f = [](double t) { return t > 0.008856 ? std::cbrt(t) : 7.787 * t + 16.0 / 116.0; };
    const double fx = f(x), fy = f(y), fz = f(z);
    return {116.0 * fy - 16.0, 500.0 * (fx - fy), 200.0 * (fy - fz)};
}

/*
 * The 256-color palette entry (the 6 x 6 x 6 cube and the 24 grays) nearest to a
 * 0xRRGGBB color in CIELAB, so dark reds stay red. No dithering: at this size
 * its noise is as large as the picture's detail. Cached per color.
 */
int ansi256(int rgb)
{
    static std::map<int, int> cache;
    static std::vector<Lab> palette;
    auto hit = cache.find(rgb);
    if (hit != cache.end()) {
        return hit->second;
    }
    if (palette.empty()) {
        for (int i = 16; i < 256; ++i) {
            int r, g, b;
            if (i < 232) {
                r = kCube[(i - 16) / 36];
                g = kCube[((i - 16) / 6) % 6];
                b = kCube[(i - 16) % 6];
            } else {
                r = g = b = 8 + 10 * (i - 232);
            }
            palette.push_back(to_lab(r, g, b));
        }
    }
    const Lab p = to_lab((rgb >> 16) & 255, (rgb >> 8) & 255, rgb & 255);
    int best = 16;
    double best_d = 1e30;
    for (size_t k = 0; k < palette.size(); ++k) {
        const double dl = p.l - palette[k].l, da = p.a - palette[k].a, db = p.b - palette[k].b;
        /* Lightness counts double, so dark reds stay dark. */
        const double d = 2.0 * dl * dl + da * da + db * db;
        if (d < best_d) {
            best_d = d;
            best = 16 + static_cast<int>(k);
        }
    }
    cache[rgb] = best;
    return best;
}

/* One half-block cell: the top pixel as foreground, the bottom (or -1 when
   there is none) as background. */
std::string Show::cell(int top, int bottom, int *fg, int *bg) const
{
    std::string s;
    if (term_.color == ColorMode::TrueColor) {
        char buf[64];
        if (top != *fg) {
            std::snprintf(buf,
                          sizeof(buf),
                          "\x1b[38;2;%d;%d;%dm",
                          (top >> 16) & 255,
                          (top >> 8) & 255,
                          top & 255);
            s += buf;
            *fg = top;
        }
        if (bottom >= 0 && bottom != *bg) {
            std::snprintf(buf,
                          sizeof(buf),
                          "\x1b[48;2;%d;%d;%dm",
                          (bottom >> 16) & 255,
                          (bottom >> 8) & 255,
                          bottom & 255);
            s += buf;
            *bg = bottom;
        }
    } else {
        const int f = ansi256(top);
        if (f != *fg) {
            s += "\x1b[38;5;" + std::to_string(f) + "m";
            *fg = f;
        }
        if (bottom >= 0) {
            const int b = ansi256(bottom);
            if (b != *bg) {
                s += "\x1b[48;5;" + std::to_string(b) + "m";
                *bg = b;
            }
        }
    }
    s += "▀";
    return s;
}

int luminance(int rgb)
{
    const int r = (rgb >> 16) & 255, g = (rgb >> 8) & 255, b = rgb & 255;
    return (2126 * r + 7152 * g + 722 * b) / 10000;
}

/* Drawn pixel row y: the mean of the scale x scale blocks of received pixels. */
std::vector<int> Show::drawn_row(int y) const
{
    std::vector<int> row(static_cast<size_t>(disp_w_), 0);
    const int y0 = y * scale_, y1 = std::min(pic_height_, y0 + scale_);
    for (int x = 0; x < disp_w_; ++x) {
        const int x0 = x * scale_, x1 = std::min(pic_width_, x0 + scale_);
        long r = 0, g = 0, b = 0, n = 0;
        for (int yy = y0; yy < y1; ++yy) {
            const std::vector<int> &src = pic_rows_[static_cast<size_t>(yy)];
            for (int xx = x0; xx < x1 && static_cast<size_t>(xx) < src.size(); ++xx) {
                const int v = src[static_cast<size_t>(xx)];
                r += (v >> 16) & 255;
                g += (v >> 8) & 255;
                b += v & 255;
                ++n;
            }
        }
        if (n > 0) {
            row[static_cast<size_t>(x)] = (static_cast<int>((r + n / 2) / n) << 16) |
                                          (static_cast<int>((g + n / 2) / n) << 8) |
                                          static_cast<int>((b + n / 2) / n);
        }
    }
    return row;
}

std::string Show::row_string(int row) const
{
    const std::vector<int> top = drawn_row(2 * row);
    const std::vector<int> bottom =
        2 * row + 1 < disp_h_ ? drawn_row(2 * row + 1) : std::vector<int>();
    std::string s(static_cast<size_t>(indent_), ' ');
    if (term_.color == ColorMode::None) {
        static const char ramp[] = " .,:;=+*%#@";
        const int levels = static_cast<int>(sizeof(ramp)) - 1;
        for (int x = 0; x < disp_w_; ++x) {
            int lum = luminance(top[static_cast<size_t>(x)]);
            if (!bottom.empty()) {
                lum = (lum + luminance(bottom[static_cast<size_t>(x)])) / 2;
            }
            s.push_back(ramp[std::min(levels - 1, lum * levels / 256)]);
        }
    } else {
        int fg = -1, bg = -1;
        for (int x = 0; x < disp_w_; ++x) {
            s += cell(top[static_cast<size_t>(x)],
                      bottom.empty() ? -1 : bottom[static_cast<size_t>(x)],
                      &fg,
                      &bg);
        }
        s += "\x1b[0m";
    }
    return s;
}

/* Redraw the reserved text rows that show pixel rows first to last. */
void Show::redraw_canvas_rows(int first, int last)
{
    const int hi = std::min(canvas_rows_ - 1, (last / scale_) / 2);
    for (int t = (first / scale_) / 2; t <= hi; ++t) {
        redraw_canvas_row(t);
    }
}

/* Redraw one reserved text row of the picture; the cursor stays on the status line. */
void Show::redraw_canvas_row(int row)
{
    const int up = canvas_rows_ - row;
    out("\r\x1b[" + std::to_string(up) + "A\x1b[K" + row_string(row) + "\r\x1b[" +
        std::to_string(up) + "B\x1b[K");
    draw_status();
    flush();
}

void Show::draw_text_row(int row)
{
    clear_status();
    out(row_string(row) + "\n");
    draw_status();
    flush();
}

std::vector<std::string> runner_args(const Options &opt, const std::string &app_dir)
{
    /* The file that bounds the counted region (demo/make_regions.py), when the
       program has one. */
    const std::string regions = app_dir + "/regions.txt";
    std::vector<std::string> extra;
    if (access(regions.c_str(), R_OK) == 0) {
        extra = {"--regions", regions};
    }
    std::vector<std::string> args = {"--mem-dir",
                                     app_dir,
                                     "--threads",
                                     std::to_string(opt.threads),
                                     "--max-cycles",
                                     "40000000",
                                     "--stop",
                                     "<<PASS>>",
                                     "--stats",
                                     "/dev/fd/3",
                                     "--stats-interval",
                                     "1000",
                                     "--quiet-summary"};
    args.insert(args.end(), extra.begin(), extra.end());
    return args;
}

std::string runner_binary(const Options &opt)
{
    return opt.bin_dir + "/frost-native-t" + std::to_string(opt.threads);
}

/* First line of the runner's own error output, for an unexpected stop. */
std::string first_error_line(const std::string &errors)
{
    size_t start = errors.find_first_not_of("\r\n ");
    if (start == std::string::npos) {
        return "";
    }
    size_t end = errors.find('\n', start);
    std::string line =
        errors.substr(start, end == std::string::npos ? std::string::npos : end - start);
    while (!line.empty() && (line.back() == '\r' || line.back() == ' ')) {
        line.pop_back();
    }
    return line;
}

std::string no_region_message(const char *what)
{
    return std::string("The ") + what +
           " run did not report the cycles of its counted region: the program was staged "
           "without its regions file (demo/make_regions.py), so the closing table cannot "
           "be shown.";
}

std::string unexpected_stop(const char *what, const RunResult &r)
{
    if (r.exit_status >= 128) {
        return std::string("The ") + what + " simulation was stopped.";
    }
    std::string detail = first_error_line(r.errors);
    return std::string("The ") + what + " simulation stopped unexpectedly" +
           (detail.empty() ? "." : ": " + detail);
}

/*
 * Expected cycles, for the time-left estimate and the slow-host check only:
 * measured on the RTL as about 800 cycles a pixel for the ray tracer and
 * 216,000 cycles for the CoreMark iteration plus 108,000 around it. Nothing
 * printed as a result depends on them.
 */
const uint64_t kCyclesPerPixel = 800;
const uint64_t kCoreMarkCyclesPerIteration = 216000;
const uint64_t kCoreMarkSetupCycles = 108000;
/* A host that would need longer than this for the full picture gets the small one. */
const double kFullPictureLimitSeconds = 360.0;

void Show::check_slow_host()
{
    if (small_ || opt_.full || switching_ || g_child <= 0) {
        return;
    }
    /* Decide once the rate has settled, and only early: a picture well under
       way is never thrown away. */
    const double elapsed = std::chrono::duration<double>(Clock::now() - act_start_).count();
    const double rate = sim_rate();
    if (elapsed < 5.0 || elapsed > 30.0 || rate <= 0.0) {
        return;
    }
    if (static_cast<double>(estimate_cycles_) / rate > kFullPictureLimitSeconds) {
        switching_ = true;
        kill(g_child, SIGTERM);
    }
}

bool Show::act_raytrace(std::string *failure)
{
    out("\n");
    para("1 \u00b7 A picture, ray traced by the simulated CPU", 2, 2);
    para("A glossy red sphere and a glossy blue sphere on a tiled floor under a sunset, with "
         "highlights and shadows.",
         6,
         1);
    para("Every pixel below is computed by the simulated processor running a real program, "
         "thousands of instructions for every row. Simulating every wire for every clock cycle "
         "is at least ten thousand times slower than hardware.",
         6,
         1);
    if (term_.live) {
        para("The bottom line follows the core: progress, instructions per cycle, branches "
             "predicted correctly, reorder-buffer entries in use.",
             6,
             1);
    }
    out("\n");
    flush();
    RunResult r;
    for (;;) {
        const std::string app =
            opt_.apps_dir + (small_ ? "/raytrace_small_bram" : "/raytrace_bram");
        reset_window();
        reset_picture();
        switching_ = false;
        act_start_ = Clock::now();
        /* Until the program announces its size, assume the picture it was built for. */
        estimate_cycles_ = (small_ ? 24 * 12 : 76 * 44) * kCyclesPerPixel;
        set_status(starting_status());
        r = run_program(
            runner_binary(opt_),
            runner_args(opt_, app),
            [this](const std::string &chunk) { picture_uart(chunk); },
            [this](const Sample &s) {
                on_sample(s);
                note_rate(s);
            },
            [this]() {
                refresh_status();
                check_slow_host();
            });
        end_status();
        if (g_signal != 0) {
            return false;
        }
        if (!switching_) {
            break;
        }
        const double rate = sim_rate();
        out("\n");
        para("Simulating " + with_commas(static_cast<uint64_t>(rate + 0.5)) +
                 " cycles a second here, the full picture needs about " +
                 time_text(static_cast<double>(estimate_cycles_) / rate) +
                 ". Drawing the small one instead; --full draws the full one.",
             2,
             0);
        out("\n");
        flush();
        small_ = true;
    }
    act_totals_[0] = r.last;
    total_cycles_ += r.last.cycle;
    if (r.uart.find("does not match the reference") != std::string::npos ||
        r.uart.find("<<FAIL>>") != std::string::npos) {
        *failure = "The ray tracer's picture did not match its reference checksum.";
        return false;
    }
    if (r.exit_status != 0 || r.uart.find("matches the reference") == std::string::npos) {
        *failure = unexpected_stop("ray tracer", r);
        return false;
    }
    if (!r.last.has_region) {
        *failure = no_region_message("ray tracer");
        return false;
    }
    const uint64_t per_row =
        pic_height_ > 0 ? r.last.instructions / static_cast<uint64_t>(pic_height_) : 0;
    out("\n");
    if (term_.fallback_256 && show_picture_) {
        para("256 colors here; for full color use -e COLORTERM=truecolor or --truecolor", 2, 0);
    }
    para("Above: " + std::to_string(pic_width_) + " x " + std::to_string(pic_height_) +
             " pixels, " + with_commas(r.last.instructions) + " instructions (about " +
             with_commas(per_row) + " a row)" +
             (scale_ > 1 ? ", drawn at 1/" + std::to_string(scale_) + " size" : ""),
         2,
         0);
    para("in " + with_commas(r.last.cycle) + " clock cycles, checksum verified.", 2, 0);
    flush();
    return true;
}

bool find_number(const std::string &text, const std::string &label, uint64_t *value)
{
    size_t pos = text.find(label);
    if (pos == std::string::npos) {
        return false;
    }
    pos = text.find(':', pos);
    if (pos == std::string::npos) {
        return false;
    }
    ++pos;
    while (pos < text.size() && text[pos] == ' ') {
        ++pos;
    }
    if (pos >= text.size() || text[pos] < '0' || text[pos] > '9') {
        return false;
    }
    *value = std::strtoull(text.c_str() + pos, nullptr, 10);
    return true;
}

/* The hexadecimal value after "label" and a colon, or false. */
bool find_hex(const std::string &text, const std::string &label, uint64_t *value)
{
    size_t pos = text.find(label);
    if (pos == std::string::npos) {
        return false;
    }
    pos = text.find(':', pos);
    if (pos == std::string::npos) {
        return false;
    }
    ++pos;
    while (pos < text.size() && text[pos] == ' ') {
        ++pos;
    }
    if (text.compare(pos, 2, "0x") != 0) {
        return false;
    }
    char *end = nullptr;
    *value = std::strtoull(text.c_str() + pos + 2, &end, 16);
    return end != text.c_str() + pos + 2;
}

/*
 * CoreMark's own CRCs for the one-iteration 2K run the demonstration builds
 * (the values CI checks in the unfiltered output). CoreMark compares them
 * itself and prints "Correct operation validated."; they are checked here as
 * well so that a run is never shown as passed on the strength of a sentence.
 */
bool coremark_crcs_correct(const std::string &uart)
{
    static const struct {
        const char *label;
        uint64_t expected;
    } crcs[] = {{"seedcrc", 0xe9f5},
                {"crclist", 0xe714},
                {"crcmatrix", 0x1fd7},
                {"crcstate", 0x8e3a},
                {"crcfinal", 0xe714}};
    for (const auto &c : crcs) {
        uint64_t got = 0;
        if (!find_hex(uart, c.label, &got) || got != c.expected) {
            return false;
        }
    }
    return true;
}

bool Show::act_coremark(std::string *failure)
{
    const std::string app = opt_.apps_dir + "/coremark_bram";
    out("\n");
    para("2 · CoreMark, the standard CPU benchmark", 2, 2);
    para("Linked lists, matrix arithmetic and a state machine, with CoreMark's own checks of "
         "every result.",
         6,
         1);
    out("\n");
    flush();
    reset_window();
    reset_picture();
    act_start_ = Clock::now();
    estimate_cycles_ = kCoreMarkCyclesPerIteration + kCoreMarkSetupCycles;
    set_status(starting_status());
    RunResult r = run_program(
        runner_binary(opt_),
        runner_args(opt_, app),
        [](const std::string &) {},
        [this](const Sample &s) {
            on_sample(s);
            note_rate(s);
        },
        [this]() { refresh_status(); });
    end_status();
    if (g_signal != 0) {
        return false;
    }
    act_totals_[1] = r.last;
    total_cycles_ += r.last.cycle;
    /* Success needs all of: a clean exit, no failure marker, the pass marker,
       CoreMark's validation sentence, its counts and every CRC. */
    if (r.exit_status != 0) {
        *failure = unexpected_stop("CoreMark", r);
        return false;
    }
    uint64_t iterations = 0, ticks = 0;
    const bool parsed = find_number(r.uart, "Iterations       :", &iterations) &&
                        find_number(r.uart, "Total ticks", &ticks) && iterations > 0 && ticks > 0;
    const bool failed = r.uart.find("<<FAIL>>") != std::string::npos ||
                        r.uart.find("ERROR") != std::string::npos ||
                        r.uart.find("Errors detected") != std::string::npos ||
                        r.uart.find("Cannot validate operation") != std::string::npos;
    const bool validated = r.uart.find("Correct operation validated.") != std::string::npos &&
                           r.uart.find("<<PASS>>") != std::string::npos;
    if (failed || !validated || !parsed || !coremark_crcs_correct(r.uart)) {
        *failure = "The CoreMark run failed: its own validation of its results did not pass.";
        return false;
    }
    /* The closing table counts CoreMark's timed loop; its cycles are the ticks
       CoreMark reports, or the table would contradict the line above it. Without
       region counters (a program staged without its regions file) the table cannot
       be shown, and this check cannot be skipped. */
    if (!r.last.has_region) {
        *failure = no_region_message("CoreMark");
        return false;
    }
    if (r.last.region_cycles != ticks) {
        *failure = "The CoreMark run failed: the cycles counted for its timed loop (" +
                   with_commas(r.last.region_cycles) + ") are not the ticks it reports (" +
                   with_commas(ticks) + ").";
        return false;
    }
    /* What this run establishes: the iterations ran and CoreMark's own result
       checks all passed, in this many cycles by CoreMark's own count. The
       score is the project's published one, measured on hardware over many
       more iterations, so the run does not compute one. */
    para(with_commas(iterations) + (iterations == 1 ? " iteration" : " iterations") +
             ", every CRC correct (validated by CoreMark)",
         2,
         0);
    if (iterations == 1) {
        para(
            with_commas(ticks) + " clock cycles for this first iteration, from a cold start", 2, 0);
    } else {
        para(with_commas(ticks) + " clock cycles, " +
                 with_commas((ticks + iterations / 2) / iterations) + " per iteration",
             2,
             0);
    }
    para("FROST's published CoreMark score is in its README.", 2, 0);
    flush();
    return true;
}

void Show::closing_table()
{
    const Sample a = counted(act_totals_[0]);
    const Sample b = counted(act_totals_[1]);
    const uint64_t depth = std::max(act_totals_[0].rob_depth, act_totals_[1].rob_depth);
    /* Three columns need 70; on a narrower terminal each figure pair gets a line
       under its label. */
    const bool stacked = (term_.tty ? width() : 80) < 72;
    auto row = [this,
                stacked](const std::string &label, const std::string &x, const std::string &y) {
        char buf[160];
        if (stacked) {
            para(label, 2, 0);
            std::snprintf(buf, sizeof(buf), "    %s | %s\n", x.c_str(), y.c_str());
        } else {
            std::snprintf(
                buf, sizeof(buf), "  %-40s%14s%14s\n", label.c_str(), x.c_str(), y.c_str());
        }
        out(buf);
    };
    auto ipc = [](const Sample &s) {
        return s.cycle == 0
                   ? std::string("-")
                   : fixed(static_cast<double>(s.instructions) / static_cast<double>(s.cycle), 2);
    };
    auto rob = [](const Sample &s) {
        return s.cycle == 0
                   ? std::string("-")
                   : fixed(static_cast<double>(s.rob_occupancy_sum) / static_cast<double>(s.cycle),
                           1);
    };
    auto active = [](const Sample &s, int k) { return percent(s.retired[k], s.cycle, 0); };
    out("\n");
    para("What the core did", 2, 2);
    para("Counted while rendering and inside CoreMark's timed loop; start-up and character "
         "output are left out. The totals above and below are for the whole programs.",
         2,
         1);
    if (stacked) {
        para("Ray tracer | CoreMark", 2, 1);
    } else {
        char head[160];
        std::snprintf(head, sizeof(head), "  %-40s%14s%14s\n", "", "Ray tracer", "CoreMark");
        out(muted(head));
    }
    row("Instructions", with_commas(a.instructions), with_commas(b.instructions));
    row("Clock cycles", with_commas(a.cycle), with_commas(b.cycle));
    row("Instructions per cycle", ipc(a), ipc(b));
    row("Cycles retiring 2 instructions", active(a, 2), active(b, 2));
    row(depth > 0 ? "Average reorder-buffer entries (of " + std::to_string(depth) + ")"
                  : "Average reorder-buffer entries",
        rob(a),
        rob(b));
    row("Branches", with_commas(a.branches), with_commas(b.branches));
    row("Branches predicted correctly",
        percent(a.branches - a.mispredicts, a.branches, 1),
        percent(b.branches - b.mispredicts, b.branches, 1));
    flush();
}

std::string duration_text(double seconds)
{
    const int total = static_cast<int>(seconds + 0.5);
    if (total < 60) {
        return std::to_string(total) + " s";
    }
    return std::to_string(total / 60) + " min " + std::to_string(total % 60) + " s";
}

int Show::run()
{
    const auto start = Clock::now();
    small_ = opt_.quick;
    para(
        "FROST \u00b7 a two-wide out-of-order RISC-V processor (RV64GCB), in SystemVerilog.", 0, 0);
    para(std::string("What runs here is its RTL, simulated clock cycle by clock cycle with "
                     "Verilator; the run takes ") +
             (opt_.quick ? "about a minute." : "a few minutes."),
         0,
         0);
    flush();
    if (term_.live) {
        std::fputs("\x1b[?25l", stdout);
        g_cursor_hidden = true;
    }

    std::string failure;
    bool ok = act_raytrace(&failure) && g_signal == 0 && act_coremark(&failure);
    restore_terminal();
    if (!ok || g_signal != 0) {
        if (g_signal != 0) {
            return 128 + g_signal;
        }
        out("\n");
        para(failure, 0, 0);
        flush();
        return 1;
    }
    closing_table();
    const double seconds = std::chrono::duration<double>(Clock::now() - start).count();
    out("\n");
    para("Both programs verified their own results.", 2, 0);
    std::string rate;
    if (seconds > 0.0) {
        rate =
            ", " +
            with_commas(static_cast<uint64_t>(static_cast<double>(total_cycles_) / seconds + 0.5)) +
            " a second";
    }
    para(with_commas(total_cycles_) + " clock cycles simulated in " + duration_text(seconds) +
             rate + ".",
         2,
         0);
    const int cols = term_.tty ? width() : 80;
    if (cols < 42) {
        para("FROST is open source on GitHub: twosigma/frost", 2, 0);
    } else if (cols < 62) {
        para("FROST is open source:", 2, 0);
        out("  " + accent("https://github.com/twosigma/frost") + "\n");
    } else {
        out("  FROST is open source: " + accent("https://github.com/twosigma/frost") + "\n");
    }
    flush();
    return 0;
}

/* True for a TERM value that names a direct-color (24-bit) terminal. */
bool term_is_direct_color(const char *term)
{
    return term != nullptr &&
           (std::strstr(term, "-direct") != nullptr || std::strstr(term, "truecolor") != nullptr ||
            std::strstr(term, "24bit") != nullptr);
}

/*
 * Whether a TERM value names a terminal known to support cursor movement,
 * line erase and in-place redraw: the common families (xterm and everything
 * that follows it, screen, tmux, rxvt, VT100 and later, the Linux console,
 * alacritty, kitty, foot, wezterm, ghostty, konsole, gnome, st, iterm). Anything
 * else, a hard-copy or unknown type included, gets plain lines.
 */
bool term_supports_controls(const char *term)
{
    if (term == nullptr || term[0] == '\0') {
        return false;
    }
    std::string base = term;
    const size_t dash = base.find('-');
    if (dash != std::string::npos) {
        base.resize(dash);
    }
    static const char *const families[] = {"xterm",
                                           "screen",
                                           "tmux",
                                           "rxvt",
                                           "linux",
                                           "alacritty",
                                           "kitty",
                                           "foot",
                                           "wezterm",
                                           "ghostty",
                                           "konsole",
                                           "gnome",
                                           "st",
                                           "iterm",
                                           "iterm2"};
    for (const char *family : families) {
        if (base == family) {
            return true;
        }
    }
    if (base.compare(0, 6, "screen") == 0 || base.compare(0, 5, "xterm") == 0 ||
        base.compare(0, 4, "rxvt") == 0) {
        return true; /* screen.linux, xterm.js, rxvt-unicode and the like */
    }
    /* vt100 and later (vt102, vt220, vt320, ...), not the vt52 or vt50 family. */
    if (base.compare(0, 2, "vt") == 0 && base.size() > 2 &&
        base.find_first_not_of("0123456789", 2) == std::string::npos) {
        return std::atoi(base.c_str() + 2) >= 100;
    }
    return false;
}

void usage()
{
    std::fputs("Usage: frost-show [--quick | --full] [--threads <1|4|8>]\n"
               "                  [--truecolor | --256 | --color auto|truecolor|256|none]\n"
               "                  [--bin-dir <dir>] [--apps-dir <dir>]\n",
               stderr);
}

} // namespace

int main(int argc, char **argv)
{
    Options opt;
    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto value = [&](const char *flag) -> std::string {
            if (i + 1 >= argc) {
                std::fprintf(stderr, "Error: %s requires a value\n", flag);
                std::exit(2);
            }
            return argv[++i];
        };
        if (arg == "--quick") {
            opt.quick = true;
        } else if (arg == "--full") {
            opt.full = true;
        } else if (arg == "--threads") {
            opt.threads = std::atoi(value("--threads").c_str());
        } else if (arg == "--color") {
            opt.color = value("--color");
        } else if (arg == "--truecolor") {
            opt.color = "truecolor";
        } else if (arg == "--256") {
            opt.color = "256";
        } else if (arg == "--bin-dir") {
            opt.bin_dir = value("--bin-dir");
        } else if (arg == "--apps-dir") {
            opt.apps_dir = value("--apps-dir");
        } else if (arg == "-h" || arg == "--help") {
            usage();
            return 0;
        } else {
            std::fprintf(stderr, "Error: unrecognized argument '%s'\n", arg.c_str());
            usage();
            return 2;
        }
    }
    if (opt.threads <= 0) {
        std::fprintf(stderr, "Error: --threads must be positive\n");
        return 2;
    }

    Terminal term;
    term.tty = isatty(STDOUT_FILENO) != 0;
    const char *term_env = std::getenv("TERM");
    const bool dumb = !term_supports_controls(term_env);
    const char *no_color = std::getenv("NO_COLOR");
    const char *colorterm = std::getenv("COLORTERM");
    if (opt.color == "truecolor") {
        term.color = ColorMode::TrueColor;
    } else if (opt.color == "256") {
        term.color = ColorMode::Ansi256;
    } else if (opt.color == "none") {
        term.color = ColorMode::None;
    } else if (opt.color != "auto") {
        std::fprintf(stderr, "Error: --color must be auto, truecolor, 256 or none\n");
        return 2;
    } else if ((no_color != nullptr && no_color[0] != '\0') || !term.tty || dumb) {
        term.color = ColorMode::None;
    } else if (colorterm != nullptr &&
               (std::strcmp(colorterm, "truecolor") == 0 || std::strcmp(colorterm, "24bit") == 0)) {
        term.color = ColorMode::TrueColor;
    } else if (term_is_direct_color(term_env)) {
        term.color = ColorMode::TrueColor;
    } else {
        term.color = ColorMode::Ansi256;
        term.fallback_256 = true;
    }
    /* Cursor movement, erase and in-place redraw only on a real terminal that
       can do them, and never with NO_COLOR set. */
    term.live = term.tty && !dumb && !(no_color != nullptr && no_color[0] != '\0');
    if (term.tty) {
        struct winsize ws;
        if (ioctl(STDOUT_FILENO, TIOCGWINSZ, &ws) == 0 && ws.ws_col > 0) {
            term.width = ws.ws_col;
        }
    }

    struct sigaction sa;
    std::memset(&sa, 0, sizeof(sa));
    sa.sa_handler = on_signal;
    sigaction(SIGINT, &sa, nullptr);
    sigaction(SIGTERM, &sa, nullptr);
    std::signal(SIGPIPE, SIG_IGN);

    Show show(opt, term);
    int rc = show.run();
    restore_terminal();
    return rc;
}
