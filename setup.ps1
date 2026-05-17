# ==============================================================
#  setup.ps1 - universal MCU project setup
# ==============================================================
# HOW TO RUN:
#   RECOMMENDED — open VS Code in this folder, then in the built-in terminal:
#              .\setup.ps1
#
#   If you get "running scripts is disabled" — run this ONCE in any PowerShell:
#              Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
#
#   If you downloaded setup.ps1 from the internet and still get blocked:
#              Unblock-File .\setup.ps1
#
#   Emergency bypass (no permanent changes):
#              powershell -ExecutionPolicy Bypass -File setup.ps1
#
# WHAT IT DOES:
#   1. Asks which MCU you are targeting
#   2. Confirms / overrides Flash and RAM size (for exact chip variant)
#   3. Searches for existing compilers on your PC (avoids re-downloading)
#   4. Shows a download plan with sizes and disk-space check
#   5. Downloads missing tools to a SHARED folder (shared by all projects)
#   6. Downloads MCU device headers into this project's device/ folder
#   7. Generates cmake/ config files, mcu.ld and updates .vscode/tasks.json
#
# SHARED TOOLS FOLDER  (default: C:\tools-mcu)
#   Override: set $env:MCU_TOOLS_DIR before running.
#
#   arm-none-eabi\    ARM compiler  ~500 MB  (arm-none-eabi-gcc)
#   riscv-none-elf\   RISC-V compiler ~350 MB  (riscv-none-elf-gcc)
#   cmake\            CMake build tool  ~170 MB
#   ninja\            Ninja build runner  ~1 MB
#
#   All your MCU projects reuse the same shared tools.
#   Typical total: ~200 MB (ARM only) or ~550 MB (both).
# ==============================================================

$ErrorActionPreference = "Stop"

# Check execution policy - the most common reason setup fails on a fresh PC.
$ep = Get-ExecutionPolicy -Scope CurrentUser
if ($ep -eq 'Restricted' -or $ep -eq 'AllSigned') {
    Write-Host ""
    Write-Host "  PowerShell execution policy blocks script execution." -ForegroundColor Red
    Write-Host "  Run this once in an Administrator PowerShell to fix it:" -ForegroundColor Yellow
    Write-Host "    Set-ExecutionPolicy RemoteSigned -Scope CurrentUser" -ForegroundColor Cyan
    Write-Host "  OR run setup.ps1 with:" -ForegroundColor Yellow
    Write-Host "    powershell -ExecutionPolicy Bypass -File setup.ps1" -ForegroundColor Cyan
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

# Trap: catch any unhandled error, print it clearly, and pause before closing.
# Without this, the terminal window closes immediately and the error is lost.
trap {
    Write-Host ""
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host "  SETUP FAILED" -ForegroundColor Red
    Write-Host "================================================================" -ForegroundColor Red
    Write-Host ($_ | Out-String).Trim() -ForegroundColor Red
    Write-Host ""
    Write-Host "  If you see a network error - check your internet connection." -ForegroundColor Yellow
    Write-Host "  If you see 'Access denied' - run PowerShell as Administrator." -ForegroundColor Yellow
    Write-Host ""
    Read-Host "Press Enter to close"
    exit 1
}

# --- Project paths ---
$Root      = $PSScriptRoot
$DeviceDir = Join-Path $Root "device"
$CmakeDir  = Join-Path $Root "cmake"
$VsCodeDir = Join-Path $Root ".vscode"

# --- Shared tools folder ---
$SharedDir = if ($env:MCU_TOOLS_DIR) { $env:MCU_TOOLS_DIR } else { "C:\tools-mcu" }

# ==============================================================
# MCU Database  -  add your chip here if it is not listed
# ==============================================================
$MCU_DB = @(
    # -- ARM Cortex (arm-none-eabi-gcc) -------------------------
    @{ Family="STM32F0xx  (Cortex-M0)";    Pattern="stm32f0"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m0 -mthumb";    FloatABI="soft"; FpuFlags=""
       Define="STM32F030x8"; Header="stm32f0xx.h"
       Repo="STMicroelectronics/cmsis_device_f0"; RepoType="STM"
       StartupGlob="startup_stm32f030x8.s"; SystemFile="system_stm32f0xx.c"
       NeedsCmsis=$true
       FlashKB=64;   RamKB=8;   FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32F1xx  (Cortex-M3)";    Pattern="stm32f1"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m3 -mthumb";    FloatABI="soft"; FpuFlags=""
       Define="STM32F103xB"; Header="stm32f1xx.h"
       # Flash code -> correct CMSIS define + startup file + RAM size for STM32F103:
       #   LD: 4=16K/6K  6=32K/10K   (STM32F103x6 covers both)
       #   MD: 8=64K/20K  B=128K/20K (STM32F103xB covers both)
       #   HD: C=256K/48K  D=384K/48K  E=512K/64K (STM32F103xE covers all three)
       #   XL: F=768K/96K  G=1024K/96K (STM32F103xG covers both)
       # ST ships ONE CMSIS header + startup per density tier, not per flash code.
       DefineByFlashCode  = @{ '4'='STM32F103x6'; '6'='STM32F103x6'; '8'='STM32F103xB'; 'B'='STM32F103xB'; 'C'='STM32F103xE'; 'D'='STM32F103xE'; 'E'='STM32F103xE'; 'F'='STM32F103xG'; 'G'='STM32F103xG' }
       StartupByFlashCode = @{ '4'='startup_stm32f103x6.s'; '6'='startup_stm32f103x6.s'; '8'='startup_stm32f103xb.s'; 'B'='startup_stm32f103xb.s'; 'C'='startup_stm32f103xe.s'; 'D'='startup_stm32f103xe.s'; 'E'='startup_stm32f103xe.s'; 'F'='startup_stm32f103xg.s'; 'G'='startup_stm32f103xg.s' }
       RamByFlashCode     = @{ '4'=6; '6'=10; '8'=20; 'B'=20; 'C'=48; 'D'=48; 'E'=64; 'F'=96; 'G'=96 }
       Repo="STMicroelectronics/cmsis_device_f1"; RepoType="STM"
       StartupGlob="startup_stm32f103xb.s"; SystemFile="system_stm32f1xx.c"
       NeedsCmsis=$true
       FlashKB=64;   RamKB=20;  FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32F4xx  (Cortex-M4F)";   Pattern="stm32f4"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m4 -mthumb";    FloatABI="hard"; FpuFlags="-mfpu=fpv4-sp-d16"
       Define="STM32F407xx"; Header="stm32f4xx.h"
       # F4 has ~17 chip variants - most map model->define with the "xx" suffix,
       # but F401/F411 split by flash size (xC <=256K, xE >=384K). F410/F412 split
       # by *package* not flash, so they fall back to the default; override
       # MCU_DEFINE in build_config.cmake if you use one (e.g. STM32F410Tx).
       DefineByModel  = @{ '401'='STM32F401xC'; '405'='STM32F405xx'; '407'='STM32F407xx'; '411'='STM32F411xE'; '413'='STM32F413xx'; '415'='STM32F415xx'; '417'='STM32F417xx'; '423'='STM32F423xx'; '427'='STM32F427xx'; '429'='STM32F429xx'; '437'='STM32F437xx'; '439'='STM32F439xx'; '446'='STM32F446xx'; '469'='STM32F469xx'; '479'='STM32F479xx' }
       StartupByModel = @{ '401'='startup_stm32f401xc.s'; '405'='startup_stm32f405xx.s'; '407'='startup_stm32f407xx.s'; '411'='startup_stm32f411xe.s'; '413'='startup_stm32f413xx.s'; '415'='startup_stm32f415xx.s'; '417'='startup_stm32f417xx.s'; '423'='startup_stm32f423xx.s'; '427'='startup_stm32f427xx.s'; '429'='startup_stm32f429xx.s'; '437'='startup_stm32f437xx.s'; '439'='startup_stm32f439xx.s'; '446'='startup_stm32f446xx.s'; '469'='startup_stm32f469xx.s'; '479'='startup_stm32f479xx.s' }
       # F401 splits by flash size (xC <=256K, xE >=384K). F411 does NOT split -
       # ST ships a single STM32F411xE / startup_stm32f411xe.s used for ALL F411
       # parts (CB/CC/CE), so only F401 needs an override here.
       DefineByModelFlash  = @{ '401_D'='STM32F401xE'; '401_E'='STM32F401xE' }
       StartupByModelFlash = @{ '401_D'='startup_stm32f401xe.s'; '401_E'='startup_stm32f401xe.s' }
       Repo="STMicroelectronics/cmsis_device_f4"; RepoType="STM"
       StartupGlob="startup_stm32f407xx.s"; SystemFile="system_stm32f4xx.c"
       NeedsCmsis=$true
       FlashKB=1024; RamKB=192; FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32G0xx  (Cortex-M0+)";   Pattern="stm32g0"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m0plus -mthumb"; FloatABI="soft"; FpuFlags=""
       Define="STM32G030xx"; Header="stm32g0xx.h"
       Repo="STMicroelectronics/cmsis_device_g0"; RepoType="STM"
       StartupGlob="startup_stm32g030xx.s"; SystemFile="system_stm32g0xx.c"
       NeedsCmsis=$true
       FlashKB=32;   RamKB=8;   FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32G4xx  (Cortex-M4F)";   Pattern="stm32g4"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m4 -mthumb";    FloatABI="hard"; FpuFlags="-mfpu=fpv4-sp-d16"
       Define="STM32G431xx"; Header="stm32g4xx.h"
       # G4 follows the generic STM32<XYY>xx pattern, no flash-tier exceptions.
       DefineByModel  = @{ '431'='STM32G431xx'; '441'='STM32G441xx'; '471'='STM32G471xx'; '473'='STM32G473xx'; '474'='STM32G474xx'; '483'='STM32G483xx'; '484'='STM32G484xx'; '491'='STM32G491xx'; '4A1'='STM32G4A1xx' }
       StartupByModel = @{ '431'='startup_stm32g431xx.s'; '441'='startup_stm32g441xx.s'; '471'='startup_stm32g471xx.s'; '473'='startup_stm32g473xx.s'; '474'='startup_stm32g474xx.s'; '483'='startup_stm32g483xx.s'; '484'='startup_stm32g484xx.s'; '491'='startup_stm32g491xx.s'; '4A1'='startup_stm32g4a1xx.s' }
       Repo="STMicroelectronics/cmsis_device_g4"; RepoType="STM"
       StartupGlob="startup_stm32g431xx.s"; SystemFile="system_stm32g4xx.c"
       NeedsCmsis=$true
       FlashKB=128;  RamKB=32;  FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32L4xx  (Cortex-M4F)";   Pattern="stm32l4"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m4 -mthumb";    FloatABI="hard"; FpuFlags="-mfpu=fpv4-sp-d16"
       Define="STM32L476xx"; Header="stm32l4xx.h"
       # L4 follows the generic STM32L<MMM>xx pattern, no flash-tier exceptions.
       DefineByModel  = @{ '412'='STM32L412xx'; '422'='STM32L422xx'; '431'='STM32L431xx'; '432'='STM32L432xx'; '433'='STM32L433xx'; '442'='STM32L442xx'; '443'='STM32L443xx'; '451'='STM32L451xx'; '452'='STM32L452xx'; '462'='STM32L462xx'; '471'='STM32L471xx'; '475'='STM32L475xx'; '476'='STM32L476xx'; '485'='STM32L485xx'; '486'='STM32L486xx'; '496'='STM32L496xx'; '4A6'='STM32L4A6xx' }
       StartupByModel = @{ '412'='startup_stm32l412xx.s'; '422'='startup_stm32l422xx.s'; '431'='startup_stm32l431xx.s'; '432'='startup_stm32l432xx.s'; '433'='startup_stm32l433xx.s'; '442'='startup_stm32l442xx.s'; '443'='startup_stm32l443xx.s'; '451'='startup_stm32l451xx.s'; '452'='startup_stm32l452xx.s'; '462'='startup_stm32l462xx.s'; '471'='startup_stm32l471xx.s'; '475'='startup_stm32l475xx.s'; '476'='startup_stm32l476xx.s'; '485'='startup_stm32l485xx.s'; '486'='startup_stm32l486xx.s'; '496'='startup_stm32l496xx.s'; '4A6'='startup_stm32l4a6xx.s' }
       Repo="STMicroelectronics/cmsis_device_l4"; RepoType="STM"
       StartupGlob="startup_stm32l476xx.s"; SystemFile="system_stm32l4xx.c"
       NeedsCmsis=$true
       FlashKB=1024; RamKB=128; FlashBase="0x08000000"; RamBase="0x20000000" },

    @{ Family="STM32H7xx  (Cortex-M7)";    Pattern="stm32h7"; Arch="ARM"
       CpuFlags="-mcpu=cortex-m7 -mthumb";    FloatABI="hard"; FpuFlags="-mfpu=fpv5-d16"
       Define="STM32H743xx"; Header="stm32h7xx.h"
       # H7 follows the generic STM32H<MMM>xx pattern. Dual-core variants (H745/
       # H747/H755/H757) build CM7 core only by default; override for CM4 if needed.
       DefineByModel  = @{ '723'='STM32H723xx'; '725'='STM32H725xx'; '730'='STM32H730xx'; '733'='STM32H733xx'; '735'='STM32H735xx'; '742'='STM32H742xx'; '743'='STM32H743xx'; '745'='STM32H745xx'; '747'='STM32H747xx'; '750'='STM32H750xx'; '753'='STM32H753xx'; '755'='STM32H755xx'; '757'='STM32H757xx'; '7A3'='STM32H7A3xx'; '7B0'='STM32H7B0xx'; '7B3'='STM32H7B3xx' }
       StartupByModel = @{ '723'='startup_stm32h723xx.s'; '725'='startup_stm32h725xx.s'; '730'='startup_stm32h730xx.s'; '733'='startup_stm32h733xx.s'; '735'='startup_stm32h735xx.s'; '742'='startup_stm32h742xx.s'; '743'='startup_stm32h743xx.s'; '745'='startup_stm32h745xx.s'; '747'='startup_stm32h747xx.s'; '750'='startup_stm32h750xx.s'; '753'='startup_stm32h753xx.s'; '755'='startup_stm32h755xx.s'; '757'='startup_stm32h757xx.s'; '7A3'='startup_stm32h7a3xx.s'; '7B0'='startup_stm32h7b0xx.s'; '7B3'='startup_stm32h7b3xx.s' }
       Repo="STMicroelectronics/cmsis_device_h7"; RepoType="STM"
       StartupGlob="startup_stm32h743xx.s"; SystemFile="system_stm32h7xx.c"
       NeedsCmsis=$true
       FlashKB=2048; RamKB=512; FlashBase="0x08000000"; RamBase="0x20000000" },

    # -- RISC-V WCH  (separate compiler: riscv-none-elf-gcc) ----
    @{ Family="CH32V003   (QingKe V2A, RV32EC)";       Pattern="ch32v003"; Arch="RISCV"
       CpuFlags="-march=rv32ec -mabi=ilp32e";           FloatABI=""; FpuFlags=""
       Define="CH32V00X"; Header="ch32v00x.h"
       Repo="openwch/ch32v003"; RepoType="WCH"
       StartupGlob="startup_ch32v00*.S"; SystemFile="system_ch32v00x.c"
       NeedsCmsis=$false
       FlashKB=16;   RamKB=2;   FlashBase="0x00000000"; RamBase="0x20000000" },

    @{ Family="CH32V10x   (QingKe V3A, RV32IMAC)";     Pattern="ch32v10"; Arch="RISCV"
       CpuFlags="-march=rv32imac -mabi=ilp32";          FloatABI=""; FpuFlags=""
       Define="CH32V10X"; Header="ch32v10x.h"
       Repo="openwch/ch32v103"; RepoType="WCH"
       StartupGlob="startup_ch32v10*.S"; SystemFile="system_ch32v10x.c"
       NeedsCmsis=$false
       FlashKB=128;  RamKB=20;  FlashBase="0x00000000"; RamBase="0x20000000" },

    @{ Family="CH32V20x   (QingKe V4B, RV32IMAC)";     Pattern="ch32v20"; Arch="RISCV"
       CpuFlags="-march=rv32imac -mabi=ilp32";          FloatABI=""; FpuFlags=""
       Define="CH32V20X"; Header="ch32v20x.h"
       Repo="openwch/ch32v20x"; RepoType="WCH"
       StartupGlob="startup_ch32v20*.S"; SystemFile="system_ch32v20x.c"
       NeedsCmsis=$false
       FlashKB=256;  RamKB=64;  FlashBase="0x00000000"; RamBase="0x20000000" },

    @{ Family="CH32V30x/V307 (QingKe V4F, RV32IMAFC)"; Pattern="ch32v3"; Arch="RISCV"
       CpuFlags="-march=rv32imafc -mabi=ilp32f";        FloatABI=""; FpuFlags=""
       Define="CH32V30X"; Header="ch32v30x.h"
       # RAM size depends on BOTH model and flash code:
       #   V303CB / V303RB (Flash B=128K): 32K SRAM (default)
       #   V303RC / V303VC (Flash C=256K): 64K SRAM (default)
       #   V305/V307: 64K SRAM regardless
       # Physical flash is 480K - the rest is "Extended SRAM zone" remappable
       # via User Option Bytes (288K code+32K SRAM, 192K+128K, etc.). Linker
       # script uses the default split; reflash OPT bytes to change it.
       RamByModel       = @{ '303'=32; '305'=64; '307'=64 }
       RamByFlashCode   = @{ 'B'=32;  'C'=64;  'D'=64 }
       # WCH ships TWO startup variants + matching ifdef blocks in ch32v30x.h.
       # Without an explicit CH32V30x_D8 / D8C define, ch32v30x.h falls back to
       # D8C (V307), which mis-initialises peripherals on a V303 chip. Pick the
       # right startup AND the right define from the model number.
       StartupByModel = @{ '303'='startup_ch32v30x_D8.S'; '305'='startup_ch32v30x_D8C.S'; '307'='startup_ch32v30x_D8C.S' }
       ExtraDefineByModel = @{ '303'='CH32V30x_D8'; '305'='CH32V30x_D8C'; '307'='CH32V30x_D8C' }
       Repo="openwch/ch32v307"; RepoType="WCH"
       StartupGlob="startup_ch32v30*.S"; SystemFile="system_ch32v30x.c"
       NeedsCmsis=$false
       FlashKB=128;  RamKB=32;  FlashBase="0x00000000"; RamBase="0x20000000" },

    @{ Family="CH32X035   (QingKe V4C, RV32IMAC)";     Pattern="ch32x0"; Arch="RISCV"
       CpuFlags="-march=rv32imac -mabi=ilp32";          FloatABI=""; FpuFlags=""
       Define="CH32X035"; Header="ch32x035.h"
       Repo="openwch/ch32x035"; RepoType="WCH"
       StartupGlob="startup_ch32x0*.S"; SystemFile="system_ch32x035.c"
       NeedsCmsis=$false
       FlashKB=62;   RamKB=20;  FlashBase="0x00000000"; RamBase="0x20000000" },

    @{ Family="CH32L103   (QingKe V4C, RV32IMAC)";     Pattern="ch32l1"; Arch="RISCV"
       CpuFlags="-march=rv32imac -mabi=ilp32";          FloatABI=""; FpuFlags=""
       Define="CH32L103"; Header="ch32l103.h"
       Repo="openwch/ch32l103"; RepoType="WCH"
       StartupGlob="startup_ch32l10*.S"; SystemFile="system_ch32l103.c"
       NeedsCmsis=$false
       FlashKB=128;  RamKB=20;  FlashBase="0x00000000"; RamBase="0x20000000" }
)

# ==============================================================
# Tool download catalog  (update URLs here when new versions release)
# ==============================================================
$TOOL_CATALOG = @{
    ARM_GCC = @{
        Name     = "arm-none-eabi-gcc 14.2"
        Url      = "https://developer.arm.com/-/media/Files/downloads/gnu/14.2.rel1/binrel/arm-gnu-toolchain-14.2.rel1-mingw-w64-i686-arm-none-eabi.zip"
        DestDir  = "$SharedDir\arm-none-eabi"
        CheckExe = "arm-none-eabi-gcc.exe"
        Prefix   = "arm-none-eabi-"
        GlobName = "arm-gnu*"
        DlMB     = 155
        DiskMB   = 500
        GdbEntry = "bin/arm-none-eabi-gdb.exe"  # zip path; update together with Url if upgrading
    }
    RISCV_GCC = @{
        Name     = "riscv-none-elf-gcc 14.2 (xpack)"
        Url      = "https://github.com/xpack-dev-tools/riscv-none-elf-gcc-xpack/releases/download/v14.2.0-3/xpack-riscv-none-elf-gcc-14.2.0-3-win32-x64.zip"
        DestDir  = "$SharedDir\riscv-none-elf"
        CheckExe = "riscv-none-elf-gcc.exe"
        Prefix   = "riscv-none-elf-"
        GlobName = "xpack-riscv*"
        DlMB     = 100
        DiskMB   = 350
    }
    CMAKE = @{
        Name     = "CMake 3.30.2"
        Url      = "https://github.com/Kitware/CMake/releases/download/v3.30.2/cmake-3.30.2-windows-x86_64.zip"
        DestDir  = "$SharedDir\cmake"
        CheckExe = "cmake.exe"
        GlobName = "cmake*"
        DlMB     = 50
        DiskMB   = 170
    }
    NINJA = @{
        Name     = "Ninja 1.12.1"
        Url      = "https://github.com/ninja-build/ninja/releases/download/v1.12.1/ninja-win.zip"
        DestDir  = "$SharedDir\ninja"
        CheckExe = "ninja.exe"
        GlobName = $null   # ninja zip has no sub-folder, just ninja.exe
        DlMB     = 1
        DiskMB   = 1
    }
    OPENOCD = @{
        Name     = "xpack-openocd 0.12.0-7"  # ARM (STM32, GD32, LPC, ...) — standard
        Url      = "https://github.com/xpack-dev-tools/openocd-xpack/releases/download/v0.12.0-7/xpack-openocd-0.12.0-7-win32-x64.zip"
        DestDir  = "$SharedDir\openocd"
        CheckExe = "openocd.exe"
        GlobName = "xpack-openocd*"
        DlMB     = 31
        DiskMB   = 95
    }
    # WCH-OpenOCD: fork with CH32V RISC-V support (also handles ARM targets).
    # Bundled with MounRiver Studio — searched there first (see $ocdWchDirs below).
    # If you have a standalone zip, set Url and DestDir accordingly.
    OPENOCD_WCH = @{
        Name     = "WCH-OpenOCD (from MounRiver Studio)"  # CH32V RISC-V + ARM
        Url      = ''   # no portable zip release; installed via MounRiver Studio
        DestDir  = "$SharedDir\openocd-wch"
        CheckExe = "openocd.exe"
        GlobName = $null
        DlMB     = 0
        DiskMB   = 0
    }
}

# ==============================================================
# Helper functions
# ==============================================================
function Find-ExeInDirs {
    param([string]$ExeName, [string[]]$Dirs)
    foreach ($d in $Dirs) {
        $p = Join-Path $d $ExeName
        if (Test-Path $p) { return $p }
    }
    $cmd = Get-Command $ExeName -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

# Returns all found instances: @( @{Bin=...; Prefix=...}, ... )
function Find-AllCompilers {
    param([string]$Arch, [string[]]$ArmDirs, [string[]]$RiscvDirs)
    $found = [System.Collections.Generic.List[hashtable]]::new()
    $seen  = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    if ($Arch -eq 'ARM') {
        # Dynamic scan: pick up any gcc placed by EIDE or other IDEs under ~\.eide\tools\
        $extraDirs = @()
        $eideRoot = Join-Path $HOME '.eide\tools'
        if (Test-Path $eideRoot) {
            Get-ChildItem $eideRoot -Recurse -Filter 'arm-none-eabi-gcc.exe' -EA SilentlyContinue |
                ForEach-Object { $extraDirs += $_.DirectoryName }
        }
        $allArmDirs = @($ArmDirs) + $extraDirs
        $candidates = @( @{ Exe='arm-none-eabi-gcc.exe'; Prefix='arm-none-eabi-'; Dirs=$allArmDirs } )
    } else {
        $candidates = @(
            @{ Exe='riscv-none-elf-gcc.exe'; Prefix='riscv-none-elf-'; Dirs=$RiscvDirs },
            @{ Exe='riscv-wch-elf-gcc.exe';  Prefix='riscv-wch-elf-';  Dirs=$RiscvDirs }
        )
    }

    foreach ($c in $candidates) {
        # 1) Search known directories
        foreach ($d in $c.Dirs) {
            if (-not $d) { continue }
            $p = Join-Path $d $c.Exe
            if ((Test-Path $p) -and $seen.Add($d)) {
                $found.Add(@{ Bin=$d; Prefix=$c.Prefix })
            }
        }
        # 2) Search PATH (handles tools added by IDEs to the terminal environment)
        $cmds = @(Get-Command $c.Exe -CommandType Application -ErrorAction SilentlyContinue)
        foreach ($cmd in $cmds) {
            if (-not $cmd.Source) { continue }
            $b = Split-Path $cmd.Source
            if ($b -and $seen.Add($b)) { $found.Add(@{ Bin=$b; Prefix=$c.Prefix }) }
        }
    }

    # Safety: drop any entries that somehow ended up with empty Bin
    return @($found | Where-Object { $_.Bin })
}

function Get-FreeDiskMB {
    param([string]$ForPath)
    $dir = $ForPath
    while ($dir -and -not (Test-Path $dir)) { $dir = Split-Path $dir }
    if (-not $dir) { return 999999 }
    try {
        $drv = (Get-Item $dir -Force).PSDrive
        return [math]::Floor($drv.Free / 1MB)
    } catch { return 999999 }
}

function Invoke-ExtractTool {
    param([hashtable]$Tool, [string]$ZipFile)
    $tmp = Join-Path $env:TEMP "mcu_extract"
    Remove-Item $tmp -Recurse -EA SilentlyContinue
    Write-Host "  Extracting..." -ForegroundColor DarkCyan
    Expand-Archive $ZipFile $tmp -Force
    Remove-Item $ZipFile -EA SilentlyContinue

    if ($null -ne $Tool.GlobName) {
        $sub = Get-ChildItem $tmp -Directory | Select-Object -First 1
        if ($sub) {
            if (Test-Path $Tool.DestDir) { Remove-Item $Tool.DestDir -Recurse -Force }
            Move-Item $sub.FullName $Tool.DestDir
        }
    } else {
        New-Item -ItemType Directory -Path $Tool.DestDir -Force | Out-Null
        Get-ChildItem $tmp | Move-Item -Destination $Tool.DestDir -Force
    }
    Remove-Item $tmp -Recurse -EA SilentlyContinue
}

# Extract a single file from a remote ZIP using HTTP Range requests.
# Downloads only: tail (EOCD) + central directory + compressed entry — typically 5-15 MB total
# instead of the full archive. No hardcoded byte offsets — parses the ZIP on every run.
function Invoke-ExtractFromZip {
    param([string]$ZipUrl, [string]$EntryName, [string]$DestFile)
    $WebReq = {
        param($u, $from, $to)
        $r = [System.Net.HttpWebRequest]::Create($u)
        $r.UserAgent = "Mozilla/5.0 (setup.ps1)"
        if ($null -ne $from) { $r.AddRange([long]$from, [long]$to) }
        $r.GetResponse()
    }
    # 1. ZIP total size
    $r0 = [System.Net.HttpWebRequest]::Create($ZipUrl)
    $r0.Method = "HEAD"; $r0.UserAgent = "Mozilla/5.0 (setup.ps1)"
    $rs0 = $r0.GetResponse(); $zipSize = $rs0.ContentLength; $rs0.Close()
    # 2. Last 10 MB — contains EOCD and often the entire central directory
    $tailStart = $zipSize - 10MB
    $rs1 = (& $WebReq $ZipUrl $tailStart ($zipSize - 1)).GetResponseStream()
    $tail = [byte[]]::new(10MB + 512); $n = 0
    while ($true) { $c = $rs1.Read($tail, $n, $tail.Length - $n); if ($c -le 0) { break }; $n += $c }
    $rs1.Close(); $tail = $tail[0..($n-1)]
    # 3. Find EOCD32 -> central directory offset + size
    $cdOff = 0L; $cdSz = 0
    for ($i = $tail.Length - 22; $i -ge 0; $i--) {
        if ($tail[$i] -eq 0x50 -and $tail[$i+1] -eq 0x4B -and $tail[$i+2] -eq 0x05 -and $tail[$i+3] -eq 0x06) {
            $cdOff = [BitConverter]::ToUInt32($tail, $i + 16)
            $cdSz  = [BitConverter]::ToUInt32($tail, $i + 12)
            break
        }
    }
    if (-not $cdOff) { throw "ZIP EOCD not found in last 10 MB" }
    # 4. Central directory: use tail if it covers it, else download separately
    $cdBufOff = $cdOff - ($zipSize - $tail.Length)
    if ($cdBufOff -ge 0 -and $cdBufOff + $cdSz -le $tail.Length) {
        $cd = $tail[$cdBufOff..($cdBufOff + $cdSz - 1)]
    } else {
        $rs2 = (& $WebReq $ZipUrl $cdOff ($cdOff + $cdSz - 1)).GetResponseStream()
        $cd = [byte[]]::new($cdSz); $n = 0
        while ($n -lt $cdSz) { $c = $rs2.Read($cd, $n, $cdSz - $n); if ($c -le 0) { break }; $n += $c }
        $rs2.Close()
    }
    # 5. Scan central directory for the requested entry
    $lfhOff = 0L; $compSz = 0; $pos = 0
    while ($pos -lt $cd.Length - 4) {
        if ($cd[$pos] -ne 0x50 -or $cd[$pos+1] -ne 0x4B -or $cd[$pos+2] -ne 0x01 -or $cd[$pos+3] -ne 0x02) { break }
        $fnLen = [BitConverter]::ToUInt16($cd, $pos + 28)
        $exLen = [BitConverter]::ToUInt16($cd, $pos + 30)
        $cmLen = [BitConverter]::ToUInt16($cd, $pos + 32)
        $fn    = [System.Text.Encoding]::ASCII.GetString($cd, $pos + 46, $fnLen)
        if ($fn -eq $EntryName) {
            $compSz = [BitConverter]::ToUInt32($cd, $pos + 20)
            $lfhOff = [BitConverter]::ToUInt32($cd, $pos + 42)
            break
        }
        $pos += 46 + $fnLen + $exLen + $cmLen
    }
    if (-not $lfhOff) { throw "Entry '$EntryName' not found in ZIP" }
    # 6. Read local file header to find exact data start
    $rs3 = (& $WebReq $ZipUrl $lfhOff ($lfhOff + 300)).GetResponseStream()
    $lfh = [byte[]]::new(300); $n = 0
    while ($n -lt 300) { $c = $rs3.Read($lfh, $n, 300 - $n); if ($c -le 0) { break }; $n += $c }
    $rs3.Close()
    $dataStart = $lfhOff + 30 + [BitConverter]::ToUInt16($lfh, 26) + [BitConverter]::ToUInt16($lfh, 28)
    # 7. Stream compressed data through DeflateStream directly to disk
    $rs4 = (& $WebReq $ZipUrl $dataStart ($dataStart + $compSz - 1)).GetResponseStream()
    New-Item -ItemType Directory (Split-Path $DestFile) -Force | Out-Null
    $def  = [System.IO.Compression.DeflateStream]::new($rs4, [System.IO.Compression.CompressionMode]::Decompress)
    $outF = [System.IO.FileStream]::new($DestFile, [System.IO.FileMode]::Create)
    $def.CopyTo($outF)
    $outF.Close(); $def.Close(); $rs4.Close()
}

# Streaming HTTP download with real-time progress bar.
# Works with any URL (handles redirects). No dependency on Invoke-WebRequest.
function Invoke-Download {
    param([string]$Url, [string]$Dest)
    $req = [System.Net.HttpWebRequest]::Create($Url)
    $req.UserAgent = "Mozilla/5.0 (setup.ps1)"
    $req.Timeout   = 30000      # 30 s connect
    $req.ReadWriteTimeout = 600000  # 10 min data
    $resp   = $req.GetResponse()
    $total  = $resp.ContentLength  # -1 if unknown
    $inStr  = $resp.GetResponseStream()
    $outStr = [System.IO.File]::Create($Dest)
    $buf    = New-Object byte[] 65536
    $read   = 0; $chunk = 0
    $sw     = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        while (($chunk = $inStr.Read($buf, 0, $buf.Length)) -gt 0) {
            $outStr.Write($buf, 0, $chunk)
            $read += $chunk
            if ($sw.ElapsedMilliseconds -ge 200) {
                $sw.Restart()
                $mb = [math]::Round($read / 1MB, 1)
                if ($total -gt 0) {
                    $pct  = [int]([math]::Min($read * 100 / $total, 100))
                    $fill = [int]($pct / 2)
                    $bar  = ('#' * $fill) + ('-' * (50 - $fill))
                    $tot  = [math]::Round($total / 1MB, 1)
                    Write-Host ("`r  [{0}] {1,3}%  {2:N1} / {3:N1} MB" -f $bar, $pct, $mb, $tot) -NoNewline
                } else {
                    Write-Host ("`r  {0:N1} MB..." -f $mb) -NoNewline
                }
            }
        }
    } finally {
        $outStr.Close(); $inStr.Close(); $resp.Close()
        Write-Host ("`r" + (' ' * 78) + "`r") -NoNewline  # clear progress line
    }
}

# Generates mcu.ld content for the selected MCU architecture and memory layout.
function New-LinkerScript {
    param(
        [string]$Arch,
        [string]$FlashBase, [int]$FlashKB,
        [string]$RamBase,   [int]$RamKB
    )

    if ($Arch -eq "ARM") {
        return @"
/* Auto-generated by setup.ps1 - do not edit manually. Re-run setup.ps1 to regenerate. */
/* Flash: ${FlashKB}K @ $FlashBase  |  RAM: ${RamKB}K @ $RamBase */

ENTRY(Reset_Handler)

_Min_Heap_Size  = 0x200;
_Min_Stack_Size = 0x400;

_estack = ORIGIN(RAM) + LENGTH(RAM);

MEMORY
{
  FLASH (rx)  : ORIGIN = $FlashBase, LENGTH = ${FlashKB}K
  RAM   (rwx) : ORIGIN = $RamBase,   LENGTH = ${RamKB}K
}

SECTIONS
{
  .isr_vector :
  {
    . = ALIGN(4);
    KEEP(*(.isr_vector))
    . = ALIGN(4);
  } >FLASH

  .text :
  {
    . = ALIGN(4);
    *(.text)
    *(.text*)
    *(.glue_7)
    *(.glue_7t)
    *(.eh_frame)
    KEEP(*(.init))
    KEEP(*(.fini))
    . = ALIGN(4);
    _etext = .;
  } >FLASH

  .rodata :
  {
    . = ALIGN(4);
    *(.rodata)
    *(.rodata*)
    . = ALIGN(4);
  } >FLASH

  .ARM.extab : { *(.ARM.extab* .gnu.linkonce.armextab.*) } >FLASH
  .ARM :
  {
    __exidx_start = .;
    *(.ARM.exidx*)
    __exidx_end = .;
  } >FLASH

  .preinit_array :
  {
    PROVIDE_HIDDEN (__preinit_array_start = .);
    KEEP (*(.preinit_array*))
    PROVIDE_HIDDEN (__preinit_array_end = .);
  } >FLASH

  .init_array :
  {
    PROVIDE_HIDDEN (__init_array_start = .);
    KEEP (*(SORT(.init_array.*)))
    KEEP (*(.init_array*))
    PROVIDE_HIDDEN (__init_array_end = .);
  } >FLASH

  .fini_array :
  {
    PROVIDE_HIDDEN (__fini_array_start = .);
    KEEP (*(SORT(.fini_array.*)))
    KEEP (*(.fini_array*))
    PROVIDE_HIDDEN (__fini_array_end = .);
  } >FLASH

  _sidata = LOADADDR(.data);

  .data :
  {
    . = ALIGN(4);
    _sdata = .;
    *(.data)
    *(.data*)
    . = ALIGN(4);
    _edata = .;
  } >RAM AT> FLASH

  .bss :
  {
    . = ALIGN(4);
    _sbss = .;
    __bss_start__ = _sbss;
    *(.bss)
    *(.bss*)
    *(COMMON)
    . = ALIGN(4);
    _ebss = .;
    __bss_end__ = _ebss;
  } >RAM

  ._user_heap_stack :
  {
    . = ALIGN(8);
    PROVIDE ( end = . );
    PROVIDE ( _end = . );
    . = . + _Min_Heap_Size;
    . = . + _Min_Stack_Size;
    . = ALIGN(8);
  } >RAM

  .ARM.attributes 0 : { *(.ARM.attributes) }
}
"@
    } else {
        # RISC-V WCH style
        return @"
/* Auto-generated by setup.ps1 - do not edit manually. Re-run setup.ps1 to regenerate. */
/* Flash: ${FlashKB}K @ $FlashBase  |  RAM: ${RamKB}K @ $RamBase */

ENTRY( _start )

__stack_size = 0x800;

PROVIDE( _stack_size = __stack_size );

MEMORY
{
    FLASH (rx)  : ORIGIN = $FlashBase, LENGTH = ${FlashKB}K
    RAM   (xrw) : ORIGIN = $RamBase,   LENGTH = ${RamKB}K
}

SECTIONS
{
    .init :
    {
        _sinit = .;
        . = ALIGN(4);
        KEEP(*(SORT_NONE(.init)))
        . = ALIGN(4);
        _einit = .;
    } >FLASH AT>FLASH

    .vector :
    {
        *(.vector);
        . = ALIGN(64);
    } >FLASH AT>FLASH

    .text :
    {
        . = ALIGN(4);
        *(.text)
        *(.text.*)
        *(.rodata)
        *(.rodata*)
        *(.gnu.linkonce.t.*)
        . = ALIGN(4);
    } >FLASH AT>FLASH

    .fini :
    {
        KEEP(*(SORT_NONE(.fini)))
        . = ALIGN(4);
    } >FLASH AT>FLASH

    PROVIDE( _etext = . );
    PROVIDE( _eitcm = . );

    .preinit_array :
    {
        PROVIDE_HIDDEN (__preinit_array_start = .);
        KEEP (*(.preinit_array))
        PROVIDE_HIDDEN (__preinit_array_end = .);
    } >FLASH AT>FLASH

    .init_array :
    {
        PROVIDE_HIDDEN (__init_array_start = .);
        KEEP (*(SORT_BY_INIT_PRIORITY(.init_array.*) SORT_BY_INIT_PRIORITY(.ctors.*)))
        KEEP (*(.init_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o ) .ctors))
        PROVIDE_HIDDEN (__init_array_end = .);
    } >FLASH AT>FLASH

    .fini_array :
    {
        PROVIDE_HIDDEN (__fini_array_start = .);
        KEEP (*(SORT_BY_INIT_PRIORITY(.fini_array.*) SORT_BY_INIT_PRIORITY(.dtors.*)))
        KEEP (*(.fini_array EXCLUDE_FILE (*crtbegin.o *crtbegin?.o *crtend.o *crtend?.o ) .dtors))
        PROVIDE_HIDDEN (__fini_array_end = .);
    } >FLASH AT>FLASH

    .dalign :
    {
        . = ALIGN(4);
        PROVIDE(_data_vma = .);
    } >RAM AT>FLASH

    .dlalign :
    {
        . = ALIGN(4);
        PROVIDE(_data_lma = .);
    } >FLASH AT>FLASH

    .data :
    {
        *(.gnu.linkonce.r.*)
        *(.data .data.*)
        *(.gnu.linkonce.d.*)
        . = ALIGN(8);
        PROVIDE( __global_pointer$ = . + 0x800 );
        *(.sdata .sdata.*)
        *(.sdata2.*)
        *(.gnu.linkonce.s.*)
        . = ALIGN(8);
        *(.srodata.cst16)
        *(.srodata.cst8)
        *(.srodata.cst4)
        *(.srodata.cst2)
        *(.srodata .srodata.*)
        . = ALIGN(4);
        PROVIDE( _edata = .);
    } >RAM AT>FLASH

    .bss :
    {
        . = ALIGN(4);
        PROVIDE( _sbss = .);
        *(.sbss*)
        *(.gnu.linkonce.sb.*)
        *(.bss*)
        *(.gnu.linkonce.b.*)
        *(COMMON*)
        . = ALIGN(4);
        PROVIDE( _ebss = .);
    } >RAM AT>FLASH

    PROVIDE( _end = _ebss );
    PROVIDE( end = . );

    .stack ORIGIN(RAM) + LENGTH(RAM) - __stack_size :
    {
        PROVIDE( _heap_end = . );
        . = ALIGN(4);
        PROVIDE( _susrstack = . );
        . = . + __stack_size;
        PROVIDE( _eusrstack = . );
    } >RAM
}
"@
    }
}

# ==============================================================
# STEP 0: Check for VS Code and extensions (install if missing)
# Results are collected into $vscodePath / $extStatus for display in STEP 2.
# ==============================================================
$neededExts = @('ms-vscode.cpptools', 'marus25.cortex-debug', 'mcu-debug.peripheral-viewer', 'eclipse-cdt.peripheral-inspector', 'actboy168.tasks')
$extStatus  = @{}  # 'found' | 'installed' | 'missing'

function Find-VsCode {
    # Must return path to bin\code.cmd - the CLI wrapper that understands
    # --install-extension. Code.exe is the GUI binary; on Windows it sits in
    # the install root and Get-Command picks it first via PATHEXT, but it
    # rejects every CLI flag with "bad option". So we always look for the
    # adjacent bin\code.cmd explicitly.
    $c = Get-Command code -EA SilentlyContinue
    if ($c -and $c.Source -match '\.(cmd|bat)$') { return $c.Source }
    # Try to derive bin\code.cmd from whatever Get-Command found (Code.exe),
    # then fall back to the standard install locations.
    if ($c) {
        $cand = Join-Path (Split-Path $c.Source) 'bin\code.cmd'
        if (Test-Path $cand) { return $cand }
    }
    foreach ($p in @(
        "$env:LOCALAPPDATA\Programs\Microsoft VS Code\bin\code.cmd"
        "$env:ProgramFiles\Microsoft VS Code\bin\code.cmd"
        "${env:ProgramFiles(x86)}\Microsoft VS Code\bin\code.cmd"
    )) { if (Test-Path $p) { return $p } }
    return $null
}

$vscodePath = Find-VsCode
if (-not $vscodePath) {
    Write-Host ""
    Write-Host "  VS Code is not installed on this PC." -ForegroundColor Yellow
    $ans = Read-Host "  Install VS Code now? [Y/n]"
    if ($ans -eq '' -or $ans -match '^[Yy]') {
        $winget = Get-Command winget -EA SilentlyContinue
        if ($winget) {
            Write-Host "  Installing VS Code via winget..." -ForegroundColor Cyan
            & winget install -e --id Microsoft.VisualStudioCode `
                --accept-source-agreements --accept-package-agreements
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  VS Code installed. Restart this terminal once for 'code' to work." -ForegroundColor Green
            } else {
                Write-Host "  winget returned exit code $LASTEXITCODE." -ForegroundColor Yellow
                Write-Host "  If VS Code did not install, download it from: https://code.visualstudio.com" -ForegroundColor Yellow
            }
        } else {
            Write-Host "  winget is not available on this PC." -ForegroundColor Yellow
            Write-Host "  Download VS Code from: https://code.visualstudio.com/download" -ForegroundColor Cyan
            Read-Host "  Press Enter to continue after installing"
        }
    } else {
        Write-Host "  Skipping. Install VS Code later from https://code.visualstudio.com" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# Re-detect after potential install, then install only missing extensions.
if (-not $vscodePath) { $vscodePath = Find-VsCode }
if ($vscodePath) {
    $vsInstalled = @(& $vscodePath --list-extensions 2>$null)
    $vsMissing   = $neededExts | Where-Object { $_ -notin $vsInstalled }
    foreach ($ext in $neededExts) {
        $extStatus[$ext] = if ($ext -in $vsInstalled) { 'found' } else { 'missing' }
    }
    if ($vsMissing) {
        Write-Host ""
        Write-Host "  Installing missing VS Code extensions..." -ForegroundColor Cyan
        foreach ($ext in $vsMissing) {
            Write-Host ("  Installing: {0}" -f $ext) -ForegroundColor DarkGray
            & $vscodePath --install-extension $ext
            $extStatus[$ext] = 'installed'
        }
        Write-Host ""
    }
} else {
    foreach ($ext in $neededExts) { $extStatus[$ext] = 'missing' }
}

# ==============================================================
# STEP 1: Select MCU
# ==============================================================
Write-Host ""
Write-Host "Supported MCU families:" -ForegroundColor Cyan
for ($idx = 0; $idx -lt $MCU_DB.Count; $idx++) {
    Write-Host ("  [{0,2}] {1}" -f ($idx + 1), $MCU_DB[$idx].Family)
}
Write-Host ""
Write-Host "Enter number, family name, or full part number  [Enter = 2]:" -ForegroundColor Yellow
Write-Host "  e.g.:  2  |  stm32f1  |  STM32F103C8T6  |  CH32V303CBT6" -ForegroundColor DarkGray
$userInput = Read-Host
if ([string]::IsNullOrWhiteSpace($userInput)) { $userInput = '2' }

$mcu = $null
if ($userInput -match "^\d+$") {
    $n = [int]$userInput - 1
    if ($n -ge 0 -and $n -lt $MCU_DB.Count) { $mcu = $MCU_DB[$n] }
} else {
    $low = $userInput.ToLower()
    $mcu = $MCU_DB | Where-Object { $low -match $_.Pattern } | Select-Object -First 1
}

if (-not $mcu) {
    Write-Host "MCU '$userInput' not found. Add it to MCU_DB in setup.ps1." -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host ("  Selected : {0}" -f $mcu.Family) -ForegroundColor Green
Write-Host ("  Arch     : {0}" -f $mcu.Arch)
Write-Host ("  Flags    : {0}" -f $mcu.CpuFlags)

# -- Memory size: auto-detect from full part number, or ask manually --
# Memory codes are the same across STM32 and CH32V:
#   4=16K  6=32K  8=64K  B=128K  C=256K  D=384K  E=512K  F=768K  G=1024K
$FLASH_CODES = @{ '4'=16; '6'=32; '8'=64; 'B'=128; 'C'=256; 'D'=384; 'E'=512; 'F'=768; 'G'=1024 }
$flashKB        = $mcu.FlashKB
$ramKB          = $mcu.RamKB
$flashBase      = $mcu.FlashBase
$ramBase        = $mcu.RamBase
$mcuDefine      = $mcu.Define
$mcuExtraDefine = ''                  # secondary chip-variant define (e.g. CH32V30x_D8 vs D8C)
$mcuStartupGlob = $mcu.StartupGlob

Write-Host ""
# Regex: STM32/CH32 prefix + 1 family letter + 3 model digits + package letter + flash code
# e.g. STM32F103C8T6: F=family, 103=model, C=package, 8=flash  |  CH32V303CBT6: V, 303, C, B
if ($userInput -match '^(?:STM32|CH32)\w(\d{3})[A-Za-z]([468BCDEFGbcdefg])') {
    $modelCode = $Matches[1]
    $memCode   = $Matches[2].ToUpper()   # normalize: 'b' -> 'B' for hashtable lookup
    $flashKB   = $FLASH_CODES[$memCode]
    # Flash-code override (single-model families like STM32F1: 4/6 -> x6, 8/B -> xB).
    if ($mcu.DefineByFlashCode -and $mcu.DefineByFlashCode.ContainsKey($memCode)) {
        $mcuDefine = $mcu.DefineByFlashCode[$memCode]
    }
    if ($mcu.StartupByFlashCode -and $mcu.StartupByFlashCode.ContainsKey($memCode)) {
        $mcuStartupGlob = $mcu.StartupByFlashCode[$memCode]
    }
    # Model-code override (multi-model families like STM32F4/G4/L4/H7).
    if ($mcu.DefineByModel -and $mcu.DefineByModel.ContainsKey($modelCode)) {
        $mcuDefine = $mcu.DefineByModel[$modelCode]
    }
    if ($mcu.StartupByModel -and $mcu.StartupByModel.ContainsKey($modelCode)) {
        $mcuStartupGlob = $mcu.StartupByModel[$modelCode]
    }
    # Model+flash combined override - for parts like STM32F401 / STM32F411 where the
    # define depends on BOTH the model and the flash density (xC <=256K, xE >=384K).
    # Key format: "<modelCode>_<memCode>" e.g. "401_E", "411_C".
    $mfKey = "${modelCode}_${memCode}"
    if ($mcu.DefineByModelFlash -and $mcu.DefineByModelFlash.ContainsKey($mfKey)) {
        $mcuDefine = $mcu.DefineByModelFlash[$mfKey]
    }
    if ($mcu.StartupByModelFlash -and $mcu.StartupByModelFlash.ContainsKey($mfKey)) {
        $mcuStartupGlob = $mcu.StartupByModelFlash[$mfKey]
    }
    # RAM: Model baseline first, then FlashCode override.
    # Order matters - e.g. CH32V303 needs 32K (RamByModel default), but
    # V303RC/VC variants (flash C=256K) bump to 64K via RamByFlashCode.
    if ($mcu.RamByModel -and $mcu.RamByModel.ContainsKey($modelCode)) {
        $ramKB = $mcu.RamByModel[$modelCode]
    }
    if ($mcu.RamByFlashCode -and $mcu.RamByFlashCode.ContainsKey($memCode)) {
        $ramKB = $mcu.RamByFlashCode[$memCode]
    }
    # Auto-detect chip-variant secondary define from model number.
    # Example: CH32V303 needs CH32V30x_D8 + startup_ch32v30x_D8.S, CH32V307 needs
    # CH32V30x_D8C + startup_ch32v30x_D8C.S. Without this the vendor header falls
    # back to D8C and a V303 board mis-initialises its peripherals.
    if ($mcu.ExtraDefineByModel -and $mcu.ExtraDefineByModel.ContainsKey($modelCode)) {
        $mcuExtraDefine = $mcu.ExtraDefineByModel[$modelCode]
    }
    Write-Host ("  Flash    :  {0,5} KB  (code '{1}' from part number)" -f $flashKB, $memCode) -ForegroundColor Cyan
    Write-Host ("  RAM      :  {0,5} KB  (model '{1}' detected)"        -f $ramKB, $modelCode)  -ForegroundColor Cyan
    Write-Host ("  Define   :  {0}{1}" -f $mcuDefine, $(if ($mcuExtraDefine) { " + $mcuExtraDefine" } else { "" })) -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Override Flash KB? [Enter = keep $flashKB]:" -ForegroundColor Yellow
    $ov = Read-Host
    if ($ov -match "^\d+$") { $flashKB = [int]$ov; Write-Host ("  Flash set to {0} KB" -f $flashKB) -ForegroundColor Green }
    Write-Host "Override RAM KB?   [Enter = keep $ramKB]:" -ForegroundColor Yellow
    $ov = Read-Host
    if ($ov -match "^\d+$") { $ramKB = [int]$ov; Write-Host ("  RAM set to {0} KB" -f $ramKB) -ForegroundColor Green }
} else {
    Write-Host ("  Flash    :  {0,5} KB  @  {1}" -f $flashKB, $flashBase) -ForegroundColor Cyan
    Write-Host ("  RAM      :  {0,5} KB  @  {1}" -f $ramKB,   $ramBase)   -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Tip: type full part number (e.g. STM32F103C8T6) for auto Flash+Define detect" -ForegroundColor DarkGray
    Write-Host "Override Flash KB? [Enter = keep $flashKB]:" -ForegroundColor Yellow
    $ov = Read-Host
    if ($ov -match "^\d+$") { $flashKB = [int]$ov; Write-Host ("  Flash set to {0} KB" -f $flashKB) -ForegroundColor Green }
    Write-Host "Override RAM KB?   [Enter = keep $ramKB]:" -ForegroundColor Yellow
    $ov = Read-Host
    if ($ov -match "^\d+$") { $ramKB = [int]$ov; Write-Host ("  RAM set to {0} KB" -f $ramKB) -ForegroundColor Green }
}

$gccKey  = if ($mcu.Arch -eq "ARM") { "ARM_GCC" } else { "RISCV_GCC" }
$gccTool = $TOOL_CATALOG[$gccKey]

# ==============================================================
# STEP 2: Search for existing tools on this computer
# ==============================================================
Write-Host ""
Write-Host "Searching for existing tools..." -ForegroundColor Cyan

$armDirs   = @( "$SharedDir\arm-none-eabi\bin",
                "$HOME\.eide\tools\gcc_arm\bin",
                "C:\Program Files (x86)\GNU Arm Embedded Toolchain\bin",
                "C:\Program Files\GNU Arm Embedded Toolchain\bin",
                "C:\ProgramData\chocolatey\lib\gcc-arm-embedded\tools\gcc-arm-none-eabi\bin" )

$riscvDirs = @( "$SharedDir\riscv-none-elf\bin",
                "C:\MounRiver\MounRiver_Studio2\resources\app\resources\win32\components\WCH\Toolchain\RISC-V Embedded GCC12\bin",
                "C:\MounRiver\MounRiver_Studio\resources\app\resources\win32\components\WCH\Toolchain\RISC-V Embedded GCC12\bin" )

$cmakeDirs = @( "$SharedDir\cmake\bin",
                "C:\Program Files\CMake\bin",
                "C:\Program Files (x86)\CMake\bin",
                "C:\ProgramData\chocolatey\lib\cmake\tools\install\bin" )

$ninjaDirs = @( "$SharedDir\ninja",
                "C:\ProgramData\chocolatey\lib\ninja\tools" )

# xpack-OpenOCD search dirs (ARM)
$ocdDirs   = @( "$SharedDir\openocd\bin",
                "C:\Program Files\OpenOCD\bin",
                "C:\OpenOCD\bin" )
# WCH-OpenOCD search dirs (RISC-V) — MounRiver Studio installs here
$ocdWchDirs = @( "$SharedDir\openocd-wch\bin",
                 "C:\MounRiver\MounRiver_Studio2\toolchain\OpenOCD\bin",
                 "C:\MounRiver\MounRiver_Studio\toolchain\OpenOCD\bin",
                 "C:\MounRiver\MounRiver_Studio2\resources\app\resources\win32\components\WCH\OpenOCD\bin",
                 "C:\MounRiver\MounRiver_Studio\resources\app\resources\win32\components\WCH\OpenOCD\bin" )

$cmakeExe  = Find-ExeInDirs "cmake.exe"   $cmakeDirs
$ninjaExe  = Find-ExeInDirs "ninja.exe"   $ninjaDirs
$ocdExe    = Find-ExeInDirs "openocd.exe" $ocdDirs
$ocdWchExe = Find-ExeInDirs "openocd.exe" $ocdWchDirs

$allGcc   = @(Find-AllCompilers -Arch $mcu.Arch -ArmDirs $armDirs -RiscvDirs $riscvDirs)
$gccBin   = $null
$gccPrefix= $null

$fmtOK   = "  [FOUND ]  {0,-22}  {1}"
$fmtMiss = "  [MISS  ]  {0,-22}  will download to shared folder"

if ($allGcc.Count -eq 0) {
    Write-Host ($fmtMiss -f "GCC ($($mcu.Arch))") -ForegroundColor Yellow
} elseif ($allGcc.Count -eq 1) {
    $gccBin = $allGcc[0].Bin; $gccPrefix = $allGcc[0].Prefix
    Write-Host ($fmtOK -f "GCC ($($mcu.Arch))", $gccBin) -ForegroundColor Green
} else {
    Write-Host ""
    Write-Host "  Found multiple compilers - choose one:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $allGcc.Count; $i++) {
        Write-Host ("  [{0}] {1}  ({2})" -f ($i + 1), $allGcc[$i].Bin, $allGcc[$i].Prefix)
    }
    Write-Host ("  [{0}] Skip all above, download new copy to $SharedDir" -f ($allGcc.Count + 1))
    Write-Host ("Choose compiler [Enter = 1]:") -ForegroundColor Yellow
    $pick = Read-Host
    if ($pick -match '^\d+$' -and [int]$pick -eq ($allGcc.Count + 1)) {
        # download requested - leave gccBin null
    } elseif ($pick -match '^\d+$' -and [int]$pick -ge 1 -and [int]$pick -le $allGcc.Count) {
        $n = [int]$pick - 1
        $gccBin = $allGcc[$n].Bin; $gccPrefix = $allGcc[$n].Prefix
    } else {
        $gccBin = $allGcc[0].Bin; $gccPrefix = $allGcc[0].Prefix
    }
    if ($gccBin) { Write-Host ("  Using: {0}" -f $gccBin) -ForegroundColor Green }
}

# Derive WCH-OpenOCD from GCC installation path (both live under MounRiver's WCH folder)
# GCC path example: ...\WCH\Toolchain\RISC-V Embedded GCC12\bin
# OCD path example: ...\WCH\OpenOCD\OpenOCD\bin\openocd.exe
if ($mcu.Arch -eq 'RISCV' -and -not $ocdWchExe -and $gccBin -and
    $gccBin -match '^(.+\\WCH)\\Toolchain\\') {
    $derived = Join-Path $Matches[1] "OpenOCD\OpenOCD\bin\openocd.exe"
    if (Test-Path $derived) { $ocdWchExe = $derived }
}

if ($cmakeExe) { Write-Host ($fmtOK   -f "CMake",   (Split-Path $cmakeExe)) -ForegroundColor Green  }
else           { Write-Host ($fmtMiss -f "CMake")                             -ForegroundColor Yellow }
if ($ninjaExe) { Write-Host ($fmtOK   -f "Ninja",   (Split-Path $ninjaExe)) -ForegroundColor Green  }
else           { Write-Host ($fmtMiss -f "Ninja")                             -ForegroundColor Yellow }
if ($mcu.Arch -eq 'ARM') {
    if ($ocdExe)    { Write-Host ($fmtOK   -f "OpenOCD (xpack)",   (Split-Path $ocdExe))    -ForegroundColor Green  }
    else            { Write-Host ($fmtMiss -f "OpenOCD (xpack)")                             -ForegroundColor Yellow }
} elseif ($mcu.Arch -eq 'RISCV') {
    if ($ocdWchExe) { Write-Host ($fmtOK   -f "OpenOCD (WCH)",    (Split-Path $ocdWchExe)) -ForegroundColor Green  }
    else {
        Write-Host "  [MISS  ]  OpenOCD (WCH)        not found!" -ForegroundColor Red
        Write-Host "  For RISC-V flashing you need WCH-OpenOCD, bundled with MounRiver Studio (free)." -ForegroundColor Yellow
        $ans = Read-Host "  Open MounRiver Studio download page now? [Y/n]"
        if ($ans -eq '' -or $ans -match '^[Yy]') {
            Start-Process "https://www.mounriver.com/download"
            Write-Host "  After installing MounRiver Studio, re-run setup.ps1 to enable flashing." -ForegroundColor Yellow
            Read-Host "  Press Enter to continue (project will be set up, flashing enabled after re-run)"
        } else {
            Write-Host "  Install MounRiver Studio later, then re-run setup.ps1 to enable flashing." -ForegroundColor DarkGray
        }
    }
}

# GDB debugger (ARM only — 14.2 no-Python build for instant startup)
if ($mcu.Arch -eq 'ARM') {
    $gdbCheckTc = "$SharedDir\arm-none-eabi\bin\arm-none-eabi-gdb.exe"
    $gdbCheckSt = "$SharedDir\gdb\arm-none-eabi-gdb.exe"
    if (Test-Path $gdbCheckTc) {
        Write-Host ($fmtOK -f "GDB (debugger)", (Split-Path $gdbCheckTc)) -ForegroundColor Green
    } elseif (Test-Path $gdbCheckSt) {
        Write-Host ($fmtOK -f "GDB (debugger)", (Split-Path $gdbCheckSt)) -ForegroundColor Green
    } else {
        Write-Host ("  [MISS  ]  {0,-22}  will download ~4 MB" -f "GDB (debugger)") -ForegroundColor Yellow
    }
}

# VS Code editor
if ($vscodePath) {
    Write-Host ($fmtOK -f "VS Code", (Split-Path $vscodePath)) -ForegroundColor Green
} else {
    Write-Host ($fmtMiss -f "VS Code") -ForegroundColor Yellow
}

# VS Code extensions
foreach ($ext in $neededExts) {
    $s = $extStatus[$ext]
    if ($s -eq 'found') {
        Write-Host ($fmtOK -f $ext, "already installed") -ForegroundColor Green
    } elseif ($s -eq 'installed') {
        Write-Host ($fmtOK -f $ext, "just installed") -ForegroundColor Green
    } else {
        Write-Host ($fmtMiss -f $ext) -ForegroundColor Yellow
    }
}

# ==============================================================
# STEP 3: Build download plan and confirm
# ==============================================================
$downloads = [System.Collections.Generic.List[hashtable]]::new()
if (-not $gccBin)   { $downloads.Add(@{ Key="gcc";   Tool=$gccTool }) }
if (-not $cmakeExe) { $downloads.Add(@{ Key="cmake"; Tool=$TOOL_CATALOG.CMAKE }) }
if (-not $ninjaExe) { $downloads.Add(@{ Key="ninja"; Tool=$TOOL_CATALOG.NINJA }) }
if ($mcu.Arch -eq 'ARM' -and -not $ocdExe) {
    $downloads.Add(@{ Key="openocd"; Tool=$TOOL_CATALOG.OPENOCD })
}
# WCH-OpenOCD has no portable zip download; user must install MounRiver Studio.
# The $ocdWchExe variable will remain null if not found; downstream code handles gracefully.

if ($downloads.Count -gt 0) {
    Write-Host ""
    Write-Host "--- Download plan ---------------------------------" -ForegroundColor Cyan
    Write-Host ("  Destination  :  {0}" -f $SharedDir)
    if (-not (Test-Path $SharedDir)) {
        Write-Host "  (folder does not exist yet - will be created)" -ForegroundColor DarkGray
    }
    Write-Host ""

    $totalDlMB   = 0
    $totalDiskMB = 0
    foreach ($e in $downloads) {
        $t = $e.Tool
        Write-Host ("  {0,-38}  dl ~{1,4} MB   unpacked ~{2,4} MB" -f $t.Name, $t.DlMB, $t.DiskMB)
        $totalDlMB   += $t.DlMB
        $totalDiskMB += $t.DiskMB
    }

    $freeMB = Get-FreeDiskMB $SharedDir
    Write-Host ""
    Write-Host ("  Total to download  :  ~{0} MB"   -f $totalDlMB)
    Write-Host ("  Total on disk      :  ~{0} MB  ->  {1}" -f $totalDiskMB, $SharedDir)

    $spaceOK = $freeMB -ge ($totalDiskMB * 1.2)
    $spaceColor = if ($spaceOK) { "DarkGray" } else { "Red" }
    Write-Host ("  Free on drive      :  {0} MB" -f $freeMB) -ForegroundColor $spaceColor

    if (-not $spaceOK) {
        Write-Host ""
        Write-Host "  WARNING: possibly insufficient disk space!" -ForegroundColor Red
    }

    Write-Host ""
    Write-Host "Proceed with download? [Y/n]" -ForegroundColor Yellow
    $answer = Read-Host
    if ($answer -match "^[Nn]") { Write-Host "Aborted."; exit 0 }

    New-Item -ItemType Directory -Path $SharedDir -Force | Out-Null

    foreach ($e in $downloads) {
        $t = $e.Tool
        Write-Host ""
        Write-Host ("[{0}]  Downloading..." -f $t.Name) -ForegroundColor Cyan
        $zip = Join-Path $env:TEMP "mcu_dl.zip"
        Invoke-Download $t.Url $zip
        Invoke-ExtractTool $t $zip
        Write-Host ("[{0}]  Done  ->  {1}" -f $t.Name, $t.DestDir) -ForegroundColor Green

        switch ($e.Key) {
            "gcc"     { $gccBin    = "$($t.DestDir)\bin"
                        $gccPrefix = if ($mcu.Arch -eq "ARM") { "arm-none-eabi-" } else { "riscv-none-elf-" } }
            "cmake"   { $cmakeExe  = "$($t.DestDir)\bin\cmake.exe" }
            "ninja"   { $ninjaExe  = "$($t.DestDir)\ninja.exe" }
            "openocd"     { $ocdExe    = "$($t.DestDir)\bin\openocd.exe" }
            "openocd-wch" { $ocdWchExe = "$($t.DestDir)\bin\openocd.exe" }
        }
    }
} else {
    Write-Host ""
    Write-Host "All tools already found - nothing to download." -ForegroundColor Green
}

# ==============================================================
# STEP 3.5: Ensure fast GDB for debugging (ARM only)
# GDB 15.x (EIDE 2025+) has Python compiled in -> 5-15s cold start.
# GDB from the 14.2 toolchain has no Python -> starts in ~20ms.
# We extract just gdb.exe (~4 MB download) via HTTP Range requests —
# no full 291 MB download needed.
# To upgrade: update ARM_GCC.Url and ARM_GCC.GdbEntry in TOOL_CATALOG.
# ==============================================================
$fastGdbFwd = ''
if ($mcu.Arch -eq 'ARM') {
    $toolchainGdb  = "$SharedDir\arm-none-eabi\bin\arm-none-eabi-gdb.exe"
    $standaloneGdb = "$SharedDir\gdb\arm-none-eabi-gdb.exe"
    if (Test-Path $toolchainGdb) {
        $fastGdbFwd = $toolchainGdb.Replace('\', '/')
    } elseif (Test-Path $standaloneGdb) {
        $fastGdbFwd = $standaloneGdb.Replace('\', '/')
    } else {
        Write-Host ""
        Write-Host "  Downloading arm-none-eabi-gdb  (~4 MB)..." -ForegroundColor Cyan
        try {
            $gdbTool = $TOOL_CATALOG.ARM_GCC
            Invoke-ExtractFromZip $gdbTool.Url $gdbTool.GdbEntry $standaloneGdb
            $fastGdbFwd = $standaloneGdb.Replace('\', '/')
            Write-Host ("  [DONE ]  {0,-22}  {1}" -f "GDB (debugger)", $standaloneGdb) -ForegroundColor Green
        } catch {
            Write-Host "  [FAIL ]  GDB download failed. Debug may be slow on first launch." -ForegroundColor Yellow
        }
    }
}

# ==============================================================
# STEP 4: Download device headers  (project-specific, small ~1-3 MB)
# ==============================================================
New-Item -ItemType Directory "$DeviceDir\inc" -Force | Out-Null
New-Item -ItemType Directory "$DeviceDir\src"     -Force | Out-Null

$sdkFlag = Join-Path $DeviceDir (".downloaded_" + $mcu.Pattern)
# Auto-reset flag if include/ is empty (user deleted files via Explorer but hidden flag survived)
if ((Test-Path $sdkFlag) -and -not (Get-ChildItem "$DeviceDir\inc" -EA SilentlyContinue)) {
    Remove-Item $sdkFlag -Force
    Write-Host "  [Device] include/ is empty - resetting download flag" -ForegroundColor DarkGray
}
if (-not (Test-Path $sdkFlag)) {
    $gotIt = $false
    Write-Host ""

    if ($mcu.RepoType -eq "WCH") {
        # WCH SDK repos (openwch/*) have inconsistent folder structures across chips,
        # so we download the full repo ZIP and extract only the needed files.
        # The ZIP is ~30-80 MB but this is a one-time download per MCU family.
        Write-Host ("[Device] Downloading WCH SDK: {0}..." -f $mcu.Repo) -ForegroundColor Cyan
        foreach ($zipBranch in @("main", "master")) {
            $zip    = Join-Path $env:TEMP "mcu_wch_sdk.zip"
            $tmpDir = Join-Path $env:TEMP "mcu_wch_sdk_tmp"
            $zipUrl = "https://github.com/$($mcu.Repo)/archive/refs/heads/$zipBranch.zip"
            Remove-Item $tmpDir -Recurse -EA SilentlyContinue
            try {
                Invoke-Download $zipUrl $zip
            } catch {
                continue
            }
            Write-Host "  Extracting..." -ForegroundColor DarkGray
            Expand-Archive $zip $tmpDir -Force
            Remove-Item $zip -EA SilentlyContinue
            $sdkRoot = Get-ChildItem $tmpDir -Directory | Select-Object -First 1 -ExpandProperty FullName

            # Core headers (core_riscv.h, core_riscv.c) — search anywhere in repo
            $coreFile = Get-ChildItem $sdkRoot -Recurse -Filter 'core_riscv.h' -EA SilentlyContinue | Select-Object -First 1
            if ($coreFile) {
                Get-ChildItem (Split-Path $coreFile.FullName) -File |
                    Copy-Item -Destination "$DeviceDir\inc\" -Force
                Write-Host ("  [core]    {0}" -f (Split-Path $coreFile.DirectoryName -Leaf)) -ForegroundColor DarkGray
            }

            # Chip peripheral headers — find the folder containing $mcu.Header
            $hdrFile = Get-ChildItem $sdkRoot -Recurse -Filter $mcu.Header -EA SilentlyContinue | Select-Object -First 1
            if ($hdrFile) {
                Get-ChildItem (Split-Path $hdrFile.FullName) -Filter '*.h' |
                    Copy-Item -Destination "$DeviceDir\inc\" -Force
                Write-Host ("  [headers] found in ...$(Split-Path $hdrFile.DirectoryName -Leaf)\") -ForegroundColor DarkGray
            } else {
                Write-Host ("  [headers] '{0}' not found in ZIP - check MCU_DB entry" -f $mcu.Header) -ForegroundColor Yellow
            }

            # system_*.c + system_*.h + *_conf.h — from first example's User/ folder
            $sysFile = Get-ChildItem $sdkRoot -Recurse -Filter 'system_*.c' -EA SilentlyContinue | Select-Object -First 1
            if ($sysFile) {
                Copy-Item $sysFile.FullName "$DeviceDir\src\$($sysFile.Name)" -Force
                Get-ChildItem (Split-Path $sysFile.FullName) -Filter 'system_*.h' -EA SilentlyContinue |
                    Copy-Item -Destination "$DeviceDir\inc\" -Force
                Get-ChildItem (Split-Path $sysFile.FullName) -Filter '*_conf.h' -EA SilentlyContinue |
                    Copy-Item -Destination "$DeviceDir\inc\" -Force
                Write-Host ("  [system]  {0}" -f $sysFile.Name) -ForegroundColor DarkGray
            }

            # Startup file
            $suFile = Get-ChildItem $sdkRoot -Recurse -Filter $mcuStartupGlob -EA SilentlyContinue | Select-Object -First 1
            if (-not $suFile) {
                $suFile = Get-ChildItem $sdkRoot -Recurse -Include '*.S','*.s' -EA SilentlyContinue |
                              Where-Object { $_.Name -like 'startup_*' } | Select-Object -First 1
            }
            if ($suFile) {
                Copy-Item $suFile.FullName "$DeviceDir\src\startup.s" -Force
                Write-Host ("  [startup] {0}" -f $suFile.Name) -ForegroundColor DarkGray
            } else {
                Write-Host "  [startup] not found in ZIP" -ForegroundColor Yellow
            }

            Remove-Item $tmpDir -Recurse -EA SilentlyContinue
            $gotIt = $hdrFile -and $suFile
            if ($gotIt) { break }
            Write-Host "  Incomplete, trying next branch..." -ForegroundColor DarkGray
        }
    } else {
        # === STM: CMSIS device repos are small (~3 MB) — full zip download is fine ===
        Write-Host ("[Device] Downloading headers: {0}..." -f $mcu.Repo) -ForegroundColor Cyan
        foreach ($branch in @("main", "master")) {
            $url    = "https://github.com/" + $mcu.Repo + "/archive/refs/heads/$branch.zip"
            $zip    = Join-Path $env:TEMP "mcu_sdk.zip"
            $tmpDir = Join-Path $env:TEMP "mcu_sdk_tmp"
            Remove-Item $tmpDir -Recurse -EA SilentlyContinue
            try {
                Invoke-Download $url $zip
            } catch {
                continue
            }
            Write-Host "  Extracting..." -ForegroundColor DarkGray
            Expand-Archive $zip $tmpDir -Force
            Remove-Item $zip -EA SilentlyContinue
            $sdkRoot = Get-ChildItem $tmpDir -Directory | Select-Object -First 1 -ExpandProperty FullName

            if (Test-Path "$sdkRoot\Include") {
                $hFiles = @(Get-ChildItem "$sdkRoot\Include" -Filter '*.h')
                $hFiles | Copy-Item -Destination "$DeviceDir\inc\" -Force
                Write-Host ("  [headers] {0} files from Include/" -f $hFiles.Count) -ForegroundColor DarkGray
            }
            $sysFiles = @(Get-ChildItem "$sdkRoot\Source\Templates" -Filter "system*.c" -EA SilentlyContinue)
            $sysFiles | Copy-Item -Destination "$DeviceDir\src\" -Force
            if ($sysFiles.Count -gt 0) {
                Write-Host ("  [system]  {0}" -f $sysFiles[0].Name) -ForegroundColor DarkGray
            }
            $su = Get-ChildItem "$sdkRoot\Source\Templates\gcc" -Filter $mcuStartupGlob -EA SilentlyContinue |
                  Select-Object -First 1
            if (-not $su) {
                $su = Get-ChildItem "$sdkRoot\Source\Templates\gcc" -Filter "*.s" -EA SilentlyContinue |
                      Select-Object -First 1
            }
            if ($su) {
                Copy-Item $su.FullName "$DeviceDir\src\startup.s" -Force
                Write-Host ("  [startup] {0}" -f $su.Name) -ForegroundColor DarkGray
            }
            Remove-Item $tmpDir -Recurse -EA SilentlyContinue
            $gotIt = $true
            break
        }
    }

    if ($gotIt) {
        # WCH: auto-generate *_conf.h if still missing (unconditionally #included by the main header)
        if ($mcu.RepoType -eq 'WCH') {
            $confName = $mcu.Header -replace '\.h$', '_conf.h'   # e.g. ch32v30x_conf.h
            $confPath = "$DeviceDir\inc\$confName"
            if (-not (Test-Path $confPath)) {
                $guard   = ('__' + ($confName -replace '\.','_').ToUpper() + '__')
                $periph  = Get-ChildItem "$DeviceDir\inc" -Filter ($mcu.Header -replace '\.h$','_*.h') |
                               Where-Object Name -ne $mcu.Header | Sort-Object Name |
                               ForEach-Object { "#include `"$($_.Name)`"" }
                $confTxt = "#ifndef $guard`n#define $guard`n`n" + ($periph -join "`n") + "`n`n#endif /* $guard */"
                [System.IO.File]::WriteAllText($confPath, $confTxt, (New-Object System.Text.UTF8Encoding $false))
                Write-Host ("  [conf.h]  Generated {0} ({1} peripheral includes)" -f $confName, $periph.Count) -ForegroundColor DarkGray
            }
        }
        New-Item -ItemType File -Path $sdkFlag | Out-Null
        Write-Host "[Device] Done" -ForegroundColor Green

        # For WCH: generate a stub <mcu>_it.h in user/inc/ if not already there
        # (ch32vXXx_conf.h unconditionally includes it, but it's project-specific)
        if ($mcu.RepoType -eq 'WCH') {
            $itHeader = $mcu.Header -replace '\.h$', '_it.h'   # e.g. ch32v30x_it.h
            $itDir    = Join-Path $Root "user\inc"
            $itPath   = Join-Path $itDir $itHeader
            if (-not (Test-Path $itDir)) { New-Item -ItemType Directory -Path $itDir -Force | Out-Null }
            if (-not (Test-Path $itPath)) {
                $guard  = ($itHeader -replace '\.', '_').ToUpper()   # CH32V30X_IT_H
                $itTxt  = "#ifndef __$guard`n#define __$guard`n`n/* Add interrupt handler prototypes here as needed */`n`n#endif /* __$guard */"
                [System.IO.File]::WriteAllText($itPath, $itTxt, (New-Object System.Text.UTF8Encoding $false))
                Write-Host ("  [user/inc] Created stub {0}" -f $itHeader) -ForegroundColor DarkGray
            }

            # CH32L103 quirk: WCH's system_ch32l103.c::SetSysClock() unconditionally
            # calls GPIO_IPD_Unused() which the user is expected to implement to put
            # unused pins into pull-down for low-power. Without it the link fails on
            # a bare project. Provide a weak no-op so the build succeeds; override in
            # user code if you actually want low-power GPIO setup.
            if ($mcu.Pattern -eq 'ch32l1') {
                $stubPath = Join-Path $Root "device\src\_weak_stubs.c"
                if (-not (Test-Path $stubPath)) {
                    $stubTxt = @'
/* Auto-generated by setup.ps1 - weak fallbacks for symbols that WCH's
 * vendor system_*.c references but does not define. Override any of these
 * in user code (drop the __attribute__((weak)) when you do).
 */

/* CH32L103: called from SetSysClock() to put unused GPIOs into pull-down. */
__attribute__((weak)) void GPIO_IPD_Unused(void) { }
'@
                    [System.IO.File]::WriteAllText($stubPath, $stubTxt, (New-Object System.Text.UTF8Encoding $false))
                    Write-Host "  [device/src] Created _weak_stubs.c (CH32L103 GPIO_IPD_Unused stub)" -ForegroundColor DarkGray
                }
            }
        }
    } else {
        Write-Host "[Device] Could not download headers automatically." -ForegroundColor Yellow
        Write-Host ("  Download manually: https://github.com/{0}" -f $mcu.Repo)
    }
} else {
    Write-Host ""
    Write-Host "[Device] Headers already present." -ForegroundColor Green
    Write-Host "  (delete $sdkFlag to force re-download)" -ForegroundColor DarkGray
}

# ==============================================================
# STEP 4.3: Download CMSIS Core headers  (ARM only, shared across projects)
# ==============================================================
if ($mcu.Arch -eq "ARM" -and $mcu.NeedsCmsis) {
    $cmsisDest = "$SharedDir\cmsis"
    $cmsisTag  = "5.9.0"
    $baseUrl   = "https://raw.githubusercontent.com/ARM-software/CMSIS_5/$cmsisTag/CMSIS/Core/Include"
    # cachel1_armv7.h is transitively included by core_cm7.h - omitting it breaks
    # every Cortex-M7 build (STM32H7/F7). Likewise core_cm4.h pulls mpu_armv7.h
    # only at runtime, but cm7.h always needs cachel1_armv7.h.
    $cmsisFiles = @(
        'cmsis_compiler.h', 'cmsis_gcc.h', 'cmsis_armcc.h', 'cmsis_armclang.h',
        'cmsis_armclang_ltm.h', 'cmsis_iccarm.h', 'cmsis_version.h',
        'cachel1_armv7.h',
        'core_cm0.h', 'core_cm0plus.h', 'core_cm1.h', 'core_cm3.h',
        'core_cm4.h', 'core_cm7.h', 'core_cm23.h', 'core_cm33.h',
        'core_cm35p.h', 'core_armv8mbl.h', 'core_armv8mml.h', 'core_armv81mml.h',
        'core_sc000.h', 'core_sc300.h',
        'mpu_armv7.h', 'mpu_armv8.h', 'pmu_armv8.h', 'tz_context.h'
    )
    New-Item -ItemType Directory $cmsisDest -Force | Out-Null
    # Per-file check: download whatever's missing. Beats a single flag file
    # which would silently keep an incomplete folder around when the file list
    # is extended (as happened with cachel1_armv7.h for Cortex-M7).
    $missing = $cmsisFiles | Where-Object { -not (Test-Path "$cmsisDest\$_") }
    if ($missing.Count -gt 0) {
        Write-Host ""
        Write-Host ("[CMSIS] Fetching {0} missing header(s) from CMSIS_5 {1}..." -f $missing.Count, $cmsisTag) -ForegroundColor Cyan
        $failed = @()
        for ($fi = 0; $fi -lt $missing.Count; $fi++) {
            $f = $missing[$fi]
            Write-Host ("`r  [{0,2}/{1}]  {2,-36}" -f ($fi + 1), $missing.Count, $f) -NoNewline
            try { Invoke-Download "$baseUrl/$f" "$cmsisDest\$f" } catch { $failed += $f }
        }
        Write-Host ""
        if ($failed.Count -eq 0) {
            Write-Host "[CMSIS] Done  ->  $cmsisDest" -ForegroundColor Green
        } else {
            Write-Host "[CMSIS] Failed to download: $($failed -join ', ')" -ForegroundColor Yellow
            Write-Host "  Get manually: https://github.com/ARM-software/CMSIS_5/tree/$cmsisTag/CMSIS/Core/Include"
        }
    } else {
        Write-Host ""
        Write-Host "[CMSIS] All headers already present." -ForegroundColor Green
    }
}

# ==============================================================
# STEP 4.5: Generate linker script  (chip-specific name)
# ==============================================================
$ldName = $mcu.Header -replace '\.h$', '.ld'
$ldContent = New-LinkerScript -Arch $mcu.Arch -FlashBase $flashBase -FlashKB $flashKB -RamBase $ramBase -RamKB $ramKB
[System.IO.File]::WriteAllText("$Root\$ldName", $ldContent, (New-Object System.Text.UTF8Encoding $false))
Write-Host ""
Write-Host ("[$ldName] Generated  ({0} KB Flash @ {1},  {2} KB RAM @ {3})" -f $flashKB, $flashBase, $ramKB, $ramBase) -ForegroundColor Green

# Paths used by scaffolding (STEP 4.7) and tool_paths.cmake (STEP 5)
# If the GCC bin dir contains spaces, Windows CMake converts it to 8.3 paths in
# compile_commands.json — cpptools then cannot run the compiler to find system
# headers (stdint.h etc.), breaking IntelliSense. Fix: create a junction under
# SharedDir (no spaces) and redirect gccBinFwd through it.
$gccBinFwd = $gccBin.Replace('\', '/')
if ($gccBinFwd -match ' ') {
    $gccTarget   = $gccPrefix.TrimEnd('-')
    $junctionDir = Join-Path $SharedDir $gccTarget
    $gccParent   = Split-Path $gccBin -Parent
    if (-not (Test-Path $junctionDir)) {
        New-Item -ItemType Junction -Path $junctionDir -Target $gccParent | Out-Null
        Write-Host ("  [junction] {0} -> {1}" -f $junctionDir, $gccParent) -ForegroundColor Green
    }
    $gccBinFwd = "$($junctionDir.Replace('\','/'))/bin"
    Write-Host ("  [gcc path] Redirected via junction: {0}" -f $gccBinFwd) -ForegroundColor Cyan
}
$cmakeFwd  = $cmakeExe.Replace('\', '/')
$ninjaFwd  = $ninjaExe.Replace('\', '/')
# For ARM use xpack-openocd; for RISC-V use WCH-OpenOCD (if found)
$activeOcdExe = if ($mcu.Arch -eq 'RISCV') { $ocdWchExe } else { $ocdExe }
$ocdFwd    = if ($activeOcdExe) { $activeOcdExe.Replace('\', '/') } else { '' }
$cmsisDir  = if ($mcu.NeedsCmsis) { "$SharedDir\cmsis".Replace('\', '/') } else { '' }
# xpack-OpenOCD (ARM): scripts are in share/openocd/scripts/ next to bin/
# WCH-OpenOCD (MounRiver): wch-riscv.cfg lives directly in bin/ — use bin/ as scripts dir
$ocdDir = if ($ocdFwd) { ($ocdFwd -replace '/bin/openocd\.exe$', '') } else { '' }
$ocdScriptsFwd = if ($ocdFwd) {
    if ($mcu.Arch -eq 'RISCV') { "$ocdDir/bin" } else { "$ocdDir/share/openocd/scripts" }
} else { '' }

# ==============================================================
# STEP 4.7: Scaffold project files  (create only if absent)
# ==============================================================
function Write-NewFile {
    param([string]$Path, [string]$Content)
    if (-not (Test-Path $Path)) {
        $d = Split-Path $Path
        if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
        [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("  [+] {0}" -f $Path.Replace($Root + '\', '')) -ForegroundColor Green
    }
}

# Infrastructure files (toolchain, linker glue) are always overwritten so fixes
# from a newer setup.ps1 are applied even on re-runs of an existing project.
function Write-InfraFile {
    param([string]$Path, [string]$Content)
    $d = Split-Path $Path
    if ($d -and -not (Test-Path $d)) { New-Item -ItemType Directory $d -Force | Out-Null }
    $label = $Path.Replace($Root + '\', '')
    if (Test-Path $Path) {
        $old = [System.IO.File]::ReadAllText($Path, (New-Object System.Text.UTF8Encoding $false))
        if ($old -eq $Content) { return }   # unchanged - silent
        [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("  [u] {0}" -f $label) -ForegroundColor DarkYellow
    } else {
        [System.IO.File]::WriteAllText($Path, $Content, (New-Object System.Text.UTF8Encoding $false))
        Write-Host ("  [+] {0}" -f $label) -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Scaffolding project files..." -ForegroundColor Cyan

New-Item -ItemType Directory (Join-Path $Root "user\inc") -Force | Out-Null
New-Item -ItemType Directory (Join-Path $Root "user\src") -Force | Out-Null
New-Item -ItemType Directory $CmakeDir                    -Force | Out-Null
New-Item -ItemType Directory $VsCodeDir                   -Force | Out-Null

# ---- CMakeLists.txt ----
$projName = Split-Path $Root -Leaf
$cmakeListsTmpl = @'
cmake_minimum_required(VERSION 3.20)

if(NOT EXISTS "${CMAKE_SOURCE_DIR}/cmake/mcu_config.cmake")
    message(FATAL_ERROR "cmake/mcu_config.cmake not found!\nRun setup.ps1 before first build.")
endif()
include(cmake/mcu_config.cmake)
# tool_paths.cmake: machine-specific paths (CMSIS_DIR, OPENOCD_EXE, etc.)
if(EXISTS "${CMAKE_SOURCE_DIR}/cmake/tool_paths.cmake")
    include("${CMAKE_SOURCE_DIR}/cmake/tool_paths.cmake")
endif()
# build_config.cmake: user-editable compile flags (optimization, warnings, C std, etc.)
if(EXISTS "${CMAKE_SOURCE_DIR}/cmake/build_config.cmake")
    include("${CMAKE_SOURCE_DIR}/cmake/build_config.cmake")
endif()

project(__PROJ__ C ASM)

set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

# CPU flags: override via BUILD_CPU_FLAGS_OVERRIDE in build_config.cmake, else use MCU defaults
if(BUILD_CPU_FLAGS_OVERRIDE)
    set(CPU_FLAGS "${BUILD_CPU_FLAGS_OVERRIDE}")
else()
    set(CPU_FLAGS "${MCU_CPU_FLAGS}")
    if(MCU_FPU_FLAGS)
        string(APPEND CPU_FLAGS " ${MCU_FPU_FLAGS}")
    endif()
endif()

# Float ABI: override via BUILD_FLOAT_ABI_OVERRIDE in build_config.cmake, else use MCU default
if(BUILD_FLOAT_ABI_OVERRIDE)
    set(FLOAT_FLAGS "-mfloat-abi=${BUILD_FLOAT_ABI_OVERRIDE}")
elseif(MCU_FLOAT_ABI)
    set(FLOAT_FLAGS "-mfloat-abi=${MCU_FLOAT_ABI}")
else()
    set(FLOAT_FLAGS "")
endif()

set(CMAKE_C_FLAGS
    "${CPU_FLAGS} ${FLOAT_FLAGS} ${BUILD_OPT} ${BUILD_C_STD} ${BUILD_WARNINGS} ${BUILD_DEBUG} -ffunction-sections -fdata-sections ${BUILD_EXTRA_DEFINES} ${BUILD_EXTRA_FLAGS}"
    CACHE STRING "" FORCE)
set(CMAKE_ASM_FLAGS
    "${CPU_FLAGS} ${FLOAT_FLAGS} -x assembler-with-cpp"
    CACHE STRING "" FORCE)
if(MCU_ARCH STREQUAL "RISCV")
    set(LINKER_WARN_FLAGS "")
    set(NOSTARTFILES "-nostartfiles")
else()
    set(LINKER_WARN_FLAGS ",--no-warn-rwx-segments")
    set(NOSTARTFILES "")
endif()
set(LD_SCRIPT "${CMAKE_SOURCE_DIR}/${MCU_LD_SCRIPT}")
set(CMAKE_EXE_LINKER_FLAGS
    "${CPU_FLAGS} ${FLOAT_FLAGS} ${NOSTARTFILES} -T${LD_SCRIPT} -Wl,--gc-sections,-Map=${CMAKE_BINARY_DIR}/${PROJECT_NAME}.map,--cref${LINKER_WARN_FLAGS} --specs=nano.specs -lm -lnosys"
    CACHE STRING "" FORCE)

# ================================================================
# USER FILES  —  add your .h and .c paths here
# ================================================================
# Sources: list every .c path or glob your project needs in ONE call.
# Mix concrete files and wildcards freely. CONFIGURE_DEPENDS tells CMake to
# re-scan when files appear or disappear, so a new .c shows up automatically.
file(GLOB_RECURSE USER_SOURCES CONFIGURE_DEPENDS
    "user/src/*.c"
    # "lib/foo.c"
    # "third_party/SomeLib/*.c"
)

# Header search paths: directories that contain your .h files.
set(USER_INCLUDES
    user/inc
    device/inc
    # "lib/inc"
    # "third_party/SomeLib"
)
# ================================================================

# Picks up device/src/_weak_stubs.c if setup.ps1 generated one (chip-specific
# fallbacks for symbols WCH's system_*.c expects the user to provide).
file(GLOB DEVICE_EXTRA_SOURCES CONFIGURE_DEPENDS "device/src/_weak_stubs.c")

set(SOURCES ${USER_SOURCES} ${MCU_STARTUP} ${MCU_SYSTEM} ${DEVICE_EXTRA_SOURCES})
add_executable(__PROJ__.elf ${SOURCES})

target_include_directories(__PROJ__.elf PRIVATE ${USER_INCLUDES})
target_compile_definitions(__PROJ__.elf PRIVATE ${MCU_DEFINE})
# Optional chip-variant define (e.g. CH32V30x_D8 vs CH32V30x_D8C).
# Empty for chips that don't need it.
if(MCU_EXTRA_DEFINE)
    target_compile_definitions(__PROJ__.elf PRIVATE ${MCU_EXTRA_DEFINE})
endif()

if(MCU_NEEDS_CMSIS)
    if(DEFINED CMSIS_DIR AND EXISTS "${CMSIS_DIR}")
        target_include_directories(__PROJ__.elf PRIVATE "${CMSIS_DIR}")
    else()
        target_include_directories(__PROJ__.elf PRIVATE cmsis)
    endif()
endif()

# Add compiler sysroot include so cpptools/IntelliSense finds <stdint.h>.
# Compilers installed in paths with spaces produce 8.3 entries in compile_commands.json;
# cpptools then cannot interrogate the compiler for system headers. Adding the sysroot
# include explicitly as a -I flag makes it visible in compile_commands.json.
get_filename_component(_gcc_bin "${CMAKE_C_COMPILER}" DIRECTORY)
get_filename_component(_gcc_root "${_gcc_bin}" DIRECTORY)
string(REGEX REPLACE "-gcc[^/\\\\]*$" "" _gcc_target "${CMAKE_C_COMPILER}")
get_filename_component(_gcc_target "${_gcc_target}" NAME)
file(GLOB _gcc_builtin_incs "${_gcc_root}/lib/gcc/${_gcc_target}/*/include")
if(_gcc_builtin_incs)
    list(GET _gcc_builtin_incs 0 _gcc_builtin_inc)
    set(CMAKE_C_FLAGS "${CMAKE_C_FLAGS} -I${_gcc_builtin_inc}" CACHE STRING "" FORCE)
endif()

# Without this the linker script change doesn't trigger a re-link
# (Ninja doesn't see it through -T<path> alone).
set_target_properties(__PROJ__.elf PROPERTIES LINK_DEPENDS "${LD_SCRIPT}")

add_custom_command(TARGET __PROJ__.elf POST_BUILD
    COMMAND ${CMAKE_OBJCOPY} -O ihex   $<TARGET_FILE:__PROJ__.elf> ${CMAKE_BINARY_DIR}/__PROJ__.hex
    COMMAND ${CMAKE_OBJCOPY} -O binary $<TARGET_FILE:__PROJ__.elf> ${CMAKE_BINARY_DIR}/__PROJ__.bin
    COMMENT "Generating __PROJ__.hex / __PROJ__.bin" VERBATIM)
add_custom_command(TARGET __PROJ__.elf POST_BUILD
    COMMAND ${CMAKE_SIZE_UTIL} $<TARGET_FILE:__PROJ__.elf>
    COMMENT "Firmware size:" VERBATIM)
'@
Write-NewFile "$Root\CMakeLists.txt" ($cmakeListsTmpl.Replace('__PROJ__', $projName))

# ---- cmake/build_config.cmake ----
# Created ONCE — setup.ps1 never overwrites it. Edit freely.
Write-NewFile "$CmakeDir\build_config.cmake" @"
# ==============================================================
# cmake/build_config.cmake
# User-editable build flags.
# Edit here — NO need to re-run setup.ps1.
# Re-run cmake configure (Ctrl+Shift+B) to apply changes.
# ==============================================================

# ---------- Optimization ----------
# -O0  None       - no optimization, easiest to step through, but 2-3x larger
# -Og  Debug      - optimizations that don't hurt debugging  (recommended default)
# -O1  Light      - mild optimizations, mostly still debuggable
# -Os  Size       - minimize Flash usage  (recommended for production / size-limited MCUs)
# -O2  Speed      - balanced speed and size
# -O3  Max        - maximum speed, may increase code size
set(BUILD_OPT "-Og")

# ---------- C standard ----------
# c99 / c11 / c17 / gnu11  (gnu11 = C11 + GCC extensions, recommended)
set(BUILD_C_STD "-std=gnu11")

# ---------- Warnings ----------
# -Wall     standard warnings  (recommended minimum)
# -Wextra   more warnings  (stricter, some false positives possible)
# -Werror   treat all warnings as errors  (CI-friendly, strict)
set(BUILD_WARNINGS "-Wall")

# ---------- Debug info ----------
# -g   full DWARF debug info (needed to step through code in VS Code / GDB)
# -g0  no debug info         (smaller .elf, cannot debug)
set(BUILD_DEBUG "-g")

# ---------- Float ABI override ----------
# ARM options: "soft" | "softfp" | "hard"
# RISC-V: not used — float ABI is encoded in -march/-mabi (see CPU flags below).
set(BUILD_FLOAT_ABI_OVERRIDE "$($mcu.FloatABI)")

# ---------- CPU / ISA flags override ----------
# Leave empty "" to fall back to mcu_config.cmake defaults.
# -march and -mabi must always go together for RISC-V.
set(BUILD_CPU_FLAGS_OVERRIDE "$($mcu.CpuFlags)$(if ($mcu.FpuFlags) { " " + $mcu.FpuFlags } else { "" })")

# ---------- Extra preprocessor defines ----------
# Space-separated, each prefixed with -D
# Example: "-DDEBUG -DUSE_FULL_ASSERT -DBOARD_REV=2"
set(BUILD_EXTRA_DEFINES "")

# ---------- Extra compiler flags ----------
# Defaults below favor single-precision float for chips with SP-only FPU
# (STM32F4/G4/L4, CH32V30x). Beginners often write `x * 1.5` instead of
# `x * 1.5f` and silently pay the softfloat cost - these flags catch and
# prevent that.
#
#   -fsingle-precision-constant : literals like 1.5 stay float instead of
#                                 double, so they don't trigger softfloat
#                                 __muldf3 / __adddf3 calls on every use
#   -Wdouble-promotion          : warn when float still gets promoted to
#                                 double anyway (e.g. printf("%f", x),
#                                 sin(x) instead of sinf(x))
#   -fno-math-errno             : math.h functions skip errno write
#                                 (~50 B per call, harmless on embedded)
#
# Remove -fsingle-precision-constant if you actually need double precision
# (e.g. on STM32H7 with DP-FPU, or numerical algorithms).
set(BUILD_EXTRA_FLAGS "-fsingle-precision-constant -Wdouble-promotion -fno-math-errno")
"@

# ---- cmake/toolchain.cmake ----
# CMAKE_CURRENT_LIST_DIR is the cmake/ folder, reliable even during try_compile.
Write-InfraFile "$CmakeDir\toolchain.cmake" @'
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/mcu_arch.txt")
    file(READ "${CMAKE_CURRENT_LIST_DIR}/mcu_arch.txt" MCU_ARCH_TXT)
    string(STRIP "${MCU_ARCH_TXT}" MCU_ARCH_TXT)
else()
    set(MCU_ARCH_TXT "ARM")
endif()
if(MCU_ARCH_TXT STREQUAL "RISCV")
    include("${CMAKE_CURRENT_LIST_DIR}/riscv-wch-elf.cmake")
else()
    include("${CMAKE_CURRENT_LIST_DIR}/arm-none-eabi.cmake")
endif()
'@

# ---- cmake/arm-none-eabi.cmake ----
Write-InfraFile "$CmakeDir\arm-none-eabi.cmake" @'
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR arm)
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/tool_paths.cmake")
    include("${CMAKE_CURRENT_LIST_DIR}/tool_paths.cmake")
else()
    set(TOOLCHAIN_GCC_BIN    "${CMAKE_CURRENT_LIST_DIR}/../tools/gcc/bin")
    set(TOOLCHAIN_GCC_PREFIX "arm-none-eabi-")
    message(WARNING "cmake/tool_paths.cmake not found - run setup.ps1!")
endif()
set(TC "${TOOLCHAIN_GCC_BIN}/${TOOLCHAIN_GCC_PREFIX}")
set(CMAKE_C_COMPILER   "${TC}gcc.exe"     CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER "${TC}g++.exe"     CACHE FILEPATH "C++ compiler")
set(CMAKE_ASM_COMPILER "${TC}gcc.exe"     CACHE FILEPATH "ASM compiler")
set(CMAKE_OBJCOPY      "${TC}objcopy.exe" CACHE FILEPATH "objcopy")
set(CMAKE_SIZE_UTIL    "${TC}size.exe"    CACHE FILEPATH "size")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
'@

# ---- cmake/riscv-wch-elf.cmake ----
Write-InfraFile "$CmakeDir\riscv-wch-elf.cmake" @'
set(CMAKE_SYSTEM_NAME Generic)
set(CMAKE_SYSTEM_PROCESSOR riscv)
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/tool_paths.cmake")
    include("${CMAKE_CURRENT_LIST_DIR}/tool_paths.cmake")
else()
    set(TOOLCHAIN_GCC_BIN    "${CMAKE_CURRENT_LIST_DIR}/../tools/gcc/bin")
    set(TOOLCHAIN_GCC_PREFIX "riscv-none-elf-")
    message(WARNING "cmake/tool_paths.cmake not found - run setup.ps1!")
endif()
set(TC "${TOOLCHAIN_GCC_BIN}/${TOOLCHAIN_GCC_PREFIX}")
set(CMAKE_C_COMPILER   "${TC}gcc.exe"     CACHE FILEPATH "C compiler")
set(CMAKE_CXX_COMPILER "${TC}g++.exe"     CACHE FILEPATH "C++ compiler")
set(CMAKE_ASM_COMPILER "${TC}gcc.exe"     CACHE FILEPATH "ASM compiler")
set(CMAKE_OBJCOPY      "${TC}objcopy.exe" CACHE FILEPATH "objcopy")
set(CMAKE_SIZE_UTIL    "${TC}size.exe"    CACHE FILEPATH "size")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
'@

# ---- build.ps1 ---- (created once - edit freely, setup.ps1 will not overwrite)
Write-NewFile "$Root\build.ps1" @'
param([switch]$Clean)
$ErrorActionPreference = 'Continue'
$root     = $PSScriptRoot
$buildDir = "$root\build\cmake"

# Read cmake/ninja paths from cmake/tool_paths.cmake
$cmakeExe = $null; $ninjaExe = $null
foreach ($ln in Get-Content "$root\cmake\tool_paths.cmake" -EA SilentlyContinue) {
    if ($ln -match 'CMAKE_EXE\s+"([^"]+)"')         { $cmakeExe = $Matches[1] }
    if ($ln -match 'CMAKE_MAKE_PROGRAM\s+"([^"]+)"') { $ninjaExe = $Matches[1] }
}
if (-not $cmakeExe) { $c = Get-Command cmake -EA SilentlyContinue; if ($c) { $cmakeExe = $c.Source } }
if (-not $cmakeExe) { Write-Host 'cmake not found - run setup.ps1' -ForegroundColor Red; exit 1 }

# -Clean wipes the build directory so the next configure starts from scratch.
# This is what "clean build" should mean. Just running `ninja clean` only
# deletes .obj/.elf - CMakeCache.txt and build.ninja survive, so a stale
# file(GLOB) list (without CONFIGURE_DEPENDS) keeps haunting the build.
if ($Clean -and (Test-Path $buildDir)) {
    Write-Host "Wiping $buildDir ..." -ForegroundColor Cyan
    Remove-Item -Recurse -Force $buildDir
}

# Configure (silent; only warnings/errors printed)
$confArgs = @('-S',$root, '-B',$buildDir, '-G','Ninja',
              "-DCMAKE_TOOLCHAIN_FILE=$root\cmake\toolchain.cmake",
              '-DCMAKE_BUILD_TYPE=Debug', '--log-level=WARNING')
if ($ninjaExe) { $confArgs += "-DCMAKE_MAKE_PROGRAM=$ninjaExe" }
& $cmakeExe @confArgs 2>&1 | Where-Object { "$_" -match 'error|warning|WARN|ERR' } |
    ForEach-Object { Write-Host "$_" -ForegroundColor Yellow }

# Build
& $cmakeExe --build $buildDir
$exitCode = $LASTEXITCODE

# Size table (optional - runs only if scripts/show-size.ps1 exists)
if ($exitCode -eq 0) {
    $helper = Join-Path $root 'scripts\show-size.ps1'
    if (Test-Path $helper) { & $helper -Root $root -BuildDir $buildDir }
}
exit $exitCode
'@

# ---- scripts/show-size.ps1 ---- (created once - Flash/RAM size table after build)
$scriptsDir = Join-Path $Root 'scripts'
if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory $scriptsDir | Out-Null }
Write-NewFile "$scriptsDir\show-size.ps1" @'
param(
    [string]$Root     = (Split-Path $PSScriptRoot -Parent),
    [string]$BuildDir = (Join-Path (Split-Path $PSScriptRoot -Parent) 'build\cmake')
)

$toolPaths = Join-Path $Root 'cmake\tool_paths.cmake'
$gcBin = $null; $gcPfx = $null
foreach ($ln in Get-Content $toolPaths -EA SilentlyContinue) {
    if ($ln -match 'TOOLCHAIN_GCC_BIN\s+"([^"]+)"')    { $gcBin = $Matches[1] }
    if ($ln -match 'TOOLCHAIN_GCC_PREFIX\s+"([^"]+)"') { $gcPfx = $Matches[1] }
}
$sizeExe = if ($gcBin -and $gcPfx) { "$gcBin\${gcPfx}size.exe" } else { $null }
if (-not $sizeExe -or -not (Test-Path $sizeExe)) { return }

$elf = Get-ChildItem "$BuildDir\*.elf" -EA SilentlyContinue | Select-Object -First 1
if (-not $elf) { return }

$sizeOut = & $sizeExe $elf.FullName 2>$null | Select-Object -Skip 1 -First 1
if ($sizeOut -notmatch '^\s*(\d+)\s+(\d+)\s+(\d+)') { return }
$flashUsed = [int]$Matches[1] + [int]$Matches[2]
$ramUsed   = [int]$Matches[2] + [int]$Matches[3]

$flashTotal = 0; $ramTotal = 0
$ldNameRun = 'mcu.ld'
foreach ($ln2 in Get-Content (Join-Path $Root 'cmake\mcu_config.cmake') -EA SilentlyContinue) {
    if ($ln2 -match 'MCU_LD_SCRIPT\s+"([^"]+)"') { $ldNameRun = $Matches[1]; break }
}
foreach ($ln in Get-Content (Join-Path $Root $ldNameRun) -EA SilentlyContinue) {
    if ($ln -match 'FLASH.*LENGTH\s*=\s*(\d+)K')  { $flashTotal = [int]$Matches[1] * 1024 }
    if ($ln -match '\bRAM\b.*LENGTH\s*=\s*(\d+)K') { $ramTotal   = [int]$Matches[1] * 1024 }
}

Write-Host ''
if ($flashTotal -gt 0) {
    $hr = '  ' + [string]::new([char]0x2500, 59)
    $fp = [int]($flashUsed * 100 / $flashTotal)
    $rp = [int]($ramUsed   * 100 / $ramTotal)
    $fc = if ($fp -lt 70) { 'Green' } elseif ($fp -lt 90) { 'Yellow' } else { 'Red' }
    $rc = if ($rp -lt 70) { 'Green' } elseif ($rp -lt 90) { 'Yellow' } else { 'Red' }
    # Clamp bar segments to [0,20] so >100% overflow doesn't crash [string]::new()
    $ff = [Math]::Max(0, [Math]::Min(20, [int]($fp/5)))
    $rf = [Math]::Max(0, [Math]::Min(20, [int]($rp/5)))
    $fb = [string]::new([char]0x2588, $ff)
    $fe = [string]::new([char]0x2591, 20 - $ff)
    $rb = [string]::new([char]0x2588, $rf)
    $re = [string]::new([char]0x2591, 20 - $rf)
    Write-Host $hr -ForegroundColor DarkGray
    Write-Host '   Flash  [' -NoNewline -ForegroundColor White
    if ($fb) { Write-Host $fb -NoNewline -ForegroundColor $fc }
    Write-Host $fe -NoNewline -ForegroundColor DarkGray
    Write-Host (']  {0,7:N0} / {1,7:N0} B  ({2,3}%)' -f $flashUsed,$flashTotal,$fp) -ForegroundColor White
    Write-Host '   RAM    [' -NoNewline -ForegroundColor White
    if ($rb) { Write-Host $rb -NoNewline -ForegroundColor $rc }
    Write-Host $re -NoNewline -ForegroundColor DarkGray
    Write-Host (']  {0,7:N0} / {1,7:N0} B  ({2,3}%)' -f $ramUsed,$ramTotal,$rp) -ForegroundColor White
    Write-Host $hr -ForegroundColor DarkGray
} else {
    $hr = '  ' + [string]::new([char]0x2500, 19)
    Write-Host $hr -ForegroundColor DarkGray
    Write-Host ('   Flash  {0,9:N0} B' -f $flashUsed) -ForegroundColor White
    Write-Host ('   RAM    {0,9:N0} B' -f $ramUsed)   -ForegroundColor White
    Write-Host $hr -ForegroundColor DarkGray
}
Write-Host ''
'@

# OpenOCD target cfg map - used by both tasks.json (flash) and launch.json (debug).
# For WCH-OpenOCD from MounRiver: bin/wch-riscv.cfg is a single self-contained
# config that already includes the adapter driver (wlinke) + target.
# Scripts dir is set to the bin/ folder so it can be found without a path prefix.
$ocdTargets = @{
    # ARM STM32
    'stm32f0'='target/stm32f0x.cfg'; 'stm32f1'='target/stm32f1x.cfg'
    'stm32f4'='target/stm32f4x.cfg'; 'stm32g0'='target/stm32g0x.cfg'
    'stm32g4'='target/stm32g4x.cfg'; 'stm32l4'='target/stm32l4x.cfg'
    'stm32h7'='target/stm32h7x0.cfg'
    # RISC-V WCH — all CH32V/X/L chips use wch-riscv.cfg (lives in bin/ dir)
    'ch32v003'='wch-riscv.cfg'; 'ch32v10'='wch-riscv.cfg'
    'ch32v20'='wch-riscv.cfg';  'ch32v3'='wch-riscv.cfg'
    'ch32x0'='wch-riscv.cfg';   'ch32l1'='wch-riscv.cfg'
}
$defaultOcdTarget = if ($mcu.Arch -eq 'RISCV') { 'wch-riscv.cfg' } else { 'target/stm32f1x.cfg' }
$ocdTarget = if ($ocdTargets.ContainsKey($mcu.Pattern)) { $ocdTargets[$mcu.Pattern] } else { $defaultOcdTarget }

# J-Link device names per family (for cortex-debug jlink servertype)
$jlinkDevices = @{
    'stm32f0'='STM32F030C8'; 'stm32f1'='STM32F103CB'
    'stm32f4'='STM32F407VG'; 'stm32g0'='STM32G030C8'
    'stm32g4'='STM32G431CB'; 'stm32l4'='STM32L432KC'
    'stm32h7'='STM32H743VI'
}
$jlinkDevice = if ($jlinkDevices.ContainsKey($mcu.Pattern)) { $jlinkDevices[$mcu.Pattern] } else { '' }

# SVD peripheral register files for Cortex-Debug xPerif window.
# STM32: modm-io/cmsis-svd-stm32 (complete coverage)
# WCH CH32: Community-PIO-CH32V/platform-ch32v misc/svd/ (community-curated from MounRiver Studio)
$svdStm = 'https://raw.githubusercontent.com/modm-io/cmsis-svd-stm32/main/'
$svdWch = 'https://raw.githubusercontent.com/Community-PIO-CH32V/platform-ch32v/master/misc/svd/'
$svdMap = @{
    # STM32 ARM families
    'stm32f0' = @{ Name='STM32F0x0.svd';   Url="${svdStm}stm32f0/STM32F0x0.svd"  }
    'stm32f1' = @{ Name='STM32F103.svd';   Url="${svdStm}stm32f1/STM32F103.svd"   }
    'stm32f4' = @{ Name='STM32F407.svd';   Url="${svdStm}stm32f4/STM32F407.svd"   }
    'stm32g0' = @{ Name='STM32G030.svd';   Url="${svdStm}stm32g0/STM32G030.svd"   }
    'stm32g4' = @{ Name='STM32G431.svd';   Url="${svdStm}stm32g4/STM32G431.svd"   }
    'stm32l4' = @{ Name='STM32L476.svd';   Url="${svdStm}stm32l4/STM32L476.svd"   }
    'stm32h7' = @{ Name='STM32H743.svd';   Url="${svdStm}stm32h7/STM32H743.svd"   }
    # WCH RISC-V families
    'ch32v003' = @{ Name='CH32V003xx.svd'; Url="${svdWch}CH32V003xx.svd" }
    'ch32v10'  = @{ Name='CH32V103xx.svd'; Url="${svdWch}CH32V103xx.svd" }
    'ch32v20'  = @{ Name='CH32V203xx.svd'; Url="${svdWch}CH32V203xx.svd" }
    'ch32v3'   = @{ Name='CH32V307xx.svd'; Url="${svdWch}CH32V307xx.svd" }
    'ch32x0'   = @{ Name='CH32X035xx.svd'; Url="${svdWch}CH32X035xx.svd" }
    'ch32l1'   = @{ Name='CH32L103xx.svd'; Url="${svdWch}CH32L103xx.svd" }
}
$svdRelPath = ''
if ($svdMap.ContainsKey($mcu.Pattern)) {
    $svdEntry = $svdMap[$mcu.Pattern]
    $svdDir   = Join-Path $Root 'device\svd'
    $svdDest  = Join-Path $svdDir $svdEntry.Name
    if (-not (Test-Path $svdDir)) { New-Item -ItemType Directory -Path $svdDir | Out-Null }
    if (Test-Path $svdDest) {
        Write-Host ("[SVD] {0} already present" -f $svdEntry.Name) -ForegroundColor Green
    } else {
        Write-Host ("[SVD] Downloading {0}..." -f $svdEntry.Name) -ForegroundColor Cyan
        try {
            Invoke-Download $svdEntry.Url $svdDest
            Write-Host ("[SVD] Saved to device/svd/{0}" -f $svdEntry.Name) -ForegroundColor Green
        } catch {
            Write-Host ("[SVD] Download failed: $_") -ForegroundColor Yellow
            Write-Host ("[SVD] Download manually from:`n      {0}" -f $svdEntry.Url) -ForegroundColor DarkGray
            Write-Host ("[SVD] Save as: device/svd/{0}" -f $svdEntry.Name) -ForegroundColor DarkGray
            if (Test-Path $svdDest) { Remove-Item $svdDest }
        }
    }
    if (Test-Path $svdDest) {
        $svdRelPath = '${workspaceFolder}/device/svd/' + $svdEntry.Name
    }
} else {
    Write-Host "[SVD] No SVD available for this MCU family (xPerif will be empty)" -ForegroundColor DarkGray
}

# ---- .vscode/tasks.json ----
# Common (cmake) part uses single-quote here-string so ${workspaceFolder} stays literal for VS Code.
# Flash tasks are built dynamically - paths injected directly (no __PLACEHOLDER__ replacements needed).
# Tcl {} braces in the -c argument prevent backslash processing of Windows paths by OpenOCD.
$cmakeTasksTmpl = @'
{
    "version": "2.0.0",
    "tasks": [
        {
            "label": "cmake build",
            "type": "shell",
            "command": "powershell",
            "args": ["-ExecutionPolicy", "Bypass", "-File", "${workspaceFolder}/build.ps1"],
            "group": { "kind": "build", "isDefault": true },
            "problemMatcher": {
                "owner": "gcc",
                "fileLocation": ["absolute"],
                "pattern": {
                    "regexp": "^(.*):(\\d+):(\\d+):\\s+(warning|error):\\s+(.*)$",
                    "file": 1, "line": 2, "column": 3, "severity": 4, "message": 5
                }
            }
        },
        {
            "label": "cmake clean build",
            "type": "shell",
            "command": "powershell",
            "args": ["-ExecutionPolicy", "Bypass", "-File", "${workspaceFolder}/build.ps1", "-Clean"],
            "group": "build",
            "problemMatcher": []
        }__FLASH_TASKS____STATIC_TASKS__
    ]
}
'@

# Build arch-specific flash tasks with all paths directly embedded.
# ${workspaceFolder} inside -c must be wrapped in Tcl {} braces so OpenOCD's
# Tcl interpreter doesn't eat the backslashes on Windows paths.
$elfPath    = '${workspaceFolder}/build/cmake/' + $projName + '.elf'
$programCmd = 'program {' + $elfPath + '} verify reset exit'

if ($ocdFwd) {
    if ($mcu.Arch -eq 'RISCV') {
        # RISC-V: WCH-Link via WCH-OpenOCD (MounRiver Studio).
        # wch-riscv.cfg is a single self-contained config (adapter + target in one file).
        $flashTasksJson = @"
        ,{
            "label": "flash (WCH-Link)",
            "type": "shell",
            "command": "$ocdFwd",
            "args": [
                "-s", "$ocdScriptsFwd",
                "-f", "$ocdTarget",
                "-c", "$programCmd"
            ],
            "group": "build",
            "problemMatcher": []
        }
"@
    } else {
        # ARM: ST-Link and CMSIS-DAP (both via xpack-OpenOCD)
        # Note: WCH-Link in CMSIS-DAP mode also works via the CMSIS-DAP task
        $flashTasksJson = @"
        ,{
            "label": "flash (ST-Link)",
            "type": "shell",
            "command": "$ocdFwd",
            "args": [
                "-s", "$ocdScriptsFwd",
                "-f", "interface/stlink.cfg",
                "-f", "$ocdTarget",
                "-c", "$programCmd"
            ],
            "group": "build",
            "problemMatcher": []
        },
        {
            "label": "flash (CMSIS-DAP)",
            "type": "shell",
            "command": "$ocdFwd",
            "args": [
                "-s", "$ocdScriptsFwd",
                "-f", "interface/cmsis-dap.cfg",
                "-f", "$ocdTarget",
                "-c", "$programCmd"
            ],
            "group": "build",
            "problemMatcher": []
        }
"@
    }
} else {
    $flashTasksJson = ''  # no OpenOCD found - cmake tasks only
}

# Static analysis tasks (objdump/readelf/size/nm).
# Logic lives in .vscode/scripts/elf-tools.ps1 (generated below).
# Tasks call it via `powershell -File` so each path/arg is quoted by VS Code
# individually — sidesteps Windows command-line quote-stripping that breaks
# `-Command` inline-strings when toolchain paths contain spaces.
$elfToolsScript = @'
# Generated by setup.ps1 - do not edit manually.
# Helper for VS Code tasks: runs binutils tools on the ELF and (where applicable)
# writes output to a file next to the ELF and opens it in VS Code.

param(
    [Parameter(Mandatory=$true)]
    [ValidateSet('disassembly','readelf','size','nm')]
    [string]$Action,

    [Parameter(Mandatory=$true)]
    [string]$Elf,

    [Parameter(Mandatory=$true)]
    [string]$Tool
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path $Tool)) { Write-Error "Tool not found: $Tool"; exit 1 }
if (-not (Test-Path $Elf))  { Write-Error "ELF not found: $Elf (build first)"; exit 1 }

switch ($Action) {
    'disassembly' {
        $out = $Elf -replace '\.elf$', '.lst'
        & $Tool -d -S -l --demangle $Elf | Out-File -Encoding utf8 $out
        Write-Host "Wrote disassembly: $out" -ForegroundColor Green
        code $out
    }
    'readelf' {
        $out = $Elf -replace '\.elf$', '.elf.txt'
        & $Tool -a $Elf | Out-File -Encoding utf8 $out
        Write-Host "Wrote ELF info: $out" -ForegroundColor Green
        code $out
    }
    'size' {
        & $Tool -A $Elf
    }
    'nm' {
        $out = $Elf -replace '\.elf$', '.syms.txt'
        & $Tool --print-size --size-sort --radix=x $Elf | Out-File -Encoding utf8 $out
        Write-Host "Wrote symbol table: $out" -ForegroundColor Green
        code $out
    }
}
'@
$scriptsDir = Join-Path $VsCodeDir 'scripts'
if (-not (Test-Path $scriptsDir)) { New-Item -ItemType Directory -Path $scriptsDir | Out-Null }
Write-InfraFile "$scriptsDir\elf-tools.ps1" $elfToolsScript

# Build the 4 tasks. Each arg is a separate JSON string so VS Code quotes
# spaces correctly. $gccBinFwd/$gccPrefix/$projName are expanded NOW; the
# `${workspaceFolder} stays literal for VS Code to expand at task-run time.
$staticTasksJson = @"
        ,{
            "label": "disassembly -> .lst",
            "type": "shell",
            "command": "powershell",
            "args": [
                "-ExecutionPolicy", "Bypass",
                "-File", "`${workspaceFolder}/.vscode/scripts/elf-tools.ps1",
                "-Action", "disassembly",
                "-Elf", "`${workspaceFolder}/build/cmake/$projName.elf",
                "-Tool", "$gccBinFwd/${gccPrefix}objdump.exe"
            ],
            "group": "build",
            "presentation": { "reveal": "always", "panel": "dedicated" },
            "problemMatcher": []
        },{
            "label": "elf info (readelf -a)",
            "type": "shell",
            "command": "powershell",
            "args": [
                "-ExecutionPolicy", "Bypass",
                "-File", "`${workspaceFolder}/.vscode/scripts/elf-tools.ps1",
                "-Action", "readelf",
                "-Elf", "`${workspaceFolder}/build/cmake/$projName.elf",
                "-Tool", "$gccBinFwd/${gccPrefix}readelf.exe"
            ],
            "group": "build",
            "presentation": { "reveal": "always", "panel": "dedicated" },
            "problemMatcher": []
        },{
            "label": "section sizes",
            "type": "shell",
            "command": "powershell",
            "args": [
                "-ExecutionPolicy", "Bypass",
                "-File", "`${workspaceFolder}/.vscode/scripts/elf-tools.ps1",
                "-Action", "size",
                "-Elf", "`${workspaceFolder}/build/cmake/$projName.elf",
                "-Tool", "$gccBinFwd/${gccPrefix}size.exe"
            ],
            "group": "build",
            "presentation": { "reveal": "always", "panel": "dedicated", "focus": true },
            "problemMatcher": []
        },{
            "label": "symbol table (nm) -> .syms.txt",
            "type": "shell",
            "command": "powershell",
            "args": [
                "-ExecutionPolicy", "Bypass",
                "-File", "`${workspaceFolder}/.vscode/scripts/elf-tools.ps1",
                "-Action", "nm",
                "-Elf", "`${workspaceFolder}/build/cmake/$projName.elf",
                "-Tool", "$gccBinFwd/${gccPrefix}nm.exe"
            ],
            "group": "build",
            "presentation": { "reveal": "always", "panel": "dedicated" },
            "problemMatcher": []
        }
"@

$tasksJsonContent = $cmakeTasksTmpl.Replace('__CMAKE__', $cmakeFwd).Replace('__NINJA__', $ninjaFwd).Replace('__FLASH_TASKS__', $flashTasksJson).Replace('__STATIC_TASKS__', $staticTasksJson)
Write-InfraFile "$VsCodeDir\tasks.json" $tasksJsonContent

# ---- .vscode/c_cpp_properties.json ----
# compileCommands provides exact build flags (includes, defines) from CMake.
# compilerPath (now always space-free via junction) lets cpptools run the compiler
# to discover built-in system headers (stdint.h etc.).
# __attribute__(x)= suppresses WCH-specific GCC attributes that confuse IntelliSense.
$isMode    = if ($mcu.Arch -eq 'ARM') { 'gcc-arm' } else { 'gcc-riscv64' }
$cfgName   = ($mcu.Family -split '[ /\(]')[0]
$gccExeFwd = "$gccBinFwd/$($gccPrefix)gcc.exe"
$cppPropContent = @"
{
    "configurations": [
        {
            "name": "$cfgName",
            "compileCommands": "`${workspaceFolder}/build/cmake/compile_commands.json",
            "compilerPath": "$gccExeFwd",
            "intelliSenseMode": "$isMode",
            "defines": ["__attribute__(x)="],
            "includePath": [
                "`${workspaceFolder}/user/inc",
                "`${workspaceFolder}/**"
            ]
        }
    ],
    "version": 4
}
"@
Write-InfraFile "$VsCodeDir\c_cpp_properties.json" $cppPropContent

# ---- .vscode/settings.json ----
Write-NewFile "$VsCodeDir\settings.json" @'
{
    "cmake.configureOnOpen": false,
    "files.exclude": {
        "**/build": true,
        "**/.downloaded_*": true
    }
}
'@

# ---- .vscode/launch.json ----
# launch.json is always regenerated (Write-InfraFile) because it contains
# machine-specific openocd paths and changes with debugger hardware choice.
$serverPath = if ($ocdFwd) { "`"serverpath`": `"$ocdFwd`"," } else { '' }
$searchDir  = if ($ocdScriptsFwd) { "`"searchDir`": [`"$ocdScriptsFwd`"]," } else { '' }

# GDB path: always prefer fast GDB 14.2 from tools-mcu (no Python = instant startup).
# Fall back to the found system/EIDE GDB only if fast GDB download failed.
$gdbExe = Join-Path $gccBin ($gccPrefix + 'gdb.exe')
$gdbFwd = if ($fastGdbFwd) { $fastGdbFwd }
          elseif (Test-Path $gdbExe) { $gdbExe.Replace('\', '/') }
          else { '' }
$gdbPathLine = if ($gdbFwd) { "`"gdbPath`": `"$gdbFwd`"," } else { '' }
$svdLine     = if ($svdRelPath) { "`"definitionPath`": `"$svdRelPath`"," } else { "`"definitionPath`": `"`"," }

if ($mcu.Arch -eq 'ARM' -and $ocdTarget) {
    $jlinkBlock = if ($jlinkDevice) { @"
        ,{
            "name": "Debug (J-Link)",
            "type": "cortex-debug",
            "request": "launch",
            "servertype": "jlink",
            "device": "$jlinkDevice",
            "interface": "swd",
            $gdbPathLine
            "executable": "`${workspaceFolder}/build/cmake/$projName.elf",
            $svdLine
            "runToEntryPoint": "main",
            "showDevDebugOutput": "none",
            "preLaunchTask": "cmake build"
        }
"@ } else { '' }
    $launchContent = @"
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug (ST-Link)",
            "type": "cortex-debug",
            "request": "launch",
            "servertype": "openocd",
            $serverPath
            $searchDir
            $gdbPathLine
            "executable": "`${workspaceFolder}/build/cmake/$projName.elf",
            "configFiles": ["interface/stlink.cfg", "$ocdTarget"],
            $svdLine
            "runToEntryPoint": "main",
            "showDevDebugOutput": "none",
            "preLaunchTask": "cmake build"
        },
        {
            "name": "Debug (CMSIS-DAP)",
            "type": "cortex-debug",
            "request": "launch",
            "servertype": "openocd",
            $serverPath
            $searchDir
            $gdbPathLine
            "executable": "`${workspaceFolder}/build/cmake/$projName.elf",
            "configFiles": ["interface/cmsis-dap.cfg", "$ocdTarget"],
            $svdLine
            "runToEntryPoint": "main",
            "showDevDebugOutput": "none",
            "preLaunchTask": "cmake build"
        }$jlinkBlock
    ]
}
"@
} elseif ($mcu.Arch -eq 'RISCV') {
    $launchContent = @"
{
    "version": "0.2.0",
    "configurations": [
        {
            "name": "Debug (WCH-Link)",
            "type": "cortex-debug",
            "request": "launch",
            "servertype": "openocd",
            $serverPath
            $searchDir
            $gdbPathLine
            "executable": "`${workspaceFolder}/build/cmake/$projName.elf",
            "configFiles": ["$ocdTarget"],
            $svdLine
            "runToEntryPoint": "main",
            "showDevDebugOutput": "none",
            "preLaunchTask": "cmake build"
        }
    ]
}
"@
} else {
    $launchContent = $null
}
if ($launchContent) { Write-InfraFile "$VsCodeDir\launch.json" $launchContent }

# ---- .gitignore ----
Write-NewFile "$Root\.gitignore" @'
/build/
/cmake/tool_paths.cmake
/device/.downloaded_*
/.vscode/launch.json
*.o
*.d
'@

# ---- user/src/main.c ----
$mcuHeader = if ($mcu.Header) { $mcu.Header } else { $mcuDefine.ToLower() + '.h' }
Write-NewFile "$Root\user\src\main.c" @"
#include <stdint.h>
#include `"$mcuHeader`"  // MCU peripheral register definitions

int main(void)
{
    while (1) {
        // your code here
    }
}
"@

Write-Host ""

# ==============================================================
# STEP 5: Generate cmake/tool_paths.cmake
# ==============================================================
$toolPathsContent = @"
# Auto-generated by setup.ps1 - do not edit manually.
# Re-run setup.ps1 to update.  Do not commit this file (machine-specific paths).
# Shared tools folder: $SharedDir
set(TOOLCHAIN_GCC_BIN    "$gccBinFwd")
set(TOOLCHAIN_GCC_PREFIX "$gccPrefix")
set(CMAKE_MAKE_PROGRAM   "$ninjaFwd"  CACHE FILEPATH "Ninja"  FORCE)
set(CMAKE_EXE            "$cmakeFwd" CACHE FILEPATH "CMake"  FORCE)
$(if ($cmsisDir) { "set(CMSIS_DIR   ""$cmsisDir"" CACHE PATH ""ARM CMSIS Core headers"" FORCE)" })
$(if ($ocdFwd)   { "set(OPENOCD_EXE ""$ocdFwd""   CACHE FILEPATH ""OpenOCD executable"" FORCE)" })
"@
[System.IO.File]::WriteAllText("$CmakeDir\tool_paths.cmake", $toolPathsContent, [System.Text.Encoding]::UTF8)

# ==============================================================
# STEP 6: Generate cmake/mcu_config.cmake  and  cmake/mcu_arch.txt
# ==============================================================
$needsCmsis = if ($mcu.NeedsCmsis) { "TRUE" } else { "FALSE" }

$mcuConfigContent = @"
# Auto-generated by setup.ps1 - re-run to change MCU.
set(MCU_FAMILY       "$($mcu.Family)")
set(MCU_ARCH         "$($mcu.Arch)")
set(MCU_CPU_FLAGS    "$($mcu.CpuFlags)")
set(MCU_FLOAT_ABI    "$($mcu.FloatABI)")
set(MCU_FPU_FLAGS    "$($mcu.FpuFlags)")
set(MCU_DEFINE       "$($mcuDefine)")
set(MCU_EXTRA_DEFINE "$($mcuExtraDefine)")
set(MCU_STARTUP      "device/src/startup.s")
set(MCU_SYSTEM       "device/src/$($mcu.SystemFile)")
set(MCU_LD_SCRIPT    "$ldName")
set(MCU_NEEDS_CMSIS  $needsCmsis)
"@
[System.IO.File]::WriteAllText("$CmakeDir\mcu_config.cmake", $mcuConfigContent, [System.Text.Encoding]::UTF8)
[System.IO.File]::WriteAllText("$CmakeDir\mcu_arch.txt",     $mcu.Arch,          [System.Text.Encoding]::UTF8)

Write-Host "[cmake] Config files updated" -ForegroundColor Green

# ==============================================================
# STEP 7: Update .vscode/tasks.json with actual cmake/ninja paths
# ==============================================================
$tasksFile = Join-Path $VsCodeDir "tasks.json"
if (Test-Path $tasksFile) {
    $raw = [System.IO.File]::ReadAllText($tasksFile)
    $raw = $raw -replace '("command"\s*:\s*")[^"]*cmake(?:\.exe)?(")', ('${1}' + $cmakeFwd + '${2}')
    $raw = $raw -replace '("-DCMAKE_MAKE_PROGRAM=)[^"]+(")',           ('${1}' + $ninjaFwd + '${2}')
    if ($ocdFwd) {
        # Update openocd executable path in flash tasks
        $raw = $raw -replace '("command"\s*:\s*")[^"]*openocd(?:\.exe)?(")', ('${1}' + $ocdFwd + '${2}')
        $raw = $raw -replace '("-s"\s*,\s*")[^"]+(?:openocd|scripts)[^"]*(")', ('${1}' + $ocdScriptsFwd + '${2}')
    }
    [System.IO.File]::WriteAllText($tasksFile, $raw, [System.Text.Encoding]::UTF8)
    Write-Host "[tasks.json] cmake/ninja paths updated" -ForegroundColor Green
}

# Ensure cmake/tool_paths.cmake is in .gitignore (machine-specific)
$gitignoreFile = Join-Path $Root ".gitignore"
if (Test-Path $gitignoreFile) {
    $gi = Get-Content $gitignoreFile -Raw
    if ($gi -notmatch "tool_paths\.cmake") {
        Add-Content $gitignoreFile "`n# Machine-specific tool paths (generated by setup.ps1)`n/cmake/tool_paths.cmake"
        Write-Host "[.gitignore] Added cmake/tool_paths.cmake" -ForegroundColor Green
    }
}

# ==============================================================
# Done
# ==============================================================
Write-Host ""
Write-Host "=============================" -ForegroundColor Green
Write-Host "  Setup complete!" -ForegroundColor Green
Write-Host "=============================" -ForegroundColor Green
Write-Host ""
Write-Host "  Shared tools : $SharedDir" -ForegroundColor DarkGray
Write-Host "  Project root : $Root"      -ForegroundColor DarkGray
if ($fastGdbFwd) {
    Write-Host ("  GDB (debug)  : {0}" -f $fastGdbFwd) -ForegroundColor DarkGray
} elseif ($gdbFwd) {
    Write-Host ("  GDB (debug)  : {0}  (may be slow on first launch)" -f $gdbFwd) -ForegroundColor Yellow
}
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  1. Check device/inc/ - MCU header should be there"
Write-Host "  2. Press Ctrl+Shift+B to build"
Write-Host "  3. Press F5 to debug  (ST-Link / CMSIS-DAP)"
Write-Host ""
Write-Host "Tip: other MCU projects can reuse the same shared tools folder." -ForegroundColor DarkGray
Write-Host ""
Read-Host "Press Enter to close"
