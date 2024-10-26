import os
import re
import sys

from dotenv import dotenv_values

config = dotenv_values(os.environ['FULL_ENV_FILE'])

bracket_sub_re = re.compile(r'\${(\w+)}')
basic_sub_re = re.compile(r'\$([A-Z0-9_]+)')


def sub(m):
    cfg = config.get(m.group(1), None)
    if cfg is None:
        raise Exception(f"Missing environment variable {m.group(1)}")
    return cfg


for line in sys.stdin:
    out = bracket_sub_re.sub(sub, line)
    out = basic_sub_re.sub(sub, out)
    sys.stdout.write(out)
