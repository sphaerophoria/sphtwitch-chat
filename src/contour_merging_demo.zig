// TODO:
// * SDF cones
// * General cleanup
// * Move into sphtud
// * Surely it's wrong to be n^2
// * Bezier support
// * Injecting contours should not require a []const sphtud.math.Vec2

const std = @import("std");
const sphtud = @import("sphtud");
const sphalloc = sphtud.alloc;
const sphrender = sphtud.render;
const gl = sphrender.gl;
const sphwindow = sphtud.window;
const gui = sphtud.ui;
const sphutil = sphtud.util;
const sphmath = sphtud.math;
const sphimage = sphtud.img;

const GuiAction = enum {
    step,
    finish,
};

const int_scale = 1 << 13;

const Contour = []const @Vector(2, i32);

pub fn dot(a: @Vector(2, i32), b: @Vector(2, i32)) i32 {
    return @reduce(.Add, a * b);
}

pub fn cross2(a: @Vector(2, i32), b: @Vector(2, i32)) i32 {
    return a[0] * b[1] - a[1] * b[0];
}

pub fn length2(in: @Vector(2, i32)) u64 {
    const in64: @Vector(2, i64) = @intCast(in);
    return @intCast(@reduce(.Add, in64 * in64));
}

pub fn length(in: @Vector(2, i32)) u32 {
    return std.math.sqrt(length2(in));
}

pub fn normalizeScale(in: @Vector(2, i32), scale: i32) @TypeOf(in) {
    const l: @Vector(2, u32) = @splat(length(in));
    const scalev: @Vector(2, i64) = @splat(scale);
    return @intCast(roundIntDiv(in * scalev, l));
}

fn intVecToFloat(in: @Vector(2, i32), scale: f32) sphtud.math.Vec2 {
    const scalev: sphtud.math.Vec2 = @splat(scale);
    return @as(sphtud.math.Vec2, @floatFromInt(in)) / scalev;
}

pub const TestCase = struct {
    contours: []const Contour,
    expected_verts: []@Vector(2, i32),
    expected_edges: [][2]@Vector(2, i32),

    pub fn loadFromPath(alloc: std.mem.Allocator, path: []const u8) !TestCase {
        const f = try std.fs.cwd().openFile(path, .{});
        defer f.close();

        var reader_buf: [4096]u8 = undefined;
        var fr = f.reader(&reader_buf);
        var reader = std.json.Reader.init(alloc, &fr.interface);

        return try std.json.parseFromTokenSourceLeaky(TestCase, alloc, &reader, .{});
    }

    pub fn loadFromSlice(alloc: std.mem.Allocator, data: []const u8) !TestCase {
        return try std.json.parseFromSliceLeaky(TestCase, alloc, data, .{});
    }
};

fn hsvToRgb(H: f32, S: f32, V: f32) sphtud.math.Vec3 {
    const C = V * S;
    const X = C * (1.0 - @abs(@mod((H / 60.0), 2) - 1.0));
    const m = V - C;

    const segment: usize = @intFromFloat(H / 60);
    const ret: sphtud.math.Vec3 = switch (segment % 6) {
        0 => .{C, X, 0, },
        1 => .{X, C, 0, },
        2 => .{0, C, X, },
        3 => .{0, X, C, },
        4 => .{X, 0, C, },
        5 => .{C, 0, X, },
        else => unreachable,
    };

    return ret + @as(sphtud.math.Vec3, @splat(m));
}

const IntersectionPoint = struct {f32, sphtud.math.Vec2 };
const IntersectionPointInt = struct {i64, @Vector(2, i32)};

fn Line(comptime T: type) type {
    return  struct {
        a: @Vector(2, T),
        b: @Vector(2, T),
    };
}

fn isParallelInt(a: Line(i32), b: Line(i32)) bool {
    const a_vec = a.b - a.a;
    const b_vec = b.b - b.a;

    const d = @abs(dot(normalizeScale(a_vec, int_scale), normalizeScale(b_vec, int_scale)));

    return d >= int_scale * int_scale;
}

fn intLerp(a: @Vector(2, i64), b: @Vector(2, i64), t: i64, scale: i64) @TypeOf(a) {
    const tv: @Vector(2, i64) = @splat(t);
    const sv: @Vector(2, i64) = @splat(scale);
    return a + roundIntDiv( ( b - a ) * tv, sv);
}

fn roundIntDiv(a: anytype, b: @TypeOf(a)) @TypeOf(a) {
    switch (@typeInfo(@TypeOf(a))) {
        .vector => |vi| {
            var ret: @TypeOf(a) = undefined;
            for (0..vi.len) |i| {
                // FIXME: This is completely losing out on all the benefits of
                // having vector types lololololol
                ret[i] = roundIntDiv(a[i], b[i]);
            }
            return ret;
        },
        .int => {
            var half_div = @divTrunc(b , 2);
            const signs_equal = (a < 0) == (b < 0);
            if (!signs_equal) half_div *= -1;
            return @divTrunc(a + half_div, b);
        },
        else => @compileError("uh oh "),
    }
}


const RayIntersection = struct {
    t: i64,
    u: i64,
    pos: @Vector(2, i32),
};

fn rayRayIntersectionInt(a: Line(i32), b: Line(i32)) ?RayIntersection {
    if (isParallelInt(a, b)) return null;

    const a_64 = Line(i64) {
        .a = @intCast(a.a),
        .b = @intCast(a.b),
    };

    const b_64 = Line(i64) {
        .a = @intCast(b.a),
        .b = @intCast(b.b),
    };

    const x1 = a_64.a[0];
    const y1 = a_64.a[1];
    const x2 = a_64.b[0];
    const y2 = a_64.b[1];

    const x3 = b_64.a[0];
    const y3 = b_64.a[1];
    const x4 = b_64.b[0];
    const y4 = b_64.b[1];

    const denom = ((x1 - x2) * (y3 - y4) - (y1 - y2) * (x3 - x4));

    if (denom == 0) {
        return null;
    }

    const t =  roundIntDiv(((x1 - x3) * (y3 - y4) - (y1 - y3) * (x3 - x4)) * int_scale, denom);
    const u =  -roundIntDiv(((x1 - x2) * (y1 - y3) - (y1 - y2) * (x1 - x3)) * int_scale, denom);

    return .{
        .t = t,
        .u = u,
        .pos = @intCast(intLerp(a_64.a, a_64.b, t, int_scale)),
    };
}

fn lineIntersectionInt(a: Line(i32), b: Line(i32)) ?IntersectionPointInt {
    const res = rayRayIntersectionInt(a, b) orelse return null;

    if (res.t > int_scale or res.t < 0) return null;
    if (res.u > int_scale or res.u < 0) return null;

    const ret = IntersectionPointInt {
        res.t,
        res.pos,
    };

    return ret;
}

fn lineRayIntersectionInt(line: Line(i32), ray: Line(i32)) ?IntersectionPointInt {
    const res = rayRayIntersectionInt(line, ray) orelse return null;

    if (res.t > int_scale or res.t < 0) return null;
    if (res.u < 0) return null;

    const ret = IntersectionPointInt {
        res.t,
        res.pos,
    };

    return ret;
}

fn isVertexOnEdge(vertex: @Vector(2, i32), edge: Line(i32)) bool {
    const ab = edge.b - edge.a;
    const av = vertex - edge.a;

    const av_len2 = length2(av);
    if (av_len2 == 0) return true;

    const ab_len2 = length2(ab);
    if (ab_len2 == 0) return false;

    const cross = cross2(ab, av);
    const is_parallel = cross == 0;
    if (!is_parallel) return false;

    const d = dot(av, ab);
    return d >= 0 and d <= ab_len2;
}

const ContourMerger = struct {
    alloc: std.mem.Allocator,

    original_contours: std.ArrayList(Contour),

    vertices: std.ArrayList(@Vector(2, i32)),
    edges: std.ArrayList(Edge),

    state: union(enum) {
        initializing,
        purge_edges: usize,
        purge_overlapping_edges: usize,
        complete,
    },

    pub fn init(alloc: std.mem.Allocator) ContourMerger {
        return .{
            .alloc = alloc,
            .state = .initializing,
            .vertices = .{},
            .edges = .{},
            .original_contours = .{},
        };
    }

    pub fn pushContour(self: *ContourMerger, contour: Contour) !void {
        try self.original_contours.append(self.alloc, contour);

        const contour_vert_start = try self.pushContourVerts(contour);
        const winding = detectWinding(contour);

        for (0..contour.len) |i| {
            var edge_inserter: EdgeInserter = undefined;
            try edge_inserter.initPinned(
                self,
                .fromContourIdx(contour_vert_start, i),
                .fromContourIdx(contour_vert_start, (i + 1) % contour.len),
                winding,
            );

            for (0..self.edges.items.len) |j| {
                const existing = &self.edges.items[j];
                try edge_inserter.splitExistingEdge(existing);
            }

            try edge_inserter.commit();
        }
    }

    pub const Diagnostics = union(enum) {
        processed_edge: struct {
            // FIXME: Maybe this should be a passed in slice?
            hits: [100]struct {
                pos: @Vector(2, i32),
                order: i32,
            } = undefined,
            num_hits: u8 = 0,
            ray_start: @Vector(2, i32),
            ray_end: @Vector(2, i32),
            count: i32,
        },
        none,
    };

    const StepOptions = struct {
        scratch: std.mem.Allocator,
        diagnostics: ?*Diagnostics = null,
    };

    pub fn step(self: *ContourMerger, options: StepOptions) !bool {
        const diagnostics = options.diagnostics;
        const scratch = options.scratch;

        if (diagnostics) |d| d.* = .none;

        switch (self.state) {
            .initializing => {
                self.state = .{ .purge_edges = self.edges.items.len };
            },
            .purge_edges => |*i| {
                if (i.* == 0) {
                    try self.purgeVertices(scratch);
                    self.state = .{ .purge_overlapping_edges = self.edges.items.len };
                }
                else {
                    i.* -= 1;
                    try self.maybePurgeEdge(i.*, diagnostics);
                }
            },
            .purge_overlapping_edges => |*i| {
                if (i.* == 0) {
                    self.state = .complete;
                    return false;
                }
                i.* -= 1;

                try self.maybePurgeOverlappingEdge(i.*);
            },
            .complete => {
                return false;
            },
        }
        return true;
    }

    fn maybePurgeEdge(self: *ContourMerger, i: usize, diagnostics: ?*Diagnostics) !void {
        const edge = &self.edges.items[i];

        const ray = self.makePurgeEdgeRay(edge.*);

        if (diagnostics) |d| d.* = .{ .processed_edge = .{
            .ray_start = ray.a,
            .ray_end = ray.b,
            .count = 0,
        }};

        var count: i32 = 0;
        const incr_mul: i32 = switch (edge.winding) {
            .cw => 1,
            .ccw => -1,
        };

        defer {
            if (diagnostics) |d| d.processed_edge.count = count;
        }

        // Test against original contours instead of our graph for 2 reasons
        // 1. We are removing edges from our graph which means that the
        //    winding count will be wrong
        // 2. Less edges to test against
        for (self.original_contours.items) |contour| {
            for (0..contour.len) |j| {
                const other_line = Line(i32){
                    .a =  contour[j],
                    .b = contour[(j + 1) % contour.len],
                };

                // Order of arguments here is important.
                //
                // Imagine we have ray as a diagonal line, and other_line as
                // completely vertical. It's easy to imagine a scenario where
                // interpolating along the ray doesn't give us a perfect hit on
                // the other line, however if we interpolate with respect to
                // the other line we are guaranteed to be on it
                //
                // Since we are comparing our intersection point with
                // other_line, it makes more sense for that to be the line that
                // is interpolated
                if (lineRayIntersectionInt(other_line, ray)) |pos| {
                    if (@reduce(.And, pos[1] == other_line.a)) {
                        continue;
                    }

                    const ray_dir = ray.b - ray.a;
                    const other_line_dir = other_line.b - other_line.a;
                    var incr: i32 = if (cross2(ray_dir, other_line_dir) > 0) 1 else -1;
                    incr *= incr_mul;


                    if (diagnostics) |d| {
                        const pe = &d.processed_edge;
                        pe.hits[pe.num_hits] = .{
                            .pos = pos[1],
                            .order = incr,
                        };
                        pe.num_hits += 1;
                    }

                    count += incr;
                }
            }
        }

        // Expected that the "inside" of this edge is outside. This is
        // incorrect if our edge is marked clockwise
        if (count == 0 and edge.winding == .cw) {
            std.mem.swap(VertexId, &edge.a, &edge.b);
        }

        if (count == -1 and edge.winding == .ccw) {
            std.mem.swap(VertexId, &edge.a, &edge.b);
        }

        const should_keep = count == 0 or count == -1;
        if (!should_keep) {
            _ = self.edges.swapRemove(i);
        }

    }

    fn maybePurgeOverlappingEdge(self: *ContourMerger, i: usize) !void {
        const edge = self.edges.items[i];

        // Check if this edge overlaps with any other edge
        var j: usize = 0;
        while (j < self.edges.items.len) : (j += 1) {
            if (i == j) continue;

            const other = self.edges.items[j];
            const overlap = self.findOverlap(edge, other) orelse continue;

            // At this point we have found an overlap, for simplicity, always
            // remove our edges and replace with new ones

            const remove_first = @max(i, j);
            const remove_second = @min(i, j);

            _ = self.edges.swapRemove(remove_first);
            _ = self.edges.swapRemove(remove_second);

            // Add back the non-overlapping parts of 'other'
            if (overlap.prefix_exists) {
                try self.edges.append(self.alloc, Edge{
                    .a = other.a,
                    .b = overlap.overlap_start_vertex,
                    .winding = other.winding,
                });
            }

            if (overlap.suffix_exists) {
                try self.edges.append(self.alloc, Edge{
                    .a = overlap.overlap_end_vertex,
                    .b = other.b,
                    .winding = other.winding,
                });
            }

            return;
        }
    }

    const OverlapInfo = struct {
        overlap_start_vertex: VertexId,
        overlap_end_vertex: VertexId,
        prefix_exists: bool,
        suffix_exists: bool,
    };

    fn findOverlap(self: *const ContourMerger, edge: Edge, other: Edge) ?OverlapInfo {
        const edge_start = self.getVertex(edge.a);
        const edge_end = self.getVertex(edge.b);

        const other_start = self.getVertex(other.a);
        const other_end = self.getVertex(other.b);

        const other_line = Line(i32) {
            .a = other_start,
            .b = other_end,
        };

        if (!isVertexOnEdge(edge_start, other_line)) return null;
        if (!isVertexOnEdge(edge_end, other_line)) return null;

        const other_len_sq = length2(other_end - other_start);

        if (other_len_sq == 0) return null; // Degenerate edge

        const start_len2 = length2(edge_start - other_start);
        const end_len2 = length2(edge_end - other_start);

        const first_len2 = @min(start_len2, end_len2);
        const last_len2 = @max(start_len2, end_len2);

        var start_vert = edge.a;
        var end_vert = edge.b;

        if (start_len2 >= end_len2) std.mem.swap(VertexId, &start_vert, &end_vert);

        return OverlapInfo{
            .overlap_start_vertex = start_vert,
            .overlap_end_vertex = end_vert,
            .prefix_exists = first_len2 > 0,
            .suffix_exists = last_len2 < other_len_sq,
        };
    }

    fn purgeVertices(self: *ContourMerger, scratch: std.mem.Allocator) !void {
        var seen_verts = std.AutoHashMapUnmanaged(VertexId, void){};

        for (self.edges.items) |edge| {
            try seen_verts.put(scratch, edge.a, {});
            try seen_verts.put(scratch, edge.b, {});
        }

        // FIXME: Stable vertex pool
        var i: u16 = @intCast(self.vertices.items.len);
        while (i > 0) {
            i -= 1;

            if (seen_verts.contains(.{ .inner = i })) continue;

            _ = self.vertices.swapRemove(i);
            // FIXME: IF vertex ids were stable we wouldn't need to heal here
            for (self.edges.items) |*edge| {
                if (edge.a.inner == self.vertices.items.len) edge.a.inner = i;
                if (edge.b.inner == self.vertices.items.len) edge.b.inner = i;
            }
        }

    }

    const Winding = enum {
        cw,
        ccw,
    };

    const Edge = struct {
        a: VertexId,
        b: VertexId,
        winding: Winding,
    };

    const VertexId = struct {
        inner: u16,

        fn fromContourIdx(contour_start: VertexId, contour_idx: usize) VertexId {
            return .{
                .inner = @intCast(contour_start.inner + contour_idx),
            };
        }
    };

    fn detectWinding(contour: Contour) Winding {
        const rightmost_idx = rightmostIdx(contour);

        const a_idx = (rightmost_idx + contour.len - 1) % contour.len;
        const b_idx = rightmost_idx;
        const c_idx = (rightmost_idx + 1) % contour.len;

        const a = contour[a_idx];
        const b = contour[b_idx];
        const c = contour[c_idx];

        const ab = b[1] - a[1];
        const bc = c[1] - b[1];

        std.debug.assert(ab == 0 or bc == 0 or ((ab > 0) == (bc > 0)));

        if (ab > 0 or bc > 0) {
            return .ccw;
        }
        return .cw;
    }

    fn rightmostIdx(contour: Contour) usize {
        var rightmost_idx: usize = 0;
        var rightmost_pos: i32 = 0;

        for (0..contour.len) |i| {
            if (contour[i][0] > rightmost_pos) {
                rightmost_pos = contour[i][0];
                rightmost_idx = i;
            }
        }

        return rightmost_idx;
    }


    fn nextVertexId(self: *ContourMerger) VertexId {
        return .{ .inner = @intCast(self.vertices.items.len) };
    }

    fn pushContourVerts(self: *ContourMerger, contour: Contour) !VertexId {
        const contour_vert_start = self.nextVertexId();

        for (0..contour.len) |i| {
            try self.vertices.append(self.alloc, contour[i]);
        }

        return contour_vert_start;
    }


    fn addEdge(self: *ContourMerger, a: VertexId, b: VertexId, winding: Winding) !void {
        if (length(self.getVertex(a) - self.getVertex(b)) == 0) return;

        try self.edges.append(self.alloc, .{
            .a = a,
            .b = b,
            .winding = winding,
        });
    }

    fn addVertex(self: *ContourMerger, new_pos: @Vector(2, i32)) !VertexId {
        for (self.vertices.items, 0..) |existing, i| {
            if (length(existing - new_pos) == 0) return .{ .inner = @intCast(i) };
        }

        const ret = VertexId{ .inner = @intCast(self.vertices.items.len )};
        try self.vertices.append(self.alloc, new_pos);
        return ret;
    }

    fn getVertex(self: *const ContourMerger, id: VertexId) @Vector(2, i32) {
        return self.vertices.items[id.inner];
    }

    fn makePurgeEdgeRay(self: *const ContourMerger, edge: Edge) Line(i32) {
        const a = self.getVertex(edge.a);
        const b = self.getVertex(edge.b);

        const center = (a + b) / @as(@Vector(2, i32), @splat(2));

        const ab = b - a;
        // Perpendicular
        var normal = normalizeScale(@Vector(2, i32){ -ab[1], ab[0] }, int_scale);

        // Detection is based off casting a ray from inside the box outwards
        if (edge.winding == .ccw) normal *= @splat(-1);

        return Line(i32) {
            .a = center,
            .b = center + normal,
        };
    }


    // FIXME: Edge to line is a better fn for this
    fn edgeIntersection(self: *ContourMerger, a: Edge, b: Edge) ?IntersectionPointInt{
        const a_line = Line(i32) {
            .a = self.getVertex(a.a),
            .b = self.getVertex(a.b),
        };
        const b_line = Line(i32) {
            .a = self.getVertex(b.a),
            .b = self.getVertex(b.b),
        };

        return lineIntersectionInt(a_line, b_line);
    }

    const EdgeInserter = struct {
        // Input edge
        candidate: Edge,

        // Tracking for how candidate edge should be split on add
        intersection_point_buf: [100]IndexedIntersectionPoint,
        intersection_points: std.ArrayList(IndexedIntersectionPoint),

        // Ref to graph for edge splitting
        parent: *ContourMerger,

        const IndexedIntersectionPoint = struct {i64, VertexId};

        fn initPinned(self: *EdgeInserter, parent: *ContourMerger, a: VertexId, b: VertexId, winding: Winding) !void {
            self.* = .{
                .intersection_point_buf = undefined,
                .intersection_points = .initBuffer(&self.intersection_point_buf),
                .candidate = .{
                    .a = a,
                    .b = b,
                    .winding = winding,
                },
                .parent = parent,
            };
            try self.intersection_points.appendBounded(.{0, a});
            try self.intersection_points.appendBounded(.{int_scale, b});
        }

        fn splitExistingEdge(self: *EdgeInserter, edge: *Edge) !void {
            const intersection = self.parent.edgeIntersection(self.candidate, edge.*) orelse return;

            if (self.intersectionCreatesZeroLengthEdge(edge.*, intersection[1])) return;

            const new_vert = try self.parent.addVertex(intersection[1]);

            try self.intersection_points.appendBounded(.{intersection[0], new_vert });

            try self.parent.addEdge(new_vert, edge.b, edge.winding);
            edge.b = new_vert;
        }

        fn intersectionCreatesZeroLengthEdge(self: *EdgeInserter, edge: Edge, point: @Vector(2, i32)) bool {
            const a = self.parent.getVertex(edge.a);
            const b = self.parent.getVertex(edge.b);

            if (@reduce(.And, a == point)) return true;
            if (@reduce(.And, b == point)) return true;
            return false;
        }

        fn sortIntersections(self: *EdgeInserter) void {
            std.mem.sort(IndexedIntersectionPoint, self.intersection_points.items, {}, struct {
                fn f(_: void, lhs: IndexedIntersectionPoint, rhs: IndexedIntersectionPoint) bool {
                    return lhs[0] < rhs[0];
                }
            }.f);
        }

        fn commit(self: *EdgeInserter) !void {
            self.sortIntersections();

            for (0..self.intersection_points.items.len - 1) |j| {
                const a = self.intersection_points.items[j];
                const b = self.intersection_points.items[j + 1];

                try self.parent.addEdge(a[1], b[1], self.candidate.winding);
            }
        }
    };
};

fn sortVert(lhs: @Vector(2, i32), rhs: @Vector(2, i32)) bool {
    if (lhs[0] == rhs[0]) {
        return lhs[1] < rhs[1];
    }
    return lhs[0] < rhs[0];
}

fn sortVerts(verts: []@Vector(2, i32)) void {
    std.mem.sort(@Vector(2, i32), verts, {}, struct {
        fn f(_: void, lhs: @Vector(2, i32), rhs: @Vector(2, i32)) bool {
            return sortVert(lhs, rhs);
        }
    }.f);
}

fn sortEdges(verts: [][2]@Vector(2, i32)) void {
    std.mem.sort([2]@Vector(2, i32), verts, {}, struct {
        fn f(_: void, lhs: [2]@Vector(2, i32), rhs: [2]@Vector(2, i32)) bool {
            if (@reduce(.Or, lhs[0] != rhs[0])) {
                return sortVert(lhs[0], rhs[0]);
            }
            return sortVert(lhs[1], rhs[1]);
        }
    }.f);

}

test "contour test spec" {
    const cases: []const []const u8 = &.{
        @embedFile("res/right_cutout_int.json"),
        @embedFile("res/ccw_box_int.json"),
        @embedFile("res/star_int.json"),
        @embedFile("res/star_ccw_int.json"),
        @embedFile("res/overlapping_edge.json"),
        @embedFile("res/overlapping_edge2.json"),
    };

    for (cases) |case| {
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();

        const tc = try TestCase.loadFromSlice(arena.allocator(), case);

        var merger = ContourMerger {
            .alloc = arena.allocator(),
            .original_contours = .{},
            .vertices = .{},
            .edges = .{},
            .state = .initializing,
        };

        for (tc.contours) |c| {
            try merger.pushContour(c);
        }

        while (try merger.step(.{ .scratch = arena.allocator() })) {}

        const output_verts = try arena.allocator().dupe(@Vector(2, i32), merger.vertices.items);

        sortVerts(output_verts);
        sortVerts(tc.expected_verts);

        try std.testing.expectEqual(tc.expected_verts.len, output_verts.len);
        for (tc.expected_verts, output_verts) |ex, ac| {
            try std.testing.expectEqual(ex[0], ac[0]);
            try std.testing.expectEqual(ex[1], ac[1]);
        }


        const output_edges = try arena.allocator().alloc([2]@Vector(2, i32), merger.edges.items.len);
        for (output_edges, merger.edges.items) |*output, in| {
            output[0] = merger.getVertex(in.a);
            output[1] = merger.getVertex(in.b);
        }

        sortEdges(output_edges);
        sortEdges(tc.expected_edges);

        try std.testing.expectEqual(tc.expected_edges.len, output_edges.len);
        for (tc.expected_edges, output_edges) |ex, ac| {
            try std.testing.expectEqual(ex[0][0], ac[0][0]);
            try std.testing.expectEqual(ex[1][0], ac[1][0]);
            try std.testing.expectEqual(ex[0][1], ac[0][1]);
            try std.testing.expectEqual(ex[1][1], ac[1][1]);
        }
    }
}

pub const CustomWidget = struct {
    arrow_head_source: sphrender.xyt_program.RenderSource,
    merger: *const ContourMerger,
    diagnostics: *ContourMerger.Diagnostics,

    line_render_source: sphrender.xyt_program.RenderSource,

    vertex_data: sphrender.xyt_program.Buffer,
    vertex_render_source: sphrender.xyt_program.RenderSource,
    program: sphrender.xyt_program.Program(Uniforms),
    sdf_renderer: sphrender.SignedDistanceFieldGenerator,

    const Uniforms = struct {
        transform: sphmath.Mat3x3,
        color: sphtud.math.Vec3,
    };

    pub const frag =
        \\#version 330
        \\out vec4 fragment;
        \\uniform vec3 color;
        \\void main()
        \\{
        \\    fragment = vec4(color, 1);
        \\}
    ;

    pub fn init(alloc: sphrender.RenderAlloc, merger: *const ContourMerger, diagnostics: *ContourMerger.Diagnostics) !CustomWidget {
        const program = try sphrender.xyt_program.Program(Uniforms).init(alloc.gl, frag);
        var line_render_source = try sphrender.xyt_program.RenderSource.init(alloc.gl);

        const vb = try sphrender.xyt_program.Buffer.init(alloc.gl, &.{
            .{ .vPos = .{ 0, 0 } },
            .{ .vPos = .{ 1, 0 } },
        });
        line_render_source.bindData(program.handle(), vb);

        var vertex_render_source = try sphrender.xyt_program.RenderSource.init(alloc.gl);
        const vertex_render_buffer = try sphrender.xyt_program.Buffer.init(alloc.gl, &.{});
        vertex_render_source.bindData(program.handle(), vertex_render_buffer);

        const arrow_head_data: [3]sphtud.render.xyt_program.Vertex = .{
            .{ .vPos = .{ 0, 0, }},
            .{ .vPos = .{ 0.1, 0.05, }},
            .{ .vPos = .{ 0.1, -0.05 }},
        };

        const arrow_head_buf = try sphrender.xyt_program.Buffer.init(alloc.gl, &arrow_head_data);
        var arrow_head_source = try sphrender.xyt_program.RenderSource.init(alloc.gl);
        arrow_head_source.bindData(program.handle(), arrow_head_buf);

        const sdf_renderer = try sphrender.SignedDistanceFieldGenerator.init(alloc.gl);

        return .{
            .program = program,
            .diagnostics = diagnostics,
            .merger = merger,
            .arrow_head_source = arrow_head_source,
            .line_render_source = line_render_source,
            .vertex_data = vertex_render_buffer,
            .vertex_render_source = vertex_render_source,
            .sdf_renderer = sdf_renderer,
        };
    }

    pub fn render(self: *CustomWidget, widget_bounds: gui.PixelBBox, window_bounds: gui.PixelBBox) void {
        const transform = gui.util.widgetToClipTransform(widget_bounds, window_bounds);

        const palette = [_]sphtud.math.Vec3{
            hsvToRgb(0, 1, 1),
            hsvToRgb(60, 1, 1),
            hsvToRgb(90, 1, 1),
            hsvToRgb(120, 1, 1),
            hsvToRgb(150, 1, 1),
            hsvToRgb(180, 1, 1),
            hsvToRgb(210, 1, 1),
            hsvToRgb(240, 1, 1),
            hsvToRgb(270, 1, 1),
            hsvToRgb(300, 1, 1),
            hsvToRgb(330, 1, 1),
            hsvToRgb(0, 0.5, 1),
            hsvToRgb(60, 0.5, 1),
            hsvToRgb(90, 0.5, 1),
            hsvToRgb(120, 0.5, 1),
            hsvToRgb(150, 0.5, 1),
            hsvToRgb(180, 0.5, 1),
            hsvToRgb(210, 0.5, 1),
            hsvToRgb(240, 0.5, 1),
            hsvToRgb(270, 0.5, 1),
            hsvToRgb(300, 0.5, 1),
            hsvToRgb(330, 0.5, 1),
        };

        for (self.merger.edges.items, 0..) |edge, i| {
            self.renderArrow(self.merger.getVertex(edge.a), self.merger.getVertex(edge.b), palette[i % palette.len], transform);
        }

        self.renderPoints(self.merger.vertices.items, .{0, 1, 0}, transform);

        switch (self.diagnostics.*) {
            .processed_edge => |pe| {
                self.renderArrow(pe.ray_start, pe.ray_end, .{ 1, 1, 1 }, transform);

                var buf: [100]@Vector(2, i32) = undefined;
                var al = std.ArrayList(@Vector(2, i32)).initBuffer(&buf);
                for (pe.hits[0..pe.num_hits]) |hit|  {
                    if (hit.order > 0) {
                        al.appendBounded(hit.pos) catch unreachable;
                    }
                }

                self.renderPoints(al.items, .{1, 0, 0}, transform);

                al.clearRetainingCapacity();
                for (pe.hits[0..pe.num_hits]) |hit|  {
                    if (hit.order < 0) {
                        al.appendBounded(hit.pos) catch unreachable;
                    }
                }
                self.renderPoints(al.items, .{1, 1, 0}, transform);
            },
            .none => {},
        }
    }

    // FIXME: Bounds of contour should be placed into clip space, not arbitrary 10k
    const contour_to_clip_scale = 10000;
    pub fn renderPoints(self: *CustomWidget, points: []const @Vector(2, i32), color: sphtud.math.Vec3, transform: sphtud.math.Transform) void {
        // FIXME: TMP
        var float_points: [1000]sphtud.render.xyt_program.Vertex = undefined;
        for (points, float_points[0..points.len]) |in, *out| {
            out.vPos = intVecToFloat(in, contour_to_clip_scale);
        }

        self.vertex_data.updateBuffer(float_points[0..points.len]);
        self.vertex_render_source.setLen(.{ .array = @intCast(self.vertex_data.len) });
        gl.glPointSize( 20.0);
        self.program.renderPoints(self.vertex_render_source, .{
            .transform = transform.inner,
            .color = color,
        });
    }

    pub fn renderArrow(self: CustomWidget, starti: @Vector(2, i32), endi: @Vector(2, i32), color: sphtud.math.Vec3, transform: sphtud.math.Transform) void {
        gl.glLineWidth(5.0);

        const start = intVecToFloat(starti, contour_to_clip_scale);
        const end = intVecToFloat(endi, contour_to_clip_scale);

        const len = sphtud.math.length(end - start);
        const line_dir = sphmath.normalize(end - start);
        const full_transform = sphtud.math.Transform.scale(len, len)
            .then(.rotateAToB(.{1, 0}, line_dir))
            .then(.translate(start[0], start[1]))
            .then(transform);

        self.program.renderLines(self.line_render_source, .{
            .transform = full_transform.inner,
            .color = color
        });

        var arrow_head_txfm = sphmath.Transform.rotateAToB(.{ 1, 0 }, -line_dir);
        arrow_head_txfm = arrow_head_txfm.then(.translate(end[0], end[1]));
        self.program.renderLineLoop(self.arrow_head_source, .{
            .transform = arrow_head_txfm.then(transform).inner,
            .color = color,
        });
    }

    pub fn getSize(_: CustomWidget) gui.PixelSize {
        return .{ .width = 600, .height = 600 };
    }
};

const DiagnosticsLabel = struct {
    diagnostics: *ContourMerger.Diagnostics,
    text_buf: [1000]u8 = undefined,

    pub fn getText(self: *DiagnosticsLabel) []const u8 {
        switch (self.diagnostics.*) {
            .processed_edge => |pe| {
                var positive_hits: usize = 0;
                var negative_hits: usize = 0;
                for (pe.hits[0..pe.num_hits]) |hit| {
                    if (hit.order > 0) positive_hits += 1;
                    if (hit.order < 0) negative_hits += 1;
                }

                return std.fmt.bufPrint(&self.text_buf, "hit {d}+, hit {d}-, total count: {d}", .{positive_hits, negative_hits, pe.count}) catch &self.text_buf;
            },
            else => return "",
        }
    }

};

pub fn main() !void {
    var allocators: sphrender.AppAllocators = undefined;
    try allocators.initPinned(10 * 1024 * 1024);

    const args = try std.process.argsAlloc(allocators.root.arena());
    const tc = try TestCase.loadFromPath(allocators.root.arena(), args[1]);

    var window: sphwindow.Window = undefined;
    try window.initPinned("sphui demo", 800, 800);

    try sphrender.initGl(window.glLoader());

    gl.glEnable(gl.GL_SCISSOR_TEST);
    gl.glBlendFunc(gl.GL_SRC_ALPHA, gl.GL_ONE_MINUS_SRC_ALPHA);
    gl.glEnable(gl.GL_BLEND);
    //gl.glEnable(gl.GL_DEPTH_TEST);
    //gl.glDepthFunc(gl.GL_LESS);

    const gui_alloc = try allocators.root_render.makeSubAlloc("gui");

    const gui_state = try gui.widget_factory.widgetState(
        GuiAction,
        gui_alloc,
        &allocators.scratch,
        &allocators.scratch_gl,
        .{},
    );

    const widget_factory = gui_state.factory(gui_alloc);
    const layout = try widget_factory.makeLayout();

    try layout.pushWidget(try widget_factory.makeLabel("A custom widget", .{}));

    var diagnostics: ContourMerger.Diagnostics = .none;
    var label_content = DiagnosticsLabel { .diagnostics = &diagnostics };
    try layout.pushWidget(try widget_factory.makeLabel(&label_content, .{}));

    var merger = ContourMerger.init(allocators.root.arena());

    for (tc.contours) |c| {
        try merger.pushContour(c);
    }

    var custom_widget = try CustomWidget.init(gui_alloc, &merger, &diagnostics);

    try layout.pushWidget(try widget_factory.makeButton(
        "step",
        GuiAction.step,
    ));

    try layout.pushWidget(try widget_factory.makeButton(
        "finish",
        GuiAction.finish,
    ));

    try layout.pushWidget(try widget_factory.makeBox(
        gui.Widget(GuiAction).fromConcrete(&custom_widget, "custom"),
        .{ .width = 300, .height = 300 },
        .fill_none,
    ));

    var runner = try widget_factory.makeRunner(try widget_factory.makeScrollView(layout.asWidget()));

    //const tent_renderer = try sphrender.SignedDistanceFieldGenerator.TentRenderer2.init(&allocators.root_gl);
    //_ = tent_renderer;

    //var tent_buf_builder = sphrender.SignedDistanceFieldGenerator.TentRenderer2.InstanceBuilder {
    //    .alloc = allocators.root.arena(),
    //    .list = .{},
    //};

    //for (merger.edges.items) |edge| {
        //try tent_buf_builder.pushEdge(intVecToFloat(merger.getVertex(edge.a), 10000), intVecToFloat(merger.getVertex(edge.b), 10000));
    //}
    //try tent_buf_builder.pushEdge(.{ -0.5, 0.5 }, .{0.5, 0.5 });
    //try tent_buf_builder.pushEdge(.{ 0.5, -0.5 }, .{-0.5, -0.5 });
    //const tent_instances = try tent_buf_builder.toGl(&allocators.root_gl);

    var last_step = try std.time.Instant.now();
    while (!window.closed()) {
        allocators.resetScratch();
        const width, const height = window.getWindowSize();

        gl.glViewport(0, 0, @intCast(width), @intCast(height));
        gl.glScissor(0, 0, @intCast(width), @intCast(height));

        const background_color = gui.widget_factory.StyleColors.background_color;
        gl.glClearColor(background_color.r, background_color.g, background_color.b, background_color.a);
        gl.glClearDepth(std.math.inf(f32));
        gl.glClear(gl.GL_COLOR_BUFFER_BIT | gl.GL_DEPTH_BUFFER_BIT);


        //tent_renderer.render(tent_instances);

        const now = try std.time.Instant.now();
        defer last_step = now;

        var delta: f64 = @floatFromInt(now.since(last_step));
        delta /= 1e9;

        const response = try runner.step(@floatCast(delta), .{
            .width = @intCast(width),
            .height = @intCast(height),
        }, &window.queue);

        if (response.action) |a| switch (a) {
            .step => {
                _ = try merger.step(.{ .scratch = allocators.scratch.allocator(), .diagnostics = &diagnostics });
            },
            .finish => {
                while (try merger.step(.{.scratch = allocators.scratch.allocator(), .diagnostics = &diagnostics })) {}

                std.debug.print("edges: [", .{});
                for (merger.edges.items) |edge| {
                    std.debug.print("[{any}, {any}]\n", .{merger.getVertex(edge.a), merger.getVertex(edge.b)});
                }
                std.debug.print("]\n", .{});

                std.debug.print("verts: {any}\n", .{merger.vertices.items});
            },
        };

        window.swapBuffers();
    }
}
