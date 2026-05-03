# Security Policy

## Reporting a Vulnerability

**Do NOT open a public issue for security vulnerabilities.**

Email **zhhlbaw2011@gmail.com** with:

1. Description of the vulnerability
2. Steps to reproduce
3. Potential impact
4. Suggested fix (if any)

You will receive a response within 72 hours.

## Scope

In scope:

- **Hook scripts** (`src/*.sh`) — command injection, path traversal, prompt manipulation
- **Routing engine** — bypass of model tier policy, unsafe regex behavior
- **Configuration** — secrets exposure, unsafe defaults

## Out of Scope

- Issues in third-party tools (RTK / Claude Code / Codex / Ollama) — report upstream
- Issues requiring physical access to the user's machine
- Social engineering attacks
- ModelSelector is a local routing layer — there is no hosted service to attack

## Disclosure Policy

Coordinated disclosure. Once a fix is released, the reporter is credited (unless anonymous is preferred) in the release notes.
