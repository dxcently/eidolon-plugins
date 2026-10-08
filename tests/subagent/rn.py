#!/usr/bin/env python3
"""Print the text of one Rune string constant, with the Rune escapes undone.

    python3 rn.py FILE.rn NAME

A constant is `const NAME = "...";` at the start of a line. Inside the string, a backslash
followed by a backslash is one backslash, a backslash followed by a quote is a quote, a
backslash followed by n is a newline and one followed by t is a tab. Any other escape is
refused. The text is printed as it is, with no newline added. The tests use it to run the shell
that each tool sends to `sh -c`, so what they run is what ships.
"""
import sys

ESCAPES = {"\\": "\\", '"': '"', "n": "\n", "t": "\t"}


def find_body(src, name):
    head = 'const %s = "' % name
    pos = src.find(head)
    while pos != -1 and pos != 0 and src[pos - 1] != "\n":
        pos = src.find(head, pos + 1)
    if pos == -1:
        return None
    i = pos + len(head)
    start = i
    while i < len(src):
        ch = src[i]
        if ch == "\\":
            i += 2
            continue
        if ch == '"':
            return src[start:i]
        i += 1
    raise SystemExit("rn.py: the string %s is not closed" % name)


def unescape(body):
    out = []
    i = 0
    while i < len(body):
        ch = body[i]
        if ch == "\\":
            nxt = body[i + 1]
            if nxt not in ESCAPES:
                raise SystemExit("rn.py: unknown escape \\%s" % nxt)
            out.append(ESCAPES[nxt])
            i += 2
        else:
            out.append(ch)
            i += 1
    return "".join(out)


def main(argv):
    if len(argv) != 3:
        sys.stderr.write("usage: rn.py FILE.rn NAME\n")
        return 2
    with open(argv[1], encoding="utf-8") as f:
        src = f.read()
    body = find_body(src, argv[2])
    if body is None:
        sys.stderr.write("rn.py: no constant %s in %s\n" % (argv[2], argv[1]))
        return 2
    sys.stdout.write(unescape(body))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
