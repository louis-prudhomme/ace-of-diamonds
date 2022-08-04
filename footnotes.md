# On footnotes

These are the footnotes for the `ace-of-diamonds` project. They serve as extended documentation to better understand why some choices were made, notably regarding ffmpeg flags and options.

# Table of Contents <!-- omit in toc -->
- [On footnotes](#on-footnotes)
- [1. OGG containers and OGX](#1-ogg-containers-and-ogx)

# 1. OGG containers and OGX

OGG is a container. While the associated Vorbis codec is often contained within an OGG container, it can also be contained in other containers such as MKV.

Similarly, the OGG container can contain other streams, whether video or audio. The nomenclature then wants it to be called OGX ; yet, the same-ish headers and hexadecimal organization can be found within, which can lead to mistake on with another.

To avoid creating OGX « by mistake » (creating a OGG container embedding a video stream), it is necessary to use the `-vn` ffmpeg flag to strip non-audio streams.