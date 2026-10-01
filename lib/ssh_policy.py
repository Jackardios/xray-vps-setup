#!/usr/bin/env python3
"""Reject authentication overrides in Match blocks, including nested Includes."""
import glob
from pathlib import Path
import re
import shlex
import sys

AUTH = {'passwordauthentication', 'kbdinteractiveauthentication', 'challengeresponseauthentication', 'permitrootlogin'}


def check(path, matched=False, parents=()):
    path = Path(path).resolve()
    if path in parents or len(parents) >= 16:
        raise ValueError('Recursive SSH Include: ' + str(path))
    for number, line in enumerate(path.read_text().splitlines(), 1):
        # OpenSSH also accepts '=' between a keyword and its value.
        line = re.sub(r'^(\s*\w+)\s*=\s*', r'\1 ', line)
        fields = shlex.split(line, comments=True)
        if not fields:
            continue
        keyword = fields[0].lower()
        if keyword == 'match':
            matched = True
        elif keyword == 'include':
            for pattern in fields[1:]:
                pattern = str(Path('/etc/ssh') / pattern) if not Path(pattern).is_absolute() else pattern
                for included in sorted(glob.glob(pattern)):
                    matched = check(included, matched, parents + (path,))
        elif matched and keyword in AUTH and [value.lower() for value in fields[1:]] != ['no']:
            raise ValueError(f'{path}:{number}: Match overrides {fields[0]}; resolve it before confirming SSH')
    return matched


if __name__ == '__main__':
    try:
        check(sys.argv[1])
    except (OSError, ValueError) as error:
        raise SystemExit('ERROR: ' + str(error))
