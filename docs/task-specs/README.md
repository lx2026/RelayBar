# Task Specifications

Task specs are executable delivery contracts. Active specs live directly in this directory. Accepted specs move to [`archive/`](archive/).

## Required structure

Each new task should define:

- the intended outcome;
- the current authorities and constraints;
- what is included and excluded;
- the required work;
- observable acceptance checks;
- completion artifacts and explicitly deferred work.

Keep requirements in one place and keep future ideas outside the current acceptance boundary.

## Completion protocol

A task may be marked `Complete` only after:

1. every acceptance criterion has current evidence;
2. affected files under [`../system-specs/`](../system-specs/) describe the implemented behavior;
3. relevant automated and manual checks pass;
4. required evidence is recorded;
5. the spec is moved to [`archive/`](archive/).

Completion does not authorize a commit, push, release, or deployment. Follow [`AGENTS.md`](../../AGENTS.md) and obtain explicit deployment approval.

## Active tasks

- [Task 020 — Escape Remote Paths That sftp Would Glob](020-escape-glob-metacharacter-paths.md)
