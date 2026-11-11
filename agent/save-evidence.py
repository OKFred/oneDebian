#!/usr/bin/env python3
"""Read fixed private state or save acceptance artifacts as the ordinary agent user."""
import argparse
import json
import os
from pathlib import Path
import pwd
import re
import stat
import struct
import sys
import tempfile

CONFIG = Path('/etc/onedebian-agent/config.json')
ARTIFACTS = {'screenshot':('verification.png',32 * 1024**2), 'cookie':('verification-cookie.json',4096)}


def validate(kind, data):
    if kind == 'screenshot':
        if len(data) < 24 or not data.startswith(b'\x89PNG\r\n\x1a\n') or data[12:16] != b'IHDR':
            raise ValueError('Expected a PNG screenshot')
        width,height = struct.unpack('>II',data[16:24])
        if not 0 < width <= 32768 or not 0 < height <= 32768:
            raise ValueError('Invalid screenshot dimensions')
    elif kind == 'cookie':
        document = json.loads(data)
        if (not isinstance(document,dict) or set(document) != {'boot_id','value'}
                or not isinstance(document['boot_id'],str) or not re.fullmatch(r'[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}',document['boot_id'])
                or not isinstance(document['value'],str) or not re.fullmatch(r'[a-f0-9]{64}',document['value'])):
            raise ValueError('Expected only the owned synthetic-cookie record')
    else:
        raise ValueError('Unknown acceptance artifact')


def user_directory(create=False):
    if os.geteuid() == 0:
        raise RuntimeError('Evidence must be saved by the ordinary agent user')
    metadata = CONFIG.lstat()
    if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != 0 or metadata.st_mode & 0o022:
        raise RuntimeError('Unsafe workstation configuration')
    settings = json.loads(CONFIG.read_text())
    user = pwd.getpwnam(settings['user'])
    if user.pw_uid != os.geteuid() or user.pw_dir != settings['home']:
        raise RuntimeError('Evidence writer must run as the configured agent')
    home = Path(user.pw_dir)
    directory = home / '.local/share/onedebian-agent'
    if create:
        directory.mkdir(mode=0o700,parents=True,exist_ok=True)
    metadata = directory.lstat()
    if (not stat.S_ISDIR(metadata.st_mode) or metadata.st_uid != os.geteuid()
            or metadata.st_mode & 0o077 or not directory.resolve().is_relative_to(home.resolve())):
        raise RuntimeError('Unsafe acceptance artifact directory')
    return directory


def read_state(kind):
    directory = user_directory()
    filename,limit = ('viewer-token',128) if kind == 'read-token' else ('verification-cookie.json',4096)
    try:
        descriptor = os.open(directory / filename,os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    except FileNotFoundError:
        if kind == 'read-cookie': return None
        raise
    with os.fdopen(descriptor,'rb') as stream:
        metadata = os.fstat(stream.fileno())
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_uid != os.geteuid() or metadata.st_mode & 0o077:
            raise RuntimeError('Unsafe private workstation state file')
        data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Private workstation state exceeds its size limit')
    if kind == 'read-token':
        token = data.decode('ascii').strip()
        if not re.fullmatch(r'[A-Za-z0-9_-]{43}',token):
            raise ValueError('Invalid viewer token')
        return token
    validate('cookie',data)
    return json.loads(data)


def save(kind, stream):
    directory = user_directory(create=True)
    filename,limit = ARTIFACTS[kind]
    data = stream.read(limit + 1)
    if len(data) > limit:
        raise ValueError('Acceptance artifact is too large')
    validate(kind,data)
    descriptor,temporary = tempfile.mkstemp(prefix='.evidence-',dir=directory)
    try:
        with os.fdopen(descriptor,'wb') as output:
            os.fchmod(output.fileno(),0o600)
            output.write(data)
        os.replace(temporary,directory / filename)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('kind',choices=[*ARTIFACTS,'read-token','read-cookie'])
    args = parser.parse_args()
    try:
        if args.kind in ('read-token','read-cookie'):
            result = read_state(args.kind)
            print(result if args.kind == 'read-token' else json.dumps(result))
        else:
            save(args.kind,sys.stdin.buffer)
        return 0
    except (OSError,ValueError,RuntimeError,KeyError) as error:
        print('oneDebian evidence: ' + str(error),file=sys.stderr)
        return 2


if __name__ == '__main__':
    raise SystemExit(main())
