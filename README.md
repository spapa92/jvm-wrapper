# jvmw — JDK Version Manager for Windows

> Like `nvm` for Node.js, but for Java. Terminal-ready and agent-friendly.

Downloads JDKs from **Adoptium (Eclipse Temurin)** — the de-facto open standard build.

---

## Quick Start

```powershell
# Install jvmw
.\install.ps1

# List available JDK versions
jvmw available --lts

# Install JDK 21 (LTS)
jvmw install 21

# Switch to JDK 21
jvmw use 21

# Verify
jvmw current
java -version
```

---

## Commands

| Command | Description |
|---|---|
| `jvmw list` | List installed JDKs |
| `jvmw available [--lts]` | List downloadable versions from Adoptium |
| `jvmw install <version>` | Download and install a JDK |
| `jvmw use <version>` | Switch active JDK (session + persistent) |
| `jvmw current` | Show active JDK |
| `jvmw remove <version>` | Uninstall a JDK |
| `jvmw path <version>` | Print JAVA_HOME path for a version |
| `jvmw env <version>` | Print PowerShell env-var commands |
| `jvmw which` | Show java binary in use |
| `jvmw doctor` | Diagnose PATH and JAVA_HOME |

---

## Agent / Automation Usage

Every command supports `--json` for structured output:

```powershell
# List installed (machine-readable)
jvmw --json list

# Check current
jvmw --json current

# Install silently (no prompts)
jvmw --json --force install 17

# Available versions
jvmw --json available --lts
```

### JSON output shape

```json
{
  "success": true,
  "exitCode": 0,
  "message": "Current JDK: jdk-21",
  "data": {
    "name": "jdk-21",
    "major": 21,
    "javaHome": "C:\\Users\\user\\.jvmw\\jdks\\jdk-21",
    "javaVersion": "openjdk version \"21.0.3\" 2024-04-16 LTS"
  },
  "timestamp": "2024-04-16T10:00:00.000Z"
}
```

Exit code `0` = success, non-zero = failure. Use `$LASTEXITCODE` to check in scripts.

### Agent pattern example

```powershell
# An agent selects the right JDK for a Maven project requiring Java 17
$result = jvmw --json --force install 17 | ConvertFrom-Json
if ($result.success) {
    jvmw --json --force use 17 | Out-Null
    mvn clean package
}
```

### Get env vars without switching globally

```powershell
# Print vars to dot-source them
jvmw env 21
# Output:
# $env:JAVA_HOME = 'C:\Users\user\.jvmw\jdks\jdk-21'
# $env:PATH = 'C:\Users\user\.jvmw\jdks\jdk-21\bin;...'
```

---

## Flags

| Flag | Description |
|---|---|
| `--json` | Machine-readable JSON output |
| `--silent` | Suppress decorative output |
| `--force` | Skip confirmation prompts |
| `--lts` | Filter LTS-only versions (with `available`) |
| `--global` | Modify Machine-scope env (requires elevation) |

---

## How it works

- JDKs are stored in `%USERPROFILE%\.jvmw\jdks\jdk-<major>\`
- Active version is persisted in `%USERPROFILE%\.jvmw\config.json`
- `use` sets both `JAVA_HOME` and prepends `bin\` to `PATH` — in the current process AND in the User env scope (persistent across terminals)
- Downloads via Adoptium REST API v3 — no external tools required

---

## Installation

```powershell
# User install (default, no elevation)
.\install.ps1

# System-wide (requires admin)
.\install.ps1 -Global

# Uninstall
.\install.ps1 -Uninstall
```

After install, `jvmw` is available as:
- `jvmw` in PowerShell (via PATH)
- `jvmw.cmd` in cmd.exe

---

## Requirements

- Windows 10/11
- PowerShell 5.1+
- Internet access (for downloads)
- No Java pre-installed needed
