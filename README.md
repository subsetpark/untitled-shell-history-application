# `U.S.H.A.`:

## Untitled Shell History Application

```
usha: search your command-line history.

Usage:
  usha init [-v]
  usha clean [DAYS]
  usha update [-v] CMD [-c CHECKSUM]
  usha [DIR] [-n N] [-tvrs SEARCHSTRING]

Options:
  DIR             Directory to search within.
  CMD             Insert command into database.
  DAYS            Number of days of history to preserve. [default: 60]
  -n N            Retrieve the N most common commands. [default: 5]
  -s SEARCHSTRING Search for commands containing a string.
  -t              Order by most recently entered.
  -v              Verbose.
  -r              Recurse current directory.
  -c CHECKSUM     Optional argument to update to prevent duplication.
```

`usha` was inspired by Denis Gladkikh's [DBHist][] post and shell script. It has few innovations over that script; mostly, it seemed like a fun project and I wanted to make my own. But I also don't use bash and wanted a shell-agnostic equivalent to Denis's program.

[DBHist]: https://www.outcoldman.com/en/archive/2017/07/19/dbhist/

As such `usha` is a standalone binary which you should put into the right part of your shell loop. It expects to be called with `update` in order to add new items to its history table. For instance, as a part of my `prompt()` routine in my shell, I call `usha update` with the most recent item in my shell's history.

I also have `hh` (*history here*) aliased to `usha .`, meaning 'show me the 5 most common commands that I have run in this directory.'

`usha` looks for the presence of a `.ushaignore` file in the user's home directory, which should contain a list of commands to ignore. Currently it doesn't support wildcards. Here's mine:

```
exit
z
ls
cd
```
