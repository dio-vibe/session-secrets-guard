# Security Policy

## What this project is

This project provides:

- prompt and tool secret guardrails
- local secret reference parsing
- secret resolution into child-process environment variables

This project does not aim to be a vault, key escrow, or secure remote secret
storage service.

## Reporting a vulnerability

Do not open a public issue with a live secret, a screenshot of a live secret,
or a transcript that contains a live secret.

If you find a vulnerability, report:

- the affected version or commit
- the expected behavior
- the actual behavior
- a reproduction using fake credentials only

If you already exposed a real credential while testing, rotate that credential
first, then report the vulnerability with a sanitized reproduction.

## Safe disclosure expectations

- Never include real secrets in pull requests or issues.
- Prefer fake sample values such as `ghp_example_not_real_1234567890`.
- Assume any secret that appeared in a terminal, screenshot, or transcript may
  need rotation.

