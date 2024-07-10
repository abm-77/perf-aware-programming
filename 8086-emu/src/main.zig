const std = @import("std");
const sim86 = @import("sim86.zig");
const print = std.debug.print;

pub const ProgramMemory = struct {
    const Self = @This();
    data: [1024 * 1024]u8,

    fn readByte(self: Self, index: u32) u8 {
        return self.data[index];
    }

    fn readWord(self: Self, index: u32) u16 {
        return std.mem.readInt(u16, @ptrCast(&self.data[index]), .big);
    }

    fn writeByte(self: *Self, index: u32, v: u8) void {
        self.data[index] = v;
    }

    fn writeWord(self: *Self, index: u32, v: u16) void {
        std.mem.writeInt(u16, @ptrCast(&self.data[index]), v, .big);
    }

    pub fn read(self: *Self, index: u32, wide: bool) u16 {
        return if (wide) self.readWord(index) else self.readByte(index);
    }
    pub fn write(self: *Self, index: u32, v: u16, wide: bool) void {
        if (wide) self.writeWord(index, v) else self.writeByte(index, @intCast(v));
    }
};

pub const Registers = struct {
    const Self = @This();
    const RegisterFlags = packed struct(u2) {
        zero: bool = false,
        sign: bool = false,
    };

    // zero, ax, bx, cx, dx, sp, bp, si, di
    data: [9][2]u8,
    flags: RegisterFlags,
    ip: i32,

    pub fn readByte(self: Self, index: u32, offset: u32) u8 {
        return self.data[index][offset];
    }
    pub fn readWord(self: Self, index: u32) u16 {
        return std.mem.readInt(u16, &self.data[index], .big);
    }

    pub fn writeByte(self: *Self, index: u32, offset: u32, v: u8) void {
        self.data[index][offset] = v;
    }

    pub fn writeWord(self: *Self, index: u32, v: u16) void {
        std.mem.writeInt(u16, &self.data[index], v, .big);
    }

    pub fn read(self: Self, reg: sim86.RegisterAccess) u16 {
        if (reg.Count == 2) {
            return self.readWord(reg.Index);
        } else {
            return @intCast(self.readByte(reg.Index, reg.Offset));
        }
    }

    pub fn write(self: *Self, reg: sim86.RegisterAccess, v: u16) void {
        if (reg.Count == 2) {
            self.writeWord(reg.Index, v);
        } else {
            self.writeByte(reg.Index, reg.Offset, @intCast(v));
        }
    }

    pub fn updateFlags(self: *Self, last_result: ?i16) void {
        self.flags = std.mem.zeroes(RegisterFlags);

        if (last_result.? == 0)
            self.flags.zero = true;
        if (last_result.? < 0)
            self.flags.sign = true;
    }

    pub fn display(self: Self) void {
        print("Register State:\n", .{});
        print("\tax: 0x{x},\tah: 0x{x},\tal: 0x{x}\n", .{ self.readWord(1), self.readByte(1, 0), self.readByte(1, 1) });
        print("\tbx: 0x{x},\tbh: 0x{x},\tbl: 0x{x}\n", .{ self.readWord(2), self.readByte(2, 0), self.readByte(2, 1) });
        print("\tcx: 0x{x},\tch: 0x{x},\tcl: 0x{x}\n", .{ self.readWord(3), self.readByte(3, 0), self.readByte(3, 1) });
        print("\tdx: 0x{x},\tdh: 0x{x},\tdl: 0x{x}\n", .{ self.readWord(4), self.readByte(4, 0), self.readByte(4, 1) });
        print("\tsp: 0x{x}\n", .{self.readWord(5)});
        print("\tbp: 0x{x}\n", .{self.readWord(6)});
        print("\tsi: 0x{x}\n", .{self.readWord(7)});
        print("\tdi: 0x{x}\n", .{self.readWord(8)});
        print("\tip: 0x{x}\n", .{self.ip});
        print("\tflags: {}", .{self.flags});
    }
};

pub fn execute(inst_stream: []u8) !void {
    var regs = std.mem.zeroes(Registers);
    var memory = std.mem.zeroes(ProgramMemory);

    while (regs.ip < inst_stream.len) {
        const decoded_instr = try sim86.decode8086Instruction(inst_stream[@intCast(regs.ip)..]);
        regs.ip += @intCast(decoded_instr.Size);
        switch (decoded_instr.Op) {
            .Op_mov => {
                const operand_l = decoded_instr.Operands[0];
                const operand_r = decoded_instr.Operands[1];
                const moved_val = blk: {
                    switch (operand_r.Type) {
                        .OperandImmediate => {
                            break :blk @as(u16, @intCast(operand_r.data.Immediate.Value));
                        },
                        .OperandRegister => {
                            break :blk regs.read(operand_r.data.Register);
                        },
                        .OperandMemory => {
                            const addr = operand_r.data.Address;
                            const idx: u32 = @intCast(regs.read(addr.Terms[0].Register) + regs.read(addr.Terms[1].Register) + addr.Displacement);
                            break :blk memory.read(idx, decoded_instr.Flags.Wide);
                        },
                        else => unreachable,
                    }
                };

                switch (operand_l.Type) {
                    .OperandRegister => {
                        regs.write(operand_l.data.Register, moved_val);
                    },
                    .OperandMemory => {
                        const addr = operand_l.data.Address;
                        const idx: u32 = @intCast(regs.read(addr.Terms[0].Register) + regs.read(addr.Terms[1].Register) + addr.Displacement);
                        memory.write(idx, moved_val, decoded_instr.Flags.Wide);
                    },
                    else => unreachable,
                }
            },
            .Op_add => {
                const operand_l = decoded_instr.Operands[0];
                const operand_r = decoded_instr.Operands[1];

                if (operand_r.Type == .OperandImmediate) {
                    switch (operand_l.Type) {
                        .OperandRegister => {
                            const reg = operand_l.data.Register;
                            const val = @as(u16, @intCast(operand_r.data.Immediate.Value));
                            const res: i16 = @truncate(@as(i32, @intCast(regs.read(reg))) + @as(i32, @intCast(val)));
                            regs.updateFlags(res);
                            regs.write(reg, @bitCast(res));
                        },
                        else => unreachable,
                    }
                } else {
                    const lhs = operand_l.data.Register;
                    const rhs = operand_r.data.Register;
                    const res: i16 = @truncate(@as(i32, @intCast(regs.read(lhs))) + @as(i32, @intCast(regs.read(rhs))));
                    regs.updateFlags(res);
                    regs.write(lhs, @bitCast(res));
                }
            },
            .Op_sub, .Op_cmp => {
                const operand_l = decoded_instr.Operands[0];
                const operand_r = decoded_instr.Operands[1];

                if (operand_r.Type == .OperandImmediate) {
                    switch (operand_l.Type) {
                        .OperandRegister => {
                            const reg = operand_l.data.Register;
                            const val = @as(u16, @intCast(operand_r.data.Immediate.Value));
                            const res: i16 = @truncate(@as(i32, @intCast(regs.read(reg))) - @as(i32, @intCast(val)));
                            regs.updateFlags(res);
                            if (decoded_instr.Op == .Op_sub) regs.write(reg, @bitCast(res));
                        },
                        else => unreachable,
                    }
                } else {
                    const lhs = operand_l.data.Register;
                    const rhs = operand_r.data.Register;
                    const res: i16 = @truncate(@as(i32, @intCast(regs.read(lhs))) - @as(i32, @intCast(regs.read(rhs))));
                    regs.updateFlags(res);
                    if (decoded_instr.Op == .Op_sub) regs.write(lhs, @bitCast(res));
                }
            },
            .Op_jne => {
                const dest_offset: i32 = decoded_instr.Operands[0].data.Immediate.Value;
                if (!regs.flags.zero) {
                    regs.ip += dest_offset;
                }
            },
            else => {},
        }
    }
    regs.display();
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);

    const allocator = gpa.allocator();
    const max_size = std.math.maxInt(usize);

    const input = try std.fmt.allocPrint(allocator, "src/asm/{s}", .{std.os.argv[1]});
    defer allocator.free(input);

    const data = try std.fs.cwd().readFileAlloc(allocator, input, max_size);
    defer allocator.free(data);

    try execute(data);
}
