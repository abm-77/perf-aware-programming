const std = @import("std");

// MOV REG/MEM INSTRUCTION
// * Encoded in 2 Bytes:
//      | 100010 ; D W | MOD ; REG ; R/M | DISP-LO | DISP-HI |
//
// * inst (6-bits):     Instruction encoding for MOV
// * D (1-bit):         If D == 0, then REG is not the destination register, otherwise REG is the destination register
// * W (1-bit):         If W == 0, then this is an 8-bit MOV, otherwise this is a 16-bit MOV
// * MOD (3-bitS):      Indicates whether this is register-register, register-memory, etc. 11 indicates register-register
// * REG (2-bits):      Register
// * R/M (3-bits):      Either other register or memory
//
// MOV IMM-REG INSTRUCTION
// * Encoded in 2 Bytes:
//      | 100010 ; D W | MOD ; REG ; R/M |
//
// * inst (6-bits):     Instruction encoding for MOV
// * D (1-bit):         If D == 0, then REG is not the destination register, otherwise REG is the destination register
// * W (1-bit):         If W == 0, then this is an 8-bit MOV, otherwise this is a 16-bit MOV
// * MOD (3-bitS):      Indicates whether this is register-register, register-memory, etc. 11 indicates register-register
// * REG (2-bits):      Register
// * R/M (3-bits):      Either other register or memory

const InstType = enum {
    MOV_REG_MEM,
    MOV_IMM_REG_MEM,
    MOV_IMM_REG,
    MOV_MEM_ACC,
    MOV_ACC_MEM,
    ADD_REG_MEM,
    ADD_IMM_REG_MEM,
    ADD_IMM_ACC,
};

const INST_TO_ENC_LUT = std.enums.EnumMap(InstType, u8).init(.{
    .MOV_REG_MEM = 0x22,
    .MOV_IMM_REG_MEM = 0x63,
    .MOV_IMM_REG = 0xB,
    .MOV_MEM_ACC = 0x50,
    .MOV_ACC_MEM = 0x51,
    .ADD_REG_MEM = 0x0,
    .ADD_IMM_REG_MEM = 0x20,
    .ADD_IMM_ACC = 0x02,
});

const INST_TO_MSK_LUT = std.enums.EnumMap(InstType, u8).init(.{
    .MOV_REG_MEM = 0xFC,
    .MOV_IMM_REG_MEM = 0xFE,
    .MOV_IMM_REG = 0xF0,
    .MOV_MEM_ACC = 0xFE,
    .MOV_ACC_MEM = 0xFE,
    .ADD_REG_MEM = 0xFC,
    .ADD_IMM_REG_MEM = 0xFC,
    .ADD_IMM_ACC = 0xFC,
});

// Register Fielnd Encoding (indexed by [REG][W])
const REG_TO_STR_LUT = [8][2][]const u8{
    [_][]const u8{ "al", "ax" },
    [_][]const u8{ "cl", "cx" },
    [_][]const u8{ "dl", "dx" },
    [_][]const u8{ "bl", "bx" },
    [_][]const u8{ "ah", "sp" },
    [_][]const u8{ "ch", "bp" },
    [_][]const u8{ "dh", "si" },
    [_][]const u8{ "bh", "di" },
};

// Effective Address Calculation (indexed by [R/M])
const EFF_ADDR_CALC = [8][]const u8{
    "[bx + si",
    "[bx + di",
    "[bp + si",
    "[bp + di",
    "[si",
    "[di",
    "[bp",
    "[bx",
};

fn maskBits(data: u32, mask: u32) u32 {
    const shift = @as(u3, @intCast(@ctz(mask)));
    return (data & mask) >> shift;
}

fn glueBytes(lo: u8, hi: u8) u16 {
    return (@as(u16, @intCast(hi)) << 8) | @as(u16, @intCast(lo));
}

fn extractInst(data: u8) ?InstType {
    inline for (std.meta.fields(InstType)) |ty| {
        const e = @as(InstType, @enumFromInt(ty.value));
        const encoding: u8 = INST_TO_ENC_LUT.get(e).?;
        const mask: u8 = INST_TO_MSK_LUT.get(e).?;
        // std.debug.print("testing: {}, data: {b}, encoding: {b}, mask: {b}, res: {b}\n", .{ e, data, encoding, mask, maskBits(data, mask) });
        if (maskBits(data, mask) == encoding) return e;
    }
    return null;
}

pub fn decode(inst_stream: []u8, output_file: std.fs.File, allocator: std.mem.Allocator) !void {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_allocator = arena.allocator();

    var idx: usize = 0;
    while (idx < inst_stream.len) {
        const b0 = inst_stream[idx];
        const b1 = inst_stream[idx + 1];

        const inst = extractInst(b0) orelse std.debug.panic("invalid instruction encountered!", .{});
        switch (inst) {
            .MOV_REG_MEM => {
                const D_MASK = 0x02; // 0b0000_0010
                const W_MASK = 0x01; // 0b0000_0001
                const MOD_MASK = 0xC0; // 0b1100_0000
                const REG_MASK = 0x38; // 0b0011_1000
                const RM_MASK = 0x07; // 0b0000_0111
                const d = maskBits(b0, D_MASK) == 1;
                const w = maskBits(b0, W_MASK);
                const mod = maskBits(b1, MOD_MASK);
                const rm = maskBits(b1, RM_MASK);
                const reg = REG_TO_STR_LUT[maskBits(b1, REG_MASK)][w];
                const addr = EFF_ADDR_CALC[rm];
                var dst: []const u8 = undefined;
                var src: []const u8 = undefined;
                var addr_str: []const u8 = undefined;

                std.debug.print("MOVE_REG_MEM: D: {}, W: {}, MOD: {b}, REG: {s}, RM: {b}\n", .{ d, w, mod, reg, rm });
                switch (mod) {
                    // No Displacement (unless R/M = 110, then it is DIRECT ADDRESS w/ 16-bit displacement)
                    0b00 => {
                        if (rm == 0b110) {
                            const disp_lo = inst_stream[idx + 2];
                            const disp_hi = inst_stream[idx + 3];
                            const dir_addr: u16 = glueBytes(disp_lo, disp_hi);
                            addr_str = try std.fmt.allocPrint(arena_allocator, "[{}]", .{dir_addr});
                            idx += 4;
                        } else {
                            addr_str = try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            idx += 2;
                        }
                    },

                    // REG-MEM w/ 8-bit displacement
                    0b01 => {
                        const disp_lo = inst_stream[idx + 2];
                        addr_str = blk: {
                            if (disp_lo == 0) {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            } else {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s} + {}]", .{ addr, disp_lo });
                            }
                        };
                        idx += 3;
                    },

                    // REG-MEM w/ 16-bit displacement
                    0b10 => {
                        const disp_lo = inst_stream[idx + 2];
                        const disp_hi = inst_stream[idx + 3];
                        addr_str = blk: {
                            const disp: u16 = glueBytes(disp_lo, disp_hi);
                            if (disp == 0) {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            } else {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s} + {}]", .{ addr, disp });
                            }
                        };
                        idx += 4;
                    },

                    // REG-REG
                    0b11 => {
                        idx += 2;
                    },

                    // Error
                    else => unreachable,
                }

                if (mod == 0b11) {
                    dst = if (d) reg else REG_TO_STR_LUT[rm][w];
                    src = if (d) REG_TO_STR_LUT[rm][w] else reg;
                } else {
                    dst = if (d) reg else addr_str;
                    src = if (d) addr_str else reg;
                }
                try output_file.writer().print("mov {s}, {s}\n", .{ dst, src });
            },
            .MOV_IMM_REG_MEM => {
                const W_MASK = 0x01; // 0b0000_0001
                const MOD_MASK = 0xC0; // 0b1100_0000
                const RM_MASK = 0x07; // 0b0000_0111
                const w = maskBits(b0, W_MASK);
                const mod = maskBits(b1, MOD_MASK);
                const rm = maskBits(b1, RM_MASK);
                const addr = EFF_ADDR_CALC[rm];

                std.debug.print("MOVE_REG_MEM:  W: {}, MOD: {b},  RM: {b}\n", .{ w, mod, rm });
                switch (mod) {
                    // No Displacement (unless R/M = 110, then it is DIRECT ADDRESS w/ 16-bit displacement)
                    0b00 => {
                        if (rm == 0b110) {
                            const disp_lo = inst_stream[idx + 2];
                            const disp_hi = inst_stream[idx + 3];
                            const dir_addr: u16 = glueBytes(disp_lo, disp_hi);
                            const addr_str = try std.fmt.allocPrint(arena_allocator, "[{}]", .{dir_addr});
                            const imm = blk: {
                                if (w == 0) {
                                    defer idx += 5;
                                    break :blk inst_stream[idx + 4];
                                } else {
                                    defer idx += 6;
                                    break :blk glueBytes(inst_stream[idx + 4], inst_stream[idx + 5]);
                                }
                            };
                            try output_file.writer().print("mov {s}, {}\n", .{ addr_str, imm });
                            idx += 4;
                        } else {
                            const addr_str = try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            var sz: []const u8 = undefined;
                            const imm = blk: {
                                if (w == 0) {
                                    defer idx += 3;
                                    sz = "byte";
                                    break :blk inst_stream[idx + 2];
                                } else {
                                    defer idx += 4;
                                    sz = "word";
                                    break :blk glueBytes(inst_stream[idx + 2], inst_stream[idx + 3]);
                                }
                            };
                            try output_file.writer().print("mov {s}, {s} {}\n", .{ addr_str, sz, imm });
                        }
                    },

                    // IMM-MEM w/ 8-bit displacement
                    0b01 => {
                        const addr_str = blk: {
                            const disp_lo = inst_stream[idx + 2];
                            if (disp_lo == 0) {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            } else {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s} + {}]", .{ addr, disp_lo });
                            }
                        };
                        var sz: []const u8 = undefined;
                        const imm = blk: {
                            if (w == 0) {
                                defer idx += 4;
                                sz = "byte";
                                break :blk inst_stream[idx + 3];
                            } else {
                                defer idx += 5;
                                sz = "word";
                                break :blk glueBytes(inst_stream[idx + 3], inst_stream[idx + 4]);
                            }
                        };
                        try output_file.writer().print("mov {s}, {s} {}\n", .{ addr_str, sz, imm });
                    },

                    // IMM-MEM w/ 16-bit displacement
                    0b10 => {
                        const addr_str = blk: {
                            const disp_lo = inst_stream[idx + 2];
                            const disp_hi = inst_stream[idx + 3];
                            const disp: u16 = glueBytes(disp_lo, disp_hi);
                            if (disp == 0) {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s}]", .{addr});
                            } else {
                                break :blk try std.fmt.allocPrint(arena_allocator, "{s} + {}]", .{ addr, disp });
                            }
                        };
                        var sz: []const u8 = undefined;
                        const imm = blk: {
                            if (w == 0) {
                                defer idx += 5;
                                sz = "byte";
                                break :blk inst_stream[idx + 4];
                            } else {
                                defer idx += 6;
                                sz = "word";
                                break :blk glueBytes(inst_stream[idx + 4], inst_stream[idx + 5]);
                            }
                        };
                        try output_file.writer().print("mov {s}, {s} {}\n", .{ addr_str, sz, imm });
                    },

                    // IMM-REG
                    0b11 => {
                        const reg = REG_TO_STR_LUT[rm][w];
                        var sz: []const u8 = undefined;
                        const imm = blk: {
                            if (w == 0) {
                                defer idx += 3;
                                sz = "byte";
                                break :blk inst_stream[idx + 2];
                            } else {
                                defer idx += 4;
                                sz = "word";
                                break :blk glueBytes(inst_stream[idx + 2], inst_stream[idx + 3]);
                            }
                        };
                        try output_file.writer().print("mov {s}, {s} {}\n", .{ reg, sz, imm });
                    },

                    // Error
                    else => unreachable,
                }
            },
            .MOV_IMM_REG => {
                const W_MASK = 0x08; // 0b0000_1000
                const REG_MASK = 0x07; // 0b0000_0111
                const w = maskBits(b0, W_MASK);
                const reg = REG_TO_STR_LUT[maskBits(b0, REG_MASK)][w];

                std.debug.print("MOVE_REG_IM:  W: {}, REG: {s}\n", .{ w, reg });
                const imm = blk: {
                    if (w == 0) {
                        defer idx += 2;
                        break :blk b1;
                    } else {
                        defer idx += 3;
                        break :blk glueBytes(b1, inst_stream[idx + 2]);
                    }
                };
                try output_file.writer().print("mov {s}, {}\n", .{ reg, imm });
            },
            .MOV_MEM_ACC => {
                const W_MASK = 0x1;
                const w = maskBits(b0, W_MASK);
                const addr = blk: {
                    if (w == 0) {
                        defer idx += 2;
                        break :blk b1;
                    } else {
                        defer idx += 3;
                        break :blk glueBytes(b1, inst_stream[idx + 2]);
                    }
                };
                try output_file.writer().print("mov ax, [{}]\n", .{addr});
            },
            .MOV_ACC_MEM => {
                const W_MASK = 0x1;
                const w = maskBits(b0, W_MASK);
                const addr = blk: {
                    if (w == 0) {
                        defer idx += 2;
                        break :blk b1;
                    } else {
                        defer idx += 3;
                        break :blk glueBytes(b1, inst_stream[idx + 2]);
                    }
                };
                try output_file.writer().print("mov [{}], ax\n", .{addr});
            },
            .ADD_IMM_ACC => {
                const W_MASK = 0x1;
                const w = maskBits(b0, W_MASK);
                const imm = blk: {
                    if (w == 0) {
                        defer idx += 2;
                        break :blk b1;
                    } else {
                        defer idx += 3;
                        break :blk glueBytes(b1, inst_stream[idx + 2]);
                    }
                };
                try output_file.writer().print("add ax, {}\n", .{imm});
            },
            .ADD_REG_MEM => {},
            .ADD_IMM_REG_MEM => {},
        }
    }
}
