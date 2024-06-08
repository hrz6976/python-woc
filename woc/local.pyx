# cython: language_level=3str, wraparound=False, boundscheck=False, nonecheck=False, profile=True, linetrace=True
# SPDX-License-Identifier: GPL-3.0-or-later
# @authors: Runzhi He <rzhe@pku.edu.cn>
# @date: 2024-01-17

import os
import json
import logging
import time
from libc.stdint cimport uint8_t, uint16_t, uint32_t, uint64_t
from libc.string cimport memchr, strstr, strchr, strlen, strncmp
from threading import Lock
from typing import Tuple, Dict, Iterable, List, Union, Literal, Optional
import gzip

try:
    import lzf
    assert lzf.decompress
except ImportError or AssertionError:
    raise ImportError('python-lzf is required to decompress LZF-compressed data: `pip install python-lzf`')

from .base import WocMapsBase, WocObjectsWithContent, WocSupportedProfileVersions
from .tch cimport TCHashDB

logger = logging.getLogger(__name__)

cdef extern from 'Python.h':
    object PyBytes_FromStringAndSize(char *s, Py_ssize_t len)
    
### Utility functions ###

cpdef uint32_t fnvhash(bytes data):
    """
    Returns the 32 bit FNV-1a hash value for the given data.
    >>> hex(fnvhash('foo'))
    '0xa9f37ed7'
    """
    # PY: 5.8usec Cy: 66.8ns
    cdef:
        uint32_t hval = 0x811c9dc5
        uint8_t b
    for b in data:  
        hval ^= b
        hval *= 0x01000193
    return hval

cpdef unber(bytes buf):
    r""" Perl BER unpacking.
    BER is a way to pack several variable-length ints into one
    binary string. Here we do the reverse.
    Format definition: from http://perldoc.perl.org/functions/pack.html
        (see "w" template description)

    Args:
        buf (bytes): a binary string with packed values

    Returns:
         str: a list of unpacked values

    >>> unber(b'\x00\x83M')
    [0, 461]
    >>> unber(b'\x83M\x96\x14')
    [461, 2836]
    >>> unber(b'\x99a\x89\x12')
    [3297, 1170]
    """
    # PY: 262ns, Cy: 78ns
    cdef:
        list res = []
        # blob_offset sizes are getting close to 32-bit integer max
        uint64_t acc = 0  
        uint8_t b

    for b in buf:
        acc = (acc << 7) + (b & 0x7f)
        if not b & 0x80:
            res.append(acc)
            acc = 0  
    return res

cpdef (int, int) lzf_length(bytes raw_data):
    r""" Get length of uncompressed data from a header of Compress::LZF
    output. Check Compress::LZF sources for the definition of this bit magic
        (namely, LZF.xs, decompress_sv)
        https://metacpan.org/source/MLEHMANN/Compress-LZF-3.8/LZF.xs

    Args:
        raw_data (bytes): data compressed with Perl Compress::LZF

    Returns:
         Tuple[int, int]: (header_size, uncompressed_content_length) in bytes

    >>> lzf_length(b'\xc4\x9b')
    (2, 283)
    >>> lzf_length(b'\xc3\xa4')
    (2, 228)
    >>> lzf_length(b'\xc3\x8a')
    (2, 202)
    >>> lzf_length(b'\xca\x87')
    (2, 647)
    >>> lzf_length(b'\xe1\xaf\xa9')
    (3, 7145)
    >>> lzf_length(b'\xe0\xa7\x9c')
    (3, 2524)
    """
    # PY:725us, Cy:194usec
    cdef:
        # compressed size, header length, uncompressed size
        uint32_t csize=len(raw_data), start=1, usize
        # first byte, mask, buffer iterator placeholder
        uint8_t lower=raw_data[0], mask=0x80, b

    while mask and csize > start and (lower & mask):
        mask >>= 1 + (mask == 0x80)
        start += 1
    if not mask or csize < start:
        raise ValueError('LZF compressed data header is corrupted')
    usize = lower & (mask - 1)
    for b in raw_data[1:start]:
        usize = (usize << 6) + (b & 0x3f)
    if not usize:
        raise ValueError('LZF compressed data header is corrupted')
    return start, usize

def decomp(bytes raw_data):
    # type: (bytes) -> bytes
    """ lzf wrapper to handle perl tweaks in Compress::LZF
    This function extracts uncompressed size header
    and then does usual lzf decompression.

    Args:
        raw_data (bytes): data compressed with Perl Compress::LZF

    Returns:
        str: unpacked data
    """
    if not raw_data:
        return b''
    if raw_data[0] == 0:
        return raw_data[1:]
    start, usize = lzf_length(raw_data)
    # while it is tempting to include liblzf and link statically, there is
    # zero advantage comparing to just using python-lzf
    return lzf.decompress(raw_data[start:], usize)

def decomp_or_raw(bytes raw_data):
    """ Try to decompress raw_data, return raw_data if it fails"""
    try:
        return decomp(raw_data)
    except ValueError:
        return raw_data

def slice20(bytes raw_data):
    """ Slice raw_data into 20-byte chunks and hex encode each of them
    It returns tuple in order to be cacheable
    """
    if raw_data is None:
        return ()
    return tuple(raw_data[i:i + 20] for i in range(0, len(raw_data), 20))

def decode_str(bytes raw_data, str encoding='utf-8'):
    """ Decode raw_data, detect the encoding if utf-8 fails """
    try:
        return raw_data.decode(encoding)
    except UnicodeDecodeError:
        import chardet  # should be rarely used
        _encoding = chardet.detect(raw_data)['encoding']
        return raw_data.decode(_encoding, errors='replace')


### TCH helpers ###

# Pool of open TokyoCabinet databases to save few milliseconds on opening
cdef dict _TCH_POOL = {}  # type: Dict[str, TCHashDB]
TCH_LOCK = Lock()

cpdef get_tch(char *path):
    """ Cache Hash() objects """
    if path in _TCH_POOL:
        return _TCH_POOL[path]
    try:
        TCH_LOCK.acquire()
        # in multithreading environment this can cause race condition,
        # so we need a lock
        if path not in _TCH_POOL:
            # open database in read-only mode and allow concurrent access
            _TCH_POOL[path] = TCHashDB(path, ro=True)  
    finally:
        TCH_LOCK.release()
    return _TCH_POOL[path]

cpdef uint8_t get_shard(bytes key, uint8_t sharding_bits, bint use_fnv_keys):
    """ Get shard id """
    cdef uint8_t p
    if use_fnv_keys:
        p = fnvhash(key)  
    else:
        p = key[0]
    cdef uint8_t prefix = p & (2**sharding_bits - 1)
    return prefix

cpdef bytes get_from_tch(bytes key, list shards, int sharding_bits, bint use_fnv_keys):
    """DEPRECATED"""
    # not 100% necessary but there are cases where some tchs are miserably missing
    _shard = get_shard(key, sharding_bits, use_fnv_keys)
    _path = shards[_shard]
    assert _path and os.path.exists(_path), f"shard {_shard} not found at {_path}"
    return get_tch(
        shards[get_shard(key, sharding_bits, use_fnv_keys)].encode('utf-8')
    )[key]

### deserializers ###

def decode_value(
    value: bytes,
    out_dtype: str
):
    if out_dtype == 'h':  # type: list[str]
        return [value[i:i + 20].hex() for i in range(0, len(value), 20)]
    elif out_dtype == 'sh':  # type: tuple[str, str, str]
        buf0 = value[0:len(value)-21]
        cmt_sha = value[(len(value)-20):len(value)]
        (Time, Author) = decode_str(buf0).split(";")
        return (Time, Author, cmt_sha.hex())  
    elif out_dtype == 'cs3':  # type: list[tuple[str, str, str]]
        data = decomp(value)
        _splited = decode_str(data).split(";")
        return [
            (_splited[i],_splited[i+1],_splited[i+2])
            for i in range(0, len(_splited), 3)
        ] 
    elif out_dtype == 'cs':   # type: list[str]
        data = decomp(value)
        return [decode_str(v)
            for v in data.split(b';')
            if v and v != b'EMPTY'] 
    elif out_dtype == 's':  # type: list[str]
        return [decode_str(v)
            for v in value.split(b';')]
    elif out_dtype == 'r':  # type: list[str, int]
        _hex = value[:20].hex()
        _len = unber(value[20:])[0]
        return (_hex, _len)
    elif out_dtype == 'hhwww':
        raise NotImplemented
    raise ValueError(f'Unsupported dtype: {out_dtype}')

def decode_tree(
    value: bytes
) -> List[Tuple[str, str, str]]:
    """
    Decode a tree binary object into tuples
    Python: 4.77 µs, Cython: 280 ns
    Reference: https://stackoverflow.com/questions/14790681/
        mode   (ASCII encoded decimal)
        SPACE (\0x20)
        filename
        NULL (\x00)
        20-byte binary hash
    >>> decode_tree(b'100644 .gitignore\x00\x8e\x9e\x1f...')
    [('100644', '.gitignore', '8e9e1...'), ...]
    """
    files = []

    cdef:
        const char* tree_cstr = value
        const char* end = tree_cstr + len(value)
        const char* pos = tree_cstr
        const char* mode_start
        const char* filename_start
        const char* hash_start
        uint8_t mode_len
        uint16_t filename_len  # git filenames can be 4096 chars long

    while pos < end:
        mode_start = pos
        pos = <const char*>memchr(pos, b' ', end - pos)
        if not pos:
            raise ValueError('Invalid tree object: missing space after mode')
        
        mode_len = pos - mode_start
        pos += 1  # Skip the space

        filename_start = pos
        pos = <const char*>memchr(pos, b'\x00', end - pos)
        if not pos:
            raise ValueError('Invalid tree object: missing null byte after filename')

        filename_len = pos - filename_start
        pos += 1  # Skip the null byte

        if pos + 20 > end:
            raise ValueError('Invalid tree object: missing or truncated hash')

        hash_start = pos
        pos += 20  # Skip the 20-byte hash

        files.append((
            value[mode_start - tree_cstr:mode_start - tree_cstr + mode_len].decode('ascii'),
            value[filename_start - tree_cstr:filename_start  - tree_cstr + filename_len].decode('utf-8'),
            value[hash_start  - tree_cstr :hash_start  - tree_cstr + 20].hex()
        ))

    return files

# def decode_tree(
#     value: bytes
# ) -> List[Tuple[str, str, str]]:
#     """
#     Decode a tree binary object into tuples
#     Reference: https://stackoverflow.com/questions/14790681/
#         mode   (ASCII encoded decimal)
#         SPACE (\0x20)
#         filename
#         NULL (\x00)
#         20-byte binary hash
#     """
#     _out_buf = []
#     _file_buf = []
#     _curr_buf = bytes()
    
#     # TODO: current impl is not efficient, need to optimize
#     i = 0
#     while i < len(value):
#         if value[i] == 0x20:
#             _file_buf.append(decode_str(_curr_buf))
#             _curr_buf = bytes()
#         elif value[i] == 0x00:
#             _file_buf.append(decode_str(_curr_buf))
#             # take next 20 bytes as a hash
#             _curr_buf = value[i+1:i+21]
#             _file_buf.append(_curr_buf.hex())
#             _out_buf.append(tuple(_file_buf))
#             # clear buffers
#             _file_buf = []
#             _curr_buf = bytes()
#             i += 20
#         else:
#             _curr_buf += bytes([value[i]])
#         i += 1

#     return _out_buf

cdef const char* strrchr2(const char* s, char c, const char* end):
    """Like strrchr but with a limit"""
    cdef const char* p = NULL
    while s and s < end:
        if s[0] == c:
            p = s
        s += 1
    return p

def decode_commit(
    commit_bin: bytes
) -> Tuple[str, Tuple[str, str, str], Tuple[str, str, str], str]:
    """
    Decode git commit objects into tuples
    Python: 2.35 µs, Cython: 855 ns
    Reference: https://git-scm.com/book/en/v2/Git-Internals-Git-Objects
    >>> decode_commit(b'tree f1b66dcca490b5c4455af319bc961a34f69c72c2\\n...')
    ('f1b66dcca490b5c4455af319bc961a34f69c72c2',
        ('c19ff598808b181f1ab2383ff0214520cb3ec659',),
        ('Audris Mockus <audris@utk.edu> 1410029988', '1410029988', '-0400'),
        ('Audris Mockus <audris@utk.edu>', '1410029988', '-0400'),
        'News for Sep 5, 2014\n')
    """
    cdef:
        const char* cmt_cstr = commit_bin
        const char* header
        const char* full_msg
        const char* line
        const char* next_line
        const char* key
        const char* value
        const char* timestamp
        const char* timezone
        bint is_reading_pgp = False
        int header_len
        int line_len
    
    _parent_shas = []
    _tree = ''
    _author_bytes = b''
    _author_timestamp = ''
    _author_timezone = ''
    _committer_bytes = b''
    _committer_timestamp = ''
    _committer_timezone = ''
    _encoding = 'utf-8'

    if not cmt_cstr or cmt_cstr[0] == b'\0':
        raise ValueError('Empty commit object')

    header = cmt_cstr
    full_msg = strstr(cmt_cstr, b"\n\n")
    if not full_msg:
        raise ValueError('Invalid commit object: no \\n\\n')

    header_len = full_msg - header
    full_msg += 2  # Skip the '\n\n'

    line = header
    while line < header + header_len:
        next_line = strchr(line, b'\n')
        if not next_line:
            next_line = header + header_len
        line_len = next_line - line

        if line_len == 0:
            line = next_line + 1
            continue

        key = line
        value = strchr(line, b' ')
        if not value or value >= next_line:
            line = next_line + 1
            continue
        value += 1

        if strncmp(key, "tree ", 5) == 0:
            _tree = (value[:line_len - 5]).decode('ascii')
        elif strncmp(key, "parent ", 7) == 0:
            _parent_shas.append(value[:line_len - 7].decode('ascii'))
        elif strncmp(key, "author ", 7) == 0:
            timezone = strrchr2(value, b' ', next_line)
            if not timezone:
                continue
            timestamp = strrchr2(value, b' ', timezone - 1)
            if not timestamp:
                continue
            _author_bytes = value[:timestamp - value]
            _author_timestamp = (value[timestamp - value + 1: timezone - value]).decode('ascii')
            _author_timezone = (value[timezone - value + 1: next_line - value]).decode('ascii')
        elif strncmp(key, "committer ", 10) == 0:
            timezone = strrchr2(value, b' ', next_line)
            if not timezone:
                continue
            timestamp = strrchr2(value, b' ', timezone - 1)
            if not timestamp:
                continue
            _committer_bytes = value[:timestamp - value]
            _committer_timestamp = (value[timestamp - value + 1: timezone - value]).decode('ascii')
            _committer_timezone = (value[timezone - value + 1: next_line - value]).decode('ascii')
        elif strncmp(key, "gpgsig", 6) == 0:
            is_reading_pgp = True
        elif is_reading_pgp and strncmp(line, "-----END PGP SIGNATURE-----", 27) == 0:
            is_reading_pgp = False
        elif strncmp(key, "encoding", 8) == 0:
            _encoding = value[:line_len - 8].decode('ascii')

        line = next_line + 1

    _author = decode_str(_author_bytes, _encoding)
    _committer = decode_str(_committer_bytes, _encoding)
    _message = decode_str(full_msg, _encoding)

    return (
        _tree,
        tuple(_parent_shas),
        (_author, _author_timestamp, _author_timezone),
        (_committer, _committer_timestamp, _committer_timezone),
        _message,   
    )

# def decode_commit(cmt: bytes):
#     """
#     Decode git commit objects into tuples
#     """
#     cmt = decode_str(cmt)
#     if cmt.strip() == '':
#         raise ValueError('Empty commit object')
#     try:
#         header, full_msg = cmt.split('\n\n', 1)
#     except ValueError:
#         raise ValueError('Invalid commit object: no \\n\\n')

#     tree = ''
#     parent = []
#     author, author_timestamp, author_timezone = '', '', ''
#     committer, committer_timestamp, committer_timezone = '', '', ''
#     encoding = 'utf-8'
#     # parse the header
#     _is_reading_pgp = False
#     for line in header.split('\n'):
#         line = line.strip()
#         if line.startswith('tree'):
#             tree = line[5:]
#         elif line.startswith('parent'):  # merge commits have multiple parents
#             parent.append(line[7:])
#         elif line.startswith('author'):
#             # res['author'], res['author_timestamp'], res['author_timezone'] = line[7:].rsplit(' ', 2)
#             author, timestamp, timezone = line[7:].rsplit(' ', 2)
#         elif line.startswith('committer'):
#             # res['committer'], res['committer_timestamp'], res['committer_timezone'] = line[10:].rsplit(' ', 2)
#             committer, timestamp, timezone = line[10:].rsplit(' ', 2)
#         elif line.startswith('gpgsig'):
#             _is_reading_pgp = True
#         elif _is_reading_pgp and line.strip() == '-----END PGP SIGNATURE-----':
#             _is_reading_pgp = False
#         elif line.startswith('encoding'):
#             encoding = line[8:]
        
#     return (
#         tree,
#         tuple(parent),
#         (author, author_timestamp, author_timezone),
#         (committer, committer_timestamp, committer_timezone),
#         full_msg,  
#     )

def read_large(path: str, dtype: str) -> bytes:
    """Read a *.large.* and return its content""" 
    if dtype == 'h':
        with open(path, 'rb') as f:
            f.seek(20) # 160 bits of SHA1
            return f.read()
    else:
        # use zlib to decompress
        with gzip.open(path, 'rb') as f:
            _uncompressed = f.read()
            # find first 256 bytes for b'\n', don't scan the whole document
            _idx = _uncompressed[:256].find(b'\n')
            if _idx > 0:
                return _uncompressed[_idx+1:]  # a2f
            return _uncompressed  # b2tac


class WocMapsLocal(WocMapsBase):
    def __init__(self, 
            profile_path: Union[str, Iterable[str], None] = None,
            version: Union[str, Iterable[str], None] = None
        ) -> None:
        # load profile
        if profile_path is None:
            profile_path = (
                "wocprofile.json",
                "~/.wocprofile.json",
                "/etc/wocprofile.json",
            )
        if isinstance(profile_path, str):
            profile_path = (profile_path, )

        for p in profile_path:
            _full_path = os.path.expanduser(p)
            if os.path.exists(_full_path):
                with open(_full_path) as f:
                    self.config = json.load(f)
                break
        else:
            raise FileNotFoundError("No wocprofile.json found in the following paths: {}, "
                                    "run `python3 -m woc.detect` to generate".format(profile_path))

        # check profile
        assert self.config["wocSchemaVersion"] in WocSupportedProfileVersions, \
                                    "Unsupported wocprofile version: {}".format(self.config["wocSchemaVersion"])
        assert self.config["maps"], "Run `python3 -m woc.detect` to scan data files and generate wocprofile.json"

    def _get_tch_bytes(
        self, map_name, key
    ) -> Tuple[bytes, str]:
        """
        Get value (in bytes) from tch maps, return bytes and dtype
        """
        # translate obj_name to map_name
        if map_name == 'tree':
            map_name = 'tree.tch'
        elif map_name == 'commit':
            map_name = 'commit.tch'
        elif map_name == 'blob':
            map_name = 'sha1.blob.tch'

        # find dtype object
        if map_name in self.config["maps"]:
            _map = self.config["maps"][map_name][0]
        elif map_name in self.config["objects"]:
            _map = self.config["objects"][map_name]
        else:
            raise KeyError(f'Invalid map name: {map_name}, '
                f'expect one of {", ".join(self.config["maps"].keys())}')
        
        in_dtype = _map["dtypes"][0] if "dtypes" in _map else "h"
        out_dtype = _map["dtypes"][1] if "dtypes" in _map else "c?"  # c? means maybe compressed

        start_time = time.time_ns()
        logger.debug(f"get from tch: {map_name} {key}")
    
        if in_dtype == 'h':
            if isinstance(key, str):
                hex_str = key
                key = bytes.fromhex(key)
            else:
                hex_str = bytes(key).hex()
        else:
            assert isinstance(key, str), "key must be a string for non-hash keys"
            hex_str = hex(fnvhash(key.encode('utf-8')))[2:]
            key = key.encode('utf-8')

        logger.debug(f"hash: hex={hex_str} in {(time.time_ns() - start_time) / 1e6:.2f}ms")
        start_time = time.time_ns()

        if "larges" in _map and hex_str in _map["larges"]:
            _bytes = read_large(_map["larges"][hex_str], out_dtype)
            logger.debug(f"read large: file={_map['larges'][hex_str]} in {(time.time_ns() - start_time) / 1e6:.2f}ms")
            start_time = time.time_ns()

            # compress string data is not compressed in larges
            if out_dtype == 'cs':
                out_dtype = 's'
        else:
            # use fnv hash as shading idx if key is not a git sha
            _shard = get_shard(key, _map["sharding_bits"], in_dtype != 'h')
            _path = _map["shards"][_shard]
            assert _path, f"shard {_shard} not found at {_path}"
            
            _tch = get_tch(_path.encode('utf-8'))

            # TODO: remove bb2cf quirk after fixing tch keys
            # bb2cf: keys are stored as hex strings in tch db
            if map_name == 'bb2cf':
                key = key.hex().encode('ascii')

            _bytes = _tch[key]

            logger.debug(f"get from tch: shard={_shard} db={_path} in {(time.time_ns() - start_time) / 1e6:.2f}ms")

        return _bytes, out_dtype

    def get_values(
        self,
        map_name: str,
        key: Union[bytes, str],
    ):
        """Eqivalent to getValues in WoC Perl API
        >>> self.get_values('P2c', 'user2589_minicms')
        ['05cf84081b63cda822ee407e688269b494a642de', ...]
        """
        _bytes, decode_dtype = self._get_tch_bytes(map_name, key)
        start_time = time.time_ns()
        _decoded = decode_value(_bytes, decode_dtype)
        logger.debug(f"decode: in {(time.time_ns() - start_time) / 1e6:.2f}ms")
        return _decoded

    def _get_pos(
        self,
        obj: str,
        key: Union[bytes, str]
    ) -> Tuple[int, int]:
        """
        Get offset and length of a stacked binary object, currently only support blob.
        Move out this part because it's much cheaper than decode the content.
        >>> self._get_pos('blob', bytes.fromhex('7a374e58c5b9dec5f7508391246c48b73c40d200'))
        (0, 123)
        """
        if obj == 'blob':
            r_res = unber(self._get_tch_bytes('blob', key)[0])
            assert len(r_res) == 2, f"Invalid (offset, length) pair: {r_res}"
            return r_res[0], r_res[1]
        else:
            raise ValueError(f'Unsupported object type: {obj}, expected blob')

    # def _show_content_bytes(
    #     self,
    #     obj_name: str,
    #     key: Union[bytes, str],
    # ):
    #     start_time = time.time_ns()
    #     logger.debug(f"show_content: {obj_name} {key}")

    #     if isinstance(key, str):
    #         key = bytes.fromhex(key)

    #     logger.debug(f"hash: {(time.time_ns() - start_time) / 1e6:.2f}ms")
    #     start_time = time.time_ns()

    #     if obj_name == 'tree':
    #         _map_obj = self.config['objects']['tree.tch']
    #         v = get_from_tch(key, 
    #             shards=_map_obj['shards'],
    #             sharding_bits=_map_obj['sharding_bits'],
    #             use_fnv_keys=False
    #         )
    #         logger.debug(f"get from tch: {(time.time_ns() - start_time) / 1e6:.2f}ms")
    #         return decomp_or_raw(v)

    #     elif obj_name == 'commit':
    #         _map_obj = self.config['objects']['commit.tch']
    #         v = get_from_tch(key, 
    #             shards=_map_obj['shards'],
    #             sharding_bits=_map_obj['sharding_bits'],
    #             use_fnv_keys=False
    #         )
    #         logger.debug(f"get from tch: {(time.time_ns() - start_time) / 1e6:.2f}ms")
    #         return decomp_or_raw(v)

    #     elif obj_name == 'blob':
    #         offset, length = self._get_pos('blob', key)
    #         logger.debug(f"get from tch: offset={offset} len={length} {(time.time_ns() - start_time) / 1e6:.2f}ms")
    #         start_time = time.time_ns()

    #         _map_obj = self.config['objects']['blob.bin']
    #         shard = get_shard(key, _map_obj['sharding_bits'], use_fnv_keys=False)

    #         with open(_map_obj['shards'][shard], "rb") as f:
    #             f.seek(offset)
    #             _out_bin = f.read(length)
    #         logger.debug(f"read blob: {(time.time_ns() - start_time) / 1e6:.2f}ms")
    #         start_time = time.time_ns()

    #         return decomp_or_raw(_out_bin)

    #     else:
    #         raise ValueError(f'Unsupported object type: {obj_name}')

    def show_content(
        self,
        obj_name: str,
        key: Union[bytes, str],
    ):
        """
        Eqivalent to showCnt in WoC perl API
        >>> self.show_content('tree', '7a374e58c5b9dec5f7508391246c48b73c40d200')
        [('100644', '.gitignore', '8e9e1...'), ...]
        """
        start_time = time.time_ns()

        if obj_name == 'tree':
            _ret = decode_tree(decomp_or_raw(self._get_tch_bytes(obj_name, key)[0]))
            logger.debug(f"decode tree: len={len(_ret)} in {(time.time_ns() - start_time) / 1e6:.2f}ms")
            return _ret

        elif obj_name == 'commit':
            _ret = decode_commit(decomp_or_raw(self._get_tch_bytes(obj_name, key)[0]))
            logger.debug(f"decode commit: len={len(_ret)}items in {(time.time_ns() - start_time) / 1e6:.2f}ms")
            return _ret

        elif obj_name == 'blob':
            key = bytes.fromhex(key) if isinstance(key, str) else key

            offset, length = self._get_pos('blob', key)
            logger.debug(f"decode pos: offset={offset} len={length} in {(time.time_ns() - start_time) / 1e6:.2f}ms")
            start_time = time.time_ns()

            _map_obj = self.config['objects']['blob.bin']
            shard = get_shard(key, _map_obj['sharding_bits'], use_fnv_keys=False)

            with open(_map_obj['shards'][shard], "rb") as f:
                f.seek(offset)
                _out_bin = f.read(length)
            logger.debug(f"read blob: in {(time.time_ns() - start_time) / 1e6:.2f}ms")
            start_time = time.time_ns()

            return decode_str(decomp_or_raw(_out_bin))

        elif obj_name == 'tkns':
            raise NotImplemented
        elif obj_name == 'tag':
            raise NotImplemented
        elif obj_name == 'bdiff':
            raise NotImplemented
        else:
            raise ValueError(f'Unsupported object type: {obj_name}, expected one of tree, blob, commit, tkns, tag, bdiff')