# Appstein

Appstein is a knowledge and verification layer for AI agents that build Flutter apps. These are the words its design, guide and code use for its own concepts; the general terms an owner may need are in §23 of the product design.

## Language

### Verifying

**Fast run**:
A verify run made after every change, limited to the checks that answer within seconds.
_Avoid_: quick check, hook check

**Full run**:
A verify run made when the work is said to be done, with every check.
_Avoid_: complete check, deep check

**Unverified files**:
The files changed since a verify run last found no error in them.
_Avoid_: changed files, dirty files, pending files

**Warm analysis**:
Analysis of the project's Dart code by an analyzer that is already running and has the project loaded, as opposed to one started for the question.
_Avoid_: hot analysis, cached analysis

**Analysis host**:
The one background process per project that keeps the project's analysis server running and answers the code questions of every session, hook and tool that works on the project.
_Avoid_: daemon, broker, analysis service
