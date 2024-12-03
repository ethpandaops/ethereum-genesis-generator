# This script substitutes environment variables in input lines using values from two .env files.
import os
import re
import sys
import json

from dotenv import dotenv_values

# Load default and full environment variables from specified files
defaults = dotenv_values(os.environ['DEFAULT_ENV_FILE'])
config = dotenv_values(os.environ['FULL_ENV_FILE'])

# Also check actual environment variables
env_vars = os.environ

# These regular expressions are used to identify and match environment variable patterns in the input text.
# The updated regex matches variables enclosed in either curly braces or square brackets.
# It captures nested structures as well, allowing for more complex variable patterns.
bracket_sub_re = re.compile(r'\$\{([A-Z0-9_]+)\}')
basic_sub_re = re.compile(r'\$([A-Z0-9_]+)')

def sub(m):
    # Get variable name from match
    var_name = m.group(1)
    
    # Try env vars first, then defaults, then config
    cfg = env_vars.get(var_name)
    if cfg is None:
        cfg = config.get(var_name)
    if cfg is None:
        cfg = defaults.get(var_name)
    
    if cfg is None:
        raise Exception(f"Missing environment variable: {var_name}")
    
    return cfg

# Read from standard input line by line
for line in sys.stdin:
    out = bracket_sub_re.sub(sub, line)  # Substitute bracketed variables
    out = basic_sub_re.sub(sub, out)  # Substitute basic variables
    sys.stdout.write(out)  # Output the final substituted line