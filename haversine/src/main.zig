const std = @import("std");
const json = @import("json.zig");
const time = @import("time.zig");

const assert = std.debug.assert;
const print = std.debug.print;

const N_THREADS = 8;
const N_PAIRS = 100_000;

const LAT_MIN = -90.0;
const LAT_MAX = 90.0;
const LON_MIN = -180.0;
const LON_MAX = 180.0;
const EARTH_RADIUS = 6372.8;

fn square(v: f64) f64 {
    return v * v;
}

fn deg2rad(deg: f64) f64 {
    return 0.01745329251994329677 * deg;
}

// NOTE(bryson): earth_radius is expected to be 6372.8
fn referenceHaversine(x0: f64, x1: f64, y0: f64, y1: f64) f64 {
    var lat1 = y0;
    var lat2 = y1;
    const lon1 = x0;
    const lon2 = x1;

    const dlat = deg2rad(lat2 - lat1);
    const dlon = deg2rad(lon2 - lon1);
    lat1 = deg2rad(lat1);
    lat2 = deg2rad(lat2);

    const a = square(std.math.sin(dlat / 2.0)) + std.math.cos(lat1) * std.math.cos(lat2) * square(std.math.sin(dlon / 2.0));
    const c = 2.0 * std.math.asin(std.math.sqrt(a));

    const res = EARTH_RADIUS * c;

    return res;
}

pub inline fn randRangef64(rand: std.Random, min: f64, max: f64) f64 {
    return (rand.float(f64) * (max - min)) + min;
}

const HaversineJsonData = struct {
    const Pair = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
    pairs: []Pair,

    pub fn init(allocator: std.mem.Allocator, rand: std.Random, count: u64) HaversineJsonData {
        var data = std.mem.zeroes(HaversineJsonData);
        data.pairs = allocator.alloc(Pair, count) catch unreachable;

        const worker = struct {
            pub fn gen(wait_group: *std.Thread.WaitGroup, arr: []Pair, start_idx: usize, len: u64, rng: std.Random) void {
                wait_group.start();
                defer wait_group.finish();

                const chunk_dim = 32.0;
                const chunk_lat_min = randRangef64(rng, LAT_MIN, LAT_MAX - chunk_dim);
                const chunk_lon_min = randRangef64(rng, LON_MIN, LON_MAX - chunk_dim);

                for (start_idx..(start_idx + len)) |idx| {
                    arr[idx] = .{
                        .x0 = randRangef64(rng, chunk_lat_min, chunk_lat_min + chunk_dim),
                        .y0 = randRangef64(rng, chunk_lon_min, chunk_lon_min + chunk_dim),
                        .x1 = randRangef64(rng, chunk_lat_min, chunk_lat_min + chunk_dim),
                        .y1 = randRangef64(rng, chunk_lon_min, chunk_lon_min + chunk_dim),
                    };
                }
            }
        };

        var pool: std.Thread.Pool = undefined;
        pool.init(.{ .allocator = allocator }) catch unreachable;
        defer pool.deinit();

        var wait_group: std.Thread.WaitGroup = undefined;
        wait_group.reset();

        const chunk_size = count / N_THREADS;
        for (0..N_THREADS) |i| pool.spawn(worker.gen, .{ &wait_group, data.pairs, i * chunk_size, chunk_size, rand }) catch unreachable;
        pool.waitAndWork(&wait_group);

        return data;
    }

    pub fn initFromFile(allocator: std.mem.Allocator, path: []const u8) !std.json.Parsed(HaversineJsonData) {
        const bytes = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(bytes);
        return try std.json.parseFromSlice(HaversineJsonData, allocator, bytes, .{});
    }

    pub fn initFromFile2(allocator: std.mem.Allocator, path: []const u8) !HaversineJsonData {
        var pair_data = std.mem.zeroes(HaversineJsonData);
        pair_data.pairs = allocator.alloc(Pair, N_PAIRS) catch unreachable;

        const data = try std.fs.cwd().readFileAlloc(allocator, path, std.math.maxInt(usize));
        defer allocator.free(data);

        const j = json.JSONParser.parseJSON(allocator, data).?;
        defer j.deinit();

        const pairs = j.lookup("pairs");
        if (pairs != null) {
            var idx: u32 = 0;
            var element = pairs.?.first_sub_element;
            while (element != null) : (element = element.?.next_sibling) {
                pair_data.pairs[idx] = .{
                    .x0 = element.?.convertElementToF64("x0"),
                    .y0 = element.?.convertElementToF64("y0"),
                    .x1 = element.?.convertElementToF64("x1"),
                    .y1 = element.?.convertElementToF64("y1"),
                };
                idx += 1;
            }
        }

        return pair_data;
    }
};

fn generateInputFile(allocator: std.mem.Allocator, out_file: std.fs.File, rand: std.Random, count: u64) !f64 {
    var arena_allocator = std.heap.ArenaAllocator.init(allocator);
    defer arena_allocator.deinit();
    const data = HaversineJsonData.init(arena_allocator.allocator(), rand, count);
    try std.json.stringify(data, .{}, out_file.writer());
    return calcAverageHaversine(data);
}

fn calcAverageHaversine(data: HaversineJsonData) f64 {
    var sum: f64 = 0;
    for (data.pairs) |pair| {
        sum += referenceHaversine(pair.x0, pair.x1, pair.y0, pair.y1);
    }
    return sum / @as(f64, @floatFromInt(data.pairs.len));
}

pub fn main() !void {
    time.Timer.calibrate(100);
    var start: f64 = 0;
    var total: f64 = 0;

    start = time.Timer.start();
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    const allocator = gpa.allocator();
    print("startup allocator: {d} secs\n", .{time.Timer.elapsed(start, &total)});

    var answer: f64 = 0;
    const argc = std.os.argv.len;
    if (argc > 1) {
        start = time.Timer.start();
        const seed: u64 = if (argc > 1) std.fmt.parseUnsigned(u64, std.mem.sliceTo(std.os.argv[1], 0), 0) catch 0 else @truncate(@as(u128, @bitCast(std.time.nanoTimestamp())));
        var prng = std.Random.DefaultPrng.init(seed);
        const rand = prng.random();
        const out_file = try std.fs.cwd().createFile("data_working.json", .{});
        defer out_file.close();
        print("startup rng: {d} secs\n", .{time.Timer.elapsed(start, &total)});

        start = time.Timer.start();
        answer = try generateInputFile(allocator, out_file, rand, N_PAIRS);
        print("generate json: {d} secs\n", .{time.Timer.elapsed(start, &total)});
    }

    start = time.Timer.start();
    const d = try HaversineJsonData.initFromFile2(allocator, "data_working.json");
    print("read json: {d} secs\n", .{time.Timer.elapsed(start, &total)});

    start = time.Timer.start();
    const calculated = calcAverageHaversine(d);
    print("haversine: {d} secs\n", .{time.Timer.elapsed(start, &total)});

    start = time.Timer.start();
    allocator.free(d.pairs);
    assert(gpa.deinit() == .ok);
    print("cleanup: {d} secs\n", .{time.Timer.elapsed(start, &total)});

    print("total time: {d}\n\n", .{total});

    print("answer: {d}, calculated: {d}, diff: {d}\n", .{ answer, calculated, calculated - answer });
}
