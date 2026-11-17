"""Append HEIF metadata while retaining encoded images and their absolute offsets.

The previous meta box becomes free space of exactly the same size. A new meta
box describes the unchanged image extents and an appended XMP item. Construction
method 1 extents remain relative to the copied idat box. External data references
and construction method 2 are deliberately rejected.
"""
import struct
from .exceptions import ProtocolError

LIMIT = 16 * 1024 * 1024


def invalid():
    raise ProtocolError('MOTION_METADATA_UNSUPPORTED')


def box(kind, data):
    if len(data) + 8 > 0xffffffff:
        invalid()
    return struct.pack('>I4s', len(data) + 8, kind) + bytes(data)


def boxes(data, start=0):
    result = []
    while start < len(data):
        if len(data) - start < 8 or len(result) >= 65535:
            invalid()
        size, kind = struct.unpack_from('>I4s', data, start)
        header = 8
        if size == 1:
            if len(data) - start < 16:
                invalid()
            size = struct.unpack_from('>Q', data, start + 8)[0]
            header = 16
        elif size == 0:
            size = len(data) - start
        if size < header or size > len(data) - start:
            invalid()
        result.append((kind, data[start + header:start + size], data[start:start + size]))
        start += size
    return result


class Reader:
    def __init__(self, data):
        self.data, self.at = data, 0

    def number(self, size):
        if not 0 <= size <= 8 or self.at + size > len(self.data):
            invalid()
        value = int.from_bytes(self.data[self.at:self.at + size], 'big')
        self.at += size
        return value


def locations(data):
    reader = Reader(data)
    version, flags = reader.number(1), reader.number(3)
    if version not in (0, 1, 2) or flags:
        invalid()
    sizes, bases = reader.number(1), reader.number(1)
    offset_size, length_size = sizes >> 4, sizes & 15
    base_size, index_size = bases >> 4, (bases & 15) if version else 0
    count = reader.number(4 if version == 2 else 2)
    if count > 65535:
        invalid()
    entries = {}
    for _ in range(count):
        identifier = reader.number(4 if version == 2 else 2)
        method = reader.number(2) if version else 0
        reference, base = reader.number(2), reader.number(base_size)
        extent_count = reader.number(2)
        if method not in (0, 1) or reference or identifier in entries:
            invalid()
        extents = [(reader.number(index_size), reader.number(offset_size), reader.number(length_size))
                   for _ in range(extent_count)]
        entries[identifier] = (method, base, extents)
    if reader.at != len(data):
        invalid()
    return entries


def encode_locations(entries):
    data = bytearray(b'\x02\x00\x00\x00\x88\x88' + struct.pack('>I', len(entries)))
    for identifier, (method, base, extents) in entries.items():
        data.extend(struct.pack('>IHHQH', identifier, method, 0, base, len(extents)))
        for index, offset, length in extents:
            data.extend(struct.pack('>QQQ', index, offset, length))
    return box(b'iloc', data)


class HeifMetadata:
    def __init__(self, source, allow_motion=False):
        self.source = source
        source.seek(0, 2)
        self.length = source.tell()
        self.meta_at = None
        self.zero_sizes = []
        self.motion = None
        at = 0
        count = 0
        found_brand = False
        while at < self.length:
            count += 1
            if count > 65535:
                invalid()
            source.seek(at)
            raw = source.read(8)
            if len(raw) != 8:
                invalid()
            size, kind = struct.unpack('>I4s', raw)
            header = 8
            if size == 1:
                raw = source.read(8)
                if len(raw) != 8:
                    invalid()
                size, header = struct.unpack('>Q', raw)[0], 16
            elif size == 0:
                size = self.length - at
                if size > 0xffffffff:
                    invalid()
                self.zero_sizes.append((at, size))
            if size < header or size > self.length - at:
                invalid()
            if kind == b'ftyp':
                if size > 4096:
                    invalid()
                brands = source.read(size - header)
                found_brand = any(brands[index:index + 4] in (b'heic', b'heix', b'hevc', b'hevx')
                                  for index in [0] + list(range(8, len(brands), 4)))
            if kind == b'mpvd':
                if not allow_motion or self.motion is not None or header != 8 or size != self.length - at or (at, size) in self.zero_sizes:
                    invalid()
                self.motion = (at + header, size - header)
            if kind == b'meta':
                if self.meta_at is not None or size - header > LIMIT:
                    invalid()
                self.meta_at = at
                metadata = source.read(size - header)
                if metadata[:4] != b'\x00\x00\x00\x00':
                    invalid()
                self.children = boxes(metadata, 4)
            at += size
        if not found_brand or self.meta_at is None:
            invalid()
        grouped = {}
        for kind, data, raw in self.children:
            grouped.setdefault(kind, []).append(data)
        if any(len(grouped.get(kind, [])) != 1 for kind in (b'pitm', b'iinf', b'iloc')):
            invalid()
        primary = Reader(grouped[b'pitm'][0])
        version, flags = primary.number(1), primary.number(3)
        if version not in (0, 1) or flags:
            invalid()
        self.primary = primary.number(4 if version else 2)
        self.entries = locations(grouped[b'iloc'][0])
        iinf = grouped[b'iinf'][0]
        reader = Reader(iinf)
        version, flags = reader.number(1), reader.number(3)
        if version not in (0, 1) or flags:
            invalid()
        expected = reader.number(2 if version == 0 else 4)
        self.info = boxes(iinf, reader.at)
        if expected != len(self.info):
            invalid()
        self.ids = set(self.entries) | {self.primary}
        self.xmp_id = None
        for kind, data, raw in self.info:
            if kind != b'infe' or len(data) < 8 or data[0] not in (0, 1, 2, 3):
                invalid()
            width = 4 if data[0] == 3 else 2
            identifier = int.from_bytes(data[4:4 + width], 'big')
            self.ids.add(identifier)
            fields = None
            if data[0] <= 1:
                fields = data[8:].split(b'\x00')
            elif data[6 + width:10 + width] == b'mime':
                fields = data[10 + width:].split(b'\x00')
            if fields is not None:
                if len(fields) >= 2 and fields[1] == b'application/rdf+xml':
                    if self.xmp_id is not None:
                        invalid()
                    self.xmp_id = identifier
        self.references = []
        for iref in grouped.get(b'iref', []):
            if len(iref) < 4 or iref[0] not in (0, 1) or iref[1:4] != b'\x00\x00\x00':
                invalid()
            width = 4 if iref[0] else 2
            for kind, data, raw in boxes(iref, 4):
                reader = Reader(data)
                origin, count = reader.number(width), reader.number(2)
                targets = [reader.number(width) for _ in range(count)]
                if reader.at != len(data):
                    invalid()
                self.ids.update([origin] + targets)
                self.references.append((kind, origin, targets))
        self.idat = grouped.get(b'idat', [b''])[0]
        if len(grouped.get(b'idat', [])) > 1:
            invalid()

    def xmp(self):
        if self.xmp_id is None:
            return b''
        if self.xmp_id not in self.entries:
            invalid()
        method, base, extents = self.entries[self.xmp_id]
        output = bytearray()
        for index, offset, length in extents:
            if index or length == 0 or len(output) + length > LIMIT:
                invalid()
            start = base + offset
            if method == 1:
                if start + length > len(self.idat):
                    invalid()
                output.extend(self.idat[start:start + length])
            else:
                if start + length > self.length:
                    invalid()
                self.source.seek(start)
                output.extend(self.source.read(length))
        return bytes(output)

    def replace_xmp(self, packet):
        identifier = self.xmp_id
        info = b''.join(raw for _, _, raw in self.info)
        count = len(self.info)
        if identifier is None:
            identifier = max(self.ids) + 1
            if identifier > 0xffffffff or count >= 65535:
                invalid()
            info += box(b'infe', b'\x03\x00\x00\x00' + struct.pack('>IH', identifier, 0)
                        + b'mimeMotionPhoto\x00application/rdf+xml\x00\x00')
            count += 1
        self.entries[identifier] = (0, 0, [(0, self.length + 8, len(packet))])
        references = list(self.references)
        if not any(kind == b'cdsc' and origin == identifier and self.primary in targets
                   for kind, origin, targets in references):
            references.append((b'cdsc', identifier, [self.primary]))
        encoded_refs = b''.join(box(kind, struct.pack('>IH', origin, len(targets))
                                   + b''.join(struct.pack('>I', target) for target in targets))
                                for kind, origin, targets in references)
        children = b''.join(raw for kind, data, raw in self.children if kind not in (b'iinf', b'iloc', b'iref'))
        children += box(b'iinf', b'\x01\x00\x00\x00' + struct.pack('>I', count) + info)
        children += encode_locations(self.entries)
        children += box(b'iref', b'\x01\x00\x00\x00' + encoded_refs)
        return box(b'mdat', packet) + box(b'meta', b'\x00\x00\x00\x00' + children)
