"""Lossless JPEG Motion Photo packaging with an explicit source keyframe time."""
from pathlib import Path
import shutil
import struct
import re
import xml.etree.ElementTree as ET
from .exceptions import ProtocolError


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
