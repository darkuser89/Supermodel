#!/usr/bin/env python3
"""Verify native build artifacts statically. Never launches the emulator/GPU."""
import argparse
import hashlib
import json
from pathlib import Path
import re
import shlex
import subprocess


def command(*args):
    return subprocess.check_output(args, text=True)


GRAPHICS_SYMBOL = re.compile(
    r"\b_+(?:gl[A-Z]\w*|glu[A-Z]\w*|glew\w*|SDL_(?:GL_\w*|CreateRenderer|CreateWindowAndRenderer|Render\w*))\b")


def preprocess_graphics(repository, build):
    """Inspect active branches with the real build flags; never execute the app."""
    plan = subprocess.check_output(["make", "-nB", "-f", "Makefiles/Makefile.OSX",
        "METAL4_BUILD_ROOT=" + str(build), "emulator", "check-render-debug"], cwd=repository, text=True)
    results = []
    calls = re.compile(r"\b(?:gl[A-Z]\w*|glu[A-Z]\w*|glew\w*|SDL_GL_\w*)\s*\(")
    marker = re.compile(r'^#\s+\d+\s+"([^"]+)"')
    for line in plan.splitlines():
        args = shlex.split(line)
        if not args or args[0] != "clang++" or ">" in args:
            continue
        if "-c" not in args and "-fsyntax-only" not in args:
            continue
        source = next((a for a in args if a.endswith((".cpp", ".mm"))), None)
        if not source:
            continue
        path = (repository / source).resolve()
        relative = str(path.relative_to(repository))
        if not (relative.startswith("Src/Graphics/") or relative in (
            "Src/OSD/SDL/Main.cpp", "Src/OSD/SDL/Gui.cpp", "Src/OSD/SDL/Crosshair.cpp",
            "Src/Pkgs/imgui/imgui_impl_sdl2.cpp")):
            continue
        cleaned = []
        index = 0
        while index < len(args):
            arg = args[index]
            if arg in ("-o", "-MF"):
                index += 2
                continue
            if arg not in ("-c", "-fsyntax-only", "-MMD", "-MP"):
                cleaned.append(arg)
            index += 1
        cleaned += ["-E", "-Wno-unused-command-line-argument"]
        output = subprocess.check_output(cleaned, cwd=repository, text=True)
        active = False
        project_lines = []
        for expanded in output.splitlines():
            location = marker.match(expanded)
            if location:
                name = location.group(1)
                current = (repository / name).resolve() if not name.startswith("<") else None
                active = current is not None and repository in current.parents and (
                    "Pkgs" not in current.parts or current == path)
            elif active:
                project_lines.append(expanded)
        text = "\n".join(project_lines)
        if calls.search(text) or "SDL_WINDOW_OPENGL" in text:
            raise SystemExit(f"Active OpenGL code after preprocessing: {relative}")
        results.append({"source": relative, "debug": "-DDEBUG" in args,
            "active_opengl_calls": False, "opengl_window_flag": False})
    if len(results) < 19 or not any(r["debug"] for r in results):
        raise SystemExit("Incomplete native graphics preprocessing coverage")
    return results


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("build", nargs="?", default="~/Documents/Supermodel-metal-build")
    parser.add_argument("--deep", action="store_true", help="also preprocess graphics sources with actual build flags")
    options = parser.parse_args()
    repository = Path(__file__).resolve().parents[1]
    build = Path(options.build).expanduser().resolve()
    if build == repository or repository in build.parents or any("audit" in p.lower() for p in build.parts):
        raise SystemExit("Expected a separate build directory")
    binary = build / "supermodel"
    library = build / "Supermodel.metallib"
    fresh = subprocess.run(["make", "-q", "-f", "Makefiles/Makefile.OSX",
        "METAL4_BUILD_ROOT=" + str(build), str(binary), str(library)], cwd=repository,
        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if fresh.returncode:
        raise SystemExit("Native build is stale or its dependency graph is invalid: " + fresh.stderr.strip())
    architecture = command("lipo", "-archs", str(binary)).strip()
    if architecture != "arm64":
        raise SystemExit(f"Expected arm64-only emulator, found {architecture}")
    imports = command("nm", "-u", str(binary))
    symbols = command("nm", "-arch", "arm64", str(binary))
    forbidden = GRAPHICS_SYMBOL.findall(symbols)
    if forbidden:
        raise SystemExit(f"OpenGL imports remain: {forbidden}")
    links = command("otool", "-L", str(binary))
    if re.search(r"OpenGL|GLUT|Vulkan", links):
        raise SystemExit("Unexpected graphics framework linked")
    if re.search(r"Legacy3D|GLSLShader|R3DShader|R3DFrameBuffers|TextureBank", symbols):
        raise SystemExit("Old renderer implementation symbols in native binary")
    binary_data = binary.read_bytes()
    for selector in (b"newMTL4CommandQueue", b"beginCommandBufferWithAllocator:",
        b"newRenderPipelineStateWithDescriptor:compilerTaskOptions:error:"):
        if selector + b"\0" not in binary_data:
            raise SystemExit("Missing Metal 4 command/compiler selector: " + selector.decode())
    if b"newCommandQueue\0" in binary_data or re.search(rb"#version\s+\d+", binary_data):
        raise SystemExit("Legacy command queue or embedded GLSL in native binary")
    framework_dependencies = {}
    for name in ("SDL2", "SDL2_net"):
        framework = build / "Frameworks" / (name + ".framework") / name
        dependencies = command("otool", "-arch", "arm64", "-L", str(framework))
        if re.search(r"OpenGL|GLUT|Vulkan", dependencies):
            raise SystemExit(f"Unexpected graphics dependency in {name}")
        framework_dependencies[name] = "no direct OpenGL/GLUT/Vulkan linkage in arm64 slice"
    for name in ("MTL4CompilerDescriptor", "MTL4ArgumentTableDescriptor", "MTL4RenderPassDescriptor", "MTL4RenderPipelineDescriptor"):
        if name not in imports:
            raise SystemExit(f"Missing native Metal 4 API reference: {name}")
    if "minos 26.0" not in command("otool", "-l", str(binary)):
        raise SystemExit("Expected macOS 26 deployment target")
    native = repository / "Src/Graphics/Metal4"
    shaders = "\n".join(p.read_text() for p in native.glob("*.metal"))
    shaders = re.sub(r"//[^\n]*|/\*.*?\*/", " ", shaders, flags=re.DOTALL)
    entries = set(re.findall(r"^\s*(?:vertex|fragment|kernel)\s+\w+\s+(\w+)\s*\(", shaders, flags=re.MULTILINE))
    implementation = "\n".join(p.read_text() for p in native.glob("*.mm"))
    required = set(re.findall(r'"(\w+_(?:vertex|fragment)(?:_culled)?)"', implementation))
    if required - entries:
        raise SystemExit(f"Missing shader entry points: {sorted(required - entries)}")
    if not library.is_file() or library.stat().st_size == 0:
        raise SystemExit("Native shader library missing")
    library_data = library.read_bytes()
    if any(name.encode() + b"\0" not in library_data for name in required):
        raise SystemExit("Referenced shader names missing from compiled library")
    if command("git", "-C", str(repository), "diff", "--name-only", "--", "Src/Pkgs").strip():
        raise SystemExit("Bundled package sources were modified")
    objects = list((build / "obj").glob("*.o"))
    object_imports = command("nm", "-u", *(str(p) for p in objects))
    if GRAPHICS_SYMBOL.search(object_imports):
        raise SystemExit("OpenGL imports in a compiled object")
    dependencies = "\n".join(p.read_text() for p in (build / "obj").glob("*.d"))
    for banned in ("GL/glew.h", "Legacy3D/", "imgui_impl_opengl3"):
        if banned in dependencies:
            raise SystemExit(f"Unexpected OpenGL dependency: {banned}")
    command("git", "-C", str(repository), "-c", "core.whitespace=cr-at-eol", "diff", "--check")
    preprocessed = preprocess_graphics(repository, build) if options.deep else None
    print(json.dumps({
        "verification": "static only; app and GPU not executed",
        "architecture": architecture,
        "minimum_macos": "26.0",
        "build_up_to_date": True,
        "object_count": len(objects),
        "opengl_imports": forbidden,
        "symbol_scope": "all defined and undefined app symbols; undefined object symbols; includes GLU and SDL renderer API",
        "framework_dependencies": framework_dependencies,
        "metal4_command_and_compiler_selectors_present": True,
        "old_renderer_symbols_or_embedded_glsl": False,
        "shader_entry_points": sorted(entries),
        "pipeline_shader_names_resolved": sorted(required),
        "pipeline_shader_names_present_in_compiled_library": True,
        "preprocessed_graphics": preprocessed,
        "bundled_package_sources_modified": False,
        "artifacts": {p.name: {"path": str(p), "bytes": p.stat().st_size,
            "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in (binary, library)},
        "not_verified": ["GPU pipeline creation", "Rendered pixels/game compatibility", "Performance/latency"],
    }, indent=2))


if __name__ == "__main__":
    main()
