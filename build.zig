const std = @import("std");
const zem = @import("zemscripten");

pub fn build(b: *std.Build) void {
    // Force wasm32-emscripten target
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .wasm32,
        .os_tag = .emscripten,
    });
    const optimize = b.standardOptimizeOption(.{
        // .preferred_optimize_mode = .Debug
    });

    const activate_emsdk_step = zem.activateEmsdkStep(b);

    const wasm = b.addLibrary(.{ .name = "webgpu-minimal", .linkage = .static, .root_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    }) });

    wasm.root_module.addAnonymousImport("triangle.wgsl", .{
        .root_source_file = b.path("src/shaders/triangle.wgsl"),
    });

    wasm.root_module.addAnonymousImport("compute.wgsl", .{
        .root_source_file = b.path("src/shaders/compute.wgsl"),
    });

    wasm.linkLibC();

    const zemscripten = b.dependency("zemscripten", .{});

    wasm.root_module.addImport("zemscripten", zemscripten.module("root"));

    // Add Emscripten include paths for @cImport
    const emsdk_path = b.dependency("emsdk", .{}).path("").getPath(b);
    const emscripten_include_path = b.pathJoin(&.{ emsdk_path, "upstream", "emscripten", "cache", "sysroot", "include" });
    wasm.root_module.addSystemIncludePath(.{ .cwd_relative = emscripten_include_path });

    // Add webgpu include path from emdawnwebgpu port
    const webgpu_include_path = b.pathJoin(&.{ emsdk_path, "upstream", "emscripten", "cache", "ports", "emdawnwebgpu", "emdawnwebgpu_pkg", "webgpu", "include" });
    wasm.root_module.addSystemIncludePath(.{ .cwd_relative = webgpu_include_path });
    wasm.linkLibC();

    var emcc_flags = zem.emccDefaultFlags(b.allocator, .{ .optimize = optimize, .fsanitize = false });

    emcc_flags.put("--use-port=emdawnwebgpu", {}) catch unreachable;

    var emcc_settings = zem.emccDefaultSettings(b.allocator, .{
        .optimize = optimize,
    });

    emcc_settings.put("ALLOW_MEMORY_GROWTH", "1") catch unreachable;
    emcc_settings.put("JSPI", "1") catch unreachable;
    emcc_settings.put("ASSERTIONS", "1") catch unreachable;
    // emcc_settings.put("SAFE_HEAP", "0") catch unreachable;

    const emcc_step = zem.emccStep(
        b,
        &.{},
        &.{wasm},
        .{
            .optimize = optimize,
            .flags = emcc_flags,
            .settings = emcc_settings,
            .use_preload_plugins = true,
            .embed_paths = &.{},
            .preload_paths = &.{},
            .out_file_name = wasm.name, // emcc output arg will default to {wasm.name}.html if unset
            .install_dir = .{ .custom = "web" },
        },
    );
    emcc_step.dependOn(activate_emsdk_step);

    b.getInstallStep().dependOn(emcc_step);
    const html_filename = std.fmt.allocPrint(b.allocator, "{s}.html", .{wasm.name}) catch unreachable;

    const emrun_args = [_][]const u8{"--browser=chrome"};
    const emrun_step = zem.emrunStep(
        b,
        b.getInstallPath(.{ .custom = "web" }, html_filename),
        &emrun_args,
    );

    emrun_step.dependOn(emcc_step);

    b.step("emrun", "Build and open the web app locally using emrun").dependOn(emrun_step);
}
