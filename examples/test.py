#!/usr/bin/env python3
from __future__ import annotations

import argparse
import collections
import ctypes
import hashlib
import os
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path


HERE = Path(__file__).resolve().parent
LLVM_ROOT = HERE.parent
UPSTREAM_EXAMPLES = LLVM_ROOT / "llvm-project" / "llvm" / "examples"
LLVM_TAG = "llvmorg-22.1.8"
LLVM_COMMIT = "ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"
LLVM_VERSION = (22, 1, 8)
SUPPORTED_HOSTS = ("Darwin", "Linux", "Windows")
UNIX_HOSTS = ("Darwin", "Linux")
LOADER_ENVIRONMENT_VARIABLES = {
    "DYLD_FALLBACK_FRAMEWORK_PATH",
    "DYLD_FALLBACK_LIBRARY_PATH",
    "DYLD_FRAMEWORK_PATH",
    "DYLD_INSERT_LIBRARIES",
    "DYLD_LIBRARY_PATH",
    "LD_LIBRARY_PATH",
    "LD_PRELOAD",
    "LIBPATH",
    "SHLIB_PATH",
}


@dataclass(frozen=True)
class Case:
    target: str
    category: str
    source: str
    args: tuple[str, ...] = ()
    stdin: str = ""
    expected: tuple[str, ...] = ()
    absent: tuple[str, ...] = ()
    exact: str | None = None
    expected_files: tuple[str, ...] = ()
    object_symbols: tuple[str, ...] = ()
    allowed_diagnostics: tuple[str, ...] = ()
    status: int = 0
    llvm_link: bool = True
    binary_prefix: bytes | None = None
    build: str = "odin"
    timeout: int = 240
    hosts: tuple[str, ...] = SUPPORTED_HOSTS


@dataclass(frozen=True)
class Host:
    system: str
    arch: str
    library_dir: Path
    llvm_library_name: str
    lto_library_name: str
    required_library_names: tuple[str, ...]
    shared_library_patterns: tuple[str, ...]
    object_binary_type: int
    executable_suffix: str


CASES = (
    Case(
        "Kaleidoscope-Ch2",
        "kaleidoscope",
        "Kaleidoscope/Chapter2",
        stdin="def add(x y) x+y;\nextern sin(x);\nadd(1,2);\n",
        expected=(
            "Parsed a function definition.",
            "Parsed an extern",
            "Parsed a top-level expr",
        ),
        status=0,
        llvm_link=False,
    ),
    Case(
        "Kaleidoscope-Ch3",
        "kaleidoscope",
        "Kaleidoscope/Chapter3",
        stdin="def add(x y) x+y;\nadd(1,2);\n",
        expected=("define double @add", "fadd double"),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch4",
        "kaleidoscope",
        "Kaleidoscope/Chapter4",
        stdin="extern twice(x);\nextern twice(x);\ndef twice(x) x*2;\ntwice(21);\n",
        expected=("Evaluated to 42.000000",),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch5",
        "kaleidoscope",
        "Kaleidoscope/Chapter5",
        stdin="def fib(x) if x < 3 then 1 else fib(x-1)+fib(x-2);\nfib(10);\n",
        expected=("Evaluated to 55.000000",),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch6",
        "kaleidoscope",
        "Kaleidoscope/Chapter6",
        stdin="def binary% 40 (x y) x*y;\n6%7;\n",
        expected=("Evaluated to 42.000000",),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch7",
        "kaleidoscope",
        "Kaleidoscope/Chapter7",
        stdin="var a = 5 in (a = a + 1) * a;\n",
        expected=("Evaluated to 36.000000",),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch8",
        "kaleidoscope",
        "Kaleidoscope/Chapter8",
        stdin="def twice(x) x*2;\n",
        expected=("Wrote output.o",),
        expected_files=("output.o",),
        object_symbols=("twice",),
        status=0,
    ),
    Case(
        "Kaleidoscope-Ch9",
        "kaleidoscope",
        "Kaleidoscope/Chapter9",
        stdin="def inc(x) x+1;\ninc(2);\n",
        expected=(
            "define double @inc",
            "#dbg_declare",
            "define double @main",
            "!DICompileUnit",
            '!DIFile(filename: "fib.ks"',
            "!DISubprogram",
            "!DILocalVariable",
            "!DILocation",
        ),
        status=0,
    ),
    Case(
        "BuildingAJIT-Ch1",
        "kaleidoscope",
        "Kaleidoscope/BuildingAJIT/Chapter1",
        stdin="def twice(x) x*2;\ntwice(21);\n",
        expected=("Evaluated to 42.000000",),
        status=0,
    ),
    Case(
        "BuildingAJIT-Ch2",
        "kaleidoscope",
        "Kaleidoscope/BuildingAJIT/Chapter2",
        stdin="def square(x) x*x;\nsquare(9);\n",
        expected=("Evaluated to 81.000000",),
        status=0,
    ),
    Case(
        "BuildingAJIT-Ch3",
        "kaleidoscope",
        "Kaleidoscope/BuildingAJIT/Chapter3",
        stdin="def add1(x) x+1;\ndef twice(x) x*2;\nadd1(twice(10));\n",
        expected=("Evaluated to 21.000000",),
        status=0,
    ),
    Case(
        "BuildingAJIT-Ch4",
        "kaleidoscope",
        "Kaleidoscope/BuildingAJIT/Chapter4",
        stdin="def add1(x) x+1;\ndef twice(x) x*2;\nadd1(twice(10));\n",
        expected=("Evaluated to 21.000000",),
        status=0,
    ),
    Case(
        "BrainF",
        "top",
        "BrainF",
        args=("-jit", "{fixtures}/brainf.bf"),
        expected=("------- Running JIT -------\nA",),
        status=0,
    ),
    Case(
        "Fibonacci",
        "top",
        "Fibonacci",
        args=("10",),
        expected=("starting fibonacci(10) with JIT", "Result: 55"),
        status=0,
    ),
    Case(
        "HowToUseJIT",
        "top",
        "HowToUseJIT",
        expected=("Running foo: Result: 11",),
        status=0,
    ),
    Case(
        "HowToUseLLJIT",
        "top",
        "HowToUseLLJIT",
        expected=("add1(42) = 43",),
        status=0,
    ),
    Case(
        "ExampleIRTransforms",
        "top",
        "IRTransforms",
        args=("-tut-simplifycfg-version=v3", "{fixtures}/passes.ll"),
        expected=("define i32 @live()", "ret i32 7"),
        absent=("br i1", "ret i32 9"),
        status=0,
        hosts=UNIX_HOSTS,
    ),
    Case(
        "ModuleMaker",
        "top",
        "ModuleMaker",
        binary_prefix=b"BC\xc0\xde",
        status=0,
    ),
    Case(
        "SpeculativeJIT",
        "top",
        "SpeculativeJIT",
        args=(
            "--num-threads=2",
            "{examples}/SpeculativeJIT/tests/fixtures/main.ll",
            "{examples}/SpeculativeJIT/tests/fixtures/support.ll",
            "--",
            "harness",
        ),
        expected=("harness",),
        status=0,
    ),
    Case(
        "Bye",
        "top",
        "Bye",
        args=("-wave-goodbye", "{fixtures}/passes.ll"),
        expected=("Bye: live",),
        status=0,
        hosts=UNIX_HOSTS,
    ),
    Case(
        "OptSubcommand",
        "top",
        "OptSubcommand",
        args=("foo", "-uppercase"),
        expected=("FOO",),
        status=0,
        llvm_link=False,
    ),
    Case(
        "ExceptionDemo",
        "conditional",
        "ExceptionDemo",
        args=("2", "3", "7", "-1"),
        expected=(
            "Begin Test:",
            "Gen: Executing catch block typeInfo2 in innerCatchFunct",
            "Gen: Executing catch block typeInfo3 in outerCatchFunct",
            "runExceptionThrow(...):In C++ catch all.",
            "runExceptionThrow(...):In C++ catch OurCppRunException",
            "End Test:",
        ),
        status=0,
        build="script",
        timeout=360,
        hosts=UNIX_HOSTS,
    ),
    Case(
        "ParallelJIT",
        "conditional",
        "ParallelJIT",
        expected=(
            "Add1 returned 1001",
            "Fib1 returned 63245986",
            "Fib2 returned 267914296",
        ),
        status=0,
        timeout=360,
        hosts=UNIX_HOSTS,
    ),
    Case(
        "LLJITDumpObjects",
        "orc",
        "OrcV2Examples/LLJITDumpObjects",
        args=("--dump-dir={run}", "--dump-file-stem=lljit-dump"),
        expected=("Usage notes:", "add1(42) = 43"),
        expected_files=("*.o",),
        object_symbols=("add1",),
        status=0,
    ),
    Case(
        "LLJITRemovableCode",
        "orc",
        "OrcV2Examples/LLJITRemovableCode",
        expected=(
            "Initially:\nfoo = 0x",
            "\nbar = 0x",
            "\nbaz = 0x",
            "After implicitly transferring ownership of baz to JD's default tracker:\nfoo = 0x",
            "\nbar = 0x",
            "\nbaz = 0x",
            "After removing bar (lookup for bar should yield a missing symbol error):\nfoo = 0x",
            "\nbar = error:",
            "\nbaz = 0x",
            "After clearing JD (lookup should yield missing symbol errors for all symbols):\nfoo = error:",
            "\nbar = error:",
            "\nbaz = error:",
            "Removing JD.",
            "done.",
        ),
        allowed_diagnostics=("missing symbol error", " = error:"),
        status=0,
    ),
    Case(
        "LLJITWithCustomObjectLinkingLayer",
        "orc",
        "OrcV2Examples/LLJITWithCustomObjectLinkingLayer",
        expected=(
            "Custom JITLink object linking layer created with in-process memory manager",
            "add1(42) = 43",
        ),
        exact=(
            "Custom JITLink object linking layer created with in-process memory manager\n"
            "add1(42) = 43\n"
        ),
        status=0,
    ),
    Case(
        "LLJITWithExecutorProcessControl",
        "orc",
        "OrcV2Examples/LLJITWithExecutorProcessControl",
        args=("argument",),
        expected=("---Session state---", "entry(2) = 2"),
        status=0,
    ),
    Case(
        "LLJITWithGDBRegistrationListener",
        "orc",
        "OrcV2Examples/LLJITWithGDBRegistrationListener",
        args=("{fixtures}/main.ll",),
        expected=(
            "Custom RTDyld layer registered GDB JIT event listener",
            "process-all-sections unavailable through LLVM-C; emitted sections only",
        ),
        status=0,
    ),
    Case(
        "LLJITWithInitializers",
        "orc",
        "OrcV2Examples/LLJITWithInitializers",
        expected=("InitializerRanFlag = 1", "DeinitializersRunFlag = 1"),
        status=0,
    ),
    Case(
        "LLJITWithLazyReexports",
        "orc",
        "OrcV2Examples/LLJITWithLazyReexports",
        expected=("---Session state---", "---Compiling---", "entry(1) = 1"),
        status=0,
    ),
    Case(
        "LLJITWithObjectCache",
        "orc",
        "OrcV2Examples/LLJITWithObjectCache",
        expected=(
            "No object for add1 in cache. Compiling.",
            "Object for add1 loaded from cache.",
            "add1(42) = 43",
            "add1(42) = 43",
        ),
        status=0,
    ),
    Case(
        "LLJITWithObjectLinkingLayerPlugin",
        "orc",
        "OrcV2Examples/LLJITWithObjectLinkingLayerPlugin",
        expected=(
            "No input objects specified. Using demo module:",
            "Stage: object transform before link",
            "Stage: lookup materialized and linked `entry'",
            "entry() = 7",
        ),
        status=0,
    ),
    Case(
        "LLJITWithOptimizingIRTransform",
        "orc",
        "OrcV2Examples/LLJITWithOptimizingIRTransform",
        expected=(
            "--- BEFORE OPTIMIZATION ---",
            "--- AFTER OPTIMIZATION ---",
            "--- Result ---",
            "entry() = 120",
        ),
        status=0,
    ),
    Case(
        "LLJITWithThinLTOSummaries",
        "orc",
        "OrcV2Examples/LLJITWithThinLTOSummaries",
        args=(
            "{examples}/OrcV2Examples/LLJITWithThinLTOSummaries/foo-mod.ll",
            "{examples}/OrcV2Examples/LLJITWithThinLTOSummaries/bar-mod.ll",
            "{examples}/OrcV2Examples/LLJITWithThinLTOSummaries/main-mod.ll",
        ),
        expected=(
            "About to load module:",
            "About to load module:",
            "About to load module:",
            "'main' finished with exit code: 0",
        ),
        status=0,
    ),
    Case(
        "OrcV2CBindingsAddObjectFile",
        "orc",
        "OrcV2Examples/OrcV2CBindingsAddObjectFile",
        expected=("1 + 2 = 3",),
        status=0,
    ),
    Case(
        "OrcV2CBindingsBasicUsage",
        "orc",
        "OrcV2Examples/OrcV2CBindingsBasicUsage",
        expected=("1 + 2 = 3",),
        status=0,
    ),
    Case(
        "OrcV2CBindingsDumpObjects",
        "orc",
        "OrcV2Examples/OrcV2CBindingsDumpObjects",
        expected=("1 + 2 = 3",),
        expected_files=("*.o",),
        object_symbols=("sum",),
        status=0,
    ),
    Case(
        "OrcV2CBindingsIRTransforms",
        "orc",
        "OrcV2Examples/OrcV2CBindingsIRTransforms",
        expected=("1 + 2 = 3",),
        status=0,
    ),
    Case(
        "OrcV2CBindingsMCJITLikeMemoryManager",
        "orc",
        "OrcV2Examples/OrcV2CBindingsMCJITLikeMemoryManager",
        expected=(
            "Allocated code section",
            "Marking code sections as executable",
            "1 + 2 = 3",
            "Releasing section memory",
        ),
        status=0,
    ),
    Case(
        "OrcV2CBindingsRemovableCode",
        "orc",
        "OrcV2Examples/OrcV2CBindingsRemovableCode",
        expected=(
            "Error: Symbols not found",
            "Looking up before removal...",
            "1 + 2 = 3",
            "Attempting to remove code / symbols...",
            "Received error as expected:",
            "Releasing resource tracker...",
            "Destroying LLJIT instance and exiting.",
        ),
        absent=("Failure: Second lookup should have generated an error.",),
        allowed_diagnostics=("received error as expected", "error: symbols not found"),
        status=0,
    ),
    Case(
        "OrcV2CBindingsLazy",
        "orc",
        "OrcV2Examples/OrcV2CBindingsLazy",
        expected=("--- Result ---", "entry(1) = 1"),
        exact="--- Result ---\nentry(1) = 1\n",
        status=0,
    ),
    Case(
        "OrcV2CBindingsVeryLazy",
        "orc",
        "OrcV2Examples/OrcV2CBindingsVeryLazy",
        expected=("--- Result ---", "entry(1) = 1"),
        exact="--- Result ---\nentry(1) = 1\n",
        status=0,
    ),
    Case(
        "LLJITWithRemoteDebugging",
        "orc",
        "OrcV2Examples/LLJITWithRemoteDebugging",
        args=(
            "{examples}/OrcV2Examples/LLJITWithRemoteDebugging/argc_sub1.ll",
            "--args",
            "hello",
        ),
        expected=(
            "Initializing in-process LLJIT with debug support",
            "Parsing input IR code from:",
            'Running: main("hello")',
            "Exit code: 1",
        ),
        absent=("unavailable through LLVM-C", "Attach a debugger"),
        status=0,
        hosts=UNIX_HOSTS,
    ),
)


EXPECTED_CATEGORY_COUNTS = {
    "kaleidoscope": 12,
    "top": 9,
    "orc": 20,
    "conditional": 2,
}
EXPECTED_HOST_CONSTRAINTS = {
    "Bye": UNIX_HOSTS,
    "ExampleIRTransforms": UNIX_HOSTS,
    "ExceptionDemo": UNIX_HOSTS,
    "LLJITWithRemoteDebugging": UNIX_HOSTS,
    "ParallelJIT": UNIX_HOSTS,
}

TARGET_RE = re.compile(
    r"\b(?:add_llvm_example|add_llvm_pass_plugin|add_kaleidoscope_chapter)"
    r"\s*\(\s*([A-Za-z0-9_.+-]+)"
)
SUBDIRECTORY_RE = re.compile(r"\badd_subdirectory\s*\(\s*([A-Za-z0-9_.+-]+)")
DIAGNOSTIC_RE = re.compile(r"\b(?:fatal(?:\s+error)?|error)\b", re.IGNORECASE)

ARTIFACT_SUFFIXES = {
    ".a",
    ".bc",
    ".dll",
    ".dylib",
    ".exe",
    ".lib",
    ".o",
    ".obj",
    ".pdb",
    ".pyc",
    ".pyo",
    ".so",
}
ARTIFACT_DIRECTORY_NAMES = {".cache", ".odin-cache", "__pycache__", "CMakeFiles"}
ARTIFACT_FILE_NAMES = {"CMakeCache.txt"}
BINARY_MAGICS = (
    b"\x7fELF",
    b"MZ",
    b"!<arch>\n",
    b"BC\xc0\xde",
    b"\x00asm",
    b"\xca\xfe\xba\xbe",
    b"\xbe\xba\xfe\xca",
    b"\xfe\xed\xfa\xce",
    b"\xce\xfa\xed\xfe",
    b"\xfe\xed\xfa\xcf",
    b"\xcf\xfa\xed\xfe",
)


def decode(data: bytes) -> str:
    return data.decode("utf-8", errors="replace")


def display_output(stdout: bytes, stderr: bytes) -> str:
    output = decode(stdout) + decode(stderr)
    if len(output) > 12_000:
        return "... output truncated ...\n" + output[-12_000:]
    return output


def canonical_targets() -> dict[str, Path]:
    pending = [UPSTREAM_EXAMPLES]
    visited: set[Path] = set()
    targets: dict[str, Path] = {}

    while pending:
        directory = pending.pop()
        cmake = directory / "CMakeLists.txt"
        if cmake in visited:
            continue
        visited.add(cmake)
        if not cmake.is_file():
            raise AssertionError(f"canonical CMake file missing: {cmake}")

        text = cmake.read_text(encoding="utf-8")
        for match in TARGET_RE.finditer(text):
            target = match.group(1)
            if target in targets:
                raise AssertionError(f"duplicate canonical target {target}: {cmake}")
            targets[target] = cmake

        for match in SUBDIRECTORY_RE.finditer(text):
            child = directory / match.group(1)
            if (child / "CMakeLists.txt").is_file():
                pending.append(child)

    return targets


def verify_manifest() -> None:
    canonical = canonical_targets()
    manifest = {case.target: case for case in CASES}
    if len(manifest) != len(CASES):
        raise AssertionError("manifest contains duplicate target names")

    missing = sorted(canonical.keys() - manifest.keys())
    extra = sorted(manifest.keys() - canonical.keys())
    if missing or extra:
        raise AssertionError(f"manifest/CMake mismatch; missing={missing}, extra={extra}")
    if len(canonical) != 43:
        raise AssertionError(f"canonical CMake defines {len(canonical)} targets, expected 43")

    counts = collections.Counter(case.category for case in CASES)
    if dict(counts) != EXPECTED_CATEGORY_COUNTS:
        raise AssertionError(
            f"manifest category counts are {dict(counts)}, expected {EXPECTED_CATEGORY_COUNTS}"
        )

    constraints = {
        case.target: case.hosts for case in CASES if case.hosts != SUPPORTED_HOSTS
    }
    if constraints != EXPECTED_HOST_CONSTRAINTS:
        raise AssertionError(
            f"manifest host constraints are {constraints}, "
            f"expected {EXPECTED_HOST_CONSTRAINTS}"
        )

    for target, cmake in canonical.items():
        relative = cmake.relative_to(UPSTREAM_EXAMPLES)
        canonical_source = relative.parent.as_posix()
        top = relative.parts[0]
        expected_category = "top"
        if top == "Kaleidoscope":
            expected_category = "kaleidoscope"
        elif top == "OrcV2Examples":
            expected_category = "orc"
        elif target in {"ExceptionDemo", "ParallelJIT"}:
            expected_category = "conditional"
        if manifest[target].category != expected_category:
            raise AssertionError(
                f"{target}: category {manifest[target].category!r}, "
                f"canonical source requires {expected_category!r}"
            )
        if manifest[target].source != canonical_source:
            raise AssertionError(
                f"{target}: source {manifest[target].source!r}, "
                f"canonical CMake directory is {canonical_source!r}"
            )

    for case in CASES:
        if not case.hosts or any(host not in SUPPORTED_HOSTS for host in case.hosts):
            raise AssertionError(f"{case.target}: invalid host constraint {case.hosts}")
        source = HERE / case.source
        if not source.is_dir():
            raise AssertionError(f"{case.target}: source package missing: {source}")
        odin_files = sorted(source.glob("*.odin"))
        if not odin_files:
            raise AssertionError(f"{case.target}: no Odin source in {source}")
        imports_llvm = any(
            re.search(r"^\s*import\s+llvm\s+", path.read_text(encoding="utf-8"), re.MULTILINE)
            for path in odin_files
        )
        if imports_llvm != case.llvm_link:
            raise AssertionError(
                f"{case.target}: llvm_link={case.llvm_link}, imports LLVM={imports_llvm}"
            )
        if case.build == "script" and not (source / "build.sh").is_file():
            raise AssertionError(f"{case.target}: build.sh missing")


def source_inventory() -> dict[str, tuple[object, ...]]:
    inventory: dict[str, tuple[object, ...]] = {}
    for path in sorted(HERE.rglob("*")):
        relative = path.relative_to(HERE).as_posix()
        info = path.lstat()
        mode = stat.S_IMODE(info.st_mode)
        if path.is_symlink():
            inventory[relative] = ("symlink", mode, os.readlink(path))
        elif path.is_dir():
            inventory[relative] = ("directory", mode)
        elif path.is_file():
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            inventory[relative] = ("file", mode, info.st_size, digest)
        else:
            inventory[relative] = ("other", mode, info.st_size)
    return inventory


def inventory_changes(
    before: dict[str, tuple[object, ...]], after: dict[str, tuple[object, ...]]
) -> list[str]:
    changes = [f"added {path}" for path in sorted(after.keys() - before.keys())]
    changes.extend(f"removed {path}" for path in sorted(before.keys() - after.keys()))
    changes.extend(
        f"changed {path}"
        for path in sorted(before.keys() & after.keys())
        if before[path] != after[path]
    )
    return changes


def generated_artifacts() -> list[str]:
    artifacts: list[str] = []
    for path in sorted(HERE.rglob("*")):
        relative = path.relative_to(HERE).as_posix()
        if path.is_dir():
            if path.name in ARTIFACT_DIRECTORY_NAMES or path.name.endswith(".dSYM"):
                artifacts.append(relative)
            continue
        if not path.is_file():
            continue
        if (
            path.name in ARTIFACT_FILE_NAMES
            or path.suffix.lower() in ARTIFACT_SUFFIXES
            or path.name.lower().endswith(".cache")
        ):
            artifacts.append(relative)
            continue
        with path.open("rb") as source:
            magic = source.read(8)
        if any(magic.startswith(candidate) for candidate in BINARY_MAGICS):
            artifacts.append(relative)
    return artifacts


def assert_no_generated_artifacts(when: str) -> None:
    artifacts = generated_artifacts()
    if artifacts:
        raise AssertionError(f"generated artifacts present {when}: {', '.join(artifacts)}")


def resolve_odin(value: str | None) -> Path:
    if not value:
        raise RuntimeError("Odin compiler not found; pass --odin or set ODIN")
    found = shutil.which(value)
    path = Path(found if found else value).expanduser().resolve()
    if not path.is_file():
        raise RuntimeError(f"Odin compiler not found: {value}")
    return path


def host_configuration() -> Host:
    system = platform.system()
    machine = platform.machine().lower()
    if machine in {"arm64", "aarch64"}:
        arch = "arm64"
    elif machine in {"x86_64", "amd64"}:
        arch = "x64"
    else:
        raise RuntimeError(f"unsupported host architecture: {machine}")

    if system == "Darwin":
        library_dir = LLVM_ROOT / f"darwin_{arch}"
        return Host(
            system,
            arch,
            library_dir,
            "libLLVM.dylib",
            "libLTO.dylib",
            ("libLLVM.dylib", "libLTO.dylib"),
            ("*.dylib",),
            12,
            "",
        )
    elif system == "Linux":
        library_dir = LLVM_ROOT / f"linux_{arch}"
        return Host(
            system,
            arch,
            library_dir,
            "libLLVM.so",
            "libLTO.so",
            ("libLLVM.so", "libLTO.so"),
            ("*.so", "*.so.*"),
            8,
            "",
        )
    elif system == "Windows":
        if arch != "x64":
            raise RuntimeError("bundled LLVM shared libraries support Windows x64 only")
        library_dir = LLVM_ROOT / "windows_x64"
        return Host(
            system,
            arch,
            library_dir,
            "LLVM-C.dll",
            "LTO.dll",
            ("LLVM-C.dll", "LTO.dll"),
            ("*.dll",),
            5,
            ".exe",
        )
    raise RuntimeError(f"unsupported host OS: {system}")


def clean_loader_environment(source: dict[str, str]) -> dict[str, str]:
    environment = dict(source)
    for name in tuple(environment):
        normalized = name.upper()
        if (
            normalized in LOADER_ENVIRONMENT_VARIABLES
            or normalized.startswith("DYLD_")
            or normalized.startswith("LD_")
        ):
            environment.pop(name)
    return environment


def git_output(*arguments: str) -> str:
    environment = dict(os.environ)
    for name in (
        "GIT_ALTERNATE_OBJECT_DIRECTORIES",
        "GIT_COMMON_DIR",
        "GIT_DIR",
        "GIT_INDEX_FILE",
        "GIT_OBJECT_DIRECTORY",
        "GIT_WORK_TREE",
    ):
        environment.pop(name, None)
    environment["GIT_OPTIONAL_LOCKS"] = "0"
    result = subprocess.run(
        ["git", "-C", str(LLVM_ROOT / "llvm-project"), *arguments],
        cwd=LLVM_ROOT,
        env=environment,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )
    if result.returncode != 0:
        detail = decode(result.stderr).strip() or decode(result.stdout).strip()
        raise RuntimeError(f"could not inspect LLVM source with git: {detail}")
    return decode(result.stdout).strip()


def verify_llvm_source() -> str:
    source = LLVM_ROOT / "llvm-project"
    if not source.is_dir() or not (source / ".git").exists():
        raise RuntimeError(f"LLVM source is not a git checkout: {source}")

    top_level = Path(git_output("rev-parse", "--show-toplevel")).resolve()
    if top_level != source.resolve():
        raise RuntimeError(f"LLVM source resolves to wrong git worktree: {top_level}")

    tag_commit = git_output(
        "rev-parse", "--verify", f"refs/tags/{LLVM_TAG}^{{commit}}"
    )
    if tag_commit != LLVM_COMMIT:
        raise RuntimeError(
            f"LLVM tag {LLVM_TAG} resolves to {tag_commit}, expected {LLVM_COMMIT}"
        )
    head = git_output("rev-parse", "--verify", "HEAD")
    if head != LLVM_COMMIT:
        raise RuntimeError(
            f"LLVM source HEAD is {head}, expected {LLVM_TAG} ({LLVM_COMMIT})"
        )
    dirty = git_output("status", "--porcelain=v1", "--untracked-files=all")
    if dirty:
        raise RuntimeError(f"LLVM source is dirty:\n{dirty}")
    return head


def stage_shared_libraries(host: Host, destination: Path) -> Path:
    if not host.library_dir.is_dir():
        raise RuntimeError(f"bundled LLVM library directory not found: {host.library_dir}")

    sources: dict[str, Path] = {}
    for pattern in host.shared_library_patterns:
        for source in sorted(host.library_dir.glob(pattern)):
            if source.name in sources:
                continue
            if source.is_symlink() and not source.exists():
                raise RuntimeError(f"bundled LLVM library is a dangling symlink: {source}")
            if not source.is_file():
                continue
            sources[source.name] = source

    missing = [name for name in host.required_library_names if name not in sources]
    if missing:
        raise RuntimeError(
            f"bundled LLVM shared libraries missing from {host.library_dir}: "
            f"{', '.join(missing)}"
        )

    for name, source in sources.items():
        target = destination / name
        if source.is_symlink():
            target.symlink_to(os.readlink(source))
        else:
            shutil.copy2(source, target)

    staged = destination / host.llvm_library_name
    if not staged.is_file():
        raise RuntimeError(f"staged LLVM shared library not found: {staged}")
    return staged


def close_windows_library(library: ctypes.CDLL, name: str) -> None:
    if os.name != "nt" or not library._handle:
        return
    free_library = ctypes.windll.kernel32.FreeLibrary
    free_library.argtypes = [ctypes.c_void_p]
    free_library.restype = ctypes.c_int
    handle = library._handle
    if not free_library(ctypes.c_void_p(handle)):
        raise RuntimeError(f"could not unload staged {name}")
    library._handle = 0


class LTOAPI:
    def __init__(self, library: Path) -> None:
        try:
            self.library = ctypes.CDLL(str(library))
        except OSError as error:
            raise RuntimeError(f"could not load staged LTO library {library}: {error}") from error
        try:
            self.get_version = self.library.lto_get_version
        except AttributeError as error:
            close_windows_library(self.library, "LTO.dll")
            raise RuntimeError(
                "staged LTO library does not export lto_get_version"
            ) from error
        self.get_version.argtypes = []
        self.get_version.restype = ctypes.c_char_p

    def version(self) -> str:
        value = self.get_version()
        if not value:
            raise RuntimeError("staged LTO library returned no version")
        return decode(value)

    def close(self) -> None:
        close_windows_library(self.library, "LTO.dll")


class LLVMAPI:
    def __init__(self, library: Path) -> None:
        try:
            self.library = ctypes.CDLL(str(library))
        except OSError as error:
            raise RuntimeError(f"could not load staged LLVM library {library}: {error}") from error

        pointer = ctypes.c_void_p
        pointer_pointer = ctypes.POINTER(pointer)
        self.get_version = self._bind(
            "LLVMGetVersion",
            None,
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
            ctypes.POINTER(ctypes.c_uint),
        )
        self.context_create = self._bind("LLVMContextCreate", pointer)
        self.context_dispose = self._bind("LLVMContextDispose", None, pointer)
        self.create_memory_buffer = self._bind(
            "LLVMCreateMemoryBufferWithMemoryRangeCopy",
            pointer,
            pointer,
            ctypes.c_size_t,
            ctypes.c_char_p,
        )
        self.dispose_memory_buffer = self._bind(
            "LLVMDisposeMemoryBuffer", None, pointer
        )
        self.parse_bitcode = self._bind(
            "LLVMParseBitcodeInContext2", ctypes.c_int, pointer, pointer, pointer_pointer
        )
        self.dispose_module = self._bind("LLVMDisposeModule", None, pointer)
        self.dispose_message = self._bind("LLVMDisposeMessage", None, pointer)
        self.verify_module = self._bind(
            "LLVMVerifyModule", ctypes.c_int, pointer, ctypes.c_int, pointer_pointer
        )
        self.get_module_identifier = self._bind(
            "LLVMGetModuleIdentifier", pointer, pointer, ctypes.POINTER(ctypes.c_size_t)
        )
        self.get_source_file_name = self._bind(
            "LLVMGetSourceFileName", pointer, pointer, ctypes.POINTER(ctypes.c_size_t)
        )
        self.get_first_function = self._bind("LLVMGetFirstFunction", pointer, pointer)
        self.get_next_function = self._bind("LLVMGetNextFunction", pointer, pointer)
        self.get_named_function = self._bind(
            "LLVMGetNamedFunction", pointer, pointer, ctypes.c_char_p
        )
        self.get_value_name = self._bind(
            "LLVMGetValueName2", pointer, pointer, ctypes.POINTER(ctypes.c_size_t)
        )
        self.is_declaration = self._bind("LLVMIsDeclaration", ctypes.c_int, pointer)
        self.global_value_type = self._bind("LLVMGlobalGetValueType", pointer, pointer)
        self.get_type_kind = self._bind("LLVMGetTypeKind", ctypes.c_int, pointer)
        self.count_params = self._bind("LLVMCountParams", ctypes.c_uint, pointer)
        self.get_return_type = self._bind("LLVMGetReturnType", pointer, pointer)
        self.get_int_type_width = self._bind(
            "LLVMGetIntTypeWidth", ctypes.c_uint, pointer
        )
        self.count_basic_blocks = self._bind(
            "LLVMCountBasicBlocks", ctypes.c_uint, pointer
        )
        self.get_first_basic_block = self._bind(
            "LLVMGetFirstBasicBlock", pointer, pointer
        )
        self.get_next_basic_block = self._bind(
            "LLVMGetNextBasicBlock", pointer, pointer
        )
        self.get_basic_block_name = self._bind(
            "LLVMGetBasicBlockName", ctypes.c_char_p, pointer
        )
        self.get_first_instruction = self._bind(
            "LLVMGetFirstInstruction", pointer, pointer
        )
        self.get_next_instruction = self._bind(
            "LLVMGetNextInstruction", pointer, pointer
        )
        self.get_instruction_opcode = self._bind(
            "LLVMGetInstructionOpcode", ctypes.c_int, pointer
        )
        self.get_num_operands = self._bind("LLVMGetNumOperands", ctypes.c_int, pointer)
        self.get_operand = self._bind(
            "LLVMGetOperand", pointer, pointer, ctypes.c_uint
        )
        self.is_constant_int = self._bind("LLVMIsAConstantInt", pointer, pointer)
        self.type_of = self._bind("LLVMTypeOf", pointer, pointer)
        self.const_int_value = self._bind(
            "LLVMConstIntGetZExtValue", ctypes.c_ulonglong, pointer
        )
        self.create_binary = self._bind(
            "LLVMCreateBinary", pointer, pointer, pointer, pointer_pointer
        )
        self.dispose_binary = self._bind("LLVMDisposeBinary", None, pointer)
        self.binary_type = self._bind("LLVMBinaryGetType", ctypes.c_int, pointer)
        self.copy_symbol_iterator = self._bind(
            "LLVMObjectFileCopySymbolIterator", pointer, pointer
        )
        self.symbol_iterator_at_end = self._bind(
            "LLVMObjectFileIsSymbolIteratorAtEnd", ctypes.c_int, pointer, pointer
        )
        self.move_to_next_symbol = self._bind(
            "LLVMMoveToNextSymbol", None, pointer
        )
        self.get_symbol_name = self._bind(
            "LLVMGetSymbolName", ctypes.c_char_p, pointer
        )
        self.dispose_symbol_iterator = self._bind(
            "LLVMDisposeSymbolIterator", None, pointer
        )

    def _bind(
        self, name: str, result: object, *arguments: object
    ) -> ctypes._CFuncPtr:
        try:
            function = getattr(self.library, name)
        except AttributeError as error:
            raise RuntimeError(f"staged LLVM library does not export {name}") from error
        function.restype = result
        function.argtypes = list(arguments)
        return function

    def version(self) -> tuple[int, int, int]:
        major = ctypes.c_uint()
        minor = ctypes.c_uint()
        patch = ctypes.c_uint()
        self.get_version(ctypes.byref(major), ctypes.byref(minor), ctypes.byref(patch))
        return major.value, minor.value, patch.value

    def close(self) -> None:
        close_windows_library(self.library, "LLVM-C.dll")

    def _value_name(self, value: int) -> str:
        length = ctypes.c_size_t()
        address = self.get_value_name(value, ctypes.byref(length))
        return decode(ctypes.string_at(address, length.value)) if address else ""

    def _message(self, message: ctypes.c_void_p) -> str:
        if not message.value:
            return "unknown LLVM error"
        try:
            return decode(ctypes.string_at(message.value))
        finally:
            self.dispose_message(message)

    def validate_module_maker(self, bitcode: bytes, label: str) -> None:
        storage = ctypes.create_string_buffer(bitcode)
        buffer = self.create_memory_buffer(
            ctypes.cast(storage, ctypes.c_void_p), len(bitcode), b"ModuleMaker.bc"
        )
        if not buffer:
            raise AssertionError(f"{label}: could not allocate LLVM memory buffer")

        context = self.context_create()
        module = ctypes.c_void_p()
        try:
            if self.parse_bitcode(context, buffer, ctypes.byref(module)) != 0:
                raise AssertionError(f"{label}: stdout is not valid LLVM bitcode")

            verifier_message = ctypes.c_void_p()
            invalid = self.verify_module(module, 2, ctypes.byref(verifier_message))
            if invalid:
                raise AssertionError(
                    f"{label}: invalid LLVM module: {self._message(verifier_message)}"
                )
            if verifier_message.value:
                self.dispose_message(verifier_message)

            identifier_length = ctypes.c_size_t()
            identifier_address = self.get_module_identifier(
                module, ctypes.byref(identifier_length)
            )
            identifier = decode(
                ctypes.string_at(identifier_address, identifier_length.value)
            )
            if identifier != "ModuleMaker.bc":
                raise AssertionError(
                    f"{label}: parsed module identifier is {identifier!r}, "
                    "expected memory-buffer identifier 'ModuleMaker.bc'"
                )

            source_length = ctypes.c_size_t()
            source_address = self.get_source_file_name(
                module, ctypes.byref(source_length)
            )
            source_name = decode(ctypes.string_at(source_address, source_length.value))
            if source_name != "test":
                raise AssertionError(
                    f"{label}: encoded source filename is {source_name!r}, expected 'test'"
                )

            function = self.get_first_function(module)
            if not function or self.get_next_function(function):
                raise AssertionError(f"{label}: expected exactly one function")
            if function != self.get_named_function(module, b"main"):
                raise AssertionError(f"{label}: sole function is not main")
            if self._value_name(function) != "main" or self.is_declaration(function):
                raise AssertionError(f"{label}: main must be a definition")

            function_type = self.global_value_type(function)
            return_type = self.get_return_type(function_type)
            if (
                self.get_type_kind(function_type) != 9
                or self.count_params(function) != 0
                or self.get_type_kind(return_type) != 8
                or self.get_int_type_width(return_type) != 32
            ):
                raise AssertionError(f"{label}: expected signature i32 @main()")

            if self.count_basic_blocks(function) != 1:
                raise AssertionError(f"{label}: main must contain one basic block")
            block = self.get_first_basic_block(function)
            if self.get_next_basic_block(block):
                raise AssertionError(f"{label}: main contains extra basic blocks")
            block_name = self.get_basic_block_name(block)
            if not block_name or decode(block_name) != "EntryBlock":
                raise AssertionError(f"{label}: main entry block has wrong name")

            instructions: list[int] = []
            instruction = self.get_first_instruction(block)
            while instruction:
                instructions.append(instruction)
                instruction = self.get_next_instruction(instruction)
            if len(instructions) != 2:
                raise AssertionError(
                    f"{label}: main has {len(instructions)} instructions, expected add and ret"
                )

            add, ret = instructions
            if self.get_instruction_opcode(add) != 8 or self._value_name(add) != "addresult":
                raise AssertionError(f"{label}: first instruction is not named integer add")
            if self.get_num_operands(add) != 2:
                raise AssertionError(f"{label}: add must have two operands")
            values = []
            for index in range(2):
                operand = self.get_operand(add, index)
                operand_type = self.type_of(operand)
                if (
                    not self.is_constant_int(operand)
                    or self.get_type_kind(operand_type) != 8
                    or self.get_int_type_width(operand_type) != 32
                ):
                    raise AssertionError(f"{label}: add operand {index} is not i32 constant")
                values.append(self.const_int_value(operand))
            if values != [2, 3]:
                raise AssertionError(f"{label}: add operands are {values}, expected [2, 3]")

            if (
                self.get_instruction_opcode(ret) != 1
                or self.get_num_operands(ret) != 1
                or self.get_operand(ret, 0) != add
            ):
                raise AssertionError(f"{label}: return does not return addresult")
        finally:
            if module.value:
                self.dispose_module(module)
            self.context_dispose(context)
            self.dispose_memory_buffer(buffer)

    def inspect_object(self, path: Path, expected_type: int, label: str) -> set[str]:
        data = path.read_bytes()
        storage = ctypes.create_string_buffer(data)
        buffer = self.create_memory_buffer(
            ctypes.cast(storage, ctypes.c_void_p), len(data), path.name.encode("utf-8")
        )
        if not buffer:
            raise AssertionError(f"{label}: could not allocate object memory buffer")

        error_message = ctypes.c_void_p()
        binary = self.create_binary(buffer, None, ctypes.byref(error_message))
        if not binary:
            try:
                detail = self._message(error_message)
            finally:
                self.dispose_memory_buffer(buffer)
            raise AssertionError(f"{label}: invalid object file {path.name}: {detail}")
        if error_message.value:
            self.dispose_message(error_message)

        iterator = None
        try:
            actual_type = self.binary_type(binary)
            if actual_type != expected_type:
                raise AssertionError(
                    f"{label}: {path.name} LLVM binary type is {actual_type}, "
                    f"expected host object type {expected_type}"
                )

            symbols: set[str] = set()
            iterator = self.copy_symbol_iterator(binary)
            while iterator and not self.symbol_iterator_at_end(binary, iterator):
                name = self.get_symbol_name(iterator)
                if name:
                    symbols.add(decode(name))
                self.move_to_next_symbol(iterator)
            return symbols
        finally:
            if iterator:
                self.dispose_symbol_iterator(iterator)
            self.dispose_binary(binary)
            self.dispose_memory_buffer(buffer)

    def validate_objects(
        self,
        paths: list[Path],
        expected_type: int,
        expected_symbols: tuple[str, ...],
        label: str,
    ) -> None:
        symbols: set[str] = set()
        for path in paths:
            symbols.update(self.inspect_object(path, expected_type, label))
        normalized = symbols | {name[1:] for name in symbols if name.startswith("_")}
        missing = [name for name in expected_symbols if name not in normalized]
        if missing:
            rendered = ", ".join(sorted(symbols))
            raise AssertionError(
                f"{label}: dumped object missing symbol(s) {missing}; symbols=[{rendered}]"
            )


def check_diagnostics(text: str, allowed: tuple[str, ...], label: str) -> None:
    allowed_lower = tuple(item.lower() for item in allowed)
    unexpected = []
    for line in text.splitlines():
        if not DIAGNOSTIC_RE.search(line):
            continue
        lowered = line.lower()
        if any(item in lowered for item in allowed_lower):
            continue
        unexpected.append(line)
    if unexpected:
        rendered = "\n".join(unexpected)
        raise AssertionError(f"{label}: unexpected fatal/error diagnostic:\n{rendered}")


def execute(
    command: list[str],
    *,
    cwd: Path,
    environment: dict[str, str],
    stdin: bytes = b"",
    expected_status: int = 0,
    allowed_diagnostics: tuple[str, ...] = (),
    binary_stdout: bool = False,
    timeout: int = 240,
    label: str,
) -> subprocess.CompletedProcess[bytes]:
    try:
        completed = subprocess.run(
            command,
            cwd=cwd,
            env=environment,
            input=stdin,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE if binary_stdout else subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise RuntimeError(
            f"{label}: timed out after {timeout}s: {shlex.join(command)}"
        ) from error

    result = subprocess.CompletedProcess(
        completed.args,
        completed.returncode,
        completed.stdout,
        completed.stderr or b"",
    )

    if result.returncode != expected_status:
        raise RuntimeError(
            f"{label}: status {result.returncode}, expected {expected_status}: "
            f"{shlex.join(command)}\n{display_output(result.stdout, result.stderr)}"
        )
    if result.returncode == 0:
        diagnostic_text = decode(result.stderr)
        if not binary_stdout:
            diagnostic_text = decode(result.stdout) + diagnostic_text
        check_diagnostics(diagnostic_text, allowed_diagnostics, label)
    return result


def inspection_output(command: list[str], binary: Path, label: str) -> str:
    environment = clean_loader_environment(os.environ)
    environment["LC_ALL"] = "C"
    try:
        result = subprocess.run(
            command,
            cwd=binary.parent,
            env=environment,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=30,
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise RuntimeError(f"{label}: metadata inspection failed: {error}") from error
    if result.returncode != 0:
        raise RuntimeError(
            f"{label}: metadata inspector failed: {shlex.join(command)}\n"
            f"{decode(result.stdout)}"
        )
    return decode(result.stdout)


def validate_darwin_loader_metadata(case: Case, binary: Path) -> None:
    dependencies_text = inspection_output(
        ["/usr/bin/otool", "-L", str(binary)], binary, case.target
    )
    dependencies = [
        line.strip().split(" (compatibility version", 1)[0]
        for line in dependencies_text.splitlines()[1:]
        if line[:1].isspace()
    ]
    llvm_dependencies = [item for item in dependencies if "libLLVM.dylib" in item]
    if llvm_dependencies != ["@rpath/libLLVM.dylib"]:
        raise AssertionError(
            f"{case.target}: LLVM dependency is {llvm_dependencies}, "
            "expected ['@rpath/libLLVM.dylib']"
        )
    bad_lto = [
        item
        for item in dependencies
        if "libLTO.dylib" in item and item != "@rpath/libLTO.dylib"
    ]
    if bad_lto:
        raise AssertionError(f"{case.target}: non-relative LTO dependency: {bad_lto}")

    commands_text = inspection_output(
        ["/usr/bin/otool", "-l", str(binary)], binary, case.target
    )
    runpaths = re.findall(r"^\s*path (.+?) \(offset \d+\)$", commands_text, re.MULTILINE)
    if "@loader_path" not in runpaths:
        raise AssertionError(
            f"{case.target}: missing @loader_path LC_RPATH; found {runpaths}"
        )
    if case.target == "ExceptionDemo":
        invalid = [
            path
            for path in runpaths
            if path != "@loader_path" and not path.startswith("@loader_path/")
        ]
    else:
        invalid = [path for path in runpaths if path != "@loader_path"]
    if invalid:
        raise AssertionError(f"{case.target}: non-loader-relative LC_RPATH: {invalid}")


def validate_linux_loader_metadata(case: Case, binary: Path) -> None:
    readelf = shutil.which("readelf")
    if not readelf:
        raise RuntimeError(f"{case.target}: readelf is required to inspect ELF metadata")
    dynamic = inspection_output(
        [readelf, "--dynamic", "--wide", str(binary)], binary, case.target
    )
    dependencies = re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic)
    llvm_dependencies = [
        item for item in dependencies if re.search(r"(?:^|/)libLLVM\.so(?:\.|$)", item)
    ]
    if llvm_dependencies != ["libLLVM.so.22.1"]:
        raise AssertionError(
            f"{case.target}: LLVM dependency is {llvm_dependencies}, "
            "expected ['libLLVM.so.22.1']"
        )
    bad_lto = [
        item
        for item in dependencies
        if re.search(r"(?:^|/)libLTO\.so(?:\.|$)", item)
        and item != "libLTO.so.22.1"
    ]
    if bad_lto:
        raise AssertionError(f"{case.target}: invalid LTO SONAME dependency: {bad_lto}")

    encoded_paths = re.findall(r"\((?:RPATH|RUNPATH)\).*?\[([^]]*)\]", dynamic)
    runpaths = [path for value in encoded_paths for path in value.split(":") if path]
    if "$ORIGIN" not in runpaths:
        raise AssertionError(f"{case.target}: missing $ORIGIN runpath; found {runpaths}")
    if case.target == "ExceptionDemo":
        invalid = [
            path
            for path in runpaths
            if path != "$ORIGIN" and not path.startswith("$ORIGIN/")
        ]
    else:
        invalid = [path for path in runpaths if path != "$ORIGIN"]
    if invalid:
        raise AssertionError(f"{case.target}: non-$ORIGIN ELF runpath: {invalid}")


def validate_windows_loader_metadata(case: Case, binary: Path) -> None:
    dumpbin = shutil.which("dumpbin")
    llvm_readobj = shutil.which("llvm-readobj")
    if dumpbin:
        text = inspection_output(
            [dumpbin, "/nologo", "/dependents", str(binary)], binary, case.target
        )
        imports = re.findall(r"^\s+([^\s]+\.dll)\s*$", text, re.MULTILINE | re.IGNORECASE)
    elif llvm_readobj:
        text = inspection_output(
            [llvm_readobj, "--coff-imports", str(binary)], binary, case.target
        )
        imports = re.findall(
            r"^\s*Name:\s*([^\s]+\.dll)\s*$", text, re.MULTILINE | re.IGNORECASE
        )
    else:
        raise RuntimeError(
            f"{case.target}: dumpbin or llvm-readobj is required to inspect PE imports"
        )

    llvm_imports = [item for item in imports if "llvm-c.dll" in item.lower()]
    if not llvm_imports or any(item.lower() != "llvm-c.dll" for item in llvm_imports):
        raise AssertionError(
            f"{case.target}: LLVM-C import is {llvm_imports}, expected LLVM-C.dll"
        )
    bad_lto = [
        item for item in imports if "lto.dll" in item.lower() and item.lower() != "lto.dll"
    ]
    if bad_lto:
        raise AssertionError(f"{case.target}: non-sibling LTO import: {bad_lto}")


def validate_binary_loader_metadata(case: Case, binary: Path, host: Host) -> None:
    if not case.llvm_link:
        return
    if host.system == "Darwin":
        validate_darwin_loader_metadata(case, binary)
    elif host.system == "Linux":
        validate_linux_loader_metadata(case, binary)
    elif host.system == "Windows":
        validate_windows_loader_metadata(case, binary)


def create_fixtures(root: Path) -> Path:
    fixtures = root / "fixtures"
    fixtures.mkdir()
    (fixtures / "brainf.bf").write_text(
        "++++++++[>++++++++<-]>+.\n",
        encoding="ascii",
    )
    (fixtures / "passes.ll").write_text(
        """define i32 @live() {
entry:
  br i1 true, label %yes, label %no

yes:
  ret i32 7

no:
  ret i32 9
}
""",
        encoding="ascii",
    )
    (fixtures / "main.ll").write_text(
        """define i32 @main(i32 %argc, ptr %argv) {
entry:
  %ok = icmp eq i32 %argc, 1
  %status = select i1 %ok, i32 0, i32 9
  ret i32 %status
}
""",
        encoding="ascii",
    )
    return fixtures


def expanded_args(case: Case, fixtures: Path, run_dir: Path) -> list[str]:
    values = {
        "examples": str(HERE),
        "fixtures": str(fixtures),
        "run": str(run_dir),
    }
    return [argument.format_map(values) for argument in case.args]


def assert_specialized_output(case: Case, output: str, host: Host) -> None:
    if case.target == "LLJITWithOptimizingIRTransform":
        before_marker = "--- BEFORE OPTIMIZATION ---"
        after_marker = "--- AFTER OPTIMIZATION ---"
        result_marker = "--- Result ---"
        before = output[output.index(before_marker) : output.index(after_marker)]
        after = output[output.index(after_marker) : output.index(result_marker)]
        if "call i32 @fac(i32 %arg)" not in before:
            raise AssertionError(f"{case.target}: pre-optimization IR lost recursive call")
        if "call i32 @fac(i32 %arg)" in after:
            raise AssertionError(f"{case.target}: optimized fac is still recursive")
        if "tailrecurse:" not in after or "%accumulator.tr = phi i32" not in after:
            raise AssertionError(
                f"{case.target}: optimized fac lacks tail-recursion accumulator loop"
            )

    if case.target == "LLJITWithLazyReexports":
        if output.count("---Compiling---") != 2:
            raise AssertionError(
                f"{case.target}: expected exactly main and selected lazy body to compile"
            )
        if "define i32 @entry" not in output or "define i32 @foo_body" not in output:
            raise AssertionError(f"{case.target}: expected main and foo_body compilation")
        if "define i32 @bar_body" in output:
            raise AssertionError(f"{case.target}: uncalled bar_body was eagerly compiled")

    if case.target == "LLJITWithGDBRegistrationListener":
        warning = "Warning: This demo may not work for platforms other than Linux.\n"
        expected = (
            ("" if host.system == "Linux" else warning)
            + "Custom RTDyld layer registered GDB JIT event listener\n"
            + "process-all-sections unavailable through LLVM-C; emitted sections only\n"
        )
        if output != expected:
            raise AssertionError(
                f"{case.target}: unexpected platform-specific debug output:\n{output}"
            )


def assert_run_contract(
    case: Case,
    result: subprocess.CompletedProcess[bytes],
    run_dir: Path,
    llvm: LLVMAPI,
    host: Host,
) -> None:
    if case.binary_prefix is not None:
        if not result.stdout.startswith(case.binary_prefix):
            actual = result.stdout[: len(case.binary_prefix)].hex()
            raise AssertionError(
                f"{case.target}: binary stdout prefix {actual!r}, "
                f"expected {case.binary_prefix.hex()!r}"
            )
        if len(result.stdout) <= len(case.binary_prefix):
            raise AssertionError(f"{case.target}: binary stdout is truncated")
        llvm.validate_module_maker(result.stdout, case.target)
        output = decode(result.stderr)
    else:
        output = decode(result.stdout) + decode(result.stderr)
    output = output.replace("\r\n", "\n").replace("\r", "\n")

    if case.exact is not None and output != case.exact:
        raise AssertionError(
            f"{case.target}: output did not exactly match expected text\n{output}"
        )

    cursor = 0
    for position, fragment in enumerate(case.expected, start=1):
        found = output.find(fragment, cursor)
        if found < 0:
            raise AssertionError(
                f"{case.target}: expected fragment {position} {fragment!r} "
                f"after offset {cursor}\n{output}"
            )
        cursor = found + len(fragment)
    for fragment in case.absent:
        if fragment in output:
            raise AssertionError(
                f"{case.target}: forbidden output {fragment!r} was present\n{output}"
            )
    expected_files: list[Path] = []
    for pattern in case.expected_files:
        matches = sorted(path for path in run_dir.glob(pattern) if path.is_file())
        if not matches:
            raise AssertionError(f"{case.target}: expected file matching {pattern!r}")
        empty = [path.name for path in matches if path.stat().st_size == 0]
        if empty:
            raise AssertionError(f"{case.target}: empty output file(s): {', '.join(empty)}")
        expected_files.extend(path for path in matches if path not in expected_files)
    if case.object_symbols:
        llvm.validate_objects(
            expected_files,
            host.object_binary_type,
            case.object_symbols,
            case.target,
        )
    assert_specialized_output(case, output, host)


def build_and_run(
    odin: Path, host: Host, temporary_root: Path, revision: str
) -> tuple[int, int]:
    binaries = temporary_root / "bin"
    build_cwd = temporary_root / "build"
    runs = temporary_root / "runs"
    scratch = temporary_root / "tmp"
    tool_bin = temporary_root / "tools"
    for directory in (binaries, build_cwd, runs, scratch, tool_bin):
        directory.mkdir()
    fixtures = create_fixtures(temporary_root)
    staged_library = stage_shared_libraries(host, binaries)
    llvm = LLVMAPI(staged_library)
    staged_lto = binaries / host.lto_library_name
    try:
        lto = LTOAPI(staged_lto)
    except RuntimeError:
        llvm.close()
        raise

    version = llvm.version()
    if version != LLVM_VERSION:
        rendered = ".".join(str(component) for component in version)
        expected = ".".join(str(component) for component in LLVM_VERSION)
        lto.close()
        llvm.close()
        raise RuntimeError(
            f"staged {host.llvm_library_name} reports LLVM {rendered}, expected {expected}"
        )
    try:
        lto_version = lto.version()
    except RuntimeError:
        lto.close()
        llvm.close()
        raise
    if lto_version != "LLVM version 22.1.8":
        lto.close()
        llvm.close()
        raise RuntimeError(
            f"staged {host.lto_library_name} reports {lto_version!r}, "
            "expected 'LLVM version 22.1.8'"
        )
    print(
        "manifest: 43 targets "
        "(12 Kaleidoscope, 9 top-level, 20 ORC, 2 conditional); "
        f"LLVM {version[0]}.{version[1]}.{version[2]} "
        f"and LTO 22.1.8; {LLVM_TAG}@{revision}",
        flush=True,
    )

    odin_alias = tool_bin / ("odin.exe" if host.system == "Windows" else "odin")
    try:
        odin_alias.symlink_to(odin)
    except OSError:
        shutil.copy2(odin, odin_alias)
    environment = clean_loader_environment(os.environ)
    environment["PATH"] = str(tool_bin) + os.pathsep + environment.get("PATH", "")
    environment["TMPDIR"] = str(scratch)
    if host.system == "Windows":
        environment["TEMP"] = str(scratch)
        environment["TMP"] = str(scratch)
    leaked = [
        name
        for name in environment
        if name.upper() in LOADER_ENVIRONMENT_VARIABLES
        or name.upper().startswith("DYLD_")
        or name.upper().startswith("LD_")
    ]
    if leaked:
        lto.close()
        llvm.close()
        raise AssertionError(f"loader environment was not cleared: {leaked}")

    total = len(CASES)
    run_count = 0
    skipped_count = 0
    try:
        for index, case in enumerate(CASES, start=1):
            prefix = f"[{index:02d}/{total}]"
            if host.system not in case.hosts:
                skipped_count += 1
                print(
                    f"{prefix} skip  {case.target} "
                    f"(canonical CMake excludes {host.system})",
                    flush=True,
                )
                continue

            case_started = time.monotonic()
            source = HERE / case.source
            binary = binaries / f"{case.target}{host.executable_suffix}"
            build_binary = binary
            print(f"{prefix} build {case.target}", flush=True)

            if case.build == "script":
                build_binary = temporary_root / f"{case.target}{host.executable_suffix}"
                command = ["bash", str(source / "build.sh"), str(build_binary)]
                build_environment = environment
            else:
                command = [str(odin), "build", str(source), f"-out:{binary}"]
                if case.llvm_link:
                    command.append("-define:LLVM_LINK=shared")
                    if host.system == "Darwin":
                        command.append(
                            "-extra-linker-flags:-Wl,-rpath,@loader_path"
                        )
                    elif host.system == "Linux":
                        command.append("-extra-linker-flags:-Wl,-rpath,$ORIGIN")
                build_environment = environment
            execute(
                command,
                cwd=build_cwd,
                environment=build_environment,
                expected_status=0,
                timeout=case.timeout,
                label=f"{case.target} build",
            )
            if not build_binary.is_file() or build_binary.stat().st_size == 0:
                raise AssertionError(
                    f"{case.target}: build did not create executable {build_binary}"
                )
            if build_binary != binary:
                build_binary.replace(binary)
            validate_binary_loader_metadata(case, binary, host)

            run_dir = runs / f"{index:02d}-{case.target}"
            run_dir.mkdir()
            command = [str(binary), *expanded_args(case, fixtures, run_dir)]
            print(f"{prefix} run   {case.target}", flush=True)
            result = execute(
                command,
                cwd=run_dir,
                environment=environment,
                stdin=case.stdin.encode("utf-8"),
                expected_status=case.status,
                allowed_diagnostics=case.allowed_diagnostics,
                binary_stdout=case.binary_prefix is not None,
                timeout=case.timeout,
                label=f"{case.target} run",
            )
            assert_run_contract(case, result, run_dir, llvm, host)
            run_count += 1
            elapsed = time.monotonic() - case_started
            print(f"{prefix} ok    {case.target} ({elapsed:.2f}s)", flush=True)
    finally:
        lto.close()
        llvm.close()
    return run_count, skipped_count


def parse_arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build and run all 43 canonical LLVM Odin examples in temporary storage."
    )
    parser.add_argument(
        "--odin",
        default=os.environ.get("ODIN") or shutil.which("odin"),
        help="Odin compiler path (default: ODIN or PATH)",
    )
    return parser.parse_args()


def main() -> int:
    started = time.monotonic()
    run_count = 0
    skipped_count = 0
    try:
        assert_no_generated_artifacts("before run")
        before = source_inventory()
        try:
            revision = verify_llvm_source()
            verify_manifest()
            odin = resolve_odin(parse_arguments().odin)
            host = host_configuration()
            with tempfile.TemporaryDirectory(prefix="llvm-examples-") as temporary:
                temporary_root = Path(temporary).resolve()
                if HERE == temporary_root or HERE in temporary_root.parents:
                    raise AssertionError("temporary directory was created inside source tree")
                run_count, skipped_count = build_and_run(
                    odin, host, temporary_root, revision
                )
        finally:
            changes = inventory_changes(before, source_inventory())
            artifacts = generated_artifacts()
            problems = []
            try:
                verify_llvm_source()
            except RuntimeError as error:
                problems.append(str(error))
            if changes:
                problems.append("source inventory changed: " + ", ".join(changes))
            if artifacts:
                problems.append("generated artifacts present after run: " + ", ".join(artifacts))
            if problems:
                raise AssertionError("; ".join(problems))
    except (AssertionError, RuntimeError) as error:
        elapsed = time.monotonic() - started
        print(f"FAIL after {elapsed:.2f}s: {error}", file=sys.stderr)
        return 1

    elapsed = time.monotonic() - started
    if skipped_count:
        print(
            f"PASS: {run_count} run, {skipped_count} canonically skipped, "
            f"{len(CASES)} manifest targets in {elapsed:.2f}s",
            flush=True,
        )
    else:
        print(f"PASS: {run_count}/{len(CASES)} targets in {elapsed:.2f}s", flush=True)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
