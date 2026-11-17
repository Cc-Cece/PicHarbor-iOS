"""Read explicit Apple pairing metadata; filenames and timestamps are not proof."""
import re
import struct

UUID = re.compile(rb'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}')

def _identifier(value):
    value = value.strip(b'\x00 \r\n')
    return value.decode('ascii').lower() if UUID.fullmatch(value) else None

def apple_photo_id(data):
    if not isinstance(data, bytes):
        return None
    xmp = re.search(rb'(?:ContentIdentifier["\s]*=\s*["\x27]|ContentIdentifier>)([0-9a-fA-F-]{36})', data)
    if xmp:
        return _identifier(xmp[1])
    start = data.find(b'Apple iOS\x00')
    if start < 0 or len(data) < start + 16:
        return None
    note = data[start:]
    order = '>' if note[12:14] == b'MM' else '<' if note[12:14] == b'II' else None
    if order is None:
        return None
    try:
        count = struct.unpack_from(order+'H', note, 14)[0]
        if count > 1024:
            return None
        for index in range(count):
            tag, kind, length, offset = struct.unpack_from(order+'HHII', note, 16+12*index)
            if tag == 17 and kind in (2, 7) and 36 <= length <= 128 and offset+length <= len(note):
                return _identifier(note[offset:offset+length])
    except (struct.error, UnicodeDecodeError):
        return None
    return None

def _atoms(stream, start, end):
    at=start
    while at+8<=end:
        stream.seek(at);raw=stream.read(8)
        if len(raw)!=8:
            return
        size,kind=struct.unpack('>I4s',raw);header=8
        if size==1:
            raw=stream.read(8)
            if len(raw)!=8:return
            size=struct.unpack('>Q',raw)[0];header=16
        if size==0:size=end-at
        if size<header or at+size>end:return
        yield kind,at+header,at+size
        at+=size

def apple_video_id(stream):
    """Walk metadata atoms without reading the video payload into memory."""
    stream.seek(0,2);length=stream.tell()
    def walk(start,end,depth=0):
        if depth>6:return None
        for kind,body,stop in _atoms(stream,start,end):
            if kind in (b'moov',b'udta'):
                found=walk(body,stop,depth+1)
                if found:return found
            if kind!=b'meta':continue
            children=list(_atoms(stream,body+4,stop))
            keys=[]
            for child,begin,finish in children:
                if child==b'keys' and finish-begin<1024*1024:
                    stream.seek(begin);payload=stream.read(finish-begin)
                    if len(payload)<8:continue
                    count=struct.unpack_from('>I',payload,4)[0];at=8
                    if count>4096:continue
                    for _ in range(count):
                        if at+8>len(payload):break
                        size=struct.unpack_from('>I',payload,at)[0]
                        if size<8 or at+size>len(payload):break
                        keys.append(payload[at+8:at+size]);at+=size
            for child,begin,finish in children:
                if child!=b'ilst':continue
                for index,value_start,value_end in _atoms(stream,begin,finish):
                    key_index=int.from_bytes(index,'big')-1
                    if not 0<=key_index<len(keys) or keys[key_index]!=b'com.apple.quicktime.content.identifier':continue
                    for field,a,b in _atoms(stream,value_start,value_end):
                        if field==b'data' and 8<=b-a<=256:
                            stream.seek(a+8);return _identifier(stream.read(b-a-8))
        return None
    return walk(0,length)

def apple_id(path,video=False):
    try:
        with open(path,'rb') as stream:
            return apple_video_id(stream) if video else apple_photo_id(stream.read(1024*1024))
    except (OSError,ValueError,struct.error):
        return None
