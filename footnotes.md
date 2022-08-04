# On footnotes

These are the footnotes for the `ace-of-diamonds` project. They serve as extended documentation to better understand why some choices were made, notably regarding ffmpeg flags and options.

# Table of Contents <!-- omit in toc -->
- [On footnotes](#on-footnotes)
- [1. On OGG containers and OGX](#1-on-ogg-containers-and-ogx)
- [2. On the choice of Bash](#2-on-the-choice-of-bash)
- [3. On comments](#3-on-comments)

# 1. On OGG containers and OGX

OGG is a container. While the associated Vorbis codec is often contained within an OGG container, it can also be contained in other containers such as MKV.

Similarly, the OGG container can contain other streams, whether video or audio. The nomenclature then wants it to be called OGX ; yet, the same-ish headers and hexadecimal organization can be found within, which can lead to mistake on with another.

To avoid creating OGX « by mistake » (creating an OGG container embedding a video stream), it is necessary to use the `-vn` ffmpeg flag to strip non-audio streams.

# 2. On the choice of Bash

Bash is often mockingly considered as a _read-only language_. This probably stems from the versatility of its uses as well as its heavily fragmented userspace.

As the [Google Shellguide](https://google.github.io/styleguide/shellguide.html) put it: `If you are writing a script that is more than 100 lines long, or that uses non-straightforward control flow logic, you should rewrite it in a more structured language now. Bear in mind that scripts grow. Rewrite your script early to avoid a more time-consuming rewrite at a later date`.

The present author has already tried to use a ffmpeg wrapper in a more maintainable language, but this attempt failed, notably for a relative lack of flexibility. Direct access to ffmpeg was required.

Moreover, while the control flow might not be "straightforward", the author felt the risk was calculated and could be mitigated with several tricks:
- code reuse & separation
- heavy comments (see [3. On comments](#3-on-comments))

# 3. On comments

Comments are code and code should be maintained. Function comments, notably, are crucial.

They should feature:
- a brief description of the function goal
- expected parameters and a description
  - `+` denotes a global parameter (declared and set outside the function scope)
  - `!` denotes a mandatory parameter
  - `?` denotes an optional parameter
  - `*` denotes an array parameter
  - ideally, a word in the following description indicates the expected parameter type
- interaction with global parameters
- return codes and values
  - `echoes` is what the function `echo` on its STDOUT