//! Buzz, the scripting language the dev console runs (`src/core/dev_console/`), compiled from its
//! package's sources as a module of Eggy's own, with PCRE2 (its patterns) built beside it.
const std = @import("std");
const c_libraries = @import("c_libraries.zig");

/// A package's dependencies, by name and hash (`std.Build.available_deps`'s type, which isn't public).
const AvailableDeps = @FieldType(std.Build, "available_deps");

/// The `buzz` module `eggy` imports: Buzz's compiler and VM where scripting runs, else a stub
/// whose `available` is false. Either way the module's root says which (`available`).
///
/// Buzz's own build.zig is never run: it calls `git rev-parse` while configuring and builds from
/// git submodules that a fetched package lacks. So the package is found by its hash and its
/// sources compiled here, with the JIT, mimalloc and the debugger left out.
///
/// ```zig
/// engine.addImport("buzz", buzz.module(b, target, optimize));
/// ```
pub fn module(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Module {
    // ponytail: desktop only; the web (Emscripten) and Android need Buzz's I/O ported first.
    const scripting = switch (target.result.os.tag) {
        .linux, .windows, .macos => !target.result.abi.isAndroid(),
        else => false,
    };
    if (!scripting) return b.createModule(.{
        .root_source_file = b.addWriteFiles().add("buzz.zig", "pub const available = false;\n"),
        .target = target,
        .optimize = optimize,
    });

    // Buzz's sources, beside a root that publishes the parts the console drives.
    const sources = b.addWriteFiles();
    const package = packageRoot(b.available_deps, "buzz");
    var native_paths: [native_libraries.len][]const u8 = undefined;
    for (&native_paths, native_libraries) |*path, name| path.* = b.fmt("lib/buzz_{s}.zig", .{name});
    _ = sources.addCopyDirectory(package.path(b, "src"), "", .{ .include_extensions = &.{ ".zig", ".buzz" }, .exclude_extensions = &native_paths });
    // Two of `lib/`'s files are symlinks, which the copy leaves out.
    _ = sources.addCopyFile(package.path(b, "src/io.zig"), "lib/io.zig");
    _ = sources.addCopyFile(package.path(b, "src/wasm.zig"), "lib/wasm.zig");
    // Its standard library's natives are `export fn`s named like libc's (`time`, `random`), which
    // in an executable stand in for libc's own: they are only called through pointers, so unexport them.
    for (native_paths) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(b.graph.io, b.pathJoin(&.{ package.cwd_relative, "src", path }), b.allocator, .limited(1 << 20)) catch |err| std.debug.panic("cannot read Buzz's {s}: {t}", .{ path, err });
        const unexported = std.mem.replaceOwned(u8, b.allocator, source, "export fn ", "fn ") catch @panic("OOM");
        _ = sources.add(path, unexported);
    }
    const root = sources.add("eggy_buzz.zig",
        \\pub const available = true;
        \\pub const vm = @import("vm.zig");
        \\pub const obj = @import("obj.zig");
        \\pub const value = @import("value.zig");
        \\pub const GC = @import("GC.zig");
        \\pub const TypeRegistry = @import("TypeRegistry.zig");
        \\pub const Parser = @import("Parser.zig");
        \\pub const CodeGen = @import("Codegen.zig");
        \\pub const Scanner = @import("Scanner.zig");
        \\pub const Token = @import("Token.zig");
        \\pub const Ast = @import("Ast.zig");
        \\pub const Reporter = @import("Reporter.zig");
        \\pub const disassembler = @import("disassembler.zig");
        \\
    );
    const buzz = b.createModule(.{
        .root_source_file = root,
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .sanitize_c = .off,
        // Linked into the editor's game library, a shared one.
        .pic = true,
    });
    buzz.addOptions("build_options", options(b));
    // Its debugger is compiled in whether used or not, with the packages Buzz's own build gives it.
    const buzz_deps = std.Build.package_map.get(packageHash(b.available_deps, "buzz")).?.deps;
    buzz.addImport("dap", b.createModule(.{ .root_source_file = packageRoot(buzz_deps, "dap_kit").path(b, "src/root.zig"), .target = target, .optimize = optimize }));
    buzz.addImport("clap", b.createModule(.{ .root_source_file = packageRoot(buzz_deps, "clap").path(b, "clap.zig"), .target = target, .optimize = optimize }));
    buzz.linkLibrary(addPcre2(b, target, optimize));
    buzz.linkLibrary(addMir(b, target, optimize));
    if (target.result.os.tag == .windows) buzz.linkSystemLibrary("bcrypt", .{});
    return buzz;
}

/// Buzz's standard libraries with natives of their own (`src/lib/buzz_<name>.zig`).
const native_libraries = [_][]const u8{ "buffer", "crypto", "debug", "ffi", "fs", "gc", "http", "io", "math", "os", "serialize", "std" };

/// The `build_options` Buzz's sources read: its defaults, less the JIT and mimalloc.
fn options(b: *std.Build) *std.Build.Step.Options {
    const buzz_options = b.addOptions();
    buzz_options.addOption(std.SemanticVersion, "version", .{ .major = 0, .minor = 6, .patch = 0, .build = "eggy" });
    buzz_options.addOption(bool, "mimalloc", false);
    buzz_options.addOption(?u128, "cycle_limit", null);
    buzz_options.addOption(?u32, "recursive_call_limit", null);
    buzz_options.addOption(usize, "stack_size", 100_000);
    inline for (.{ "debug", "debug_stack", "debug_current_instruction", "show_perf", "stop_on_report", "debug_placeholders", "debug_type_registry" }) |name| buzz_options.addOption(bool, name, false);
    inline for (.{ "gc_debug", "gc_debug_light", "gc_debug_access" }) |name| buzz_options.addOption(bool, name, false);
    buzz_options.addOption(bool, "gc", true);
    buzz_options.addOption(usize, "initial_gc", 40_960);
    buzz_options.addOption(usize, "next_gc_ratio", 2);
    buzz_options.addOption(usize, "next_full_gc_ratio", 4);
    buzz_options.addOption(?usize, "memory_limit", null);
    inline for (.{ "jit", "jit_debug", "jit_always_on", "jit_hotspot_always_on", "jit_hotspot", "jit_asynchronous" }) |name| buzz_options.addOption(bool, name, false);
    inline for (.{ "jit_call_threshold", "jit_score_threshold", "jit_hotspot_threshold", "jit_hotspot_score_threshold" }) |name| buzz_options.addOption(u16, name, 65535);
    return buzz_options;
}

/// PCRE2 (8-bit code units), as Buzz's own build compiles it.
fn addPcre2(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Step.Compile {
    const pcre2 = packageRoot(b.available_deps, "pcre2");
    // Its generic config and tables, under the names its sources include.
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(pcre2.path(b, "src/config.h.generic"), "config.h");
    _ = generated.addCopyFile(pcre2.path(b, "src/pcre2.h.generic"), "pcre2.h");
    const chartables = generated.addCopyFile(pcre2.path(b, "src/pcre2_chartables.c.dist"), "pcre2_chartables.c");

    const library = b.addLibrary(.{
        .name = "pcre2",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = c_libraries.optimize(optimize),
            .link_libc = true,
            .sanitize_c = .off,
            .pic = true,
        }),
    });
    const flags: []const []const u8 = &.{ "-std=c99", "-DHAVE_CONFIG_H", "-DPCRE2_CODE_UNIT_WIDTH=8", "-DPCRE2_STATIC" };
    library.root_module.addIncludePath(generated.getDirectory());
    library.root_module.addIncludePath(pcre2.path(b, "src"));
    library.root_module.addCSourceFiles(.{
        .root = pcre2.path(b, "src"),
        .files = &.{
            "pcre2_auto_possess.c", "pcre2_compile.c",      "pcre2_config.c",       "pcre2_context.c",
            "pcre2_convert.c",      "pcre2_dfa_match.c",    "pcre2_error.c",        "pcre2_extuni.c",
            "pcre2_find_bracket.c", "pcre2_maketables.c",   "pcre2_match.c",        "pcre2_match_data.c",
            "pcre2_newline.c",      "pcre2_ord2utf.c",      "pcre2_pattern_info.c", "pcre2_script_run.c",
            "pcre2_serialize.c",    "pcre2_string_utils.c", "pcre2_study.c",        "pcre2_substitute.c",
            "pcre2_substring.c",    "pcre2_tables.c",       "pcre2_ucd.c",          "pcre2_valid_utf.c",
            "pcre2_xclass.c",
        },
        .flags = flags,
    });
    library.root_module.addCSourceFile(.{ .file = chartables, .flags = flags });
    return library;
}

/// MIR, the code generator behind Buzz's JIT and `zdef`, which its VM links even with the JIT off.
fn addMir(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.Optimize) *std.Build.Step.Compile {
    const mir = packageRoot(b.available_deps, "mir");
    const library = b.addLibrary(.{
        .name = "mir",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = c_libraries.optimize(optimize),
            .link_libc = true,
            .pic = true,
        }),
    });
    library.root_module.addIncludePath(mir);
    library.root_module.addCSourceFiles(.{
        .root = mir,
        .files = &.{ "mir.c", "mir-gen.c", "c2mir/c2mir.c" },
        // As Buzz builds it: MIR has undefined behaviour somewhere, so no sanitizer.
        .flags = &.{ "-fsigned-char", "-DNDEBUG=1", "-DMIR_PARALLEL_GEN=1", "-fno-sanitize=undefined" },
    });
    if (target.result.os.tag == .windows) {
        library.root_module.linkSystemLibrary("kernel32", .{});
        library.root_module.linkSystemLibrary("psapi", .{});
    }
    return library;
}

/// Where the package `name` (one of `deps`, a package's dependencies) was fetched to, without
/// running its build.zig as `b.dependency` would.
fn packageRoot(deps: AvailableDeps, name: []const u8) std.Build.LazyPath {
    return .{ .cwd_relative = std.Build.package_map.get(packageHash(deps, name)).?.build_root };
}

fn packageHash(deps: AvailableDeps, name: []const u8) []const u8 {
    for (deps) |dependency| if (std.mem.eql(u8, dependency[0], name)) return dependency[1];
    std.debug.panic("no dependency named {s}", .{name});
}
