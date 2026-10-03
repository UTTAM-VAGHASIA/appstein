# Security policy

## Supported versions

Appstein is pre-alpha and not released yet. Only the `main` branch gets fixes.

## Reporting a vulnerability

Please don't open a public issue for a security problem. Report it privately:

- **Preferred:** GitHub's private reporting. Open the repository's **Security** tab and choose **Report a vulnerability**.
- **Or email** the.uttam.vaghasia@gmail.com.

Say what you found, how to reproduce it, and what an attacker could do with it. Appstein is a one-person project, so a reply may take a few days. You'll hear back before anything about the problem is made public.

## Scope

Appstein runs locally, inside your own agent sessions: the `appstein` CLI, its git and agent hooks, and the files it writes into your project. In scope, for example: a command or hook that runs code it shouldn't, writes outside the project, or sends data anywhere. Appstein never handles agent credentials, so any way it could read or expose them is in scope too.
