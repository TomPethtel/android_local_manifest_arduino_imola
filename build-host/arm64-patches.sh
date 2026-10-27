#!/bin/bash
# Native arm64 host support for the LineageOS 24 imola tree (after actinis.io/blog/building-aosp-on-arm64).
# Idempotent: every edit checks for its marker first. Run from the tree root.
set -euo pipefail
cd "$(dirname "$0")/lineage-24" 2>/dev/null || cd ~/lineage-24

python3 - <<'PY'
import re, pathlib
def patch(path, old, new, marker=None):
    p = pathlib.Path(path); s = p.read_text()
    if (marker or new) in s: print(f"already: {path}"); return
    assert s.count(old) == 1, f"anchor not unique in {path}: {old[:60]!r} x{s.count(old)}"
    p.write_text(s.replace(old, new)); print(f"patched: {path}")

# 1. envsetup.sh: host prebuilt prefix on aarch64
patch("build/make/envsetup.sh",
      '  if [[ $un == "Linux" ]] ; then\n    echo linux-x86\n',
      '  if [[ $un == "Linux" ]] ; then\n    if [[ $(uname -m) == "aarch64" ]] ; then echo linux-arm64; else echo linux-x86; fi\n')

# 2. envsetup.mk: HOST_ARCH / HOST_PREBUILT_ARCH on aarch64
patch("build/make/core/envsetup.mk",
      'ifneq (,$(findstring x86_64,$(UNAME)))\n  HOST_ARCH := x86_64\n',
      'ifneq (,$(findstring aarch64,$(UNAME)))\n  HOST_ARCH := arm64\n  HOST_2ND_ARCH :=\n  HOST_IS_64_BIT := true\nelse ifneq (,$(findstring x86_64,$(UNAME)))\n  HOST_ARCH := x86_64\n')
patch("build/make/core/envsetup.mk",
      'HOST_PREBUILT_ARCH := x86\n',
      'ifeq ($(HOST_ARCH),arm64)\nHOST_PREBUILT_ARCH := arm64\nelse\nHOST_PREBUILT_ARCH := x86\nendif\n')

# 3. clang config.mk: use HOST_PREBUILT_TAG instead of hardcoded x86 dirs; add HOST_arm64.mk
patch("build/make/core/clang/config.mk",
      '$(LLVM_PREBUILTS_BASE)/$(BUILD_OS)-x86/$(LLVM_PREBUILTS_VERSION)/bin/llvm-readobj',
      '$(LLVM_PREBUILTS_BASE)/$(HOST_PREBUILT_TAG)/$(LLVM_PREBUILTS_VERSION)/bin/llvm-readobj')
patch("build/make/core/clang/config.mk",
      '$(LLVM_PREBUILTS_BASE)/linux-x86/$(LLVM_PREBUILTS_VERSION)/lib/clang/*)/lib/linux/',
      '$(LLVM_PREBUILTS_BASE)/$(HOST_PREBUILT_TAG)/$(LLVM_PREBUILTS_VERSION)/lib/clang/*)/lib/linux/')
hp = pathlib.Path("build/make/core/clang/HOST_arm64.mk")
if not hp.exists():
    hp.write_text("HOST_LIBPROFILE_RT := $(LLVM_RTLIB_PATH)/aarch64-unknown-linux-musl/libclang_rt.profile.a\n"
                  "HOST_LIBCRT_BUILTINS := $(LLVM_RTLIB_PATH)/aarch64-unknown-linux-musl/libclang_rt.builtins.a\n"); print("created: HOST_arm64.mk")

# 4. soong paths.go: host install dir = out/host/linux-arm64 on an arm64 musl host
patch("build/soong/android/paths.go",
      '\t\tif os == LinuxMusl && ctx.Config().UseHostMusl() {\n',
      '\t\tif os == LinuxMusl && (ctx.Config().UseHostMusl() || ctx.Config().BuildOS == LinuxMusl) {\n')
patch("build/soong/android/paths.go",
      '\t\tif os.Class == Host && (arch == X86_64 || arch == Common) {\n\t\t\tarchName = "x86"\n\t\t}\n',
      '\t\tif os.Class == Host && (arch == X86_64 || arch == Common) {\n\t\t\tarchName = "x86"\n\t\t\tif ctx.Config().BuildArch == Arm64 {\n\t\t\t\tarchName = "arm64" // Local: arm64 build host (matches HOST_PREBUILT_ARCH)\n\t\t\t}\n\t\t}\n')

# 5. rule_builder.go: stage libc_musl.so whenever the build host is musl (forced on arm64)
patch("build/soong/android/rule_builder.go",
      '\tif c.rule.ctx.Config().UseHostMusl() {\n\t\t// If the host is using musl',
      '\tif c.rule.ctx.Config().UseHostMusl() || c.rule.ctx.Config().BuildOS == LinuxMusl {\n\t\t// If the host is using musl')

# 6. rust HostPrebuiltTag: arm64 host -> prebuilts/rust-toolchain/linux-arm64
patch("build/soong/rust/config/global.go",
      'func HostPrebuiltTag(config android.Config) string {\n\tif config.UseHostMusl() {\n',
      'func HostPrebuiltTag(config android.Config) string {\n\tif config.PrebuiltOS() == "linux-arm64" {\n\t\treturn "linux-arm64" // Local: native arm64 host toolchain\n\t} else if config.UseHostMusl() {\n')

# 7. rust toolchain_library.go: linux_musl_arm64 prebuilt sysroot target
patch("build/soong/rust/toolchain_library.go",
      '\t\tLinux_musl_x86     hostPrebuiltTargetProps\n',
      '\t\tLinux_musl_x86     hostPrebuiltTargetProps\n\t\tLinux_musl_arm64   hostPrebuiltTargetProps\n')
patch("build/soong/rust/toolchain_library.go",
      '\t\t} else if platform == "darwin" && ctx.Config().BuildOS == android.Darwin {\n',
      '\t\t} else if platform == "linux-arm64" && ctx.Config().BuildOS == android.LinuxMusl && ctx.Config().BuildArch == android.Arm64 {\n\t\t\tp.Target.Linux_musl_arm64.addPrebuiltToTarget(ctx, name, rustDir, "linux-arm64", "aarch64-unknown-linux-musl", rlib, solib)\n\t\t} else if platform == "darwin" && ctx.Config().BuildOS == android.Darwin {\n')

patch("build/soong/rust/toolchain_library.go",
      '\t\t} else if platform == "linux-musl-x86" && ctx.Config().BuildOS == android.LinuxMusl {\n',
      '\t\t} else if platform == "linux-musl-x86" && ctx.Config().BuildOS == android.LinuxMusl && ctx.Config().BuildArch != android.Arm64 {\n')

# 8. soong_ui sandbox: nsjail from the host's own prebuilt dir
sp = pathlib.Path("build/soong/ui/build/sandbox_linux.go"); s = sp.read_text()
if "nsjailPath = \"prebuilts/build-tools/linux-x86/bin/nsjail\"" in s:
    s = s.replace('\tnsjailPath = "prebuilts/build-tools/linux-x86/bin/nsjail"\n', '')
    s = s.replace('\tabfsSrcDir = "/src"\n)\n', '\tabfsSrcDir = "/src"\n)\n\n// Local: pick the nsjail prebuilt matching the build host.\nvar nsjailPath = "prebuilts/build-tools/" + map[string]string{"arm64": "linux-arm64"}[runtime.GOARCH] + "/bin/nsjail"\n', 1)
    s = s.replace('var nsjailPath = "prebuilts/build-tools/" + map[string]string{"arm64": "linux-arm64"}[runtime.GOARCH] + "/bin/nsjail"',
                  'var nsjailPath = func() string {\n\tif runtime.GOARCH == "arm64" {\n\t\treturn "prebuilts/build-tools/linux-arm64/bin/nsjail"\n\t}\n\treturn "prebuilts/build-tools/linux-x86/bin/nsjail"\n}()')
    if '"runtime"' not in s:
        s = s.replace('import (\n', 'import (\n\t"runtime"\n', 1)
    sp.write_text(s); print("patched: sandbox_linux.go")
else: print("already: sandbox_linux.go")

# 9. prebuilts/build-tools: enable bison/flex/m4/make on an arm64 musl host
bp = pathlib.Path("prebuilts/build-tools/Android.bp"); s = bp.read_text()
if "linux-arm64/bin/bison" not in s:
    for tool in ["bison", "flex", "m4", "make"]:
        m = re.search(r'prebuilt_build_tool \{\n    name: "%s",\n.*?\n\}\n' % tool, s, re.S)
        assert m, tool
        block = m.group(0)
        nb = block.replace('        x86_64: {\n            enabled: true,\n        },\n    },',
                           '        x86_64: {\n            enabled: true,\n        },\n        arm64: {\n            enabled: true,\n        },\n    },', 1)
        nb = nb.replace('        linux: {\n            src: "linux-x86/bin/%s",' % tool,
                        '        linux_musl_arm64: {\n            src: "linux-arm64/bin/%s",\n            deps: ["linux-arm64/lib64/libc_musl.so"],\n        },\n        linux: {\n            src: "linux-x86/bin/%s",' % (tool, tool), 1)
        assert nb != block, tool
        s = s.replace(block, nb)
    bp.write_text(s); print("patched: prebuilts/build-tools/Android.bp")
else: print("already: prebuilts/build-tools/Android.bp")

# 10. prebuilts/jdk/jdk21: javap on arm64
jp = pathlib.Path("prebuilts/jdk/jdk21/Android.bp"); s = jp.read_text()
if "linux_musl_arm64" not in s:
    m = re.search(r'        linux: \{\n            src: "linux-x86/bin/javap",\n            deps: \[\n(.*?)            \],\n        \},\n', s, re.S)
    assert m
    deps = m.group(1).replace("linux-x86/", "linux-arm64/")
    arm = '        linux_musl_arm64: {\n            src: "linux-arm64/bin/javap",\n            deps: [\n' + deps + '            ],\n        },\n'
    s = s.replace(m.group(0), arm + m.group(0), 1)
    s = s.replace('        x86_64: {\n            enabled: true,\n        },\n    },', '        x86_64: {\n            enabled: true,\n        },\n        arm64: {\n            enabled: true,\n        },\n    },', 1)
    jp.write_text(s); print("patched: prebuilts/jdk/jdk21/Android.bp")
else: print("already: prebuilts/jdk/jdk21/Android.bp")

# 11. sepolicy tools: getopt result must be int (char is unsigned on aarch64, so -1 never matches)
cp = pathlib.Path("system/sepolicy/tools/checkfc.c"); s = cp.read_text()
i = s.index("while ((c = getopt("); j = s.rfind("char c;", 0, i)
if j < 0: print("already: checkfc.c")
else: cp.write_text(s[:j] + "int c;" + s[j+len("char c;"):]); print("patched: checkfc.c")
patch("system/sepolicy/tools/sepolicy-analyze/attribute.c", '    char ch;\n', '    int ch;\n')
patch("system/sepolicy/tools/sepolicy-analyze/neverallow.c", '    char ch;\n', '    int ch;\n')
print("ALL PATCHES OK")
PY

# 12. prebuilts/clang/host/linux-x86 Soong plugin: teach it about the linux-arm64 prebuilts.
#     The linux-arm64 Android.bp (from AOSP main) uses llvm_host_arch_filegroup, which our older plugin lacks.
python3 - <<'PY'
import pathlib
p = pathlib.Path("prebuilts/clang/host/linux-x86/soong/clangprebuilts.go"); s = p.read_text()
if "llvm_host_arch_filegroup" in s:
    print("already: clangprebuilts.go")
else:
    # register the module type
    a = '\tandroid.RegisterModuleType("llvm_tools_filegroup",\n\t\tllvmToolsFilegroupFactory)\n'
    assert s.count(a) == 1
    s = s.replace(a, a + '\tandroid.RegisterModuleType("llvm_host_arch_filegroup",\n\t\tllvmHostArchFileGroupFactory)\n')
    # helpers + filegroup implementation (ported from AOSP main)
    s += '''
// ---- Local: native arm64 host support, ported from AOSP main's clangprebuilts.go ----

// hasLinuxArm64ClangPrebuilt returns true if clang prebuilts are present for linux-arm64.
func hasLinuxArm64ClangPrebuilt(ctx android.LoadHookContext) bool {
	return android.ExistentPathForSource(ctx, "prebuilts/clang/host/linux-arm64", getClangPrebuiltDir(ctx), "bin/clang").Valid()
}

type llvmHostArchFileGroupProperties struct {
	Lib *string
}

type llvmHostArchFileGroup struct {
	android.Module

	properties llvmHostArchFileGroupProperties
}

func llvmHostArchFileGroupHook(ctx android.LoadHookContext, fileGroupProps *llvmHostArchFileGroupProperties) {
	clangDir := getClangPrebuiltDir(ctx)
	lib := proptools.String(fileGroupProps.Lib)
	if !android.ExistentPathForSource(ctx, ctx.ModuleDir(), clangDir, lib).Valid() {
		return
	}
	type props struct {
		Srcs []string
	}
	p := &props{}
	p.Srcs = []string{path.Join(clangDir, lib)}
	ctx.AppendProperties(p)
}

func llvmHostArchFileGroupFactory() android.Module {
	module := &llvmHostArchFileGroup{
		Module: android.FileGroupFactory(),
	}
	module.AddProperties(&module.properties)
	android.AddLoadHook(module, func(ctx android.LoadHookContext) {
		llvmHostArchFileGroupHook(ctx, &module.properties)
	})
	return module
}
'''
    # llvm_prebuilt_build_tool: arm64 host tools come from the linux-arm64 filegroups
    a = '\tp.Target.Linux.Enabled = proptools.BoolPtr(true)\n\tp.Target.Linux.Src = &src\n\tp.Target.Linux.Deps = deps\n\tctx.AppendProperties(p)\n'
    assert s.count(a) == 1
    s = s.replace('\t\t\tLinux struct {\n\t\t\t\tEnabled *bool\n\t\t\t\tSrc     *string\n\t\t\t\tDeps    []string\n\t\t\t}\n\t\t}\n\t}\n\tp := &props{}\n\tp.Enabled = proptools.BoolPtr(false)\n\tp.Target.Linux.Enabled',
                  '\t\t\tLinux struct {\n\t\t\t\tEnabled *bool\n\t\t\t\tSrc     *string\n\t\t\t\tDeps    []string\n\t\t\t}\n\t\t\tHost_linux_arm64 struct {\n\t\t\t\tEnabled *bool\n\t\t\t\tSrc     *string\n\t\t\t\tDeps    []string\n\t\t\t}\n\t\t}\n\t}\n\tp := &props{}\n\tp.Enabled = proptools.BoolPtr(false)\n\tp.Target.Linux.Enabled')
    s = s.replace(a, '\tp.Target.Linux.Enabled = proptools.BoolPtr(true)\n\tp.Target.Linux.Src = &src\n\tp.Target.Linux.Deps = deps\n\tif hasLinuxArm64ClangPrebuilt(ctx) {\n\t\tp.Target.Host_linux_arm64.Enabled = proptools.BoolPtr(true)\n\t\tp.Target.Host_linux_arm64.Src = proptools.StringPtr(":" + name + "_host_linux_arm64")\n\t\tp.Target.Host_linux_arm64.Deps = []string{":llvm_tools_libc_musl_host_linux_arm64"}\n\t}\n\tctx.AppendProperties(p)\n')
    assert "Host_linux_arm64.Enabled" in s and "Host_linux_arm64 struct" in s
    # libclang-cpp_host on an arm64 host
    a = '\t} else if moduleName == "libclang-cpp_host" {\n'
    assert s.count(a) == 1
    i = s.index(a); j = s.index("\n\t}", i + len(a))
    block = s[i:j]
    assert "Linux_musl_arm64" not in block
    s = s[:j] + '\n\t\tif hasLinuxArm64ClangPrebuilt(ctx) {\n\t\t\tp.Target.Linux_musl_arm64.Srcs = []string{":libclang-cpp_host_linux_arm64"}\n\t\t}' + s[j:]
    p.write_text(s); print("patched: clangprebuilts.go")
PY

# 13. Toolchain glue (not source patches):
#   - prebuilts/jdk/jdk8 has only linux-x86; its jars are arch-neutral, so alias linux-arm64 to it (guava needs rt.jar/jce.jar).
#   - upstream stable rustc rejects the -Z flags Soong passes (AOSP's own rustc build accepts them): wrap it with RUSTC_BOOTSTRAP=1.
[ -e prebuilts/jdk/jdk8/linux-arm64 ] || { ln -s linux-x86 prebuilts/jdk/jdk8/linux-arm64 && echo "linked: prebuilts/jdk/jdk8/linux-arm64"; }
rb=prebuilts/rust-toolchain/linux-arm64/1.93.1/bin
if [ -f "$rb/rustc" ] && [ ! -f "$rb/rustc.real" ]; then
  mv "$rb/rustc" "$rb/rustc.real"
  printf '#!/bin/sh\n# Upstream stable rustc rejects the -Z flags Soong passes; AOSP'"'"'s own rustc build accepts them.\nRUSTC_BOOTSTRAP=1 exec "$(dirname "$0")/rustc.real" "$@"\n' > "$rb/rustc"
  chmod +x "$rb/rustc"; echo "wrapped: $rb/rustc"
fi
echo "TOOLCHAIN GLUE OK"
