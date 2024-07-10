const std = @import("std");

var cpu_freq: u64 = 0;
var calibrated: bool = false;

inline fn rdtsc() u64 {
    var hi: u64 = 0;
    var lo: u64 = 0;

    asm volatile (
        \\rdtsc 
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );

    return ((hi << 32) | (lo));
}

pub const Timer = struct {
    // get an estimate for cpu_frequency relative to real world time
    pub fn calibrate(millis_to_wait: u64) void {
        const os_freq = getOSTimeFrequency();
        const os_start = readOSTimer();
        const os_wait_time = @divTrunc(os_freq * millis_to_wait, 1000);
        var os_end: u64 = 0;
        var os_elapsed: u64 = 0;

        const cpu_start = readCPUTimer();
        while (os_elapsed < os_wait_time) {
            os_end = readOSTimer();
            os_elapsed = os_end - os_start;
        }
        const cpu_end = readCPUTimer();
        const cpu_elapsed = cpu_end - cpu_start;

        cpu_freq = @divTrunc(os_freq * cpu_elapsed, os_elapsed);
        calibrated = true;
    }

    pub fn isCalibrated() bool {
        return calibrated;
    }

    // us / s
    pub fn getOSTimeFrequency() u64 {
        return @intCast(std.time.us_per_s);
    }

    // in micros
    pub fn readOSTimer() u64 {
        return @intCast(std.time.microTimestamp());
    }

    // in "clocks"
    pub inline fn readCPUTimer() u64 {
        return rdtsc();
    }

    // in seconds
    pub fn getRealWorldCPUTime() f64 {
        return if (calibrated) @as(f64, @floatFromInt(readCPUTimer())) / @as(f64, @floatFromInt(cpu_freq)) else 0;
    }

    pub inline fn start() f64 {
        return getRealWorldCPUTime();
    }

    pub fn elapsed(start_time: f64, elapsed_total: ?*f64) f64 {
        const e = getRealWorldCPUTime() - start_time;
        if (elapsed_total != null) elapsed_total.?.* += e;
        return e;
    }
};
