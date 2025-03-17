# SSH-AGENT-SWITCHER DEV GUIDE

## Build Commands
- Build with Go: `go build`
- Build with Bazel: `bazel build -c opt //:ssh-agent-switcher`
- Run integration tests: `./inttest.sh` or `bazel test //:inttest`
- Test single test (with shtk): `shtk_unittest_one_test inttest.sh integration list_identities`

## Code Style
- Format: Standard Go formatting (`gofmt`)
- Imports: Standard library first, then third-party, alphabetically sorted
- Error handling: Return errors with context using `fmt.Errorf("operation failed: %v", err)`
- Logging: Use `log` package for operational logging
- File naming: Lowercase with hyphens for binaries (`ssh-agent-switcher`)
- Code comments: Full sentences with periods, start with function/variable name
- Variable naming: camelCase for variables, CamelCase for exported items
- Line length: Keep under 100 characters when possible

## Project Organization
- Single binary application written in Go
- Testing via shell script using shtk framework
- Bazel build system support