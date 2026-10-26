"""Portable, content-checked release baselines; contains no payload or device data."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys
import tempfile
from types import SimpleNamespace

from .ota_engine import canonical, safe_name, validate_descriptor

FORMAT = 'openwrt-release-index'
SUFFIX = '.owrt-index.json'
MAX_SIZE = 64 << 20


def index_directory():
    if sys.platform == 'darwin':
        base = Path.home()/'Library/Application Support'
    else:
        base = Path(os.environ.get('LOCALAPPDATA', Path.home()/'.local/share'))
    return base/'OpenWrt-Installer/release-indexes'


def validate(data):
    if not isinstance(data, dict) or set(data) != {'format','version','sha256','release'} or data.get('format') != FORMAT or type(data.get('version')) is not int or data['version'] != 1:
        raise ValueError('Unsupported release index / 不支持的版本摘要格式')
    release = data['release']
    if not isinstance(release, dict) or set(release) != {'family','meta','entries','packages','boot_digest'}:
        raise ValueError('Incomplete release index / 版本摘要不完整')
    if data['sha256'] != hashlib.sha256(canonical(release)).hexdigest():
        raise ValueError('Release index checksum mismatch / 版本摘要校验失败')
    if release['family'] not in ('e5','mu300'):
        raise ValueError('Invalid release index family')
    meta = release['meta']
    if not isinstance(meta, dict) or set(meta) != {'profile','image_version','kernel_release','openwrt'} or any(not isinstance(v,str) or not v or len(v)>256 or any(ord(c)<32 for c in v) for v in meta.values()):
        raise ValueError('Invalid release index identity')
    if not re.fullmatch(r'[a-z0-9][a-z0-9_-]{0,63}',meta['profile']) or not isinstance(release['boot_digest'],str) or not re.fullmatch('[a-f0-9]{64}',release['boot_digest']):
        raise ValueError('Invalid release index profile/boot hash')
    entries = release['entries']
    if not isinstance(entries,dict) or not entries or len(entries)>250000:
        raise ValueError('Invalid release index file table')
    for name, desc in entries.items():
        if not isinstance(name,str):raise ValueError('Invalid release index path')
        safe_name(name)
        if not isinstance(desc,dict) or not isinstance(desc.get('xattrs',{}),dict) or set(desc)-{'kind','mode','uid','gid','size','sha256','target','xattrs'}:
            raise ValueError('Invalid release index descriptor')
        validate_descriptor(desc)
    packages = release['packages']
    if not isinstance(packages,dict) or any(not isinstance(k,str) or not k or len(k)>256 or not isinstance(v,dict)
            or set(v)!={'V','A','D'} or any(not isinstance(s,str) or len(s)>65536 for s in v.values()) for k,v in packages.items()):
        raise ValueError('Invalid release index packages')
    return data


def snapshot(release):
    body = dict(family=release.family,meta={k:release.meta[k] for k in ('profile','image_version','kernel_release','openwrt')},
                entries=release.entries,packages=release.packages,boot_digest=release.boot_digest)
    return validate(dict(format=FORMAT,version=1,sha256=hashlib.sha256(canonical(body)).hexdigest(),release=body))


def _unique(pairs):
    result = {}
    for key,value in pairs:
        if key in result:raise ValueError('Duplicate release index key / 版本摘要存在重复字段')
        result[key] = value
    return result


def read_index(path):
    with Path(path).open('rb') as stream:
        raw = stream.read(MAX_SIZE+1)
    if len(raw)>MAX_SIZE:raise ValueError('Release index exceeds 64 MiB')
    try:
        return validate(json.loads(raw,object_pairs_hook=_unique))
    except (TypeError,AttributeError,UnicodeError,RecursionError) as error:
        raise ValueError('Invalid release index / 版本摘要损坏') from error


def load_index(path):
    data = read_index(path)
    return SimpleNamespace(source=Path(path),**data['release'])


def write_index(path,data,reuse=False):
    validate(data)
    path = Path(path)
    raw = canonical(data)+b'\n'
    if len(raw)>MAX_SIZE:raise ValueError('Release index exceeds 64 MiB')
    path.parent.mkdir(parents=True,exist_ok=True)
    if os.path.lexists(path):
        if reuse and read_index(path)==data:return path
        raise ValueError('Release index destination already exists / 版本摘要目标文件已存在: '+str(path))
    fd,temp = tempfile.mkstemp(prefix='.release-index-',dir=path.parent)
    try:
        with os.fdopen(fd,'wb') as stream:
            stream.write(raw);stream.flush();os.fsync(stream.fileno())
        os.replace(temp,path)
        if os.name != 'nt':
            directory = os.open(path.parent,os.O_RDONLY | os.O_DIRECTORY)
            try:os.fsync(directory)
            finally:os.close(directory)
    finally:
        if os.path.exists(temp):os.unlink(temp)
    return path


def save_index(release,directory):
    data = snapshot(release)
    label = re.sub('[^A-Za-z0-9._-]','_',release.meta['image_version'])[:100]
    path = Path(directory)/('OpenWrt-'+label+'-'+data['sha256']+SUFFIX)
    return write_index(path,data,reuse=True)
