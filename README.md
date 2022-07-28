# Ace of Diamonds

## What is this ?

This is a script leveraging Ffmpeg to mass-transcode files to either Vorbis ou FLAC.

## Requirements 

Ffmpeg (and Ffprobe) are required. 
The script was developped using Bash 5 ; it requires a Bash version at least superior to 3.2.75.

## Usage

Invoke the script with the `input`, `output` and `codec` parameters (at least).

```bash
$ ./aofd.bash --input ~/Musics/To/Transcode -output ~/Musics/Transcoded -codec vorbis
```

Other parameters and options are available ; use the `--help` to learn everything about it.

WARNING: during execution, some files will crash the ffmpeg, thus crashing the script, which will stop execution.