# Security policy

Loom runs on your Windows machine and can change installed programs, services, registry values,
Windows features and setup media. Please treat reports about that power carefully.

## Reporting a vulnerability

Do not open a public issue, and do not send a pull request that describes the problem in the open.

Use [private vulnerability reporting](https://github.com/TomFleuren/Loom/security/advisories/new)
on this repository. If that is unavailable, contact the repository owner on GitHub with the
subject "Loom security".

Include what you did, what you expected, and what happened. A small proof is enough. Please give
the maintainers a chance to respond before you publish anything.

## What to report

- The app or installer doing something the person did not ask for.
- A way to make Loom run a script or a path that did not come from its own catalog.
- Writing a setup image or USB drive to the wrong disk.
- Secrets, credentials or private files ending up in the log.

## What this is not

A tweak you dislike, a Windows setting you would choose differently, or a package that fails to
install upstream, is a normal issue. Open one. Those are not vulnerabilities.
