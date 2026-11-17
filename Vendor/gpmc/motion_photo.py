"""Lossless JPEG/HEIC motion packaging with an explicit source keyframe time."""
from pathlib import Path
import shutil
import struct
import re
import xml.etree.ElementTree as ET
from .exceptions import ProtocolError


def motion_format(path):
    with open(path, 'rb') as source:
        header = source.read(4096)
    if header[:2] == b'\xff\xd8':
        return 'jpg'
    if len(header) >= 16 and header[4:8] == b'ftyp':
        length = int.from_bytes(header[:4], 'big')
        if 16 <= length <= len(header) and any(header[at:at + 4] in (b'heic', b'heix', b'hevc', b'hevx')
                                             for at in [8] + list(range(16, length, 4))):
            return 'heic'
    raise ProtocolError('MOTION_FORMAT_UNSUPPORTED')


def _video_mime(path):
    with open(path, 'rb') as source:
        header = source.read(12)
    return 'video/mp4' if header[4:8] == b'ftyp' and header[8:12] != b'qt  ' else 'video/quicktime'


def _packet(keyframe_us, length, mime, padding, video_mime):
    return (f'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
        f'<rdf:Description xmlns:Camera="http://ns.google.com/photos/1.0/camera/" '
        f'xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
        f'Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="{keyframe_us}">'
        f'<Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="{mime}" Item:Semantic="Primary" Item:Padding="{padding}"/></rdf:li>'
        f'<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="{video_mime}" Item:Semantic="MotionPhoto" Item:Length="{length}"/></rdf:li>'
        f'</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>').encode()


def _merge_xmp(existing, addition):
    camera = '{http://ns.google.com/photos/1.0/camera/}'
    container = '{http://ns.google.com/photos/1.0/container/}'
    item = '{http://ns.google.com/photos/1.0/container/item/}'
    rdf = '{http://www.w3.org/1999/02/22-rdf-syntax-ns#}'
    if not existing:
        return addition
    if b'<!DOCTYPE' in existing or b'<!ENTITY' in existing:
        raise ProtocolError('MOTION_METADATA_UNSUPPORTED')
    try:
        root = ET.fromstring(existing.strip(b'\x00 \r\n'))
        target = next(root.iter(rdf + 'RDF'), None)
        if target is None:
            raise ProtocolError('MOTION_METADATA_UNSUPPORTED')
        for parent in root.iter():
            for key in list(parent.attrib):
                if key.startswith(camera) and key[len(camera):].startswith(('MotionPhoto', 'MicroVideo')):
                    del parent.attrib[key]
            for child in list(parent):
                if child.tag == container + 'Directory':
                    # Unknown extra container resources need their own offset rules.
                    if any(node.attrib.get(item + 'Semantic') not in (None, 'Primary', 'MotionPhoto') for node in child.iter()):
                        raise ProtocolError('MOTION_METADATA_UNSUPPORTED')
                    parent.remove(child)
                elif child.tag.startswith(camera) and child.tag[len(camera):].startswith(('MotionPhoto', 'MicroVideo')):
                    parent.remove(child)
        target.append(ET.fromstring(addition).find(rdf + 'RDF/' + rdf + 'Description'))
        return ET.tostring(root, encoding='utf-8')
    except ET.ParseError:
        raise ProtocolError('MOTION_METADATA_UNSUPPORTED') from None


def mux_heic(photo, video, destination, keyframe_us):
    from .heif_metadata import HeifMetadata
    if type(keyframe_us) is not int or keyframe_us < 0:
        raise ProtocolError('LIVE_KEYFRAME_MISSING')
    photo, video, destination = map(Path, (photo, video, destination))
    length = video.stat().st_size
    if not 0 < length <= 0xffffffff - 8:
        raise ProtocolError('MOTION_FORMAT_UNSUPPORTED')
    video_mime = _video_mime(video)
    with photo.open('rb') as source:
        metadata = HeifMetadata(source)
        packet = _merge_xmp(metadata.xmp(), _packet(keyframe_us, length, 'image/heic', 8, video_mime))
        additions = metadata.replace_xmp(packet)
        with destination.open('xb') as output:
            source.seek(0)
            shutil.copyfileobj(source, output, 1024 * 1024)
            if output.tell() != metadata.length:
                raise ProtocolError('SOURCE_CHANGED')
            for at, size in metadata.zero_sizes:
                output.seek(at)
                output.write(struct.pack('>I', size))
            output.seek(metadata.meta_at + 4)
            output.write(b'free')
            output.seek(0, 2)
            output.write(additions)
            output.write(struct.pack('>I4s', length + 8, b'mpvd'))
            with video.open('rb') as movie:
                start = output.tell()
                shutil.copyfileobj(movie, output, 1024 * 1024)
                if output.tell() - start != length:
                    raise ProtocolError('SOURCE_CHANGED')
    return destination


def mux_motion(photo, video, destination, keyframe_us):
    return (mux_jpeg if motion_format(photo) == 'jpg' else mux_heic)(photo, video, destination, keyframe_us)


def has_embedded_motion(path):
    """Recognize a declared JPEG motion resource only when its offset is valid.

    Container rules: https://developer.android.com/media/platform/motion-photo-format
    No filename or timestamp inference, and no video payload is loaded into memory.
    """
    try:
        with open(path, 'rb') as source:
            if source.read(2) != b'\xff\xd8':
                return False
            source.seek(0)
            prefix = source.read(1024 * 1024)
            packet = re.search(rb'<(?:[A-Za-z_][\w.-]*:)?xmpmeta\b.*?</(?:[A-Za-z_][\w.-]*:)?xmpmeta\s*>', prefix, re.DOTALL)
            if not packet or b'<!DOCTYPE' in packet[0] or b'<!ENTITY' in packet[0]:
                return False
            root = ET.fromstring(packet[0])
            enabled = False
            lengths = set()
            camera = '{http://ns.google.com/photos/1.0/camera/}'
            item = '{http://ns.google.com/photos/1.0/container/item/}'
            for node in root.iter():
                attributes = node.attrib
                enabled = enabled or attributes.get(camera + 'MotionPhoto') == '1' or attributes.get(camera + 'MicroVideo') == '1'
                legacy = attributes.get(camera + 'MicroVideoOffset')
                length = attributes.get(item + 'Length') if attributes.get(item + 'Semantic') == 'MotionPhoto' else None
                for value in (legacy, length):
                    if value is not None and re.fullmatch(r'[0-9]{1,20}', value):
                        lengths.add(int(value))
            if not enabled or len(lengths) != 1:
                return False
            length = lengths.pop()
            source.seek(0, 2)
            total = source.tell()
            if length < 16 or length > total - 2:
                return False
            source.seek(total - length)
            header = source.read(12)
            size, kind = struct.unpack('>I4s', header[:8])
            return kind == b'ftyp' and 12 <= size <= length
    except (OSError, ValueError, struct.error, ET.ParseError):
        return False

def mux_jpeg(photo, video, destination, keyframe_us):
    if type(keyframe_us) is not int or keyframe_us < 0:
        raise ProtocolError('LIVE_KEYFRAME_MISSING')
    photo, video, destination = map(Path, (photo, video, destination))
    length = video.stat().st_size
    if length <= 0:
        raise ProtocolError('FILE_ACCESS')
    with photo.open('rb') as source:
        if source.read(2) != b'\xff\xd8':
            raise ProtocolError('MOTION_FORMAT_UNSUPPORTED')
        packet = (f'<x:xmpmeta xmlns:x="adobe:ns:meta/"><rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">'
            f'<rdf:Description xmlns:Camera="http://ns.google.com/photos/1.0/camera/" xmlns:GCamera="http://ns.google.com/photos/1.0/camera/" '
            f'xmlns:Container="http://ns.google.com/photos/1.0/container/" xmlns:Item="http://ns.google.com/photos/1.0/container/item/" '
            f'Camera:MotionPhoto="1" Camera:MotionPhotoVersion="1" Camera:MotionPhotoPresentationTimestampUs="{keyframe_us}" '
            f'GCamera:MicroVideo="1" GCamera:MicroVideoVersion="1" GCamera:MicroVideoOffset="{length}" GCamera:MicroVideoPresentationTimestampUs="{keyframe_us}">'
            f'<Container:Directory><rdf:Seq><rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="image/jpeg" Item:Semantic="Primary" Item:Padding="0"/></rdf:li>'
            f'<rdf:li rdf:parseType="Resource"><Container:Item Item:Mime="video/quicktime" Item:Semantic="MotionPhoto" Item:Length="{length}"/></rdf:li>'
            f'</rdf:Seq></Container:Directory></rdf:Description></rdf:RDF></x:xmpmeta>').encode()
        payload = b'http://ns.adobe.com/xap/1.0/\x00' + packet
        with destination.open('xb') as output:
            output.write(b'\xff\xd8\xff\xe1'+struct.pack('>H',len(payload)+2)+payload)
            shutil.copyfileobj(source,output,1024*1024)
            with video.open('rb') as movie:shutil.copyfileobj(movie,output,1024*1024)
    return destination
