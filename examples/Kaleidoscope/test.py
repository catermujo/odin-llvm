from __future__ import annotations

import argparse
import os
import platform
import re
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


HERE = Path(__file__).resolve().parent
LLVM_ROOT = HERE.parents[1]


@dataclass(frozen=True)
class Case:
    name: str
    source: str
    expected: tuple[str, ...]
    status: int = 0
    allowed_diagnostics: tuple[str, ...] = ()
    absent: tuple[str, ...] = ()
    timeout: int = 60
    object_output: bool = False
    object_result: float | None = None
    forbid_object: bool = False
    ir_output: bool = False
    debug_locations: tuple[tuple[str, int, int], ...] = ()
    debug_declarations: tuple[tuple[str, str, str, int, int, int], ...] = ()


@dataclass(frozen=True)
class Example:
    path: str
    source: str
    expected: tuple[str, ...]
    object_output: bool = False
    ir_output: bool = False
    debug_declarations: tuple[tuple[str, str, str, int, int, int], ...] = ()
    regressions: tuple[Case, ...] = ()


AJIT_REGRESSIONS = (
    Case(
        "scope-and-assignment",
        "var a = 10 in (var a = 1, a = 2 in a) + a;\n"
        "var a = 0, b = 0 in (a = b = 7) + a + b;\n",
        ("Evaluated to 12.000000", "Evaluated to 21.000000"),
    ),
    Case(
        "parser-recovery",
        "1+;\ndef semi(x) x;\n1+);\ndef paren(x) x;\nsemi(20)+paren(22);\n",
        (
            "Error: unknown token when expecting an expression",
            "Error: unknown token when expecting an expression",
            "Evaluated to 42.000000",
        ),
        allowed_diagnostics=("unknown token when expecting an expression",),
    ),
)

JIT_REGRESSIONS = (
    Case(
        "host-process-symbol",
        "extern printd(x);\nprintd(42);\n",
        ("42.000000", "Evaluated to 0.000000"),
    ),
    Case(
        "user-symbol-override",
        "extern printd(x);\ndef printd(x) x+1;\nprintd(41);\n",
        ("Evaluated to 42.000000",),
        absent=("41.000000",),
    ),
    Case(
        "orc-failure-stops-loop",
        "extern missing(x);\nmissing(1);\n42;\n",
        ("Symbols not found:",),
        status=1,
        allowed_diagnostics=("jit session error",),
        absent=("Evaluated to 42.000000",),
        timeout=10,
    ),
)


EXAMPLES = (
    Example(
        "Chapter2",
        "def add(x y) x+y;\nextern sin(x);\nadd(1,2);\n",
        (
            "Parsed a function definition.",
            "Parsed an extern",
            "Parsed a top-level expr",
        ),
    ),
    Example(
        "Chapter3",
        "def add(x y) x+y;\nadd(1,2);\n",
        ("define double @add", "fadd double"),
        regressions=(
            Case(
                "redefinition",
                "extern keep(x);\n"
                "def keep(x) missing;\n"
                "def stable(x) x+1;\n"
                "def stable(x) x+2;\n",
                (
                    "declare double @keep",
                    "Error: Unknown variable name",
                    "define double @stable",
                    "Error: Function cannot be redefined",
                    "declare double @keep",
                    "define double @stable",
                ),
                allowed_diagnostics=(
                    "unknown variable name",
                    "function cannot be redefined",
                ),
                absent=("define double @keep",),
            ),
        ),
    ),
    Example(
        "Chapter4",
        "extern twice(x);\nextern twice(x);\ndef twice(x) x*2;\ntwice(21);\n",
        ("Evaluated to 42.000000",),
        regressions=JIT_REGRESSIONS,
    ),
    Example(
        "Chapter5",
        "def fib(x) if x < 3 then 1 else fib(x-1)+fib(x-2);\nfib(10);\n",
        ("Evaluated to 55.000000",),
        regressions=JIT_REGRESSIONS
        + (
            Case(
                "control-flow-recovery",
                "def bad(x) if x then missing else x;\n"
                "def good(x) if x then x else 0;\n"
                "good(42);\n"
                "1+;\n"
                "def semi(x) x;\n"
                "1+);\n"
                "def paren(x) x;\n"
                "semi(20)+paren(22);\n",
                (
                    "Error: Unknown variable name",
                    "Evaluated to 42.000000",
                    "Error: unknown token when expecting an expression",
                    "Error: unknown token when expecting an expression",
                    "Evaluated to 42.000000",
                ),
                allowed_diagnostics=(
                    "unknown variable name",
                    "unknown token when expecting an expression",
                ),
            ),
            Case(
                "loop-shadowing",
                "def shadow(x) (for x = 1, x < 2 in x) + x;\nshadow(42);\n",
                ("Evaluated to 42.000000",),
            ),
        ),
    ),
    Example(
        "Chapter6",
        "def binary% 40 (x y) x*y;\n6%7;\n",
        ("Evaluated to 42.000000",),
        regressions=JIT_REGRESSIONS
        + (
            Case(
                "custom-operators-and-rollback",
                "def binary% 50 (x y) x-y;\n"
                "10%3*2;\n"
                "def unary!(x) if x then 0 else 1;\n"
                "!0+!1;\n"
                "def binary+ 90 (x y) missing;\n"
                "1+2*3;\n",
                (
                    "Evaluated to 14.000000",
                    "Evaluated to 1.000000",
                    "Error: Unknown variable name",
                    "Evaluated to 7.000000",
                ),
                allowed_diagnostics=("unknown variable name",),
            ),
            Case(
                "delimiter-recovery",
                "1+;\ndef semi(x) x;\n1+);\ndef paren(x) x;\n"
                "semi(20)+paren(22);\n",
                (
                    "Error: unknown token when expecting an expression",
                    "Error: unknown token when expecting an expression",
                    "Evaluated to 42.000000",
                ),
                allowed_diagnostics=("unknown token when expecting an expression",),
            ),
        ),
    ),
    Example(
        "Chapter7",
        "var a = 5 in (a = a + 1) * a;\n",
        ("Evaluated to 36.000000",),
        regressions=JIT_REGRESSIONS
        + (
            Case(
                "scope-and-assignment",
                "var a = 10 in (var a = 1, a = 2 in a) + a;\n"
                "var a = 0, b = 0 in (a = b = 7) + a + b;\n",
                ("Evaluated to 12.000000", "Evaluated to 21.000000"),
            ),
            Case(
                "argument-and-loop-mutation",
                "def bump(x) x = x + 1;\n"
                "bump(41);\n"
                "var result = 0 in "
                "(for i = 1, i < 4, 1 in result = i = i + 1) + result;\n",
                ("Evaluated to 42.000000", "Evaluated to 4.000000"),
            ),
            Case(
                "assignment-and-shadow-recovery",
                "(1+2)=3;\n"
                "def missingrestore() (var a = 1 in a) + a;\n"
                "1+;\n"
                "def semi(x) x;\n"
                "1+);\n"
                "def paren(x) x;\n"
                "semi(20)+paren(22);\n",
                (
                    "Error: destination of '=' must be a variable",
                    "Error: Unknown variable name",
                    "Error: unknown token when expecting an expression",
                    "Error: unknown token when expecting an expression",
                    "Evaluated to 42.000000",
                ),
                allowed_diagnostics=(
                    "destination of '=' must be a variable",
                    "unknown variable name",
                    "unknown token when expecting an expression",
                ),
            ),
        ),
    ),
    Example(
        "Chapter8",
        "def twice(x) x*2;\n",
        ("Wrote output.o",),
        object_output=True,
        regressions=(
            Case(
                "duplicate-shadowing-object",
                "def answer() var a = 10 in (var a = 1, a = 2 in a) + a;\n",
                ("define double @answer", "Wrote output.o"),
                object_output=True,
                object_result=12,
            ),
            Case(
                "right-associative-assignment-object",
                "def answer() var a = 0, b = 0 in (a = b = 7) + a + b;\n",
                ("define double @answer", "Wrote output.o"),
                object_output=True,
                object_result=21,
            ),
            Case(
                "definition-errors-no-object",
                "extern keep(x);\n"
                "def keep(x) missing;\n"
                "def stable(x) x+1;\n"
                "def stable(x) x+2;\n"
                "extern arity(x);\n"
                "extern arity(x y);\n",
                (
                    "Error: Unknown variable name",
                    "Error: Function cannot be redefined.",
                    "Error: Function prototype has conflicting arity.",
                ),
                status=1,
                allowed_diagnostics=(
                    "unknown variable name",
                    "function cannot be redefined",
                    "function prototype has conflicting arity",
                ),
                absent=("Wrote output.o", "define double @keep"),
                forbid_object=True,
            ),
            Case(
                "assignment-error-no-object",
                "def bad() (1+2)=3;\ndef good() 42;\n",
                (
                    "Error: destination of '=' must be a variable",
                    "define double @good",
                ),
                status=1,
                allowed_diagnostics=("destination of '=' must be a variable",),
                absent=("Wrote output.o",),
                forbid_object=True,
            ),
            Case(
                "custom-precedence-rollback",
                "def binary+ 90 (x y) missing;\ndef order() 1+2*3;\n",
                (
                    "Error: Unknown variable name",
                    "define double @order",
                    "ret double 7.000000e+00",
                ),
                status=1,
                allowed_diagnostics=("unknown variable name",),
                absent=("Wrote output.o",),
                forbid_object=True,
            ),
            Case(
                "parser-recovery",
                "1+;\ndef semi(x) x;\n1+);\ndef paren(x) x;\n",
                (
                    "Error: unknown token when expecting an expression",
                    "define double @semi",
                    "Error: unknown token when expecting an expression",
                    "define double @paren",
                ),
                status=1,
                allowed_diagnostics=("unknown token when expecting an expression",),
                absent=("Wrote output.o",),
                forbid_object=True,
            ),
        ),
    ),
    Example(
        "Chapter9",
        "def inc(x) x+1;\ninc(2);\n",
        (
            "target datalayout =",
            "target triple =",
            "#dbg_declare",
            "define double @main",
            "!DICompileUnit",
            "!DISubprogram",
            "!DILocation",
        ),
        ir_output=True,
        debug_declarations=(("inc", "%x1", "x", 1, 1, 0),),
        regressions=(
            Case(
                "duplicate-shadowing",
                "def answer() var a = 10 in (var a = 1, a = 2 in a) + a;\n",
                (
                    "define double @answer",
                    "load double, ptr %a2",
                    "load double, ptr %a,",
                ),
                absent=("load double, ptr %a1",),
                ir_output=True,
            ),
            Case(
                "right-associative-assignment",
                "def assign() var a = 0, b = 0 in (a = b = 7) + a + b;\n",
                (
                    "define double @assign",
                    "store double 7.000000e+00, ptr %b",
                    "store double 7.000000e+00, ptr %a",
                ),
                ir_output=True,
            ),
            Case(
                "debug-location-restoration",
                "def nested(x) x + (x * x);\n",
                ("define double @nested",),
                ir_output=True,
                debug_locations=(
                    ("%multmp = fmul", 1, 22),
                    ("%addtmp = fadd", 1, 17),
                ),
            ),
            Case(
                "parser-recovery",
                "1+;\ndef semi(x) x;\n1+);\ndef paren(x) x;\n"
                "semi(20)+paren(22);\n",
                (
                    "Error: unknown token when expecting an expression",
                    "Error: unknown token when expecting an expression",
                ),
                status=1,
                allowed_diagnostics=("unknown token when expecting an expression",),
                absent=("; ModuleID =", "define double"),
                forbid_object=True,
            ),
            Case(
                "codegen-recovery-no-ir",
                "def bad(x) missing;\ndef good(x) x+1;\ndef good(x) x+2;\n",
                (
                    "Error: Unknown variable name",
                    "Error: Function cannot be redefined.",
                ),
                status=1,
                allowed_diagnostics=(
                    "unknown variable name",
                    "function cannot be redefined",
                ),
                absent=("; ModuleID =", "define double"),
                forbid_object=True,
            ),
            Case(
                "crlf-locations",
                "def loc(x)\r\nx+1;\r\n",
                ("define double @loc", "!DILocation(line: 2, column: 2"),
                absent=("!DILocation(line: 3",),
                ir_output=True,
            ),
        ),
    ),
    Example(
        "BuildingAJIT/Chapter1",
        "def twice(x) x*2;\ntwice(21);\n",
        ("Evaluated to 42.000000",),
        regressions=AJIT_REGRESSIONS,
    ),
    Example(
        "BuildingAJIT/Chapter2",
        "def square(x) x*x;\nsquare(9);\n",
        ("Evaluated to 81.000000",),
        regressions=AJIT_REGRESSIONS,
    ),
    Example(
        "BuildingAJIT/Chapter3",
        "def add1(x) x+1;\ndef twice(x) x*2;\nadd1(twice(10));\n",
        ("Evaluated to 21.000000",),
        regressions=AJIT_REGRESSIONS
        + (
            Case(
                "lazy-unresolved",
                "extern missing(x);\n"
                "def callsmissing(x) missing(x);\n"
                "callsmissing(1);\n",
                ("Lazy compilation failed.",),
                status=1,
                allowed_diagnostics=("jit session error",),
                timeout=10,
            ),
        ),
    ),
    Example(
        "BuildingAJIT/Chapter4",
        "def add1(x) x+1;\ndef twice(x) x*2;\nadd1(twice(10));\n",
        ("Evaluated to 21.000000",),
        regressions=AJIT_REGRESSIONS
        + (
            Case(
                "deferred-ast-materialization",
                "def deferred(x) later(x);\n"
                "def later(x) x+1;\n"
                "deferred(41);\n",
                ("Evaluated to 42.000000",),
                absent=("unknown function referenced",),
            ),
        ),
    ),
)

DIAGNOSTIC_RE = re.compile(r"\b(?:fatal(?:\s+error)?|error)\b", re.IGNORECASE)
OBJECT_MAGICS = {
    "Darwin": (b"\xfe\xed\xfa\xce", b"\xce\xfa\xed\xfe", b"\xfe\xed\xfa\xcf", b"\xcf\xfa\xed\xfe"),
    "Linux": (b"\x7fELF",),
    "Windows": (b"\x4c\x01", b"\x64\x86", b"\x64\xaa", b"\x00\x00\xff\xff"),
}
PASS_DEBUG_FRAGMENTS = ("Running pass:", "Running analysis:", "Invalidating analysis:")


def runtime_environment() -> dict[str, str]:
    system = platform.system()
    machine = platform.machine().lower()
    arch = "arm64" if machine in {"arm64", "aarch64"} else "x64"
    if system == "Darwin":
        directory = LLVM_ROOT / f"darwin_{arch}"
        key = "DYLD_LIBRARY_PATH"
    elif system == "Linux":
        directory = LLVM_ROOT / f"linux_{arch}"
        key = "LD_LIBRARY_PATH"
    elif system == "Windows":
        directory = LLVM_ROOT / "windows_x64"
        key = "PATH"
    else:
        raise RuntimeError(f"unsupported host: {system}")

    if not directory.is_dir():
        raise RuntimeError(f"LLVM shared-library directory not found: {directory}")
    env = dict(os.environ)
    current = env.get(key, "")
    env[key] = str(directory) + (os.pathsep + current if current else "")
    return env


def check_diagnostics(output: str, allowed: tuple[str, ...], label: str) -> None:
    allowed = tuple(fragment.lower() for fragment in allowed)
    unexpected = []
    for line in output.splitlines():
        if not DIAGNOSTIC_RE.search(line):
            continue
        lowered = line.lower()
        if any(fragment in lowered for fragment in allowed):
            continue
        unexpected.append(line)
    if unexpected:
        rendered = "\n".join(unexpected)
        raise AssertionError(
            f"{label}: unexpected fatal/error diagnostic:\n{rendered}"
        )


def decode_timeout_stream(stream: bytes | str | None) -> str:
    if isinstance(stream, bytes):
        return stream.decode("utf-8", errors="replace")
    return stream or ""


def run(
    command: list[str],
    *,
    cwd: Path,
    env: dict[str, str],
    stdin: str = "",
    expected_status: int = 0,
    allowed_diagnostics: tuple[str, ...] = (),
    timeout: int = 240,
    label: str,
    allow_pass_debug: bool = False,
) -> str:
    try:
        result = subprocess.run(
            command,
            cwd=cwd,
            env=env,
            input=stdin,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        output = decode_timeout_stream(error.stdout)
        raise RuntimeError(f"{label}: timed out after {timeout}s\n{output}") from error

    output = result.stdout
    if result.returncode != expected_status:
        raise RuntimeError(
            f"{label}: status {result.returncode}, expected {expected_status}: "
            f"{' '.join(command)}\n{output}"
        )
    check_diagnostics(output, allowed_diagnostics, label)
    if not allow_pass_debug:
        for fragment in PASS_DEBUG_FRAGMENTS:
            if fragment in output:
                raise AssertionError(f"{label}: unexpected pass debug logging {fragment!r}\n{output}")
    return output


def check_output(case: Case, output: str, label: str) -> None:
    position = 0
    for expected in case.expected:
        next_position = output.find(expected, position)
        if next_position < 0:
            raise AssertionError(
                f"{label}: expected {expected!r} after output offset {position}\n{output}"
            )
        position = next_position + len(expected)
    for absent in case.absent:
        if absent in output:
            raise AssertionError(f"{label}: forbidden output {absent!r} was present\n{output}")


def check_object(
    object_path: Path,
    case: Case,
    *,
    odin: str,
    env: dict[str, str],
    run_dir: Path,
    suffix: str,
    label: str,
) -> None:
    if not object_path.is_file() or object_path.stat().st_size == 0:
        raise AssertionError(f"{label}: output.o was not emitted")
    prefix = object_path.read_bytes()[:4]
    if not any(prefix.startswith(magic) for magic in OBJECT_MAGICS[platform.system()]):
        raise AssertionError(f"{label}: output.o has invalid object magic {prefix.hex()}")
    if case.object_result is None:
        return

    probe_source = run_dir / "object_probe.odin"
    probe_source.write_text(
        """package main

import "core:os"

foreign import generated_object "output.o"

@(default_calling_convention = "c")
foreign generated_object {
    answer :: proc() -> f64 ---
}

main :: proc() {
    if answer() != OBJECT_RESULT {
        os.exit(1)
    }
}
""".replace("OBJECT_RESULT", repr(case.object_result)),
        encoding="ascii",
    )
    probe = run_dir / f"object-probe{suffix}"
    run(
        [odin, "build", str(probe_source), "-file", f"-out:{probe}"],
        cwd=run_dir,
        env=env,
        label=f"{label} object probe build",
    )
    run([str(probe)], cwd=run_dir, env=env, label=f"{label} object probe run")


def check_debug_locations(case: Case, ir: str, label: str) -> None:
    locations = {
        match.group(1): (int(match.group(2)), int(match.group(3)))
        for match in re.finditer(
            r"!(\d+) = !DILocation\(line: (\d+), column: (\d+)", ir
        )
    }
    for instruction, line, column in case.debug_locations:
        matches = [text for text in ir.splitlines() if instruction in text]
        if len(matches) != 1:
            raise AssertionError(
                f"{label}: expected one instruction containing {instruction!r}, "
                f"found {len(matches)}\n{ir}"
            )
        debug_match = re.search(r"!dbg !(\d+)", matches[0])
        if debug_match is None:
            raise AssertionError(f"{label}: instruction has no debug location: {matches[0]}")
        actual = locations.get(debug_match.group(1))
        if actual != (line, column):
            raise AssertionError(
                f"{label}: {instruction!r} location {actual}, expected {(line, column)}"
            )


def check_debug_declarations(case: Case, ir: str, label: str) -> None:
    metadata = {
        match.group(1): match.group(2)
        for match in re.finditer(r"^!(\d+) = (.+)$", ir, re.MULTILINE)
    }
    for function, storage, name, index, line, column in case.debug_declarations:
        function_match = re.search(
            rf"^define [^\n]*@{re.escape(function)}\([^)]*\) !dbg !(\d+) \{{\n(.*?)^\}}",
            ir,
            re.MULTILINE | re.DOTALL,
        )
        if function_match is None:
            raise AssertionError(f"{label}: debug function {function!r} not found\n{ir}")
        scope = function_match.group(1)
        body = function_match.group(2)
        subprogram = metadata.get(scope, "")
        if not re.search(
            rf'^distinct !DISubprogram\(name: "{re.escape(function)}"(?:,|\))',
            subprogram,
        ):
            raise AssertionError(f"{label}: !{scope} is not {function!r} subprogram: {subprogram}")
        if not re.search(rf"^  {re.escape(storage)} = alloca double(?:,|$)", body, re.MULTILINE):
            raise AssertionError(f"{label}: parameter storage {storage!r} not found in {function!r}\n{body}")

        declaration = re.search(
            rf"^    #dbg_declare\(ptr {re.escape(storage)}, !(\d+), !DIExpression\(\), !(\d+)\)$",
            body,
            re.MULTILINE,
        )
        if declaration is None:
            raise AssertionError(f"{label}: debug declaration for {storage!r} not found\n{body}")
        descriptor = metadata.get(declaration.group(1), "")
        expected_descriptor = re.compile(
            rf'^!DILocalVariable\(name: "{re.escape(name)}", arg: {index}, '
            rf"scope: !{scope}, .*\bline: {line}(?:,|\))"
        )
        if expected_descriptor.search(descriptor) is None:
            raise AssertionError(
                f"{label}: parameter descriptor name/index/scope/line mismatch: {descriptor}"
            )

        location = metadata.get(declaration.group(2), "")
        location_match = re.fullmatch(
            r"!DILocation\(line: (\d+)(?:, column: (\d+))?, scope: !(\d+)\)",
            location,
        )
        actual_location = None
        if location_match is not None:
            actual_location = (
                int(location_match.group(1)),
                int(location_match.group(2) or 0),
                location_match.group(3),
            )
        if actual_location != (line, column, scope):
            raise AssertionError(
                f"{label}: parameter declaration location {actual_location}, "
                f"expected {(line, column, scope)}"
            )


def check_ir(
    case: Case,
    output: str,
    *,
    env: dict[str, str],
    run_dir: Path,
    label: str,
) -> None:
    if not output.startswith("; ModuleID ="):
        raise AssertionError(
            f"{label}: expected standalone LLVM IR with no prompt or AST dump prefix\n{output}"
        )
    ir = output
    check_debug_locations(case, ir, label)
    check_debug_declarations(case, ir, label)

    llvm_as = shutil.which("llvm-as")
    if not llvm_as:
        raise RuntimeError(f"{label}: required LLVM IR tool not found on PATH: llvm-as")

    ir_path = run_dir / "module.ll"
    bitcode_path = run_dir / "module.bc"
    tool_env = dict(os.environ)
    ir_path.write_text(ir, encoding="utf-8")
    run(
        [llvm_as, str(ir_path), "-o", str(bitcode_path)],
        cwd=run_dir,
        env=tool_env,
        label=f"{label} IR assembly",
    )
    compile_unit_anchor = re.search(r"!llvm\.dbg\.cu\s*=\s*!\{([^}]*)\}", ir)
    if compile_unit_anchor is None:
        raise AssertionError(f"{label}: missing !llvm.dbg.cu compile-unit anchor")
    compile_unit_ids = re.findall(r"!(\d+)", compile_unit_anchor.group(1))
    if not compile_unit_ids or not any(
        re.search(rf"^!{metadata_id} = distinct !DICompileUnit\(", ir, re.MULTILINE)
        for metadata_id in compile_unit_ids
    ):
        raise AssertionError(f"{label}: !llvm.dbg.cu does not reference a DICompileUnit")

    llc = shutil.which("llc")
    if not llc:
        raise RuntimeError(f"{label}: required debug-object tool not found on PATH: llc")
    dwarfdump = shutil.which("llvm-dwarfdump")
    if not dwarfdump:
        raise RuntimeError(
            f"{label}: required debug-object tool not found on PATH: llvm-dwarfdump"
        )

    object_path = run_dir / "module-debug.o"
    run(
        [llc, "-filetype=obj", str(bitcode_path), "-o", str(object_path)],
        cwd=run_dir,
        env=tool_env,
        label=f"{label} debug object emission",
    )
    run(
        [dwarfdump, "--verify", str(object_path)],
        cwd=run_dir,
        env=tool_env,
        label=f"{label} DWARF verification",
    )
    debug_info = run(
        [dwarfdump, "--debug-info", str(object_path)],
        cwd=run_dir,
        env=tool_env,
        label=f"{label} DWARF inspection",
    )
    if "DW_TAG_compile_unit" not in debug_info:
        raise AssertionError(f"{label}: emitted object has no DWARF compile unit")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--odin", default=os.environ.get("ODIN") or shutil.which("odin"))
    args = parser.parse_args()
    if not args.odin:
        raise SystemExit("Odin compiler not found; pass --odin or set ODIN")

    odin_path = shutil.which(args.odin) or args.odin
    odin = str(Path(odin_path).expanduser().resolve())
    env = runtime_environment()
    suffix = ".exe" if os.name == "nt" else ""
    with tempfile.TemporaryDirectory(prefix="llvm-kaleidoscope-") as temp:
        output_dir = Path(temp)
        for index, example in enumerate(EXAMPLES, start=1):
            source_dir = HERE / example.path
            binary = output_dir / f"example-{index}{suffix}"
            build = [odin, "build", str(source_dir), f"-out:{binary}"]
            if example.path != "Chapter2":
                build.append("-define:LLVM_LINK=shared")
            run(build, cwd=LLVM_ROOT, env=env, label=f"{example.path} build")

            cases = (
                Case(
                    "smoke",
                    example.source,
                    example.expected,
                    object_output=example.object_output,
                    ir_output=example.ir_output,
                    debug_declarations=example.debug_declarations,
                ),
                *example.regressions,
            )
            for case_index, case in enumerate(cases, start=1):
                label = f"{example.path} {case.name}"
                run_dir = output_dir / f"run-{index}-{case_index}"
                run_dir.mkdir()
                output = run(
                    [str(binary)],
                    cwd=run_dir,
                    env=env,
                    stdin=case.source,
                    expected_status=case.status,
                    allowed_diagnostics=case.allowed_diagnostics,
                    timeout=case.timeout,
                    label=label,
                )
                check_output(case, output, label)
                if case.object_output:
                    check_object(
                        run_dir / "output.o",
                        case,
                        odin=odin,
                        env=env,
                        run_dir=run_dir,
                        suffix=suffix,
                        label=label,
                    )
                if case.forbid_object and (run_dir / "output.o").exists():
                    raise AssertionError(f"{label}: output.o was emitted after a source error")
                if case.ir_output:
                    check_ir(case, output, env=env, run_dir=run_dir, label=label)
            print(f"ok {example.path}")


if __name__ == "__main__":
    main()
