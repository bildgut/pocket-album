# Security Policy

## Reporting a vulnerability

Please **do not** open a public issue for security problems. Use GitHub's private
reporting instead: **Security → Report a vulnerability** on this repository.

Include what you found, how to reproduce it and which version you tested. You'll get an
answer within a few days.

## Scope

Pocket Album stores your server address and API key on the phone and sends the key with
every request to your Immich server. Especially interesting are ways the key could reach a
host other than your server, be written to logs, or survive signing out.

Vulnerabilities in Immich itself belong to the [Immich project](https://github.com/immich-app/immich/security).
