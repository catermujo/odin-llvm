@echo off

setlocal EnableDelayedExpansion

set "VENDOR_WINDOWS_ARCH=%VSCMD_ARG_TGT_ARCH%"
if defined VENDOR_WINDOWS_ARCH if /I "%VENDOR_WINDOWS_ARCH%"=="x86" (
    echo vendor/llvm does not support explicit Windows x86 targets 1>&2
    exit /b 1
)
if not defined VENDOR_WINDOWS_ARCH (
    set "VENDOR_WINDOWS_ARCH=%PROCESSOR_ARCHITECTURE%"
    if /I "!VENDOR_WINDOWS_ARCH!"=="x86" if /I "%PROCESSOR_ARCHITEW6432%"=="AMD64" set "VENDOR_WINDOWS_ARCH=AMD64"
)
if /I "%VENDOR_WINDOWS_ARCH%"=="AMD64" set "VENDOR_WINDOWS_ARCH=x64"
if /I not "%VENDOR_WINDOWS_ARCH%"=="x64" (
    echo vendor/llvm supports Windows x64 only 1>&2
    exit /b 1
)

set "BASE=%~dp0"
set "SOURCE_DIR=%BASE%llvm-project"
set "BUILD_DIR=%BASE%build_shared_%VENDOR_WINDOWS_ARCH%"
set "OUTPUT_DIR=%BASE%windows_%VENDOR_WINDOWS_ARCH%"
set "REMOTE=https://github.com/llvm/llvm-project.git"
set "REVISION=llvmorg-22.1.8"
set "REVISION_COMMIT=ca7933e47d3a3451d81e72ac174dcb5aa28b59d1"
if defined LLVM_REPOSITORY set "REMOTE=%LLVM_REPOSITORY%"
set "GIT_ALTERNATE_OBJECT_DIRECTORIES="
set "GIT_COMMON_DIR="
set "GIT_DIR="
set "GIT_INDEX_FILE="
set "GIT_OBJECT_DIRECTORY="
set "GIT_OPTIONAL_LOCKS=0"
set "GIT_WORK_TREE="

where git >nul 2>&1 || (
    echo Missing required command: git 1>&2
    exit /b 1
)
where cmake >nul 2>&1 || (
    echo Missing required command: cmake 1>&2
    exit /b 1
)

if exist "%SOURCE_DIR%" if not exist "%SOURCE_DIR%\.git" (
    echo LLVM source path exists but is not a git checkout: %SOURCE_DIR% 1>&2
    exit /b 1
)

if not exist "%SOURCE_DIR%\.git" (
    git clone --branch "%REVISION%" --depth=1 "%REMOTE%" "%SOURCE_DIR%" || exit /b 1
)
call :verify_source || exit /b 1

echo Configuring LLVM %REVISION% shared build...
cmake -S "%SOURCE_DIR%\llvm" -B "%BUILD_DIR%" -A %VENDOR_WINDOWS_ARCH% ^
    -DCMAKE_BUILD_TYPE=Release ^
    -DLLVM_BUILD_LLVM_C_DYLIB=ON ^
    -DLLVM_BUILD_LLVM_DYLIB=OFF ^
    -DLLVM_LINK_LLVM_DYLIB=OFF ^
    -DLLVM_BUILD_TOOLS=OFF ^
    -DLLVM_ENABLE_ASSERTIONS=OFF ^
    -DLLVM_ENABLE_BINDINGS=OFF ^
    -DLLVM_ENABLE_DIA_SDK=OFF ^
    -DLLVM_ENABLE_FFI=OFF ^
    -DLLVM_ENABLE_LIBEDIT=OFF ^
    -DLLVM_ENABLE_LIBXML2=OFF ^
    -DLLVM_ENABLE_TERMINFO=OFF ^
    -DLLVM_ENABLE_ZLIB=OFF ^
    -DLLVM_ENABLE_ZSTD=OFF ^
    -DLLVM_INCLUDE_BENCHMARKS=OFF ^
    -DLLVM_INCLUDE_DOCS=OFF ^
    -DLLVM_INCLUDE_EXAMPLES=OFF ^
    -DLLVM_INCLUDE_TESTS=OFF ^
    -DLLVM_TARGETS_TO_BUILD=all || exit /b 1

echo Building LLVM-C and LTO...
cmake --build "%BUILD_DIR%" --target LLVM-C LTO --config Release --parallel || exit /b 1

set "LLVM_DLL=%BUILD_DIR%\Release\bin\LLVM-C.dll"
set "LLVM_LIB=%BUILD_DIR%\Release\lib\LLVM-C.lib"
set "LTO_DLL=%BUILD_DIR%\Release\bin\LTO.dll"
set "LTO_LIB=%BUILD_DIR%\Release\lib\LTO.lib"

if not exist "%LLVM_DLL%" (
    echo Missing Release LLVM-C.dll: %LLVM_DLL% 1>&2
    exit /b 1
)
if not exist "%LLVM_LIB%" (
    echo Missing Release LLVM-C.lib: %LLVM_LIB% 1>&2
    exit /b 1
)
if not exist "%LTO_DLL%" (
    echo Missing Release LTO.dll: %LTO_DLL% 1>&2
    exit /b 1
)
if not exist "%LTO_LIB%" (
    echo Missing Release LTO.lib: %LTO_LIB% 1>&2
    exit /b 1
)

if not exist "%OUTPUT_DIR%" mkdir "%OUTPUT_DIR%"
copy /y "%LLVM_DLL%" "%OUTPUT_DIR%\LLVM-C.dll" >nul || exit /b 1
copy /y "%LLVM_LIB%" "%OUTPUT_DIR%\LLVM-C.lib" >nul || exit /b 1
copy /y "%LTO_DLL%" "%OUTPUT_DIR%\LTO.dll" >nul || exit /b 1
copy /y "%LTO_LIB%" "%OUTPUT_DIR%\LTO.lib" >nul || exit /b 1

echo LLVM shared build completed successfully!
exit /b 0

:verify_source
git -C "%SOURCE_DIR%" show-ref --verify --quiet "refs/tags/%REVISION%"
if errorlevel 1 (
    echo LLVM source is missing required tag %REVISION% 1>&2
    exit /b 1
)

set "TAG_COMMIT="
for /f "delims=" %%F in ('git -C "%SOURCE_DIR%" rev-list -n 1 "refs/tags/%REVISION%" 2^>nul') do set "TAG_COMMIT=%%F"
if not defined TAG_COMMIT (
    echo Could not resolve LLVM tag %REVISION% 1>&2
    exit /b 1
)
if /I not "%TAG_COMMIT%"=="%REVISION_COMMIT%" (
    echo LLVM tag %REVISION% resolves to %TAG_COMMIT%, expected %REVISION_COMMIT% 1>&2
    exit /b 1
)

set "SOURCE_HEAD="
for /f "delims=" %%F in ('git -C "%SOURCE_DIR%" rev-parse --verify HEAD 2^>nul') do set "SOURCE_HEAD=%%F"
if not defined SOURCE_HEAD (
    echo Could not resolve LLVM source HEAD 1>&2
    exit /b 1
)
if /I not "%SOURCE_HEAD%"=="%REVISION_COMMIT%" (
    echo LLVM source HEAD is %SOURCE_HEAD%, expected %REVISION% ^(%REVISION_COMMIT%^) 1>&2
    exit /b 1
)

git -C "%SOURCE_DIR%" status --porcelain=v1 --untracked-files=all >nul 2>&1
if errorlevel 1 (
    echo Could not inspect LLVM source status 1>&2
    exit /b 1
)
set "SOURCE_DIRTY="
for /f "delims=" %%F in ('git -C "%SOURCE_DIR%" status --porcelain=v1 --untracked-files=all 2^>nul') do set "SOURCE_DIRTY=1"
if defined SOURCE_DIRTY (
    echo LLVM source is dirty; refusing to build 1>&2
    git -C "%SOURCE_DIR%" status --short --untracked-files=all 1>&2
    exit /b 1
)
exit /b 0
