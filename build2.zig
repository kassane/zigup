const std = @import("std");
const builtin = @import("builtin");
const Builder = std.Build;

// TODO: make this work with "GitRepoStep.zig", there is a
//       problem with the -Dfetch option
const GitRepoStep = @import("dep/ziget/GitRepoStep.zig");

const zigetbuild = @import("dep/ziget/build.zig");
const SslBackend = zigetbuild.SslBackend;

fn unwrapOptionalBool(optionalBool: ?bool) bool {
    if (optionalBool) |b| return b;
    return false;
}

pub fn build(b: *Builder) !void {
    const ziget_repo = GitRepoStep.create(b, .{
        .url = "https://github.com/kassane/ziget",
        .branch = "main",
        .sha = @embedFile("zigetsha"),
    });

    // TODO: implement this if/when we get @tryImport
    //if (zigetbuild) |_| { } else {
    //    std.log.err("TODO: add zigetbuild package and recompile/reinvoke build.d", .{});
    //    return;
    //}

    //var github_release_step = b.step("github-release", "Build the github-release binaries");
    //try addGithubReleaseExe(b, github_release_step, ziget_repo, "x86_64-linux", .std);
    const ci_target = b.option([]const u8, "ci_target", "the CI target being built") orelse try b.host.query.zigTriple(b.allocator);
    const target = b.standardTargetOptions(.{ .default_target = try std.Target.Query.parse(.{
        .arch_os_abi = ci_target_map.get(ci_target) orelse {
            std.log.err("unknown ci_target '{s}'", .{ci_target});
            std.os.exit(1);
        },
    }) });

    const optimize = b.standardOptimizeOption(.{});

    const win32exelink_mod: ?*Builder.Module = blk: {
        if (target.result.os.tag == .windows) {
            const exe = b.addExecutable(.{
                .name = "win32exelink",
                .root_source_file = .{ .path = "win32exelink.zig" },
                .target = target,
                .optimize = optimize,
            });
            break :blk b.createModule(.{
                .root_source_file = exe.getEmittedBin(),
            });
        }
        break :blk null;
    };

    // TODO: Maybe add more executables with different ssl backends
    const exe = try addZigupExe(
        b,
        ziget_repo,
        target,
        optimize,
        win32exelink_mod,
        .iguana,
    );
    b.installArtifact(exe);

    const run_cmd = b.addRunArtifact(exe);
    run_cmd.step.dependOn(b.getInstallStep());

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    addTest(b, exe, target, optimize);
}

fn addTest(b: *Builder, exe: *Builder.Step.Compile, target: Builder.ResolvedTarget, optimize: std.builtin.Mode) void {
    const test_exe = b.addExecutable(.{
        .name = "test",
        .root_source_file = .{ .path = "test.zig" },
        .target = target,
        .optimize = optimize,
    });
    const run_cmd = b.addRunArtifact(test_exe);

    // TODO: make this work, add exe install path as argument to test
    //run_cmd.addArg(exe.getInstallPath());
    _ = exe;
    run_cmd.step.dependOn(b.getInstallStep());

    const test_step = b.step("test", "test the executable");
    test_step.dependOn(&run_cmd.step);
}

fn addZigupExe(
    b: *Builder,
    ziget_repo: *GitRepoStep,
    target: Builder.ResolvedTarget,
    optimize: std.builtin.Mode,
    win32exelink_mod: ?*Builder.Module,
    ssl_backend: ?SslBackend,
) !*Builder.Step.Compile {
    const require_ssl_backend = b.allocator.create(RequireSslBackendStep) catch unreachable;
    require_ssl_backend.* = RequireSslBackendStep.init(b, "the zigup exe", ssl_backend);

    const exe = b.addExecutable(.{
        .name = "zigup",
        .root_source_file = .{ .path = "zigup.zig" },
        .target = target,
        .optimize = optimize,
    });

    exe.step.dependOn(&ziget_repo.step);
    zigetbuild.addZigetModule(exe, ssl_backend, ziget_repo.getPath(&exe.step));

    if (targetIsWindows(target)) {
        exe.root_module.addImport("win32exelink", win32exelink_mod.?);
        const zarc_repo = GitRepoStep.create(b, .{
            .url = "https://github.com/kassane/zarc",
            .branch = "protected",
            .sha = "9d59ec6b93309ce652e028b588a87e29beda86b0",
            .fetch_enabled = true,
        });
        exe.step.dependOn(&zarc_repo.step);
        const zarc_repo_path = zarc_repo.getPath(&exe.step);
        const zarc_mod = b.addModule("zarc", .{
            .root_source_file = .{ .path = b.pathJoin(&.{ zarc_repo_path, "src", "main.zig" }) },
        });
        exe.root_module.addImport("zarc", zarc_mod);
    }

    exe.step.dependOn(&require_ssl_backend.step);
    return exe;
}

fn targetIsWindows(target: Builder.ResolvedTarget) bool {
    return target.result.os.tag == .windows;
}

const SslBackendFailedStep = struct {
    step: Builder.Step,
    context: []const u8,
    backend: SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: SslBackend) SslBackendFailedStep {
        return .{
            .step = Builder.Step.init(.custom, "SslBackendFailedStep", b.allocator, make),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *Builder.Step) !void {
        const self = @fieldParentPtr(RequireSslBackendStep, "step", step);
        std.debug.print("error: the {s} failed to add the {s} SSL backend\n", .{ self.context, self.backend });
        std.os.exit(1);
    }
};

const RequireSslBackendStep = struct {
    step: Builder.Step,
    context: []const u8,
    backend: ?SslBackend,
    pub fn init(b: *Builder, context: []const u8, backend: ?SslBackend) RequireSslBackendStep {
        return .{
            .step = Builder.Step.init(.{
                .id = .custom,
                .name = "RequireSslBackend",
                .owner = b,
                .makeFn = make,
            }),
            .context = context,
            .backend = backend,
        };
    }
    fn make(step: *Builder.Step, prog_node: *std.Progress.Node) !void {
        _ = prog_node;
        const self = @fieldParentPtr(RequireSslBackendStep, "step", step);
        if (self.backend) |_| {} else {
            std.debug.print("error: {s} requires an SSL backend:\n", .{self.context});
            inline for (zigetbuild.ssl_backends) |field| {
                std.debug.print("    -D{s}\n", .{field.name});
            }
            std.os.exit(1);
        }
    }
};

fn addGithubReleaseExe(b: *Builder, github_release_step: *Builder.Step, ziget_repo: []const u8, comptime target_triple: []const u8, comptime ssl_backend: SslBackend) !void {
    const small_release = true;

    const target = try std.Target.Query.parse(.{ .arch_os_abi = target_triple });
    const mode = if (small_release) .ReleaseSafe else .Debug;
    const exe = try addZigupExe(b, ziget_repo, target, mode, ssl_backend);
    if (small_release) {
        exe.strip = true;
    }
    exe.setOutputDir("github-release" ++ std.fs.path.sep_str ++ target_triple ++ std.fs.path.sep_str ++ @tagName(ssl_backend));
    github_release_step.dependOn(&exe.step);
}

const ci_target_map = std.ComptimeStringMap([]const u8, .{
    .{ "ubuntu-latest-x86_64", "x86_64-linux" },
    .{ "macos-latest-x86_64", "x86_64-macos" },
    .{ "windows-latest-x86_64", "x86_64-windows" },
    .{ "freebsd-latest-x86_64", "x86_64-freebsd" },
    .{ "ubuntu-latest-aarch64", "aarch64-linux" },
    .{ "ubuntu-latest-armv7a", "arm-linux" },
    .{ "ubuntu-latest-riscv64", "riscv64-linux" },
    .{ "ubuntu-latest-powerpc64le", "powerpc64le-linux" },
    .{ "ubuntu-latest-powerpc", "powerpc-linux" },
    .{ "macos-latest-aarch64", "aarch64-macos" },
});
