const std = @import("std");

const Buffer = []const u8;
const JSONTokenType = enum {
    token_end_of_stream,
    token_error,
    token_open_brace,
    token_open_bracket,
    token_close_brace,
    token_close_bracket,
    token_comma,
    token_colon,
    token_semicolon,
    token_string_literal,
    token_number,
    token_true,
    token_false,
    token_null,
};

const JSONToken = struct {
    ty: JSONTokenType,
    value: Buffer,
};

const JSONElement = struct {
    const Self = @This();
    label: Buffer,
    value: Buffer,
    first_sub_element: ?*JSONElement,
    next_sibling: ?*JSONElement,
    allocator: std.mem.Allocator,

    pub fn lookup(self: Self, name: Buffer) ?*JSONElement {
        var res: ?*JSONElement = null;
        var search = self.first_sub_element;
        while (search != null) : (search = search.?.next_sibling) {
            if (std.mem.eql(u8, search.?.label, name)) {
                res = search;
                break;
            }
        }
        return res;
    }

    pub fn convertElementToF64(self: *Self, name: Buffer) f64 {
        var res: f64 = 0.0;

        const element = self.lookup(name);
        if (element != null) {
            const src = element.?.value;
            var at: u64 = 0;

            const sign = convertJSONSign(src, &at);
            var number = convertJSONNumber(src, &at);

            if (isInBounds(src, at) and (src[at] == '.')) {
                at += 1;
                var c: f64 = 1.0 / 10.0;
                while (isInBounds(src, at)) {
                    const char = src[at] - '0';
                    if (char < 10) {
                        number = number + c * @as(f64, @floatFromInt(char));
                        c *= 1.0 / 10.0;
                        at += 1;
                    } else {
                        break;
                    }
                }
            }

            if (isInBounds(src, at) and ((src[at] == 'e') or (src[at] == 'E'))) {
                at += 1;
                if (isInBounds(src, at) and (src[at] == '+')) {
                    at += 1;
                }

                const exp_sign = convertJSONSign(src, &at);
                const exp = exp_sign * convertJSONNumber(src, &at);
                number *= std.math.pow(f64, 10.0, exp);
            }

            res = sign * number;
        }

        return res;
    }

    pub fn deinit(self: *Self) void {
        var curr: ?*JSONElement = self;

        while (curr != null) {
            const free_element = curr.?;
            curr = curr.?.next_sibling;

            if (free_element.first_sub_element != null) {
                free_element.first_sub_element.?.deinit();
            }
            free_element.allocator.destroy(free_element);
        }
    }
};

pub const JSONParser = struct {
    const Self = @This();

    allocator: std.mem.Allocator,
    source: Buffer,
    at: u64,
    had_error: bool,

    fn init(allocator: std.mem.Allocator, src: Buffer) Self {
        return .{
            .allocator = allocator,
            .source = src,
            .at = 0,
            .had_error = false,
        };
    }

    pub fn isParsing(self: Self) bool {
        return !self.had_error and isInBounds(self.source, self.at);
    }

    pub fn err(self: *Self, token: JSONToken, msg: []const u8) void {
        self.had_error = true;
        std.debug.print("ERROR at {}, character {s} : {any}, {s}\n", .{ self.at, self.source[self.at .. self.at + 1], token, msg });
    }

    pub fn parseKeyword(self: *Self, keyword_remaining: Buffer, token_type: JSONTokenType) JSONToken {
        if ((self.source.len - self.at) >= keyword_remaining.len) {
            const check = self.source[self.at .. self.at + keyword_remaining.len];
            if (std.mem.eql(u8, check, keyword_remaining)) {
                self.at += keyword_remaining.len;
                return .{
                    .ty = token_type,
                    .value = check,
                };
            }
        }
        return .{ .ty = .token_error, .value = "" };
    }

    pub fn getJSONToken(self: *Self) JSONToken {
        var res = std.mem.zeroes(JSONToken);
        const src = self.source;
        var at = self.at;

        while (isJSONWhiteSpace(src, at)) at += 1;

        if (isInBounds(src, at)) {
            res = .{ .ty = .token_error, .value = src[at .. at + 1] };

            var c = src[at];
            at += 1;

            switch (c) {
                '{' => res.ty = .token_open_brace,
                '[' => res.ty = .token_open_bracket,
                '}' => res.ty = .token_close_brace,
                ']' => res.ty = .token_close_bracket,
                ',' => res.ty = .token_comma,
                ':' => res.ty = .token_colon,
                ';' => res.ty = .token_semicolon,

                'f' => res = self.parseKeyword("alse", .token_false),
                't' => res = self.parseKeyword("rue", .token_true),
                'n' => res = self.parseKeyword("ull", .token_null),

                '"' => {
                    const start = at;
                    while (isInBounds(src, at) and (src[at] != '"')) {
                        if (isInBounds(src, (at + 1)) and
                            (src[at] == '\\') and
                            (src[at + 1] == '"'))
                        {
                            // NOTE(casey): Skip escaped quotation marks
                            at += 1;
                        }

                        at += 1;
                    }

                    res = .{ .ty = .token_string_literal, .value = src[start..at] };

                    if (isInBounds(src, at)) {
                        at += 1;
                    }
                },

                '-', '0', '1', '2', '3', '4', '5', '6', '7', '8', '9' => {
                    const start = at - 1;

                    // NOTE(casey): Move past a leading negative sign if one exists
                    if ((c == '-') and isInBounds(src, at)) {
                        c = src[at];
                        at += 1;
                    }

                    // NOTE(casey): If the leading digit wasn't 0, parse any digits before the decimal point
                    if (c != '0') {
                        while (isJSONDigit(src, at)) {
                            at += 1;
                        }
                    }

                    // NOTE(casey): If there is a decimal point, parse any digits after the decimal point
                    if (isInBounds(src, at) and (src[at] == '.')) {
                        at += 1;
                        while (isJSONDigit(src, at)) {
                            at += 1;
                        }
                    }

                    // NOTE(casey): If it's in scientific notation, parse any digits after the "e"
                    if (isInBounds(src, at) and ((src[at] == 'e') or (src[at] == 'E'))) {
                        at += 1;

                        if (isInBounds(src, at) and ((src[at] == '+') or (src[at] == '-'))) {
                            at += 1;
                        }

                        while (isJSONDigit(src, at)) {
                            at += 1;
                        }
                    }

                    res.ty = .token_number;
                    res.value = src[start..at];
                },
                else => {},
            }
        }

        self.at = at;

        return res;
    }

    fn parseJSONList(self: *Self, end_type: JSONTokenType, has_labels: bool) ?*JSONElement {
        var first_element: ?*JSONElement = null;
        var last_element: ?*JSONElement = null;

        while (self.isParsing()) {
            var label = std.mem.zeroes(Buffer);
            var value = self.getJSONToken();
            if (has_labels) {
                if (value.ty == .token_string_literal) {
                    label = value.value;

                    const colon = self.getJSONToken();
                    if (colon.ty == .token_colon) {
                        value = self.getJSONToken();
                    } else {
                        self.err(colon, "Expected colon after field name");
                    }
                } else if (value.ty != end_type) {
                    self.err(value, "Unexpected token in JSON");
                }
            }

            const element = self.parseJSONElement(label, value);
            if (element != null) {
                if (last_element != null) {
                    last_element.?.next_sibling = element;
                    last_element = last_element.?.next_sibling;
                } else {
                    first_element = element;
                    last_element = element;
                }
            } else if (value.ty == end_type) {
                break;
            } else {
                self.err(value, "Unexpected token in JSON");
            }

            const comma = self.getJSONToken();
            if (comma.ty == end_type) {
                break;
            } else if (comma.ty != .token_comma) {
                self.err(comma, "Unexpected token in JSON");
            }
        }

        return first_element;
    }

    pub fn parseJSONElement(self: *Self, label: Buffer, val: JSONToken) ?*JSONElement {
        var valid = true;
        var sub_element: ?*JSONElement = null;
        switch (val.ty) {
            .token_open_brace => sub_element = self.parseJSONList(.token_close_brace, true),
            .token_open_bracket => sub_element = self.parseJSONList(.token_close_bracket, false),
            .token_string_literal, .token_true, .token_false, .token_null, .token_number => {},
            else => valid = false,
        }

        var res: ?*JSONElement = null;
        if (valid) {
            res = self.allocator.create(JSONElement) catch unreachable;
            res.?.* = .{
                .label = label,
                .allocator = self.allocator,
                .value = val.value,
                .first_sub_element = sub_element,
                .next_sibling = null,
            };
        }
        return res;
    }

    pub fn parseJSON(allocator: std.mem.Allocator, src: Buffer) ?*JSONElement {
        var parser = JSONParser.init(allocator, src);
        return parser.parseJSONElement("", parser.getJSONToken());
    }
};

inline fn isInBounds(buffer: Buffer, pos: u64) bool {
    return pos >= 0 and pos < buffer.len;
}

fn isJSONDigit(source: Buffer, at: u64) bool {
    var res = false;
    if (isInBounds(source, at)) {
        const val = source[at];
        res = ((val >= '0') and (val <= '9'));
    }
    return res;
}

fn isJSONWhiteSpace(source: Buffer, at: u64) bool {
    var res = false;
    if (isInBounds(source, at)) {
        const val = source[at];
        res = ((val == ' ') or (val == '\t') or (val == '\n') or (val == '\r'));
    }
    return res;
}

fn convertJSONSign(src: Buffer, at_res: *u64) f64 {
    var at = at_res.*;

    var res: f64 = 1.0;
    if (isInBounds(src, at) and (src[at] == '-')) {
        res = -1.0;
        at += 1;
    }

    at_res.* = at;

    return res;
}

fn convertJSONNumber(src: Buffer, at_res: *u64) f64 {
    var at = at_res.*;

    var res: f64 = 0.0;
    while (isInBounds(src, at)) {
        const c: i32 = @as(i32, @intCast(src[at])) - @as(i32, @intCast('0'));
        if (c > 0 and c < 10) {
            res = 10.0 * res + @as(f64, @floatFromInt(c));
            at += 1;
        } else {
            break;
        }
    }

    at_res.* = at;

    return res;
}
