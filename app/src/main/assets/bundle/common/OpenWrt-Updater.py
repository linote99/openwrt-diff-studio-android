#!/usr/bin/env python3
"""Portable command line companion to OpenWrt Diff Studio / OTA updater."""
import argparse
import json
from pathlib import Path
from backend.ota_package import analyze
from backend.ota_desktop import Desktop


def main():
    p = argparse.ArgumentParser(description=__doc__)
    sub = p.add_subparsers(dest='command', required=True)
    for name in ('analyze', 'generate'):
        q = sub.add_parser(name)
        q.add_argument('old',help='Old release ZIP/folder or saved .owrt-index.json')
        q.add_argument('new',help='New complete release ZIP/folder')
        if name == 'generate':
            q.add_argument('output')
    q = sub.add_parser('update')
    q.add_argument('package')
    q.add_argument('--host', required=True)
    args = p.parse_args()
    if args.command != 'update':
        from backend.release_index import index_directory
        result = analyze(args.old, args.new, getattr(args, 'output', None), index_directory=index_directory())
    else:
        import getpass
        d = Desktop(Path(__file__).parent, lambda *_: None)
        params = dict(host=args.host, password=getpass.getpass('SSH root password: '), path=args.package)
        result = d.dispatch('ota_probe', params)
        print(json.dumps(result['check'], indent=2))
        if not result['check']['applicable']:
            raise ValueError('Device files conflict or lack space')
        if input('Apply this differential system update and retain rollback? Type yes: ') != 'yes':
            return
        result = d.dispatch('ota_apply', dict(params, token=result['token']))
    print(json.dumps(result, indent=2))


if __name__ == '__main__':
    main()
